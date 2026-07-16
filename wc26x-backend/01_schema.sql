-- ============================================================================
-- WC26-X — SCHEMA
--
-- Conventions:
--   - All monetary values are bigint CENTS. Never floats. $10,000 = 1_000_000.
--   - All prices are smallint CENTS in [1, 99]. A YES share pays out 100¢ ($1).
--   - Positions are SIGNED YES shares: +shares = long YES, -shares = short YES (= long NO).
--   - Avg cost is stored in CENTS_PER_SHARE * 10000 (i.e. 4 decimals of cents) as bigint.
--     This lets us track fractional avg cost without floats.
-- ============================================================================

-- Extensions
create extension if not exists "pgcrypto"; -- gen_random_uuid

-- Enums
do $$ begin
  create type market_type as enum ('WINNER','OU','BTTS','METHOD','FUTURE');
exception when duplicate_object then null; end $$;

do $$ begin
  create type market_status as enum ('LOCKED','OPEN','SUSPENDED','SETTLING','SETTLED','CANCELLED');
exception when duplicate_object then null; end $$;

do $$ begin
  create type order_side as enum ('BUY','SELL'); -- BUY = take YES; SELL = take NO (= sell YES)
exception when duplicate_object then null; end $$;

do $$ begin
  create type order_status as enum ('OPEN','FILLED','PARTIAL','CANCELLED','REJECTED');
exception when duplicate_object then null; end $$;


-- ============================================================================
-- USERS
-- Supabase Auth handles the auth.users table.
--  extend it with our public.users profile.
-- ============================================================================
create table if not exists public.users (
  id            uuid primary key,
  display_name  text        not null,
  linkedin_url  text        not null,
  email         text        not null,
  bankroll_c    bigint      not null default 1000000,  -- cents (= $10,000)
  realized_c    bigint      not null default 0,
  trade_count   integer     not null default 0,
  is_admin      boolean     not null default false,
  is_banned     boolean     not null default false,
  is_house      boolean     not null default false,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  -- Uniqueness — one display name and one linkedin per contest
  constraint users_display_name_uniq unique (display_name),
  constraint users_linkedin_uniq     unique (linkedin_url),
  constraint users_email_uniq        unique (email)
);

-- FK to auth.users, but DEFERRABLE so we can insert the house user without
-- requiring an auth.users row. The FK is enforced at end-of-transaction.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'users_id_fkey'
  ) then
    alter table public.users
      add constraint users_id_fkey
      foreign key (id) references auth.users(id)
      on delete cascade
      deferrable initially deferred;
  end if;
exception when others then
  -- If we don't have access to auth schema, skip the FK. The app-layer
  -- create_user_profile() function ensures consistency in normal flow.
  raise notice 'Could not add FK on users.id (auth.users not accessible); continuing without FK';
end $$;

create index if not exists users_realized_idx on public.users (realized_c desc)
  where is_banned = false and is_house = false;

-- ============================================================================
-- FIXTURES
-- A single row per knockout fixture. 
-- ============================================================================
create table if not exists public.fixtures (
  id          text primary key,         -- 'r32.01', 'r16.01', 'qf.01', ...
  round       text not null,            -- 'R32','R16','QF','SF','F'
  team_a      text not null,            -- ISO/FIFA 3-letter code, e.g. 'ARG'
  team_b      text not null,
  kickoff_at  timestamptz,
  venue       text,
  status      text not null default 'SCHEDULED',  -- SCHEDULED / LIVE / FINAL
  -- Settlement
  winner_team text,        -- 'ARG' or 'BRA' once known
  goals_a     smallint,
  goals_b     smallint,
  method      text,        -- 'REGULATION','ET','PENALTIES'
  settled_at  timestamptz,
  created_at  timestamptz not null default now()
);

