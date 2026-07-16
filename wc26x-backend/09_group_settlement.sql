-- ============================================================================
-- WC26-X — GROUP SETTLEMENT
--
-- Contents:
--   1. Add SETTLEMENT to ledger_kind enum (if missing)
--   2. _is_admin_or_service() — admin bypass helper
--   3. pending_results table — staging area for confirmed scores
--   4. _settle_single_market(market_id, won) — settles one binary market
--   5. admin_settle_group_fixture(fixture_id, goals_home, goals_away) — group settlement
--   6. admin_settle_knockout_fixture (placeholder for later)
--   7. Permissions + RLS
-- ============================================================================

-- ============================================================================
-- 1. ENUM — add SETTLEMENT kind to ledger
-- ============================================================================

ALTER TYPE ledger_kind ADD VALUE IF NOT EXISTS 'SETTLEMENT';

-- Add settled_at column to markets if it doesn't exist
DO $$ BEGIN
  ALTER TABLE public.markets ADD COLUMN settled_at timestamptz;
EXCEPTION WHEN duplicate_column THEN NULL;
END $$;


-- ============================================================================
-- 2. ADMIN BYPASS HELPER
-- ============================================================================
CREATE OR REPLACE FUNCTION public._is_admin_or_service()
RETURNS boolean
LANGUAGE plpgsql STABLE
AS $$
BEGIN
  -- 1. SQL editor / superuser (postgres, supabase_admin)
  IF current_user IN ('postgres', 'supabase_admin') THEN
    RETURN true;
  END IF;

  -- 2. Service-role JWT (sync scripts, scheduled functions)
  IF coalesce(current_setting('request.jwt.claim.role', true), '') = 'service_role' THEN
    RETURN true;
  END IF;

  -- 3. Authenticated admin user
  IF auth.uid() IS NOT NULL THEN
    RETURN EXISTS (SELECT 1 FROM public.users WHERE id = auth.uid() AND is_admin = true);
  END IF;

  RETURN false;
END $$;


-- ============================================================================
-- 3. PENDING RESULTS — staging table for API-synced or manually entered scores
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.pending_results (
  id            serial PRIMARY KEY,
  fixture_id    text NOT NULL REFERENCES public.fixtures(id),
  goals_home    smallint NOT NULL,
  goals_away    smallint NOT NULL,
  source        text DEFAULT 'manual',        -- 'api-football' or 'manual'
  api_data      jsonb,                         -- raw API response for audit
  status        text DEFAULT 'PENDING' CHECK (status IN ('PENDING','CONFIRMED','REJECTED')),
  created_at    timestamptz DEFAULT now(),
  confirmed_at  timestamptz,
  confirmed_by  text                           -- display_name or 'system'
);

-- Idempotent index: one pending/confirmed result per fixture
CREATE UNIQUE INDEX IF NOT EXISTS idx_pending_results_fixture
  ON public.pending_results (fixture_id) WHERE status IN ('PENDING','CONFIRMED');

-- RLS
ALTER TABLE public.pending_results ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anyone can read pending_results" ON public.pending_results;
CREATE POLICY "Anyone can read pending_results" ON public.pending_results
  FOR SELECT USING (true);

DROP POLICY IF EXISTS "Service/admin can insert pending_results" ON public.pending_results;
CREATE POLICY "Service/admin can insert pending_results" ON public.pending_results
  FOR INSERT WITH CHECK (true);  -- sync script uses service_role; RPC checks admin

DROP POLICY IF EXISTS "Service/admin can update pending_results" ON public.pending_results;
CREATE POLICY "Service/admin can update pending_results" ON public.pending_results
  FOR UPDATE USING (true);

GRANT SELECT ON public.pending_results TO anon, authenticated;
GRANT INSERT, UPDATE ON public.pending_results TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE pending_results_id_seq TO authenticated;


