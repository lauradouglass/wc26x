-- ============================================================================
-- WC26-X — SEED DATA
-- Inserts projected R32 fixtures, all markets per fixture, the futures markets,
-- and a synthetic resting "house" maker so the books aren't empty on launch.
--
-- IMPORTANT: The bracket below is PROJECTED. 
-- ============================================================================

insert into public.users (id, display_name, linkedin_url, email, bankroll_c, is_admin, is_house)
values ('00000000-0000-0000-0000-00000000ffff',
        '__house__', 'https://linkedin.com/in/wc26x-house',
        'house@wc26x.local',
        1000000000000, -- $10 million
        true, true)
on conflict (id) do update
  set bankroll_c = excluded.bankroll_c,
      is_house = true;

-- ----- Fixtures (projected R32) -----
insert into public.fixtures (id, round, team_a, team_b, kickoff_at, venue) values
  ('r32.01','R32','ARG','EGY','2026-06-30 20:00+00','Estadio Azteca'),
  ('r32.02','R32','FRA','SCO','2026-06-30 23:00+00','AT&T Stadium'),
  ('r32.03','R32','BRA','NOR','2026-07-01 20:00+00','MetLife Stadium'),
  ('r32.04','R32','ENG','TUN','2026-07-01 23:00+00','Lincoln Financial Field'),
  ('r32.05','R32','ESP','WAL','2026-07-02 20:00+00','SoFi Stadium'),
  ('r32.06','R32','GER','AUT','2026-07-02 23:00+00','NRG Stadium'),
  ('r32.07','R32','POR','SRB','2026-07-03 20:00+00','Hard Rock Stadium'),
  ('r32.08','R32','NED','POL','2026-07-03 23:00+00','Lumen Field'),
  ('r32.09','R32','ITA','ECU','2026-07-04 20:00+00','Mercedes-Benz Stadium'),
  ('r32.10','R32','BEL','AUS','2026-07-04 23:00+00','BMO Field'),
  ('r32.11','R32','CRO','CAN','2026-07-05 16:00+00','BC Place'),
  ('r32.12','R32','URU','KOR','2026-07-05 19:00+00','Estadio BBVA'),
  ('r32.13','R32','COL','SEN','2026-07-05 22:00+00','Gillette Stadium'),
  ('r32.14','R32','USA','JPN','2026-07-06 20:00+00','SoFi Stadium'),
  ('r32.15','R32','MEX','MAR','2026-07-06 23:00+00','Estadio Akron'),
  ('r32.16','R32','SUI','DEN','2026-07-07 20:00+00','Arrowhead Stadium')
on conflict (id) do nothing;

-- ----- Markets -----
-- Helper to compute prior from FIFA Elo ratings
create or replace function public._team_elo(team_code text) returns int as $$
  select case team_code
    when 'ARG' then 2152 when 'FRA' then 2114 when 'BRA' then 2091 when 'ENG' then 2076
    when 'ESP' then 2069 when 'GER' then 2034 when 'POR' then 2027 when 'NED' then 2008
    when 'ITA' then 1998 when 'BEL' then 1985 when 'CRO' then 1977 when 'URU' then 1968
    when 'COL' then 1962 when 'USA' then 1955 when 'MEX' then 1948 when 'SUI' then 1941
    when 'DEN' then 1932 when 'MAR' then 1928 when 'JPN' then 1925 when 'SEN' then 1918
    when 'KOR' then 1907 when 'CAN' then 1894 when 'AUS' then 1881 when 'ECU' then 1876
    when 'POL' then 1862 when 'SRB' then 1848 when 'AUT' then 1843 when 'WAL' then 1828
    when 'TUN' then 1815 when 'SCO' then 1802 when 'NOR' then 1798 when 'EGY' then 1781
    else 1700
  end
$$ language sql immutable;

