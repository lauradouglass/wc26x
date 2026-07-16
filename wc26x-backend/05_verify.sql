-- ============================================================================
-- WC26-X — POST-SETUP VERIFICATION
-- ============================================================================

\echo '========== 1. Tables exist =========='
select
  (select count(*) from information_schema.tables where table_schema='public' and table_name in
    ('users','fixtures','markets','orders','fills','positions','ledger')) as core_tables_present,
  (select count(*) from information_schema.routines where routine_schema='public' and routine_name in
    ('place_order','cancel_order','create_user_profile','admin_record_fixture_result','admin_settle_market_group','admin_auto_settle_deadline','get_order_book','_refresh_market_book','_update_position_on_fill','_ledger_insert','refresh_leaderboard')) as core_functions_present;
-- 7 tables, 11 functions

\echo '========== 2. Fixtures seeded =========='
select count(*) as fixtures from public.fixtures;
-- 16

\echo '========== 3. Markets seeded =========='
select type, count(*) from public.markets group by type order by 1;
-- BTTS:32, FUTURE:27, METHOD:48, OU:32, WINNER:32

\echo '========== 4. House liquidity present =========='
select
  count(*) filter (where side='BUY')  as house_bids,
  count(*) filter (where side='SELL') as house_asks,
  count(distinct market_id)            as markets_with_book
from public.orders where user_id = '00000000-0000-0000-0000-00000000ffff';
-- ~600 bids, ~600 asks, 159 markets

\echo '========== 5. Markets are OPEN for testing =========='
select status, count(*) from public.markets group by status;
-- OPEN: 171 (all)

\echo '========== 6. Sample book sanity =========='
select id, best_bid, best_ask, last_px from public.markets
  where id like 'r32.01%' order by id;

\echo '========== 7. RLS is enabled =========='
select tablename, rowsecurity from pg_tables
  where schemaname = 'public'
    and tablename in ('users','orders','fills','positions','ledger','markets','fixtures');

\echo '========== 8. Leaderboard view ready =========='
select count(*) as leaderboard_rows from public.leaderboard;

