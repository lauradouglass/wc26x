-- ============================================================================
-- WC26-X — MATCHING ENGINE
-- All trade-creating logic. Functions are SECURITY DEFINER so they bypass
-- RLS and can write to orders/fills/positions/ledger, but they enforce
-- authorization themselves by checking auth.uid().
--
-- Design notes:
--   -  take a row-level lock on every resting order we touch using FOR UPDATE.
--   -  lock the market row itself first (FOR UPDATE) to serialize concurrent
--     orders on the same market. This is the "matching engine mutex" — without
--     it, two simultaneous takers could both consume the same maker.
--   - All cash math is in bigint cents. No floats.
--   - place_order is idempotent w.r.t. failure: any thrown exception rolls
--     the whole txn back, including reserved cash.
--   - The 500-share-per-order cap is enforced in SQL.
-- ============================================================================


-- Helper: get current authenticated user id, or raise
create or replace function public._auth_uid()
returns uuid language sql stable as $$
  select auth.uid()
$$;


-- ============================================================================
-- _update_position_on_fill
--   Apply a fill to a user's position. Mutates positions + users (realized).
--   Returns the realized PnL delta in cents (signed).
--
--   Convention reminder:
--     side_eff = +1  →  long YES (BUY took asks)
--     side_eff = -1  →  short YES (SELL took bids; = long NO)
-- ============================================================================
create or replace function public._update_position_on_fill(
  p_user_id    uuid,
  p_market_id  text,
  p_side_eff   smallint,       -- +1 or -1
  p_qty        integer,
  p_price_c    smallint        -- fill price in cents (1..99)
) returns bigint
language plpgsql
as $$
declare
  v_pos             public.positions%rowtype;
  v_old_shares      integer := 0;
  v_old_avg         numeric(10,4) := 0;
  v_new_shares      integer;
  v_d_shares        integer := p_side_eff * p_qty;
  v_realized_cents  bigint := 0;
  v_closing_qty     integer;
  v_remain_open     integer;
begin
  -- Lock the position row if it exists (or create implicitly via upsert)
  select * into v_pos from public.positions
   where user_id = p_user_id and market_id = p_market_id
   for update;

  if found then
    v_old_shares := v_pos.shares;
    v_old_avg    := v_pos.avg_cost_c;
  end if;

  v_new_shares := v_old_shares + v_d_shares;

  if v_old_shares = 0 or sign(v_old_shares) = sign(v_d_shares) then
    -- Same direction: weighted-avg cost basis on absolute shares
    declare
      v_old_notional numeric := abs(v_old_shares) * v_old_avg;
      v_add_notional numeric := p_qty * p_price_c;
    begin
      if abs(v_new_shares) > 0 then
        v_old_avg := (v_old_notional + v_add_notional) / abs(v_new_shares);
      else
        v_old_avg := 0;
      end if;
    end;
  else
    -- Reducing or flipping
    v_closing_qty := least(abs(v_old_shares), p_qty);

    if v_old_shares > 0 then
      -- Were long YES, now selling → realized = (sell - avgCost) * closingQty (cents)
      v_realized_cents := round((p_price_c - v_old_avg) * v_closing_qty)::bigint;
    else
      -- Were short YES, now buying back → realized = (avgCost - buy) * closingQty
      v_realized_cents := round((v_old_avg - p_price_c) * v_closing_qty)::bigint;
    end if;

    v_remain_open := p_qty - v_closing_qty;

    if abs(v_new_shares) = 0 then
      v_old_avg := 0;
    elsif v_remain_open > 0 then
      -- Flipped: leftover opens fresh at current price
      v_old_avg := p_price_c;
    end if;
    -- else: just reduced, avgCost unchanged on remaining
  end if;

  -- Persist
  if v_new_shares = 0 then
    delete from public.positions
     where user_id = p_user_id and market_id = p_market_id;
  else
    insert into public.positions (user_id, market_id, shares, avg_cost_c, updated_at)
    values (p_user_id, p_market_id, v_new_shares, v_old_avg, now())
    on conflict (user_id, market_id) do update
      set shares     = excluded.shares,
          avg_cost_c = excluded.avg_cost_c,
          updated_at = now();
  end if;

  -- Apply realized to users.realized_c
  if v_realized_cents <> 0 then
    update public.users
       set realized_c = realized_c + v_realized_cents
     where id = p_user_id;
  end if;

  return v_realized_cents;