-- ============================================================================
-- 4. _settle_single_market
--    Settles one binary market. Idempotent via settled_at check.
--
--    Steps:
--      a) Cancel all resting orders → refund reserves
--      b) Pay out each position at settlement price (100 if won, 0 if lost)
--      c) Record realized P&L delta
--      d) Delete settled positions
--      e) Mark market SETTLED
--
--    Returns: { market_id, won, positions_settled, orders_cancelled, total_paid_c }
-- ============================================================================
CREATE OR REPLACE FUNCTION public._settle_single_market(
  p_market_id  text,
  p_won        boolean       -- true = YES outcome happened → long YES gets $1/share
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_market           public.markets%rowtype;
  v_settlement_px    smallint := CASE WHEN p_won THEN 100 ELSE 0 END;
  v_ord              record;
  v_pos              record;
  v_payout_c         bigint;
  v_realized_delta_c bigint;
  v_refund_c         bigint;
  v_total_paid_c     bigint := 0;
  v_positions_count  int := 0;
  v_orders_count     int := 0;
BEGIN
  -- Lock the market row
  SELECT * INTO v_market FROM public.markets WHERE id = p_market_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'MARKET_NOT_FOUND: %', p_market_id;
  END IF;

  -- Idempotent: already settled → skip
  IF v_market.status = 'SETTLED' THEN
    RETURN jsonb_build_object('market_id', p_market_id, 'already_settled', true);
  END IF;

  -- ---- A. Cancel all resting orders, refund reserves ----
  FOR v_ord IN
    SELECT * FROM public.orders
    WHERE market_id = p_market_id
      AND status IN ('OPEN','PARTIAL')
      AND remaining_qty > 0
    FOR UPDATE
  LOOP
    IF v_ord.side = 'BUY' THEN
      v_refund_c := (v_ord.remaining_qty * v_ord.limit_px)::bigint;
    ELSE
      v_refund_c := (v_ord.remaining_qty * (100 - v_ord.limit_px))::bigint;
    END IF;

    UPDATE public.orders
    SET status = 'CANCELLED', cancelled_at = now(), remaining_qty = 0
    WHERE id = v_ord.id;

    IF v_refund_c > 0 THEN
      PERFORM public._ledger_insert(
        v_ord.user_id, 'ORDER_REFUND', v_ord.id::text, v_refund_c, 0,
        jsonb_build_object('reason', 'settlement_cancel'));
    END IF;

    v_orders_count := v_orders_count + 1;
  END LOOP;

  -- ---- B. Settle all positions ----
  FOR v_pos IN
    SELECT * FROM public.positions WHERE market_id = p_market_id FOR UPDATE
  LOOP
    IF v_pos.shares > 0 THEN
      -- Long YES: gets settlement_px per share
      v_payout_c         := (v_pos.shares * v_settlement_px)::bigint;
      v_realized_delta_c := round((v_settlement_px - v_pos.avg_cost_c) * v_pos.shares)::bigint;
    ELSE
      -- Short YES (long NO): gets (100 - settlement_px) per share
      v_payout_c         := (abs(v_pos.shares) * (100 - v_settlement_px))::bigint;
      v_realized_delta_c := round((v_pos.avg_cost_c - v_settlement_px) * abs(v_pos.shares))::bigint;
    END IF;

    -- Credit payout to bankroll (0 for losers — still record the ledger entry)
    PERFORM public._ledger_insert(
      v_pos.user_id, 'SETTLEMENT', p_market_id,
      v_payout_c, v_realized_delta_c,
      jsonb_build_object(
        'settlement_px', v_settlement_px,
        'shares', v_pos.shares,
        'avg_cost_c', v_pos.avg_cost_c,
        'payout_c', v_payout_c
      ));

    -- Update realized P&L on users row
    IF v_realized_delta_c <> 0 THEN
      UPDATE public.users
      SET realized_c = realized_c + v_realized_delta_c
      WHERE id = v_pos.user_id;
    END IF;

    -- Remove settled position
    DELETE FROM public.positions
    WHERE user_id = v_pos.user_id AND market_id = p_market_id;

    v_total_paid_c  := v_total_paid_c + v_payout_c;
    v_positions_count := v_positions_count + 1;
  END LOOP;

  -- ---- C. Mark market as SETTLED ----
  UPDATE public.markets
  SET status = 'SETTLED', settled_at = now(), last_px = v_settlement_px
  WHERE id = p_market_id;

  -- Refresh book (clears best_bid/best_ask)
  PERFORM public._refresh_market_book(p_market_id);

  RETURN jsonb_build_object(
    'market_id',          p_market_id,
    'won',                p_won,
    'settlement_px',      v_settlement_px,
    'positions_settled',  v_positions_count,
    'orders_cancelled',   v_orders_count,
    'total_paid_c',       v_total_paid_c
  );
END $$;


-- ============================================================================
-- 5. admin_settle_group_fixture
--    Given a GROUP-STAGE fixture and the final score, determines winners for
--    all 3 market types (RESULT 3-way, O/U 2.5, BTTS) and settles each.
--
--    Market-id convention (from create_markets_for_fixture):
--      {fixture_id}.result.{HOME}    — YES if home wins
--      {fixture_id}.result.X         — YES if draw
--      {fixture_id}.result.{AWAY}    — YES if away wins
--      {fixture_id}.ou25.over        — YES if total goals >= 3
--      {fixture_id}.ou25.under       — YES if total goals <= 2
--      {fixture_id}.btts.yes         — YES if both teams scored
--      {fixture_id}.btts.no          — YES if at least one team blanked
--
--    Idempotent: re-running with the same fixture skips already-settled markets.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.admin_settle_group_fixture(
  p_fixture_id   text,
  p_goals_home   smallint,
  p_goals_away   smallint
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_fix          public.fixtures%rowtype;
  v_home         text;
  v_away         text;
  v_total_goals  int;
  v_result_winner text;   -- home_code, 'X', or away_code
  v_ou_winner    text;    -- 'over' or 'under'
  v_btts_winner  text;    -- 'yes' or 'no'
  v_results      jsonb := '[]'::jsonb;
  v_mkt          record;
  v_won          boolean;
  v_r            jsonb;
BEGIN
  -- Authorization
  IF NOT public._is_admin_or_service() THEN
    RAISE EXCEPTION 'NOT_ADMIN: you must be admin, service_role, or postgres to settle';
  END IF;

  -- Look up fixture
  SELECT * INTO v_fix FROM public.fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FIXTURE_NOT_FOUND: %', p_fixture_id;
  END IF;

  v_home := v_fix.team_a;
  v_away := v_fix.team_b;
  v_total_goals := p_goals_home + p_goals_away;

  -- Determine winners (market outcomes use 'home'/'draw'/'away', not team codes)
  IF p_goals_home > p_goals_away THEN
    v_result_winner := 'home';
  ELSIF p_goals_home < p_goals_away THEN
    v_result_winner := 'away';
  ELSE
    v_result_winner := 'draw';
  END IF;

  v_ou_winner   := CASE WHEN v_total_goals >= 3 THEN 'over' ELSE 'under' END;
  v_btts_winner := CASE WHEN p_goals_home > 0 AND p_goals_away > 0 THEN 'yes' ELSE 'no' END;

  -- Settle every market belonging to this fixture
  FOR v_mkt IN
    SELECT id, group_key FROM public.markets
    WHERE fixture_id = p_fixture_id
    ORDER BY id
  LOOP
    -- Determine if this specific market's YES outcome won
    -- group_key is like 'f1489369.result', 'f1489369.ou', 'f1489369.btts'
    -- Market id suffix (3rd dot-segment) is 'home'/'draw'/'away', 'over'/'under', 'yes'/'no'
    IF v_mkt.group_key LIKE '%result' THEN
      v_won := (split_part(v_mkt.id, '.', 3) = v_result_winner);

    ELSIF v_mkt.group_key LIKE '%ou' OR v_mkt.group_key LIKE '%ou25' THEN
      v_won := (split_part(v_mkt.id, '.', 3) = v_ou_winner);

    ELSIF v_mkt.group_key LIKE '%btts' THEN
      v_won := (split_part(v_mkt.id, '.', 3) = v_btts_winner);

    ELSE
      -- Unknown market type for group stage — skip (futures)
      CONTINUE;
    END IF;

    v_r := public._settle_single_market(v_mkt.id, v_won);
    v_results := v_results || v_r;
  END LOOP;

  -- Update fixture status
  UPDATE public.fixtures
  SET status = 'SETTLED'
  WHERE id = p_fixture_id;

  RETURN jsonb_build_object(
    'fixture_id',    p_fixture_id,
    'score',         format('%s %s - %s %s', v_home, p_goals_home, p_goals_away, v_away),
    'result_winner', v_result_winner,
    'ou_winner',     v_ou_winner,
    'btts_winner',   v_btts_winner,
    'markets',       v_results
  );
END $$;


-- ============================================================================
-- 6. admin_confirm_pending_result
--    Confirms a staged result and triggers settlement.
--    Called from the admin UI or via RPC.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.admin_confirm_pending_result(
  p_pending_id  int
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_pr    public.pending_results%rowtype;
  v_who   text;
  v_res   jsonb;
BEGIN
  IF NOT public._is_admin_or_service() THEN
    RAISE EXCEPTION 'NOT_ADMIN';
  END IF;

  SELECT * INTO v_pr FROM public.pending_results WHERE id = p_pending_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'PENDING_RESULT_NOT_FOUND: %', p_pending_id;
  END IF;

  IF v_pr.status = 'CONFIRMED' THEN
    RETURN jsonb_build_object('already_confirmed', true, 'fixture_id', v_pr.fixture_id);
  END IF;

  IF v_pr.status = 'REJECTED' THEN
    RAISE EXCEPTION 'RESULT_ALREADY_REJECTED';
  END IF;

  -- Determine who is confirming
  IF auth.uid() IS NOT NULL THEN
    SELECT display_name INTO v_who FROM public.users WHERE id = auth.uid();
  ELSE
    v_who := current_user;  -- 'postgres' in SQL editor
  END IF;

  -- Settle
  v_res := public.admin_settle_group_fixture(
    v_pr.fixture_id,
    v_pr.goals_home,
    v_pr.goals_away
  );

  -- Mark confirmed
  UPDATE public.pending_results
  SET status = 'CONFIRMED',
      confirmed_at = now(),
      confirmed_by = coalesce(v_who, 'unknown')
  WHERE id = p_pending_id;

  RETURN v_res;
END $$;


-- ============================================================================
-- 7. admin_stage_result (manual entry from admin UI)
--    Inserts a pending result for a fixture. Idempotent per fixture.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.admin_stage_result(
  p_fixture_id  text,
  p_goals_home  smallint,
  p_goals_away  smallint
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id int;
BEGIN
  IF NOT public._is_admin_or_service() THEN
    RAISE EXCEPTION 'NOT_ADMIN';
  END IF;

  -- Upsert: if a PENDING row already exists for this fixture, update the score
  INSERT INTO public.pending_results (fixture_id, goals_home, goals_away, source)
  VALUES (p_fixture_id, p_goals_home, p_goals_away, 'manual')
  ON CONFLICT (fixture_id) WHERE status IN ('PENDING','CONFIRMED')
  DO UPDATE SET goals_home = EXCLUDED.goals_home,
                goals_away = EXCLUDED.goals_away,
                source     = 'manual'
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('pending_result_id', v_id, 'fixture_id', p_fixture_id);
END $$;


-- ============================================================================
-- 8. GRANTS — let authenticated users call the admin RPCs
--    (the functions themselves check _is_admin_or_service internally)
-- ============================================================================
GRANT EXECUTE ON FUNCTION public.admin_settle_group_fixture(text, smallint, smallint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_confirm_pending_result(int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_stage_result(text, smallint, smallint) TO authenticated;


-- ============================================================================
-- 9. QUICK SETTLE SHORTCUT — for SQL editor use during the tournament.
--    Example:  SELECT public.quick_settle_group('f1489369', 2, 1);
--    Stages + confirms in one call. Only works from postgres/service_role.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.quick_settle_group(
  p_fixture_id  text,
  p_goals_home  smallint,
  p_goals_away  smallint
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public._is_admin_or_service() THEN
    RAISE EXCEPTION 'NOT_ADMIN';
  END IF;

  RETURN public.admin_settle_group_fixture(p_fixture_id, p_goals_home, p_goals_away);
END $$;