create or replace function public._team_name(team_code text) returns text as $$
  select case team_code
    when 'ARG' then 'Argentina' when 'FRA' then 'France' when 'BRA' then 'Brazil' when 'ENG' then 'England'
    when 'ESP' then 'Spain' when 'GER' then 'Germany' when 'POR' then 'Portugal' when 'NED' then 'Netherlands'
    when 'ITA' then 'Italy' when 'BEL' then 'Belgium' when 'CRO' then 'Croatia' when 'URU' then 'Uruguay'
    when 'COL' then 'Colombia' when 'USA' then 'USA' when 'MEX' then 'Mexico' when 'SUI' then 'Switzerland'
    when 'DEN' then 'Denmark' when 'MAR' then 'Morocco' when 'JPN' then 'Japan' when 'SEN' then 'Senegal'
    when 'KOR' then 'South Korea' when 'CAN' then 'Canada' when 'AUS' then 'Australia' when 'ECU' then 'Ecuador'
    when 'POL' then 'Poland' when 'SRB' then 'Serbia' when 'AUT' then 'Austria' when 'WAL' then 'Wales'
    when 'TUN' then 'Tunisia' when 'SCO' then 'Scotland' when 'NOR' then 'Norway' when 'EGY' then 'Egypt'
    else team_code
  end
$$ language sql immutable;

-- For each fixture, create markets
do $$
declare
  fx record;
  eloA int; eloB int;
  pA   numeric;
begin
  for fx in select * from public.fixtures order by id loop
    eloA := public._team_elo(fx.team_a);
    eloB := public._team_elo(fx.team_b);
    pA := 1.0 / (1.0 + power(10.0, (eloB - eloA)::numeric / 400));

    -- Match winner: 2 markets (Team A wins, Team B wins)
    insert into public.markets (id, fixture_id, type, name, outcome_label, team_code, group_key, status, last_px, description)
    values
      (fx.id || '.winner.a', fx.id, 'WINNER', 'MATCH WINNER · ' || fx.team_a, public._team_name(fx.team_a),
       fx.team_a, fx.id || '.winner', 'LOCKED', round(pA * 100)::smallint,
       'Pays $1 if ' || fx.team_a || ' advances. Includes ET / penalties.'),
      (fx.id || '.winner.b', fx.id, 'WINNER', 'MATCH WINNER · ' || fx.team_b, public._team_name(fx.team_b),
       fx.team_b, fx.id || '.winner', 'LOCKED', round((1-pA) * 100)::smallint,
       'Pays $1 if ' || fx.team_b || ' advances. Includes ET / penalties.')
    on conflict (id) do nothing;

    -- Goals O/U 2.5
    insert into public.markets (id, fixture_id, type, name, outcome_label, group_key, status, last_px, description)
    values
      (fx.id || '.ou.over',  fx.id, 'OU', 'TOTAL GOALS O/U 2.5 · OVER',  'OVER 2.5',  fx.id || '.ou', 'LOCKED', 51,
       'Pays $1 if combined goals in regulation > 2.5'),
      (fx.id || '.ou.under', fx.id, 'OU', 'TOTAL GOALS O/U 2.5 · UNDER', 'UNDER 2.5', fx.id || '.ou', 'LOCKED', 49,
       'Pays $1 if combined goals in regulation <= 2.5')
    on conflict (id) do nothing;

    -- BTTS
    insert into public.markets (id, fixture_id, type, name, outcome_label, group_key, status, last_px, description)
    values
      (fx.id || '.btts.yes', fx.id, 'BTTS', 'BTTS · YES', 'YES', fx.id || '.btts', 'LOCKED', 53,
       'Pays $1 if both teams score in regulation'),
      (fx.id || '.btts.no',  fx.id, 'BTTS', 'BTTS · NO',  'NO',  fx.id || '.btts', 'LOCKED', 47,
       'Pays $1 if at least one team is shut out in regulation')
    on conflict (id) do nothing;

    -- Method of decision (3-way)
    insert into public.markets (id, fixture_id, type, name, outcome_label, group_key, status, last_px, description)
    values
      (fx.id || '.method.reg', fx.id, 'METHOD', 'METHOD · REGULATION', 'REGULATION', fx.id || '.method', 'LOCKED', 76, 'Pays $1 if decided in 90 min'),
      (fx.id || '.method.et',  fx.id, 'METHOD', 'METHOD · EXTRA TIME', 'EXTRA TIME', fx.id || '.method', 'LOCKED', 16, 'Pays $1 if decided in ET'),
      (fx.id || '.method.pen', fx.id, 'METHOD', 'METHOD · PENALTIES',  'PENALTIES',  fx.id || '.method', 'LOCKED', 8,  'Pays $1 if decided on penalties')
    on conflict (id) do nothing;
  end loop;
