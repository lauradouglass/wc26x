# WC26-X — World Cup 2026 Prediction Exchange

A play-money prediction market exchange for the 2026 FIFA World Cup. Users trade binary event contracts on match outcomes through a central limit order book with continuous double-auction matching.

**Stack:** Single-file HTML frontend · Supabase (PostgreSQL 15) backend · Realtime WebSocket push

---

## About

A few months ago I won $180 trading recessions and US gas prices on Kalshi. It was thrilling, but it left me curious about what was running underneath. How does the price actually move? Who's on the other side of my trade? How does the platform know what to pay me when the event resolves?

The way I learn is by building. With the 2026 World Cup approaching, I decided to understand prediction markets by building one from scratch, a fully functional exchange with a real matching engine, position accounting, settlement, and real-time data push.

WC26-X was the result: 72 group-stage fixtures, 531 binary markets, cross-user matching with price-time priority, and a leaderboard ranked by realized P&L. I launched it on LinkedIn for the tournament opener, targeting students and early-career finance professionals.

**Nobody signed up.**

Zero signups after two weeks taught me something no amount of engineering could: distribution matters as much as the product. The exchange was technically sound , matching, settlement, and real-time propagation all worked correctly in multi-user testing and even the offer of prize money, but I had no rollout strategy, no community pre-built, and a cold-start problem I hadn't planned for. The lesson stuck, and it's one I'll carry into every future project.

