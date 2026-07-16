-- ============================================================================
-- WC26-X — WORLD CUP PIVOT (migration 06)
-- Adding stage-aware fixtures + markets so we can ingest the *entire* tournament
-- from API-Football instead of a hardcoded projected bracket.
--
-- NOTE: group RESULT markets use type='WINNER' (the draw is just a third
-- outcome). 
-- ============================================================================

alter table public.fixtures add column if not exists stage          text;     -- 'GROUP','R32','R16','QF','SF','3P','F'
alter table public.fixtures add column if not exists matchday       int;      -- group matchday 1..3
alter table public.fixtures add column if not exists api_fixture_id bigint;    -- API-Football fixture id

create index if not exists fixtures_api_idx   on public.fixtures (api_fixture_id);
create index if not exists fixtures_stage_idx on public.fixtures (stage);

-- ============================================================================
-- seed_house_liquidity — post resting house bids/asks around a mid price.
-- ============================================================================
create or replace function public.seed_house_liquidity(p_market_id text, p_mid_px int)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_house uuid := '00000000-0000-0000-0000-00000000ffff';
  v_spread smallint;
  i int;
  v_bid smallint;
  v_ask smallint;
  v_qty int;
  v_oid uuid;
  v_reserve bigint;
begin
  v_spread := case when p_mid_px < 10 or p_mid_px > 90 then 4 else 2 end;
  for i in 0..3 loop
    v_bid := greatest(1, p_mid_px - (v_spread/2) - i);
    v_ask := least(99, p_mid_px + ((v_spread+1)/2) + i);
    v_qty := 100 + (random()*200)::int + i*60;

    if v_bid >= 1 then
      v_oid := gen_random_uuid();
      v_reserve := (v_qty * v_bid)::bigint;
      insert into public.orders (id, user_id, market_id, side, limit_px, qty, filled_qty, status, reserved_c)
      values (v_oid, v_house, p_market_id, 'BUY', v_bid, v_qty, 0, 'OPEN', v_reserve);
      update public.users set bankroll_c = bankroll_c - v_reserve where id = v_house;
    end if;

    if v_ask <= 99 then
      v_oid := gen_random_uuid();
      v_reserve := (v_qty * (100 - v_ask))::bigint;
      insert into public.orders (id, user_id, market_id, side, limit_px, qty, filled_qty, status, reserved_c)
      values (v_oid, v_house, p_market_id, 'SELL', v_ask, v_qty, 0, 'OPEN', v_reserve);
      update public.users set bankroll_c = bankroll_c - v_reserve where id = v_house;
    end if;
  end loop;
  perform public._refresh_market_book(p_market_id);
end $$;

