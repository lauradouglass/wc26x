# WC26-X — World Cup 2026 Prediction Exchange

A prediction market exchange for the 2026 FIFA World Cup. Binary event contracts on match outcomes, traded through a central limit order book with continuous double-auction matching.

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

[**View the exchange live HERE!**](https://wc26x.netlify.app)


---

## Market Microstructure

### Contract Design

Each market is a **binary event contract** paying $1.00 if the outcome occurs, $0.00 otherwise. Prices in cents (1¢–99¢) represent implied probabilities, a contract at 40¢ implies the market thinks there's roughly a 40% chance.

For each group-stage fixture, three market groups are created:

| Market Group | Outcomes | Settlement Condition |
|---|---|---|
| **Match Result** (3-way) | Home / Draw / Away | Determined by final score |
| **Total Goals O/U 2.5** | Over / Under | Total goals ≥ 3 → Over wins |
| **Both Teams to Score** | Yes / No | Both teams score ≥ 1 → Yes wins |

Each outcome trades independently as its own YES/NO pair. The three result contracts are **not** constrained to sum to $1, so the book can briefly imply >100% or <100% aggregate probability, the same arbitrage surface that exists in real sportsbook markets.

### Order Book

A **continuous limit order book (CLOB)** with **price-time priority**:

- **Price priority:** Best-priced resting order fills first. Highest bid for incoming sells, lowest ask for incoming buys.
- **Time priority:** At the same price, earliest order fills first (FIFO).
- **Self-trade prevention:** An order never matches against another order from the same account.
- **Partial fills:** Incoming orders can sweep multiple price levels. The unfilled remainder rests as a new limit.
- **Price improvement:** A buy at 45¢ matching a resting sell at 41¢ fills at **41¢** — the maker's price. The taker gets the better deal.

### Position Accounting

Positions are **signed share counts** with a **weighted-average cost basis**:

- `shares > 0` → long YES
- `shares < 0` → short YES / long NO

Three accounting paths on fill:

**1. Opening or adding (same direction):**

$$C_{new} = \frac{|S_{old}| \cdot C_{old} + Q_{fill} \cdot P_{fill}}{|S_{new}|}$$

No P&L realized, the position grows at a blended cost.

**2. Reducing (opposite direction, not crossing zero):**

```
If closing a long:  realized = (fill_price - avg_cost) × closing_qty
If closing a short: realized = (avg_cost - fill_price) × closing_qty
```

The remaining position keeps its original cost basis.

**3. Flipping (crossing zero):**

Close the entire old position (realizing P&L on all old shares), then open fresh at the fill price with the leftover quantity.

All cash arithmetic uses **integer cents** (`bigint`). Cost basis is `numeric(10,4)` for weighted-average precision. No floats anywhere in the money path.

---

## Matching Engine

### Architecture

The matching engine is a single PL/pgSQL function (`place_order`) running inside PostgreSQL. The entire order lifecycle: validation, reservation, matching, position update, bankroll mutation; executes in one database transaction. Either everything commits or everything rolls back. There is no application-layer state that can desynchronize from the database.

### Concurrency Control

Two users hitting the same resting order simultaneously is the core race condition in exchange design. WC26-X serializes this with three levels of locking:

**1. Market-level mutex:** `SELECT ... FOR UPDATE` on the market row before the matching loop. All concurrent takers on the same market are serialized, while one transaction matches, others block until it commits.

**2. Order-level locking:** Each consumed resting order is locked with `SELECT ... FOR UPDATE SKIP LOCKED`.

**3. User-level locking:** The taker's user row is locked before reserve deduction, preventing double-spending from concurrent orders on the same account.

### Reserve System

Cash is escrowed from bankroll at order time, equal to the worst-case loss:

| Side | Reserve per share |
|---|---|
| **BUY** (long YES) | `limit_price` cents |
| **SELL** (short YES) | `100 - limit_price` cents |

A SELL at 40¢ reserves 60¢/share: if YES happens you owe $1/share but received 40¢, so max loss is 60¢. If the fill improves on the limit, the surplus is refunded. **No account can ever owe more than its bankroll, risk is bounded at order time, not at settlement.**

### Matching Loop

```
for each resting order on the opposite side (price-time priority):
    if no crossable orders → exit
    fill_qty = min(taker_remaining, maker_remaining)
    fill_px  = maker's limit price (price improvement to taker)

    1. Create fill record
    2. Update maker order (filled_qty, status)
    3. Update taker + maker positions
    4. Record maker ledger entry + increment trade count
    5. Update market last_px + volume

after loop:
    6. Refund taker's overpaid reserve
    7. Record taker ledger entry + increment trade count
    8. Set taker order final status (FILLED / PARTIAL / OPEN)
    9. Refresh best_bid / best_ask
```

---

## Settlement

When a match finishes, the final score is entered and outcomes derive deterministically:

```
goals_home > goals_away      →  result.home wins
goals_home < goals_away      →  result.away wins
goals_home = goals_away      →  result.draw wins
goals_home + goals_away ≥ 3  →  ou.over wins
both teams > 0               →  btts.yes wins
```

Settlement is two-phase:

**Phase 1 — Cancel resting orders.** All open/partial orders cancelled, reserves refunded to bankroll.

**Phase 2 — Pay out positions:**

| Position | Outcome | Payout per share | Realized per share |
|---|---|---|---|
| Long YES | YES wins | 100¢ | `100 - avg_cost` |
| Long YES | NO wins | 0¢ | `0 - avg_cost` |
| Short YES | YES wins | 0¢ | `avg_cost - 100` |
| Short YES | NO wins | 100¢ | `avg_cost - 0` |

Settlement is idempotent i.e. re-running on a settled market is a no-op. Realized P&L from settlement is additive with P&L already crystallized by closing trades.

Results are staged first, then explicitly confirmed before payouts execute. This mirrors how real clearinghouses handle corporate actions: automated ingestion, human confirmation, atomic execution.

---

## Real-Time System

The frontend subscribes to five PostgreSQL tables via Supabase Realtime (WebSocket):

| Table | Event | UI Update |
|---|---|---|
| `fills` | INSERT | Tape, sparklines, prices |
| `markets` | UPDATE | Best bid/ask, last price |
| `positions` | * | Position panel, open P&L |
| `orders` | * | Open orders panel |
| `users` | UPDATE | Bankroll, realized P&L |

Cross-user fills propagate within ~1 second without polling. When one user's resting bid is hit, their position and bankroll update via WebSocket push: no refresh, no polling.

---

## Security

- **Row-Level Security (RLS)** on every table. Users read only their own orders and positions; fills and markets are globally readable.
- **SECURITY DEFINER functions** for all writes. Authorization enforced via `auth.uid()` checks inside the function body.
- **No client-side state mutation.** The frontend is a read-through cache, all writes go through RPCs, and the UI re-hydrates from the database after every action.

---

## Technical Stack

| Layer | Technology |
|---|---|
| **Frontend** | Single HTML file (~3,400 lines), vanilla JS, CSS |
| **Database** | PostgreSQL 15 (Supabase) |
| **Auth** | Supabase Auth |
| **Realtime** | Supabase Realtime (WebSocket) |
| **Hosting** | Netlify (static) |
| **Data ingestion** | Node.js sync script + API-Football |

The matching engine lives in PostgreSQL because the database is the only component that provides serializable transaction guarantees without distributed coordination. A separate application backend would need explicit distributed locking (Redis, advisory locks) to prevent the same race conditions, added complexity, no added capability.

---

## Project Structure

```
wc26x-live.html            — Frontend (auth, trading, admin, realtime)
wc26x-backend/
  01_schema.sql             — Tables, enums, RLS policies, indexes
  02_engine.sql             — place_order(), cancel_order(), position accounting, ledger
  03_seed.sql               — House liquidity + futures markets (projected bracket, superseded by 06)
  04_settle.sql             — Knockout settlement functions
  05_verify.sql             — Post-setup sanity checks
  06_worldcup_pivot.sql     — API-Football fixture sync, stage-aware market creation
  07_leaderboard_view.sql   — Live leaderboard view (replaced a stale materialized view)
  09_group_settlement.sql   — Group-stage settlement, admin bypass, staged results
node_modules/
  sync-fixtures.mjs         — Node: API-Football → Supabase fixture sync
```

---

## Running Locally

**Backend:**
1. Run SQL files 01–09 in order against a Supabase project.
2. Run `sync-fixtures.mjs` with API-Football credentials to populate fixtures and markets.

**Frontend:**
1. Update `SUPA_URL` and `SUPA_KEY` in `wc26x-live.html` to point at your project.
2. Open the file in a browser.

---

## Related

- [pyclob](https://github.com/lauradouglass/pyclob) — The matching engine as a standalone Python library. Same logic, 29 tests, pip-installable.

---

## Author

[Laura Douglas](https://linkedin.com/in/laura-douglas-904a741ab) \
BS Computer Engineering, Drexel University. \
Incoming MS Mathematics in Finance, NYU Courant.