end $$;


-- ============================================================================
-- _ledger_insert
--   Append a row to the ledger and bump users.bankroll_c atomically.
--   Returns the new balance.
-- ============================================================================
create or replace function public._ledger_insert(
  p_user_id    uuid,
  p_kind       ledger_kind,
  p_ref_id     text,
  p_delta_c    bigint,
  p_realized_c bigint,
  p_notes      jsonb default null
) returns bigint
language plpgsql
as $$
declare
  v_bal bigint;
begin
  -- Lock user row for balance update
  select bankroll_c into v_bal from public.users
   where id = p_user_id
   for update;

  if not found then
    raise exception 'ledger_insert: user % not found', p_user_id;
  end if;

  v_bal := v_bal + p_delta_c;

  if v_bal < 0 then
    raise exception 'INSUFFICIENT_BANKROLL: user % balance would go negative (%, delta %)',
      p_user_id, v_bal - p_delta_c, p_delta_c;
  end if;

  update public.users set bankroll_c = v_bal where id = p_user_id;

  insert into public.ledger (user_id, kind, ref_id, delta_c, realized_delta_c, balance_after_c, notes)
  values (p_user_id, p_kind, p_ref_id, p_delta_c, p_realized_c, v_bal, p_notes);

  return v_bal;
end $$;


-- ============================================================================
-- _refresh_market_book
--   Recompute best_bid / best_ask on a market after a change.
-- ============================================================================
create or replace function public._refresh_market_book(p_market_id text)
returns void language plpgsql as $$
declare
  v_best_bid smallint;
  v_best_ask smallint;
begin
  select max(limit_px) into v_best_bid from public.orders
   where market_id = p_market_id and side = 'BUY'
     and status in ('OPEN','PARTIAL') and remaining_qty > 0;

  select min(limit_px) into v_best_ask from public.orders
   where market_id = p_market_id and side = 'SELL'
     and status in ('OPEN','PARTIAL') and remaining_qty > 0;

  update public.markets
     set best_bid = v_best_bid,
         best_ask = v_best_ask
   where id = p_market_id;
end $$;