-- ============================================================================
-- create_markets_for_fixture — stage-aware market generation.
-- Idempotent: if the fixture already has markets, does nothing.
-- ============================================================================
create or replace function public.create_markets_for_fixture(
  p_fid     text,
  p_stage   text,
  p_team_a  text,   -- home (group) / side A (knockout); display label
  p_team_b  text,   -- away (group) / side B (knockout)
  p_open    boolean default false
) returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_status market_status := case when p_open then 'OPEN' else 'LOCKED' end;
begin
  -- Idempotency guard: skip if this fixture already has markets.
  if exists (select 1 from public.markets where fixture_id = p_fid) then
    return;
  end if;

  if p_stage = 'GROUP' then
    -- 3-way RESULT (Home / Draw / Away). Group games can draw; no ET/pens.
    insert into public.markets (id, fixture_id, type, name, outcome_label, team_code, group_key, status, last_px, description) values
      (p_fid||'.result.home', p_fid, 'WINNER', 'RESULT · '||p_team_a, p_team_a, p_team_a, p_fid||'.result', v_status, 40, 'Pays $1 if '||p_team_a||' win'),
      (p_fid||'.result.draw', p_fid, 'WINNER', 'RESULT · DRAW',       'DRAW',   null,    p_fid||'.result', v_status, 27, 'Pays $1 if the match is drawn'),
      (p_fid||'.result.away', p_fid, 'WINNER', 'RESULT · '||p_team_b, p_team_b, p_team_b, p_fid||'.result', v_status, 33, 'Pays $1 if '||p_team_b||' win')
    on conflict (id) do nothing;
    perform public.seed_house_liquidity(p_fid||'.result.home', 40);
    perform public.seed_house_liquidity(p_fid||'.result.draw', 27);
    perform public.seed_house_liquidity(p_fid||'.result.away', 33);
  else
    -- Knockout: who advances (2-way, incl ET/pens) + method of decision.
    insert into public.markets (id, fixture_id, type, name, outcome_label, team_code, group_key, status, last_px, description) values
      (p_fid||'.winner.a', p_fid, 'WINNER', 'MATCH WINNER · '||p_team_a, p_team_a, p_team_a, p_fid||'.winner', v_status, 50, 'Pays $1 if '||p_team_a||' advances. Incl ET/penalties'),
      (p_fid||'.winner.b', p_fid, 'WINNER', 'MATCH WINNER · '||p_team_b, p_team_b, p_team_b, p_fid||'.winner', v_status, 50, 'Pays $1 if '||p_team_b||' advances. Incl ET/penalties')
    on conflict (id) do nothing;
    insert into public.markets (id, fixture_id, type, name, outcome_label, group_key, status, last_px, description) values
      (p_fid||'.method.reg', p_fid, 'METHOD', 'METHOD · REGULATION', 'REGULATION', p_fid||'.method', v_status, 76, 'Decided in 90 minutes'),
      (p_fid||'.method.et',  p_fid, 'METHOD', 'METHOD · EXTRA TIME', 'EXTRA TIME', p_fid||'.method', v_status, 16, 'Decided in extra time'),
      (p_fid||'.method.pen', p_fid, 'METHOD', 'METHOD · PENALTIES',  'PENALTIES',  p_fid||'.method', v_status,  8, 'Decided on penalties')
    on conflict (id) do nothing;
    perform public.seed_house_liquidity(p_fid||'.winner.a', 50);
    perform public.seed_house_liquidity(p_fid||'.winner.b', 50);
    perform public.seed_house_liquidity(p_fid||'.method.reg', 76);
    perform public.seed_house_liquidity(p_fid||'.method.et', 16);
    perform public.seed_house_liquidity(p_fid||'.method.pen', 8);
  end if;

  -- Common to every stage: Total Goals O/U 2.5 + BTTS.
  insert into public.markets (id, fixture_id, type, name, outcome_label, group_key, status, last_px, description) values
    (p_fid||'.ou.over',  p_fid, 'OU',   'TOTAL GOALS O/U 2.5 · OVER',  'OVER 2.5',  p_fid||'.ou',   v_status, 51, 'Pays $1 if regulation goals > 2.5'),
    (p_fid||'.ou.under', p_fid, 'OU',   'TOTAL GOALS O/U 2.5 · UNDER', 'UNDER 2.5', p_fid||'.ou',   v_status, 49, 'Pays $1 if regulation goals <= 2.5'),
    (p_fid||'.btts.yes', p_fid, 'BTTS', 'BTTS · YES', 'YES', p_fid||'.btts', v_status, 53, 'Both teams score in regulation'),
    (p_fid||'.btts.no',  p_fid, 'BTTS', 'BTTS · NO',  'NO',  p_fid||'.btts', v_status, 47, 'A team is shut out in regulation')
  on conflict (id) do nothing;
  perform public.seed_house_liquidity(p_fid||'.ou.over', 51);
  perform public.seed_house_liquidity(p_fid||'.ou.under', 49);
  perform public.seed_house_liquidity(p_fid||'.btts.yes', 53);
  perform public.seed_house_liquidity(p_fid||'.btts.no', 47);
end $$;

-- ============================================================================
-- sync_fixture — upsert a fixture AND create its markets in one call.
-- The ingestion script calls this once per API fixture.
-- SECURITY DEFINER + callable by the service role (server-side ingestion).
-- ============================================================================
create or replace function public.sync_fixture(
  p_api_id    bigint,
  p_stage     text,
  p_matchday  int,
  p_team_a    text,
  p_team_b    text,
  p_kickoff   timestamptz,
  p_venue     text,
  p_open      boolean default false
) returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_fid text := 'f' || p_api_id::text;   -- stable text id derived from the API id
  v_round text := p_stage;
begin
  insert into public.fixtures (id, round, stage, matchday, api_fixture_id, team_a, team_b, kickoff_at, venue, status)
  values (v_fid, v_round, p_stage, p_matchday, p_api_id, p_team_a, p_team_b, p_kickoff, p_venue, 'SCHEDULED')
  on conflict (id) do update
    set team_a = excluded.team_a,
        team_b = excluded.team_b,
        kickoff_at = excluded.kickoff_at,
        venue = excluded.venue,
        stage = excluded.stage,
        matchday = excluded.matchday;

  perform public.create_markets_for_fixture(v_fid, p_stage, p_team_a, p_team_b, p_open);
  return v_fid;
end $$;

revoke all on function public.sync_fixture(bigint, text, int, text, text, timestamptz, text, boolean) from public;
grant  execute on function public.sync_fixture(bigint, text, int, text, text, timestamptz, text, boolean) to service_role;
