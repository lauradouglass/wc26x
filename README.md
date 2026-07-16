# WC26-X — World Cup 2026 Prediction Exchange

A fully functional play-money prediction market exchange for the 2026 FIFA World Cup. Users trade binary event contracts on match outcomes (result, over/under 2.5 goals, both teams to score) through a central limit order book with continuous double-auction matching.

[**Live HERE!**](https://wc26x.netlify.app) \
    \
**Stack:** Single-file HTML frontend · Supabase (PostgreSQL 15) backend · Realtime WebSocket push


---

## About
 
A few months ago I won $180 trading recessions and US gas prices on Kalshi. It was thrilling, but it left me curious about what was running underneath. How does the price actually move? Who's on the other side of my trade? How does the platform know what to pay me when the event resolves?
 
The way I learn is by building. So I built one, a working exchange with a real matching engine, position accounting, settlement, and real-time data distribution, using the 2026 World Cup as the settlement oracle.
 
What I set out to understand:
 
- **Market microstructure** — how a bid-ask spread emerges from order flow, why price-time priority matters, what happens when two orders cross
- **The accounting** — weighted-average cost basis, when P&L is realized vs. unrealized, how a position flips through zero
- **Risk containment** — how a platform guarantees a trader can never owe more than they deposited
- **Concurrency** — what actually breaks when two people hit the same resting order at the same instant
The answers are in the code, and the math is documented below rather than left implicit.
 
The matching engine was later extracted into [pyclob](https://github.com/lauradouglass/pyclob), a pip-installable Python library with 29 tests covering every edge case.
 

---

## Market Microstructure

### Contract Design

Each tradeable market is a **binary event contract** that pays $1.00 if the specified outcome occurs, $0.00 otherwise. Prices are quoted in cents (1¢–99¢) and represent implied probabilities.

For a group-stage fixture (e.g., Mexico vs South Africa), three market groups are created:

| Market Group | Outcomes | Settlement Condition |
|---|---|---|
| **Match Result** (3-way) | Home / Draw / Away | Determined by final score |
| **Total Goals O/U 2.5** | Over / Under | Total goals ≥ 3 → Over wins |
| **Both Teams to Score** | Yes / No | Both teams score ≥ 1 → Yes wins |

Each outcome is an independent binary contract. In a 3-way result market, the three contracts are **not** constrained to sum to $1 — each trades independently as its own YES/NO pair. This means the book can briefly imply >100% or <100% aggregate probability across outcomes, creating arbitrage opportunities identical to those found in real sportsbook markets.

### Order Book Structure

The exchange implements a **continuous limit order book (CLOB)** with **price-time priority**:

- **Price priority:** The best-priced order always fills first. For buy orders, the highest bid; for sell orders, the lowest ask.
- **Time priority:** At the same price level, the order that arrived first fills first (FIFO).
- **No self-trade:** A user's incoming order will never match against their own resting order.
- **Partial fills:** An incoming order can sweep multiple price levels or partially fill against a single resting order. The unfilled remainder rests as a new limit order.

The bid-ask spread emerges organically from participant order flow. House liquidity seeds initial markets at calibrated prices to bootstrap two-sided books.

### Position Accounting

Positions are tracked as **signed share counts** with a **weighted-average cost basis**:

- `shares > 0` → long YES (bullish on the outcome)
- `shares < 0` → short YES / long NO (bearish on the outcome)

When a fill occurs, position accounting follows one of three paths:

**1. Opening or adding (same direction):**
$$\text{avg\_cost} = \frac{|S_{\text{old}}| \cdot C_{\text{old}} + Q \cdot P_{\text{fill}}}{|S_{\text{new}}|}$$

where $S$ = shares, $C$ = cost basis, $Q$ = fill quantity, $P$ = fill price.

**2. Reducing (opposite direction, not flipping):**
$$\text{realized} = (P_{\text{fill}} - C_{\text{old}}) \cdot Q_{\text{close}} \quad \text{(if closing a long)}$$
$$\text{realized} = (C_{\text{old}} - P_{\text{fill}}) \cdot Q_{\text{close}} \quad \text{(if closing a short)}$$

Cost basis on the remaining position is unchanged.

**3. Flipping (opposite direction, crossing zero):**

The closing portion realizes P&L as above. The leftover opens a new position at the fill price.

All arithmetic is in **integer cents** (bigint) to avoid floating-point drift. Cost basis is stored as `numeric(10,4)` for weighted-average precision.

---

## Matching Engine

### Architecture

The matching engine runs entirely inside PostgreSQL as a single PL/pgSQL function (`place_order`). This is a deliberate architectural choice: by keeping the entire order lifecycle inside a single database transaction, we get **serializable atomicity for free** — reserve, match, fill, position update, and bankroll mutation either all commit or all roll back. There is no application-layer state that can desynchronize from the database.

### Concurrency Control

Two users submitting orders to the same market simultaneously is the canonical race condition in exchange design. WC26-X handles this with two levels of locking:

**1. Market-level mutex:** The engine acquires a `SELECT ... FOR UPDATE` lock on the market row before entering the matching loop. This serializes all concurrent takers on the same market — while one transaction is matching, any other taker blocks until the first commits.

**2. Order-level locking:** Each resting order consumed during matching is locked with `SELECT ... FOR UPDATE SKIP LOCKED`. The `SKIP LOCKED` is defensive — under the market mutex, contention on individual orders shouldn't occur, but it prevents deadlocks if the locking topology changes.

**3. User-level locking:** The taker's user row is locked (`FOR UPDATE`) before the reserve deduction, preventing concurrent orders from the same user from double-spending their bankroll.

### Reserve System

When an order is placed, cash is reserved (escrowed) from the user's bankroll immediately:

| Side | Reserve per share | Rationale |
|---|---|---|
| **BUY** (long YES) | `limit_px` cents | Maximum loss if YES doesn't happen |
| **SELL** (short YES) | `100 - limit_px` cents | Maximum loss if YES happens ($1 payout obligation minus premium received) |

If the fill price is better than the limit price, the difference is refunded:

- **BUY fill at P < limit:** refund = `(limit - P) × qty` (overpaid reserve)
- **SELL fill at P > limit:** refund = `(P - limit) × qty` (overcollateralized margin)

This ensures **no user can ever owe more than their bankroll** — the worst-case payout is fully collateralized at order time.

### Matching Loop

```
for each resting order on the opposite side (price-time priority):
    if no more crossable orders → exit
    fill_qty  = min(remaining_taker_qty, resting_maker_qty)
    fill_px   = maker's limit price (price improvement goes to taker)
    
    1. Create fill record (audit trail)
    2. Update maker order (filled_qty, status)
    3. Update taker + maker positions (_update_position_on_fill)
    4. Record maker ledger entry
    5. Increment maker trade count
    6. Update market last_px + volume
    
after loop:
    7. Refund taker's overpaid reserve
    8. Record taker ledger entry
    9. Increment taker trade count
    10. Set taker order final status (FILLED / PARTIAL / OPEN)
    11. Refresh market best_bid / best_ask
```

Price improvement always favors the taker — if a buy order at 45¢ matches against a resting sell at 41¢, the fill occurs at 41¢, and the taker receives a 4¢/share reserve refund.

---

## Settlement

### Group Stage Settlement

When a group-stage match finishes, the admin enters the final score. The settlement function derives all market outcomes deterministically:

```
goals_home > goals_away → result.home wins
goals_home < goals_away → result.away wins
goals_home = goals_away → result.draw wins
goals_home + goals_away ≥ 3 → ou.over wins
goals_home > 0 AND goals_away > 0 → btts.yes wins
```

For each market, settlement proceeds in two phases:

**Phase 1 — Cancel resting orders:** All open/partial orders are cancelled, reserves refunded to bankroll. This returns uncommitted capital to users.

**Phase 2 — Payout positions:** Each position is settled at the terminal price:

| Position | Outcome Won | Payout | Realized Delta |
|---|---|---|---|
| Long YES (shares > 0) | YES wins | `shares × 100¢` | `(100 - avg_cost) × shares` |
| Long YES (shares > 0) | NO wins | `0` | `(0 - avg_cost) × shares` |
| Short YES (shares < 0) | YES wins | `0` | `(avg_cost - 100) × |shares|` |
| Short YES (shares < 0) | NO wins | `|shares| × 100¢` | `(avg_cost - 0) × |shares|` |

Settlement is **idempotent** — re-running on an already-settled market is a no-op. Realized P&L from settlement is additive with any P&L already realized from closing trades during the market's lifetime.

---

## Real-Time System

The frontend subscribes to five PostgreSQL tables via Supabase Realtime (WebSocket channels):

| Table | Event | UI Update |
|---|---|---|
| `fills` | INSERT | Tape, sparklines, market prices |
| `markets` | UPDATE | Best bid/ask, last price |
| `positions` | INSERT/UPDATE/DELETE | Position panel, open P&L |
| `orders` | INSERT/UPDATE | Open orders panel |
| `users` | UPDATE | Bankroll, realized P&L, leaderboard |

Cross-user fills propagate to both windows within ~1 second without polling. When User A's resting bid is hit by User B, User A sees their position update, bankroll change, and leaderboard re-rank — all pushed via WebSocket, not fetched.

---

## Bankroll & Leaderboard

**Starting bankroll:** $10,000 play money per user.

**Leaderboard ranking:** Top 3 by **realized P&L** at the July 19, 2026 deadline win the prize pool. Realized P&L is the sum of:
1. P&L crystallized by closing trades during market lifetime
2. P&L crystallized by settlement when markets resolve

Open (unrealized) P&L from unsettled positions does not count toward ranking. This incentivizes active position management and conviction-based trading rather than passive holding.

The leaderboard is computed as a live database view (not a materialized view), ensuring rankings reflect the latest settlement within milliseconds.

---

## Security Model

- **Row-Level Security (RLS):** Every table has RLS enabled. Users can only read their own orders and positions; fills and markets are globally readable.
- **SECURITY DEFINER functions:** All write operations (`place_order`, `cancel_order`, settlement RPCs) run as the function owner, bypassing RLS internally while enforcing authorization via `auth.uid()` checks.
- **No client-side state mutation:** The frontend is a read-through cache. All writes go through RPCs; the UI re-hydrates from the database after every action.
- **Admin bypass helper:** Settlement functions recognize SQL editor sessions (`postgres` role), service-role JWTs, and `is_admin` flag — enabling operational flexibility without compromising user-facing security.

---

## Technical Stack

| Layer | Technology | Rationale |
|---|---|---|
| **Frontend** | Single HTML file (~3,400 lines), vanilla JS, CSS | Zero build step, instant deploy, no framework overhead |
| **Database** | PostgreSQL 15 (Supabase) | ACID transactions, row-level locking, PL/pgSQL matching engine |
| **Auth** | Supabase Auth (email + magic link) | Handles JWT issuance, session management |
| **Realtime** | Supabase Realtime (WebSocket) | Change data capture on 5 tables, sub-second push |
| **Hosting** | Netlify (static) | CDN-backed, single-file deploy |
| **Data ingestion** | Node.js sync script + API-Football | Fixture + result ingestion, staging table for admin review |

### Why Not a Separate Backend?

The matching engine lives in PostgreSQL because the database is the **only component that can provide serializable transaction guarantees without distributed coordination.** A Node/Python backend would require explicit distributed locking (Redis, advisory locks) to prevent race conditions during matching — adding complexity without adding capability. By pushing the engine into PL/pgSQL, we get linearizable order processing as a property of the database itself.

This is the same architectural pattern used by several real prediction market platforms and smaller crypto exchanges where throughput requirements don't justify a dedicated matching engine process.

---

## Project Structure

```
wc26x-live.html          — Complete frontend (auth, trading, admin, realtime)
01_schema.sql            — Tables, enums, RLS policies, indexes
02_engine.sql            — place_order(), cancel_order(), position accounting
03_seed.sql              — House liquidity + Golden Boot futures
04_settle.sql            — Original settlement functions (superseded by 09)
06_worldcup_pivot.sql    — API-Football fixture sync, market creation
07_leaderboard_view.sql  — Live leaderboard view (replaced materialized view)
09_group_settlement.sql  — Group-stage settlement, admin bypass, pending results
sync-fixtures.mjs        — Node script: API-Football → Supabase fixture sync
```

---

## Key Design Decisions

1. **Integer arithmetic everywhere.** All cash is stored as `bigint` cents. Cost basis is `numeric(10,4)`. No `float` or `double precision` anywhere in the money path. This eliminates accumulated rounding errors across thousands of fills.

2. **Single-function matching.** The entire order lifecycle — validation, reservation, matching loop, position update, ledger entry, book refresh — runs in one PL/pgSQL function call. This is atomic by construction; there is no possibility of a half-executed trade.

3. **Human-confirmed settlement.** Results are staged (via API sync or manual entry), then explicitly confirmed by an admin before payouts execute. This prevents incorrect API data from silently settling markets. The flow mirrors how real clearinghouses handle corporate actions — automated ingestion, human confirmation, atomic execution.

4. **Realized P&L for ranking.** Using realized (not mark-to-market) P&L for the leaderboard rewards trading skill over passive position-holding. A trader who correctly predicts an outcome AND manages entry/exit timing ranks higher than one who buys and holds at the same price.

5. **Independent binary contracts for 3-way markets.** Rather than constraining home + draw + away probabilities to sum to 100%, each outcome trades independently. This is simpler to implement and creates a richer microstructure — arbitrageurs can exploit probability sum deviations, adding a layer of strategic depth.

---

## Running Locally

1. Clone and open `wc26x-live.html` in a browser.
2. The frontend connects to the live Supabase project (publishable key is embedded).
3. Sign up with any email + LinkedIn URL. Trading is live when the contest is open.

For backend development:
1. Run the SQL files (01–09) against a Supabase project in order.
2. Run `sync-fixtures.mjs` with API-Football credentials to populate fixtures.
3. Update `SUPA_URL` and `SUPA_KEY` in the HTML if using a different Supabase project.

---

## Author

Built by ([Laura Douglas](https://linkedin.com/in/laura-douglas-904a741ab)).
BS Computer Engineering, Drexel University. Incoming MS Mathematics in Finance, NYU Courant.