end $$;

-- ----- Futures markets -----
-- Tournament winner (11 candidates incl. field)
do $$
declare
  c record;
  cands text[] := array['ARG','FRA','BRA','ENG','ESP','GER','POR','NED','ITA','BEL'];
  weights numeric;
  total_w numeric := 0;
  field_share numeric := 0.10;
  t text;
  prior_pct int;
begin
  -- Compute total elo-based weight
  foreach t in array cands loop
    total_w := total_w + exp(public._team_elo(t)::numeric / 400);
  end loop;

  foreach t in array cands loop
    weights := exp(public._team_elo(t)::numeric / 400);
    prior_pct := round(weights / total_w * (1 - field_share) * 100)::int;
    insert into public.markets (id, fixture_id, type, name, outcome_label, team_code, group_key, status, last_px, description)
    values ('fut.winner.' || t, null, 'FUTURE', 'TOURNAMENT WINNER · ' || t, public._team_name(t),
            t, 'fut.winner', 'LOCKED', prior_pct,
            'Pays $1 if ' || t || ' wins the WC26 Final.')
    on conflict (id) do nothing;
  end loop;

  -- Field
  insert into public.markets (id, type, name, outcome_label, group_key, status, last_px, description)
  values ('fut.winner.field', 'FUTURE', 'TOURNAMENT WINNER · FIELD', 'FIELD',
          'fut.winner', 'LOCKED', round(field_share * 100)::int,
          'Pays $1 if any team not listed individually wins the Final.')
  on conflict (id) do nothing;
end $$;

-- Golden Boot (8 candidates incl. field)
insert into public.markets (id, type, name, outcome_label, team_code, group_key, status, last_px, description) values
  ('fut.boot.ARG', 'FUTURE', 'GOLDEN BOOT · Messi (ARG)',    'Messi (ARG)',    'ARG', 'fut.boot', 'LOCKED', 14, 'Top scorer at WC26'),
  ('fut.boot.FRA', 'FUTURE', 'GOLDEN BOOT · Mbappé (FRA)',   'Mbappé (FRA)',   'FRA', 'fut.boot', 'LOCKED', 18, 'Top scorer at WC26'),
  ('fut.boot.BRA', 'FUTURE', 'GOLDEN BOOT · Vinícius (BRA)', 'Vinícius (BRA)', 'BRA', 'fut.boot', 'LOCKED', 12, 'Top scorer at WC26'),
  ('fut.boot.ENG', 'FUTURE', 'GOLDEN BOOT · Kane (ENG)',     'Kane (ENG)',     'ENG', 'fut.boot', 'LOCKED', 11, 'Top scorer at WC26'),
  ('fut.boot.POR', 'FUTURE', 'GOLDEN BOOT · Ronaldo (POR)',  'Ronaldo (POR)',  'POR', 'fut.boot', 'LOCKED', 8,  'Top scorer at WC26'),
  ('fut.boot.GER', 'FUTURE', 'GOLDEN BOOT · Musiala (GER)',  'Musiala (GER)',  'GER', 'fut.boot', 'LOCKED', 7,  'Top scorer at WC26'),
  ('fut.boot.ESP', 'FUTURE', 'GOLDEN BOOT · Yamal (ESP)',    'Yamal (ESP)',    'ESP', 'fut.boot', 'LOCKED', 7,  'Top scorer at WC26'),
  ('fut.boot.field','FUTURE','GOLDEN BOOT · FIELD',          'FIELD',          null, 'fut.boot', 'LOCKED', 23, 'Top scorer at WC26 (other)')
on conflict (id) do nothing;

