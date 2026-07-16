-- ============================================================================
-- WC26-X — SETTLEMENT
-- Admin-only functions for resolving markets after each match.
--
-- Workflow per match (e.g. ARG 2 - 1 EGY decided in regulation):
--   1) call admin_record_fixture_result('r32.01','ARG',2,1,'REGULATION');
--   2) that internally calls admin_settle_market_group(...) for each group:
--      'r32.01.winner', 'r32.01.ou', 'r32.01.btts', 'r32.01.method'
--   3) for futures, call admin_settle_market_group manually at end of tournament:
--      admin_settle_market_group('fut.winner','fut.winner.ARG')  -- ARG wins it all
--      admin_settle_market_group('fut.boot','fut.boot.ARG')      -- Messi top scores
--      admin_settle_market_group('prop.upper','prop.upper.upper')  etc.
--
-- Settlement effects:
--   - For each market in the group, set resolves_yes = (market_id == winner_market_id).
--   - Pay $1 (100¢) to every long YES share holder of the winning market.
--   - Pay $1 (100¢) to every long NO share holder (i.e. short YES) of every losing market.
--   - All open orders on settled markets are CANCELLED and reserves refunded.
--   - Realized PnL is computed as (final_payout - avg_cost) for longs, (avg_cost - final_payout) for shorts.
--
-- These functions are SECURITY DEFINER and restricted to admin users.
-- ============================================================================