-- ============================================================================
-- place_order
--   The main entry point. Called by authenticated users via Supabase RPC.
--
--   Pricing convention:
--     BUY at limit L:  cross with asks at px <= L. Reserves L cents/share.
--                      Refunds (L - fill_px) per filled share.
--     SELL at limit L: cross with bids at px >= L. Reserves (100 - L) cents/share
--                      (the short-side margin). A short at fill_px means you
--                      receive fill_px and owe up to $1 if YES wins, so the
--                      margin actually needed is (100 - fill_px). The better the
--                      fill (higher price), the LESS margin required — hence
--                      refund = (fill_px - L) per filled share.
--
--   Returns jsonb: { order_id, filled_qty, remaining_qty, avg_fill_px, fills: [...] }
-- ============================================================================
create or replace function public.place_order(
  p_market_id text,
  p_side      order_side,
  p_limit_px  smallint,
  p_qty       integer
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id        uuid := auth.uid();
  v_user           public.users%rowtype;
  v_market         public.markets%rowtype;
  v_order_id       uuid;
  v_reserve_c      bigint;
  v_remaining      integer := p_qty;
  v_filled         integer := 0;
  v_total_fill_c   bigint := 0;
  v_maker          public.orders%rowtype;
  v_take_qty       integer;
  v_fill_px        smallint;
  v_fill_id        uuid;
  v_realized_c     bigint;
  v_refund_c       bigint := 0;
  v_avg_fill       numeric(10,4);
  v_fills          jsonb := '[]'::jsonb;
  v_status         order_status;
begin
  -- ----- 1. Authorization & input validation -----
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select * into v_user from public.users where id = v_user_id for update;
  if not found then raise exception 'USER_NOT_FOUND'; end if;
  if v_user.is_banned then raise exception 'USER_BANNED'; end if;

  if p_limit_px < 1 or p_limit_px > 99 then
    raise exception 'INVALID_PRICE: must be 1..99';
  end if;
  if p_qty < 1 or p_qty > 500 then
    raise exception 'INVALID_QTY: must be 1..500';
  end if;

  -- ----- 2. Lock market (engine mutex) -----
  select * into v_market from public.markets where id = p_market_id for update;
  if not found then raise exception 'MARKET_NOT_FOUND: %', p_market_id; end if;
  if v_market.status <> 'OPEN' then
    raise exception 'MARKET_NOT_OPEN: % is %', p_market_id, v_market.status;
  end if;

  -- ----- 3. Compute reservation -----
  if p_side = 'BUY' then
    v_reserve_c := (p_qty * p_limit_px)::bigint;
  else
    v_reserve_c := (p_qty * (100 - p_limit_px))::bigint;
  end if;

  -- Create the taker order row up front (so fills can reference it)
  v_order_id := gen_random_uuid();
  insert into public.orders (id, user_id, market_id, side, limit_px, qty, filled_qty, remaining_qty, status, reserved_c)
  values (v_order_id, v_user_id, p_market_id, p_side, p_limit_px, p_qty, 0, p_qty, 'OPEN', v_reserve_c);

  -- Debit the reserve (will throw INSUFFICIENT_BANKROLL if not enough)
  perform public._ledger_insert(v_user_id, 'ORDER_RESERVE', v_order_id::text, -v_reserve_c, 0,
    jsonb_build_object('market_id', p_market_id, 'side', p_side, 'limit_px', p_limit_px, 'qty', p_qty));

  -- ----- 4. Match against the opposite side -----
  loop
    exit when v_remaining = 0;

    -- Lock + select the best maker on the opposite side
    if p_side = 'BUY' then
      select * into v_maker from public.orders
       where market_id = p_market_id
         and side = 'SELL'
         and status in ('OPEN','PARTIAL')
         and limit_px <= p_limit_px
         and remaining_qty > 0
         and user_id <> v_user_id            -- no self-match
       order by limit_px asc, created_at asc
       for update skip locked
       limit 1;
    else
      select * into v_maker from public.orders
       where market_id = p_market_id
         and side = 'BUY'
         and status in ('OPEN','PARTIAL')
         and limit_px >= p_limit_px
         and remaining_qty > 0
         and user_id <> v_user_id
       order by limit_px desc, created_at asc
       for update skip locked
       limit 1;
    end if;

    exit when not found;

    v_fill_px  := v_maker.limit_px;
    v_take_qty := least(v_remaining, v_maker.remaining_qty);

    -- ----- 4a. Create the fill row -----
    v_fill_id := gen_random_uuid();
    insert into public.fills (id, market_id, taker_order_id, maker_order_id,
                              taker_user_id, maker_user_id, taker_side, qty, price_c)
    values (v_fill_id, p_market_id, v_order_id, v_maker.id,
            v_user_id, v_maker.user_id, p_side, v_take_qty, v_fill_px);

    v_fills := v_fills || jsonb_build_object('qty', v_take_qty, 'price', v_fill_px);

    -- ----- 4b. Update the maker order -----
    update public.orders
       set filled_qty    = filled_qty + v_take_qty,
           remaining_qty = remaining_qty - v_take_qty,
           status        = case when (filled_qty + v_take_qty) >= qty
                                then 'FILLED'::order_status
                                else 'PARTIAL'::order_status end,
           filled_at     = case when (filled_qty + v_take_qty) >= qty then now() else filled_at end
     where id = v_maker.id;

    -- Recompute taker's running avg_fill price
    v_total_fill_c := v_total_fill_c + (v_take_qty * v_fill_px)::bigint;
    v_filled       := v_filled + v_take_qty;
    v_remaining    := v_remaining - v_take_qty;

    -- ----- 4c. Apply position deltas for both sides -----
    declare
      v_taker_realized bigint;
      v_maker_realized bigint;
    begin
      -- Taker
      v_taker_realized := public._update_position_on_fill(
        v_user_id, p_market_id,
        case when p_side = 'BUY' then 1::smallint else -1::smallint end,
        v_take_qty, v_fill_px
      );

      -- Maker (opposite side from how *they* entered)
      v_maker_realized := public._update_position_on_fill(
        v_maker.user_id, p_market_id,
        case when v_maker.side = 'BUY' then 1::smallint else -1::smallint end,
        v_take_qty, v_fill_px
      );

      -- ----- 4d. Maker ledger entry -----
      -- Cash delta on the maker side at fill time is 0 (their reserve already covered it).
      -- But if this fill closed/reduced an existing maker position, realized_delta_c reflects that.
      insert into public.ledger (user_id, kind, ref_id, delta_c, realized_delta_c, balance_after_c, notes)
      select v_maker.user_id,
             case when v_maker.side = 'BUY' then 'FILL_BUY'::ledger_kind else 'FILL_SELL'::ledger_kind end,
             v_fill_id::text, 0::bigint, v_maker_realized,
             u.bankroll_c,
             jsonb_build_object('role','maker','market_id', p_market_id, 'qty', v_take_qty, 'price', v_fill_px)
        from public.users u where u.id = v_maker.user_id;
    end;

    -- ----- 4e. Increment the maker's trade count -----
    -- The maker is a participant in this trade even though they didn't initiate
    -- it. Crediting only the taker (as an earlier version did) understates
    -- activity for anyone providing liquidity.
    update public.users set trade_count = trade_count + 1 where id = v_maker.user_id;

    -- Update market last_px / volume
    update public.markets
       set last_px    = v_fill_px,
           volume     = volume + v_take_qty,
           updated_at = now()
     where id = p_market_id;

  end loop;

  -- ----- 5. Handle the taker's resting remainder + refunds -----
  if v_filled > 0 then
    v_avg_fill := v_total_fill_c::numeric / v_filled;

    -- Refund the gap between reserve-at-limit and actual-fill on filled portion
    if p_side = 'BUY' then
      --  reserved limit_px per share; actual cost is avg_fill. Refund the difference.
      v_refund_c := (v_filled * p_limit_px)::bigint - v_total_fill_c;
    else
      --  reserved (100-limit_px) per share; needed (100-fill_px). Refund delta,
      -- which simplifies to v_total_fill_c - v_filled*p_limit_px.
      -- Sanity: when fill_px = limit_px, refund = 0.
      v_refund_c := (v_filled * (100 - p_limit_px))::bigint - (v_filled * 100 - v_total_fill_c);
    end if;

    if v_refund_c > 0 then
      perform public._ledger_insert(v_user_id, 'ORDER_REFUND', v_order_id::text, v_refund_c, 0,
        jsonb_build_object('reason','fill_better_than_limit','filled_qty', v_filled, 'avg_fill_c', v_avg_fill));
    end if;

    -- Realized PnL was already applied per-fill inside _update_position_on_fill.
    --  record one consolidated FILL_BUY/FILL_SELL ledger entry for the taker here:
    perform public._ledger_insert(
      v_user_id,
      case when p_side = 'BUY' then 'FILL_BUY'::ledger_kind else 'FILL_SELL'::ledger_kind end,
      v_order_id::text,
      0,  -- delta_c = 0; cash already moved via reserve + refund
      0,
      jsonb_build_object('role','taker','filled_qty', v_filled, 'avg_fill_c', v_avg_fill)
    );

    update public.users set trade_count = trade_count + 1 where id = v_user_id;
  end if;

  -- Update the taker order's final state
  if v_filled = p_qty then
    v_status := 'FILLED';
  elsif v_filled > 0 then
    v_status := 'PARTIAL';
  else
    v_status := 'OPEN';
  end if;

  update public.orders
     set filled_qty    = v_filled,
         remaining_qty = v_remaining,
         avg_fill_px_c = v_avg_fill,
         status        = v_status,
         filled_at     = case when v_status = 'FILLED' then now() else filled_at end
   where id = v_order_id;

  -- ----- 6. Refresh denormalized best_bid/best_ask on the market -----
  perform public._refresh_market_book(p_market_id);

  -- ----- 7. Return summary -----
  return jsonb_build_object(
    'order_id',      v_order_id,
    'filled_qty',    v_filled,
    'remaining_qty', v_remaining,
    'avg_fill_px',   v_avg_fill,
    'refund_c',      v_refund_c,
    'fills',         v_fills,
    'status',        v_status
  );
end $$;

revoke all on function public.place_order(text, order_side, smallint, integer) from public;
grant  execute on function public.place_order(text, order_side, smallint, integer) to authenticated;


-- ============================================================================
-- cancel_order
--   Cancel a resting order owned by caller. Refunds remaining reserve.
-- ============================================================================
create or replace function public.cancel_order(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id   uuid := auth.uid();
  v_order     public.orders%rowtype;
  v_refund_c  bigint;
begin
  if v_user_id is null then raise exception 'AUTH_REQUIRED'; end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;
  if v_order.user_id <> v_user_id then raise exception 'NOT_AUTHORIZED'; end if;
  if v_order.status not in ('OPEN','PARTIAL') then
    raise exception 'ORDER_NOT_CANCELLABLE: status %', v_order.status;
  end if;

  -- Refund the reserve on the unfilled portion
  if v_order.side = 'BUY' then
    v_refund_c := (v_order.remaining_qty * v_order.limit_px)::bigint;
  else
    v_refund_c := (v_order.remaining_qty * (100 - v_order.limit_px))::bigint;
  end if;

  update public.orders
     set status       = 'CANCELLED',
         cancelled_at = now()
   where id = p_order_id;

  if v_refund_c > 0 then
    perform public._ledger_insert(v_user_id, 'ORDER_REFUND', p_order_id::text, v_refund_c, 0,
      jsonb_build_object('reason','cancel','remaining_qty', v_order.remaining_qty));
  end if;

  perform public._refresh_market_book(v_order.market_id);

  return jsonb_build_object('cancelled', true, 'refund_c', v_refund_c);
end $$;

revoke all on function public.cancel_order(uuid) from public;
grant  execute on function public.cancel_order(uuid) to authenticated;


-- ============================================================================
-- create_user_profile (called once after Supabase Auth signup)
--   Upsert the public.users row with display_name + linkedin_url.
-- ============================================================================
create or replace function public.create_user_profile(
  p_display_name text,
  p_linkedin_url text
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid   uuid := auth.uid();
  v_email text;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED'; end if;
  if length(coalesce(p_display_name,'')) < 2 then raise exception 'DISPLAY_NAME_TOO_SHORT'; end if;
  if p_linkedin_url !~* '^https?://([a-z0-9-]+\.)*linkedin\.com/' then
    raise exception 'INVALID_LINKEDIN_URL';
  end if;

  select email into v_email from auth.users where id = v_uid;
  if v_email is null then raise exception 'AUTH_EMAIL_MISSING'; end if;

  insert into public.users (id, display_name, linkedin_url, email)
  values (v_uid, p_display_name, p_linkedin_url, v_email)
  on conflict (id) do update
    set display_name = excluded.display_name,
        linkedin_url = excluded.linkedin_url;

  -- Initial bankroll ledger entry
  insert into public.ledger (user_id, kind, ref_id, delta_c, balance_after_c, notes)
  values (v_uid, 'BANKROLL_INIT', null, 0, 1000000, jsonb_build_object('starting_bankroll_c', 1000000))
  on conflict do nothing;

  return jsonb_build_object('user_id', v_uid, 'display_name', p_display_name);
end $$;

revoke all on function public.create_user_profile(text, text) from public;
grant  execute on function public.create_user_profile(text, text) to authenticated;


-- ============================================================================
-- refresh_leaderboard
--  live refresh implemented so dropping this
-- ============================================================================
create or replace function public.refresh_leaderboard()
returns void language sql security definer as $$
  refresh materialized view concurrently public.leaderboard;
$$;


-- ============================================================================
-- get_order_book
--   Fast public read of N levels of the book for a market.
-- ============================================================================
create or replace function public.get_order_book(p_market_id text, p_levels int default 5)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'bids', (
      select coalesce(jsonb_agg(jsonb_build_object('px', px, 'qty', qty) order by px desc), '[]')
        from (
          select limit_px as px, sum(remaining_qty)::int as qty
            from public.orders
           where market_id = p_market_id and side = 'BUY'
             and status in ('OPEN','PARTIAL') and remaining_qty > 0
           group by limit_px
           order by limit_px desc
           limit p_levels
        ) b
    ),
    'asks', (
      select coalesce(jsonb_agg(jsonb_build_object('px', px, 'qty', qty) order by px asc), '[]')
        from (
          select limit_px as px, sum(remaining_qty)::int as qty
            from public.orders
           where market_id = p_market_id and side = 'SELL'
             and status in ('OPEN','PARTIAL') and remaining_qty > 0
           group by limit_px
           order by limit_px asc
           limit p_levels
        ) a
    )
  )
$$;