-- Bracket props (binary)
insert into public.markets (id, type, name, outcome_label, group_key, status, last_px, description) values
  ('prop.upper.upper', 'FUTURE', 'CHAMPION FROM UPPER BRACKET · UPPER', 'UPPER HALF', 'prop.upper', 'LOCKED', 50, 'Winner emerges from upper half (fixtures 1-8)'),
  ('prop.upper.lower', 'FUTURE', 'CHAMPION FROM UPPER BRACKET · LOWER', 'LOWER HALF', 'prop.upper', 'LOCKED', 50, 'Winner emerges from lower half (fixtures 9-16)'),
  ('prop.uefasf.yes',  'FUTURE', 'ALL-UEFA SEMIFINAL · YES',            'YES',        'prop.uefasf','LOCKED', 38, 'All four SF teams are UEFA nations'),
  ('prop.uefasf.no',   'FUTURE', 'ALL-UEFA SEMIFINAL · NO',             'NO',         'prop.uefasf','LOCKED', 62, 'Not all SF teams are UEFA'),
  ('prop.hostqf.yes',  'FUTURE', 'HOST NATION REACHES QF · YES',        'YES',        'prop.hostqf','LOCKED', 28, 'USA/MEX/CAN reaches QF'),
  ('prop.hostqf.no',   'FUTURE', 'HOST NATION REACHES QF · NO',         'NO',         'prop.hostqf','LOCKED', 72, 'No host nation reaches QF'),
  ('prop.afrsf.yes',   'FUTURE', 'AFRICAN NATION REACHES SF · YES',     'YES',        'prop.afrsf', 'LOCKED', 22, 'A CAF nation makes SF'),
  ('prop.afrsf.no',    'FUTURE', 'AFRICAN NATION REACHES SF · NO',      'NO',         'prop.afrsf', 'LOCKED', 78, 'No CAF nation in SF')
on conflict (id) do nothing;

-- ============================================================================
-- HOUSE LIQUIDITY
-- Seed the order book with house bids and asks around each market's prior.
-- ============================================================================
do $$
declare
  m record;
  v_house_id uuid := '00000000-0000-0000-0000-00000000ffff';
  mid_px smallint;
  spread smallint;
  i int;
  bid_px smallint; ask_px smallint;
  qty int;
  order_id uuid;
  reserve_c bigint;
begin
  -- Set every market to OPEN for seeding (we'll lock them again at the end).
  -- This is so place_order's MARKET_NOT_OPEN check passes during seeding.
  -- Actually, we'll insert orders DIRECTLY here, not via place_order, since
  -- the house is special and shouldn't go through user-facing flow.

  -- Make sure the house user has enough bankroll
  update public.users set bankroll_c = 1000000000000 where id = v_house_id;

  for m in select id, last_px from public.markets order by id loop
    mid_px := coalesce(m.last_px, 50);
    spread := case when mid_px < 10 or mid_px > 90 then 4 else 2 end;

    for i in 0..3 loop
      bid_px := greatest(1, mid_px - (spread/2) - i);
      ask_px := least(99, mid_px + ((spread+1)/2) + i);
      qty := 100 + (random()*200)::int + i*60;

      -- House BID
      if bid_px >= 1 then
        order_id := gen_random_uuid();
        reserve_c := (qty * bid_px)::bigint;
        insert into public.orders (id, user_id, market_id, side, limit_px, qty, filled_qty, status, reserved_c)
        values (order_id, v_house_id, m.id, 'BUY', bid_px, qty, 0, 'OPEN', reserve_c);
        -- Skip ledger entry for house seeding to keep audit log clean
        update public.users set bankroll_c = bankroll_c - reserve_c where id = v_house_id;
      end if;

      -- House ASK
      if ask_px <= 99 then
        order_id := gen_random_uuid();
        reserve_c := (qty * (100 - ask_px))::bigint;
        insert into public.orders (id, user_id, market_id, side, limit_px, qty, filled_qty, status, reserved_c)
        values (order_id, v_house_id, m.id, 'SELL', ask_px, qty, 0, 'OPEN', reserve_c);
        update public.users set bankroll_c = bankroll_c - reserve_c where id = v_house_id;
      end if;
    end loop;

    -- Refresh denormalized best_bid/best_ask
    perform public._refresh_market_book(m.id);
  end loop;
end $$;

-- ============================================================================
-- OPEN ALL MARKETS FOR TRADING
-- For DEV: open immediately so you can test.
-- For PROD: leave them LOCKED, and run a scheduled job at 2026-06-30 20:00 UTC
--           that does `update markets set status = 'OPEN'` then.
-- ============================================================================
-- Uncomment for dev:
update public.markets set status = 'OPEN';

-- Refresh leaderboard materialized view so it has rows
refresh materialized view public.leaderboard;
