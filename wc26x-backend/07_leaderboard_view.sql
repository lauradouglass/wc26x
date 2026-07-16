-- ============================================================================
-- WC26-X — LEADERBOARD VIEW (migration 07)
--
-- Design Notes:
--   - the leaderboard reflects every trade immediately
--   - no scheduled job needed
-- ============================================================================

drop materialized view if exists public.leaderboard cascade;
drop function if exists public.refresh_leaderboard();

create view public.leaderboard as
select
  u.id,
  u.display_name,
  u.linkedin_url,
  u.realized_c,
  u.trade_count,
  rank() over (order by u.realized_c desc, u.trade_count asc) as rank,
  u.updated_at
from public.users u
where u.is_house = false
  and u.is_banned = false
  and u.display_name is not null;

grant select on public.leaderboard to anon, authenticated;