The code and the math remain useful as a piece of a larger project. The matching engine logic was later extracted into [pyclob](https://github.com/lauradouglass/pyclob), a pip-installable Python library with 29 tests covering every edge case.

---

## Market Microstructure

### Contract Design

Each market is a **binary event contract** paying $1.00 if the outcome occurs, $0.00 otherwise. Prices in cents (1¢–99¢) represent implied probabilities.

For each group-stage fixture, three market groups are created:

| Market Group | Outcomes | Settlement Condition |
|---|---|---|
| **Match Result** (3-way) | Home / Draw / Away | Determined by final score |
| **Total Goals O/U 2.5** | Over / Under | Total goals ≥ 3 → Over wins |
| **Both Teams to Score** | Yes / No | Both teams score ≥ 1 → Yes wins |

Each outcome trades independently as its own YES/NO pair. The three result contracts are **not** constrained to sum to $1, meaning the book can briefly imply >100% or <100% aggregate probability, creating arbitrage opportunities identical to those in real sportsbook markets.

### Order Book

The exchange implements a **continuous limit order book (CLOB)** with **price-time priority**:

- **Price priority:** Best-priced resting order fills first. Highest bid for sells, lowest ask for buys.
- **Time priority:** At the same price, earliest order fills first (FIFO).
- **Self-trade prevention:** A user's order never matches against their own resting order.
- **Partial fills:** Incoming orders can sweep multiple price levels. Unfilled remainder rests as a new limit.

### Position Accounting

Positions are tracked as **signed share counts** with **weighted-average cost basis**:

- `shares > 0` → long YES
- `shares < 0` → short YES / long NO

Three accounting paths on fill:

**1. Opening or adding (same direction):**

$$C_{new} = \frac{|S_{old}| \cdot C_{old} + Q_{fill} \cdot P_{fill}}{|S_{new}|}$$

**2. Reducing (opposite direction, not flipping):**

```
If closing a long:  realized = (fill_price - avg_cost) × closing_qty
If closing a short: realized = (avg_cost - fill_price) × closing_qty
```

Cost basis on the remainder is unchanged.

**3. Flipping (crossing zero):**

Close the entire old position (realize P&L), then open fresh at the fill price with the leftover quantity.

All cash arithmetic uses **integer cents** (`bigint`). Cost basis is `numeric(10,4)` for weighted-average precision. No floats in the money path.

---

## Matching Engine

### Architecture

The matching engine is a single PL/pgSQL function (`place_order`) running inside PostgreSQL. The entire order lifecycle: validation, reservation, matching, position update, bankroll mutation; executes in one database transaction. Either everything commits or everything rolls back. There is no application-layer state that can desynchronize.

### Concurrency Control

Two users hitting the same resting order simultaneously is the core race condition in exchange design. WC26-X serializes this with two levels of locking:

**1. Market-level mutex:** `SELECT ... FOR UPDATE` on the market row before the matching loop. All concurrent takers on the same market are serialized.

**2. Order-level locking:** Each consumed resting order is locked with `SELECT ... FOR UPDATE SKIP LOCKED`. Defensive against deadlocks if locking topology changes.

**3. User-level locking:** The taker's user row is locked before reserve deduction, preventing double-spending from concurrent orders by the same account.

### Reserve System

Cash is escrowed from bankroll at order time:

| Side | Reserve per share |
|---|---|
| **BUY** (long YES) | `limit_price` cents |
| **SELL** (short YES) | `100 - limit_price` cents |

If the fill price improves on the limit, the surplus is refunded. No account can ever owe more than its bankroll, risk is bounded by construction.

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

When a match finishes, the admin enters the final score. The settlement function derives outcomes deterministically:

```
goals_home > goals_away  →  result.home wins
goals_home < goals_away  →  result.away wins
goals_home = goals_away  →  result.draw wins
goals_home + goals_away ≥ 3  →  ou.over wins
both > 0  →  btts.yes wins
```

Settlement is two-phase:

**Phase 1 — Cancel resting orders:** All open/partial orders cancelled, reserves refunded.

**Phase 2 — Payout positions:**

| Position | Outcome | Payout per share | Realized per share |
|---|---|---|---|
| Long YES | YES wins | 100¢ | `100 - avg_cost` |
| Long YES | NO wins | 0¢ | `0 - avg_cost` |
| Short YES | YES wins | 0¢ | `avg_cost - 100` |
| Short YES | NO wins | 100¢ | `avg_cost - 0` |

Settlement is idempotent. Realized P&L from settlement is additive with P&L from trading.

---

## Real-Time System

The frontend subscribes to five PostgreSQL tables via Supabase Realtime (WebSocket):

| Table | Event | UI Update |
|---|---|---|
| `fills` | INSERT | Tape, sparklines, prices |
| `markets` | UPDATE | Best bid/ask, last price |
| `positions` | * | Position panel, open P&L |
| `orders` | * | Open orders panel |
| `users` | UPDATE | Bankroll, realized P&L, leaderboard |

Cross-user fills propagate to both windows within ~1 second without polling.

---

## Security

- **Row-Level Security (RLS)** on every table. Users read only their own orders and positions.
- **SECURITY DEFINER functions** for all writes (`place_order`, `cancel_order`, settlement RPCs). Authorization enforced via `auth.uid()` checks inside the function.
- **No client-side state mutation.** The frontend is a read-through cache. All writes go through RPCs.
- **Admin bypass helper** recognizes SQL editor sessions, service-role JWTs, and the `is_admin` flag.

---

## Technical Stack

| Layer | Technology |
|---|---|
| **Frontend** | Single HTML file (~3,400 lines), vanilla JS, CSS |
| **Database** | PostgreSQL 15 (Supabase) |
| **Auth** | Supabase Auth (email + magic link) |
| **Realtime** | Supabase Realtime (WebSocket) |
| **Hosting** | Netlify (static) |
| **Data ingestion** | Node.js sync script + API-Football |

The matching engine lives in PostgreSQL because the database is the only component that provides serializable transaction guarantees without distributed coordination. 

---

## Related

- [pyclob](https://github.com/lauradouglass/pyclob) — The matching engine extracted as a standalone Python library. 

- [live](https://wc26x.netlify.app/) - The exchange 
---

## Author

[Laura Douglas](https://linkedin.com/in/laura-douglas-904a741ab). \
B.S. Computer Engineering, Drexel University. \
M.S. Mathematics in Finance, NYU Courant.