-- ============================================================================
-- admin_settle_market_group
--   Settles every market sharing a group_key. Exactly one of them must be
--   the "winning" market (the one that pays $1 to YES holders).
--   All others resolve NO (YES holders get $0, NO holders get $1).
-- ============================================================================
create or replace function public.admin_settle_market_group(
  p_group_key   text,
  p_winner_id   text
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := auth.uid();
  v_admin  boolean;
  v_market record;
  v_pos    record;
  v_order  record;
  v_payout_c    bigint;
  v_cost_basis  bigint;
  v_realized_c  bigint;
  v_refund_c    bigint;
  v_count_pos   int := 0;
  v_count_ord   int := 0;
begin
  -- Auth: admin only
  select is_admin into v_admin from public.users where id = v_uid;
  if not coalesce(v_admin, false) then raise exception 'NOT_ADMIN'; end if;

  -- Validate winner_id is in the group
  perform 1 from public.markets where id = p_winner_id and group_key = p_group_key;
  if not found then raise exception 'WINNER_NOT_IN_GROUP: % is not in %', p_winner_id, p_group_key; end if;

  -- ----- 1. Mark every market in the group as SETTLING and set resolves_yes -----
  for v_market in
    select * from public.markets where group_key = p_group_key for update
  loop
    if v_market.status in ('SETTLED','CANCELLED') then
      continue;  -- idempotent
    end if;

    update public.markets
       set resolves_yes = (id = p_winner_id),
           status = 'SETTLING',
           updated_at = now()
     where id = v_market.id;
  end loop;

  -- ----- 2. Cancel and refund every open order in this group -----
  for v_order in
    select o.* from public.orders o
      join public.markets m on m.id = o.market_id
     where m.group_key = p_group_key
       and o.status in ('OPEN','PARTIAL')
     for update
  loop
    if v_order.side = 'BUY' then
      v_refund_c := (v_order.remaining_qty * v_order.limit_px)::bigint;
    else
      v_refund_c := (v_order.remaining_qty * (100 - v_order.limit_px))::bigint;
    end if;

    update public.orders set status = 'CANCELLED', cancelled_at = now() where id = v_order.id;

    if v_refund_c > 0 then
      perform public._ledger_insert(v_order.user_id, 'ORDER_REFUND', v_order.id::text, v_refund_c, 0,
        jsonb_build_object('reason','market_settled','group_key', p_group_key));
    end if;
    v_count_ord := v_count_ord + 1;
  end loop;

  -- ----- 3. Pay out every position in this group -----
  for v_pos in
    select p.*, m.resolves_yes as wins
      from public.positions p
      join public.markets m on m.id = p.market_id
     where m.group_key = p_group_key
       for update of p
  loop
    -- For each long YES share: payout = 100 cents if resolves_yes else 0
    -- For each short YES share (negative shares): payout = 100 cents if NOT resolves_yes else 0
    -- The reserve we already debited for shorts was (100 - avg_cost) per share — releasing 100 to them = total $1 collected (their proceeds) + already-paid reserve refund... no wait.
    --
    -- Let me reason carefully:
    --   LONG YES: paid avg_cost per share. Asset = YES contract. If YES wins → asset = 100¢ → realized = 100 - avg_cost. If YES loses → asset = 0 → realized = 0 - avg_cost = -avg_cost.
    --   SHORT YES: received avg_proceeds per share at sale (call it p_sell), reserved (100 - p_sell) margin. Liability = 100¢ if YES wins, 0 if YES loses.
    --      track avg_cost_c on the position (which for shorts represents avg_proceeds).
    --     If YES wins → pay 100, net = p_sell - 100 = -(100 - p_sell). Margin (100-p_sell) covers it exactly.
    --     If YES loses → liability 0, net = p_sell. Margin (100-p_sell) is released back as cash; the p_sell we received originally was also held as part of reserve, so total cash credit on close = 100 cents per share (the full reserved amount).
    --
    --  never actually credited the SELL proceeds — we kept the entire (100) cents per share as reserve at order time (because reserve = qty*(100-limit_px) but we ALSO didn't credit the qty*limit_px proceeds; we just debited reserve). Wait, let me re-check engine.sql...
    --
    -- In place_order(): for SELL we reserved qty*(100-limit_px). On fill, the seller gets nothing in cash (proceeds stay in reserve as part of the margin model). At settlement:
    --   - If YES wins: short owes 100/share.  deduct nothing from balance (already reserved). Realized = (avg_cost - 100) which is negative if avg_cost < 100. The reserve (100-avg_cost) was the loss — already debited from bankroll, nothing to refund.
    --   - If YES loses: short owes 0.  refund the entire (100-avg_cost) reserve PLUS we credit avg_cost cents/share as the proceeds. Realized = avg_cost. Total cash credit = 100/share.
    --
    -- For consistency, I'll model settlement as: every share resolves to 0 or 100 cents.
    --   long_payout  = 100 if YES wins else 0   (credit to balance)
    --   short_payout = 100 if YES loses else 0  (credit to balance, releases the reserve which was 100-avg_cost AND the avg_cost in proceeds)
    -- Realized PnL = payout - cost_basis. For longs cost_basis = avg_cost; for shorts cost_basis = avg_cost (proceeds) and payout is netted differently.
    --
    -- Simpler unified rule:
    --   shares_resolution_value = 100 if (shares>0 AND wins) OR (shares<0 AND NOT wins) else 0
    --   For longs: credit = |shares| * shares_resolution_value; realized = shares * (shares_resolution_value - avg_cost) / 1... cents.
    --   For shorts: credit = |shares| * shares_resolution_value (this fully releases reserve+proceeds); realized = |shares| * (avg_cost - (100 - shares_resolution_value)).
    --     Because at order time we reserved (100 - avg_cost). After settlement, if YES loses, we get back 100 per share (full reserve + the proceeds we "kept"), realized = avg_cost.
    --     If YES wins, we get back 0, realized = avg_cost - 100 (negative).
    --
    -- OK — let me just code it directly:
    if v_pos.shares > 0 then
      -- Long YES position
      if v_pos.wins then
        v_payout_c := (v_pos.shares * 100)::bigint;
        v_realized_c := round((100 - v_pos.avg_cost_c) * v_pos.shares)::bigint;
      else
        v_payout_c := 0;
        v_realized_c := round((0 - v_pos.avg_cost_c) * v_pos.shares)::bigint;
      end if;
    else
      -- Short YES position (shares is negative); |shares| short contracts
      if v_pos.wins then
        -- Short loses
        v_payout_c := 0;
        v_realized_c := round((v_pos.avg_cost_c - 100) * abs(v_pos.shares))::bigint;
      else
        -- Short wins, payout 100/share back to free balance
        v_payout_c := (abs(v_pos.shares) * 100)::bigint;
        v_realized_c := round(v_pos.avg_cost_c * abs(v_pos.shares))::bigint;
      end if;
    end if;

    -- Credit the payout to balance and log realized in one ledger entry
    perform public._ledger_insert(
      v_pos.user_id, 'SETTLEMENT', v_pos.market_id, v_payout_c, v_realized_c,
      jsonb_build_object(
        'group_key', p_group_key,
        'market_id', v_pos.market_id,
        'shares', v_pos.shares,
        'avg_cost_c', v_pos.avg_cost_c,
        'wins', v_pos.wins
      )
    );

    -- Apply realized to users
    if v_realized_c <> 0 then
      update public.users set realized_c = realized_c + v_realized_c where id = v_pos.user_id;
    end if;

    -- Remove the position row
    delete from public.positions where user_id = v_pos.user_id and market_id = v_pos.market_id;
    v_count_pos := v_count_pos + 1;
  end loop;

  -- ----- 4. Mark all markets in the group SETTLED -----
  update public.markets set status = 'SETTLED', updated_at = now() where group_key = p_group_key;

  return jsonb_build_object(
    'group_key', p_group_key,
    'winner_market_id', p_winner_id,
    'positions_settled', v_count_pos,
    'orders_cancelled',  v_count_ord
  );
end $$;

revoke all on function public.admin_settle_market_group(text, text) from public;
grant  execute on function public.admin_settle_market_group(text, text) to authenticated;
-- (Function checks is_admin internally)


-- ============================================================================
-- admin_record_fixture_result
--   Convenience: record a match result and auto-settle all 4 market groups
--   for that fixture (winner, ou, btts, method).
-- ============================================================================
create or replace function public.admin_record_fixture_result(
  p_fixture_id text,
  p_winner_team text,          -- 'ARG' or 'EGY' for r32.01
  p_goals_a smallint,
  p_goals_b smallint,
  p_method text                -- 'REGULATION','ET','PENALTIES'
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := auth.uid();
  v_admin  boolean;
  v_fix    public.fixtures%rowtype;
  v_total_goals int;
  v_btts boolean;
  v_winner_mkt text;
  v_ou_mkt text;
  v_btts_mkt text;
  v_method_mkt text;
  v_result jsonb := '[]'::jsonb;
begin
  select is_admin into v_admin from public.users where id = v_uid;
  if not coalesce(v_admin, false) then raise exception 'NOT_ADMIN'; end if;

  select * into v_fix from public.fixtures where id = p_fixture_id for update;
  if not found then raise exception 'FIXTURE_NOT_FOUND'; end if;
  if v_fix.settled_at is not null then raise exception 'FIXTURE_ALREADY_SETTLED'; end if;

  if p_winner_team <> v_fix.team_a and p_winner_team <> v_fix.team_b then
    raise exception 'INVALID_WINNER: % is not % or %', p_winner_team, v_fix.team_a, v_fix.team_b;
  end if;
  if p_method not in ('REGULATION','ET','PENALTIES') then
    raise exception 'INVALID_METHOD: %', p_method;
  end if;

  v_total_goals := p_goals_a + p_goals_b;
  v_btts := (p_goals_a > 0 and p_goals_b > 0);

  -- Pick the winning market in each group
  if p_winner_team = v_fix.team_a then
    v_winner_mkt := p_fixture_id || '.winner.a';
  else
    v_winner_mkt := p_fixture_id || '.winner.b';
  end if;

  -- O/U uses regulation goals; we treat the recorded goals_a/b as 90-min totals.
  -- (If they include ET goals, your admin entry should net those out first.)
  if v_total_goals > 2 then
    v_ou_mkt := p_fixture_id || '.ou.over';
  else
    v_ou_mkt := p_fixture_id || '.ou.under';
  end if;

  if v_btts then
    v_btts_mkt := p_fixture_id || '.btts.yes';
  else
    v_btts_mkt := p_fixture_id || '.btts.no';
  end if;

  if p_method = 'REGULATION' then v_method_mkt := p_fixture_id || '.method.reg';
  elsif p_method = 'ET'          then v_method_mkt := p_fixture_id || '.method.et';
  else                                v_method_mkt := p_fixture_id || '.method.pen';
  end if;

  -- Settle each group
  v_result := v_result || jsonb_build_array(public.admin_settle_market_group(p_fixture_id || '.winner', v_winner_mkt));
  v_result := v_result || jsonb_build_array(public.admin_settle_market_group(p_fixture_id || '.ou',     v_ou_mkt));
  v_result := v_result || jsonb_build_array(public.admin_settle_market_group(p_fixture_id || '.btts',   v_btts_mkt));
  v_result := v_result || jsonb_build_array(public.admin_settle_market_group(p_fixture_id || '.method', v_method_mkt));

  -- Mark the fixture itself
  update public.fixtures
     set winner_team = p_winner_team,
         goals_a = p_goals_a, goals_b = p_goals_b,
         method = p_method,
         status = 'FINAL',
         settled_at = now()
   where id = p_fixture_id;

  -- Refresh leaderboard
  perform public.refresh_leaderboard();

  return jsonb_build_object(
    'fixture_id', p_fixture_id,
    'winner_team', p_winner_team,
    'goals', p_goals_a || '-' || p_goals_b,
    'method', p_method,
    'groups_settled', v_result
  );
end $$;

revoke all on function public.admin_record_fixture_result(text, text, smallint, smallint, text) from public;
grant  execute on function public.admin_record_fixture_result(text, text, smallint, smallint, text) to authenticated;


-- ============================================================================
-- admin_open_market_group / admin_lock_market_group
-- Toggle a market group between LOCKED and OPEN. Used at contest start.
-- ============================================================================
create or replace function public.admin_set_market_group_status(
  p_group_key text,
  p_status text  -- 'OPEN' or 'LOCKED' or 'SUSPENDED'
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin boolean;
begin
  select is_admin into v_admin from public.users where id = auth.uid();
  if not coalesce(v_admin, false) then raise exception 'NOT_ADMIN'; end if;
  if p_status not in ('OPEN','LOCKED','SUSPENDED') then raise exception 'INVALID_STATUS'; end if;

  update public.markets set status = p_status::market_status, updated_at = now()
   where group_key = p_group_key;

  return jsonb_build_object('group_key', p_group_key, 'status', p_status);
end $$;

revoke all on function public.admin_set_market_group_status(text, text) from public;
grant  execute on function public.admin_set_market_group_status(text, text) to authenticated;

-- ============================================================================
-- admin_open_all_markets (called once at contest start)
-- ============================================================================
create or replace function public.admin_open_all_markets()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin boolean;
  v_count int;
begin
  select is_admin into v_admin from public.users where id = auth.uid();
  if not coalesce(v_admin, false) then raise exception 'NOT_ADMIN'; end if;

  update public.markets set status = 'OPEN', updated_at = now()
   where status = 'LOCKED';
  get diagnostics v_count = row_count;

  return jsonb_build_object('opened', v_count);
end $$;

revoke all on function public.admin_open_all_markets() from public;
grant  execute on function public.admin_open_all_markets() to authenticated;

-- ============================================================================
-- auto_settle_at_deadline
-- Marks every open position to last_px and converts to realized.
-- Run this at the contest deadline.
-- ============================================================================
create or replace function public.admin_auto_settle_deadline()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin boolean;
  v_pos record;
  v_mark smallint;
  v_realized_c bigint;
  v_count int := 0;
begin
  select is_admin into v_admin from public.users where id = auth.uid();
  if not coalesce(v_admin, false) then raise exception 'NOT_ADMIN'; end if;

  for v_pos in
    select p.*, m.last_px
      from public.positions p
      join public.markets m on m.id = p.market_id
     where m.status in ('OPEN','LOCKED','SUSPENDED')   -- not yet settled
       for update of p
  loop
    v_mark := coalesce(v_pos.last_px, round(v_pos.avg_cost_c)::smallint);

    if v_pos.shares > 0 then
      v_realized_c := round((v_mark - v_pos.avg_cost_c) * v_pos.shares)::bigint;
    else
      v_realized_c := round((v_pos.avg_cost_c - v_mark) * abs(v_pos.shares))::bigint;
    end if;

    update public.users set realized_c = realized_c + v_realized_c where id = v_pos.user_id;

    insert into public.ledger (user_id, kind, ref_id, delta_c, realized_delta_c, balance_after_c, notes)
      select v_pos.user_id, 'POSITION_REALIZED', v_pos.market_id, 0, v_realized_c,
             u.bankroll_c,
             jsonb_build_object('reason','auto_settle_deadline','shares', v_pos.shares,
                                'avg_cost_c', v_pos.avg_cost_c, 'mark_c', v_mark)
        from public.users u where u.id = v_pos.user_id;

    delete from public.positions where user_id = v_pos.user_id and market_id = v_pos.market_id;
    v_count := v_count + 1;
  end loop;

  perform public.refresh_leaderboard();

  return jsonb_build_object('positions_auto_settled', v_count);
end $$;

revoke all on function public.admin_auto_settle_deadline() from public;
grant  execute on function public.admin_auto_settle_deadline() to authenticated;