-- ============================================================================
-- MARKETS
-- Each row is a single tradeable contract. A "match winner" market for one
-- fixture produces two markets (Team A wins, Team B wins) — actually, we model
-- each market as a single contract that pays $1 to the YES side. So:
--   - Match Winner ARG-vs-BRA → 2 markets: "ARG.winner", "BRA.winner"
--   - Total Goals O/U 2.5     → 2 markets: "OVER", "UNDER"
--   - Method of Decision      → 3 markets: "REG", "ET", "PEN"
--   - Tournament Winner       → 11 markets: one per candidate (incl. field)
-- This single-contract-per-outcome design makes the matching engine simple.
-- ============================================================================
create table if not exists public.markets (
  id            text primary key,        -- e.g. 'r32.01.winner.a' or 'fut.winner.ARG'
  fixture_id    text references public.fixtures(id),  -- null for futures
  type          market_type not null,
  name          text not null,           -- "MATCH WINNER · ARG"
  outcome_label text not null,           -- "Argentina"
  -- Display fields
  description   text,
  team_code     text,                    -- 'ARG' for team-related; null otherwise
  -- Group key — markets that resolve together share this. Used for fast
  -- settlement and the Σ-mid arb check.
  group_key     text not null,           -- e.g. 'r32.01.winner', 'fut.winner', 'r32.01.ou'
  -- Status / settlement
  status        market_status not null default 'LOCKED',
  resolves_yes  boolean,                 -- null until settled; true = $1 to YES holders
  -- Last trade and best book metadata (denormalized for speed)
  last_px       smallint,                -- cents
  best_bid      smallint,
  best_ask      smallint,
  volume        integer not null default 0,
  -- Audit
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists markets_group_idx     on public.markets (group_key);
create index if not exists markets_fixture_idx   on public.markets (fixture_id);
create index if not exists markets_status_idx    on public.markets (status);

-- ============================================================================
-- ORDERS
-- An order is an instruction. Once placed it either fills (consumes other
-- resting orders), rests (becomes a resting order itself), or both.
-- ============================================================================
create table if not exists public.orders (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.users(id) on delete cascade,
  market_id     text not null references public.markets(id),
  side          order_side not null,        -- BUY = long YES; SELL = long NO
  limit_px      smallint not null check (limit_px between 1 and 99),
  qty           integer  not null check (qty between 1 and 500),  -- max 500/order
  filled_qty    integer  not null default 0,
  remaining_qty integer  not null,          -- qty - filled_qty, denormalized for index
  avg_fill_px_c numeric(10,4),              -- cents per share, 4 decimals
  status        order_status not null default 'OPEN',
  -- Cash reserved up-front (cents). For BUY, this is qty * limit_px - refunded as fills come in better.
  -- For SELL, this is qty * (100 - limit_px) - the short-side margin.
  reserved_c    bigint not null,
  -- Audit
  created_at    timestamptz not null default now(),
  filled_at     timestamptz,
  cancelled_at  timestamptz
);

-- Critical index for book scans: resting orders by market, side, price, time.
-- Bids (BUY) want highest price first; asks (SELL) want lowest price first.
create index if not exists orders_book_buy_idx
  on public.orders (market_id, limit_px desc, created_at asc)
  where status in ('OPEN','PARTIAL') and side = 'BUY';

create index if not exists orders_book_sell_idx
  on public.orders (market_id, limit_px asc, created_at asc)
  where status in ('OPEN','PARTIAL') and side = 'SELL';

create index if not exists orders_user_idx on public.orders (user_id, created_at desc);

-- ============================================================================
-- FILLS — the actual matched trades
-- A fill is created when one taker order consumes one maker order (partial or full).
-- A single submit can generate many fills.
-- ============================================================================
create table if not exists public.fills (
  id              uuid primary key default gen_random_uuid(),
  market_id       text not null references public.markets(id),
  taker_order_id  uuid not null references public.orders(id),
  maker_order_id  uuid not null references public.orders(id),
  taker_user_id   uuid not null references public.users(id),
  maker_user_id   uuid not null references public.users(id),
  taker_side      order_side not null, -- side of the taker
  qty             integer  not null check (qty > 0),
  price_c         smallint not null check (price_c between 1 and 99),
  created_at      timestamptz not null default now()
);

create index if not exists fills_market_time_idx on public.fills (market_id, created_at desc);
create index if not exists fills_user_idx        on public.fills (taker_user_id, created_at desc);
create index if not exists fills_maker_user_idx  on public.fills (maker_user_id, created_at desc);

-- ============================================================================
-- POSITIONS
-- One row per (user, market). Maintained by the matching engine.
-- Cleared (deleted) when shares hits zero.
-- ============================================================================
create table if not exists public.positions (
  user_id       uuid not null references public.users(id) on delete cascade,
  market_id     text not null references public.markets(id),
  shares        integer not null,         -- signed; + long YES, - short YES (= long NO)
  avg_cost_c    numeric(10,4) not null,    -- cents per share (4 decimals)
  updated_at    timestamptz not null default now(),
  primary key (user_id, market_id)
);

create index if not exists positions_user_idx on public.positions (user_id);
create index if not exists positions_market_idx on public.positions (market_id);

-- ============================================================================
-- LEDGER
-- An append-only log of every cash movement (debit/credit) and realized PnL event.
-- Used for the audit at payout. Never updated, only inserted.
-- ============================================================================
do $$ begin
  create type ledger_kind as enum (
    'BANKROLL_INIT','ORDER_RESERVE','ORDER_REFUND','FILL_BUY','FILL_SELL',
    'POSITION_REALIZED','SETTLEMENT','ADMIN_ADJUST'
  );
exception when duplicate_object then null; end $$;

create table if not exists public.ledger (
  id          bigserial primary key,
  user_id     uuid not null references public.users(id) on delete cascade,
  kind        ledger_kind not null,
  ref_id      text,                        -- order id, fill id, market id, etc.
  delta_c     bigint not null,             -- signed cents (cash delta)
  realized_delta_c bigint not null default 0,
  balance_after_c  bigint not null,
  notes       jsonb,
  created_at  timestamptz not null default now()
);

create index if not exists ledger_user_time_idx on public.ledger (user_id, created_at desc);

-- ============================================================================
-- LEADERBOARD VIEW
-- Public materialized view, refreshed every 30s by a cron job.
-- Excludes the house and banned users.
-- ============================================================================
create materialized view if not exists public.leaderboard as
  select
    u.id,
    u.display_name,
    u.linkedin_url,
    u.realized_c,
    u.trade_count,
    rank() over (order by u.realized_c desc) as rank,
    u.updated_at
  from public.users u
  where u.is_banned = false
    and u.is_house = false;

create unique index if not exists leaderboard_id_idx on public.leaderboard (id);
create index        if not exists leaderboard_rank_idx on public.leaderboard (rank);

-- ============================================================================
-- ROW LEVEL SECURITY
-- ============================================================================
alter table public.users      enable row level security;
alter table public.orders     enable row level security;
alter table public.fills      enable row level security;
alter table public.positions  enable row level security;
alter table public.ledger     enable row level security;
alter table public.markets    enable row level security;
alter table public.fixtures   enable row level security;

-- USERS: anyone can read display_name + linkedin + realized for leaderboard; only owner can read full row
drop policy if exists "users_self_read"   on public.users;
drop policy if exists "users_public_read" on public.users;
drop policy if exists "users_self_update" on public.users;

create policy "users_self_read"   on public.users for select using (auth.uid() = id);
create policy "users_public_read" on public.users for select using (true);  -- relies on column exposure via views
create policy "users_self_update" on public.users for update using (auth.uid() = id);

-- MARKETS / FIXTURES — public read
drop policy if exists "markets_public_read"  on public.markets;
drop policy if exists "fixtures_public_read" on public.fixtures;
create policy "markets_public_read"  on public.markets  for select using (true);
create policy "fixtures_public_read" on public.fixtures for select using (true);

-- ORDERS — owner reads & inserts via RPC (no direct INSERT); we drop INSERT and route through place_order()
drop policy if exists "orders_self_read"   on public.orders;
create policy "orders_self_read"   on public.orders for select using (auth.uid() = user_id);

-- FILLS — public read (so the tape is shared); insert via engine only
drop policy if exists "fills_public_read" on public.fills;
create policy "fills_public_read" on public.fills for select using (true);

-- POSITIONS — owner reads
drop policy if exists "positions_self_read" on public.positions;
create policy "positions_self_read" on public.positions for select using (auth.uid() = user_id);

-- LEDGER — owner reads
drop policy if exists "ledger_self_read" on public.ledger;
create policy "ledger_self_read" on public.ledger for select using (auth.uid() = user_id);

-- Default: no INSERT/UPDATE/DELETE for anon/authenticated on orders/fills/positions/ledger.
-- All writes go through SECURITY DEFINER RPCs in engine.sql.

-- ============================================================================
-- TRIGGER: keep orders.remaining_qty consistent
-- ============================================================================
create or replace function public._sync_remaining_qty()
returns trigger language plpgsql as $$
begin
  new.remaining_qty := new.qty - new.filled_qty;
  return new;
end $$;

drop trigger if exists trg_orders_remaining on public.orders;
create trigger trg_orders_remaining
  before insert or update of qty, filled_qty on public.orders
  for each row execute function public._sync_remaining_qty();

-- ============================================================================
-- TRIGGER: bump users.updated_at
-- ============================================================================
create or replace function public._bump_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

drop trigger if exists trg_users_updated on public.users;
create trigger trg_users_updated
  before update on public.users
  for each row execute function public._bump_updated_at();

drop trigger if exists trg_markets_updated on public.markets;
create trigger trg_markets_updated
  before update on public.markets
  for each row execute function public._bump_updated_at();
