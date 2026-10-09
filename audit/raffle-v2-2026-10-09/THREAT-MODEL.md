# Raffle v2 — threat model and known risks

## 1. Assets

| Asset | Held until | Tracked by |
|---|---|---|
| Ticket USDC | prize buy (the `base` part), or settle (fee and fallback prize), or `withdrawUsdc` | `usdcLiability`, `usdcOwed` |
| Bought prize stock | settle (pushed) or `claimPrize` | `erc20PrizeEscrow`, `prizeOwedTo` |
| ETH reserve (Entropy fees) | each request; the leftover goes to the creator as a credit | `ethReserve`, `ethLiability`, `ethOwed` |
| **Prize value**: a fair share count for the budget | fixed at `acquirePrize` | price guard (§3 of the brief) |
| Draw integrity | — | Entropy commit-reveal, user seed, events |

## 2. Actors and trust

| Actor | Trust | Powers |
|---|---|---|
| Owner (Safe, 2-of-3) | Trusted for parameters and stock choice; **not** for custody | Create raffles; set fee, base limits, timeouts, price guard (all bounded, future raffles only); set keeper; `acquirePrize`; `retryDraw`. No path to escrowed value. |
| Keeper (set by the owner) | Trusted for **timing** of the buy, and liveness | `acquirePrize`, `retryDraw`. Nothing else. |
| Anyone | Untrusted | `buy`, `fallbackToUsdc` (after the timeout), `requestDraw`, `settle`, claims and withdrawals, top-ups |
| Pyth Entropy and its provider (Fortuna) | Trusted: liveness, and not selectively withholding | Reveal |
| Aerodrome Slipstream (router, factory, pools) | Trusted code; **pool price is adversarial** | Executes the swap |
| StockRegistry admin (the Safe) | Trusted | Which stocks and pools are listed |
| Circle (USDC), Coinbase (B20) | Trusted, systemic | Blacklist, pause, upgrade |

## 3. Threats

**T1. Sandwich or price push around the prize buy.** An attacker pushes the pool, lets our buy fill at a bad price, and pushes it back.
- **Timing.** Only the owner or keeper can call `acquirePrize`, so the attacker doesn't control the moment of the buy.
- **Guard.** The buy is refused if spot sits more than 100 ticks (≈1%) from the 30-minute TWAP.
- **Floor.** `minOut` is 150 bps under the TWAP price. Worst case on a $1,000 prize is ≈$15, for someone able to order transactions around the keeper's.
- **Proven on the real pool.** The live-node simulation pushed NVDAc ~2,000 ticks with a $1M buy, and `acquirePrize` refused with `SpotDeviates`, moving nothing.

**T2. TWAP manipulation.** Moving a 30-minute TWAP means holding the pool off-market for 30 minutes against arbitrage, which costs far more than the bounded gain. A pool whose oracle can't answer the window refuses creation, and the buy (`TwapUnavailable`).

**T3. Wrong pool.** Reading a TWAP from one pool and swapping in another is prevented:
- `registry.pool == factory.getPool(USDC, stock, spacing)`, with the router's own factory pinned at construction to the registry's;
- the pool's tokens are {USDC, stock} and its tick spacing matches;
- acquire also requires the pool snapshotted at creation.

Covered by the impostor-pool, wrong-pair, spacing, re-pointed-pool and foreign-router tests, and by mutants #36–40 and #43.

**T4. Router misbehaviour.** The router's return value is ignored. Spend and receipt are measured by balance delta; `spent == base` and `received ≥ minOut` are required. The approval equals `base` exactly and is reset afterwards. A failure reverts everything. Covered by tests with lying and partial-spend routers, and mutants #53–55.

**T5. A buy that never lands** (pool drained, stock paused or delisted, guard refusing for hours). The raffle can't strand: after its snapshotted `acquireTimeout` (6 h) anyone falls back to the USDC prize and the draw proceeds. This is covered by tests, mutants #59–63, the `invariant_noDrawWithoutAHeldPrize` invariant, and the keeper E2E.

**T6. Winner drawn for an unheld prize.** Impossible by construction: randomness is requested only from `acquirePrize` (after the stock is measured in) or `fallbackToUsdc` (the USDC is already held). The invariant suite asserts it over 20,480 random calls.

**T7. Last buyer steering.** The last `buy` doesn't swap or draw, so the last buyer controls neither the buy's moment nor the randomness request.

**T8. Re-rolling a known number.** v1.2 is unchanged: `retryDraw` is owner/keeper only, only for `CALLBACK_NOT_STARTED`, and only after the snapshotted 24 h.

**T9. Provider withholding.** Accepted Pyth trust assumption, as in v1.2. The keeper's 15-minute alert makes it visible.

**T10. Owner or Safe compromise.** A compromised Safe can:
- create raffles in any registry-enabled stock, and list stocks it chooses through the registry it owns;
- set the guard to its loosest (500 ticks, 500 bps, 5% of the pool) **for future raffles only**;
- call `acquirePrize` at a moment of its choosing on a live raffle, still bounded by that raffle's snapshotted guard. This is the residual of T1.

It cannot move escrowed value.

**T11. Reentrancy.** Every state-changing function is `nonReentrant`. The swap path changes state after balances are measured.

**T12. Stuck credits.** v1.2 is unchanged: refusal-tolerant push-or-credit, and `_tryTransfer` accepts only empty return data (from a contract) or exactly one word equal to 1.

## 4. Known and accepted risks

| # | Risk | Status |
|---|---|---|
| **R1** | **No refund before sellout.** A raffle that never sells out keeps its ticket USDC and ETH reserve forever. | Accepted (owner). UX disclosure. Only the house creates. |
| R2 | A custody bug with no exit path | Non-upgradeable; small caps; invariant fuzzing; mutation testing; external audit |
| R3 | Sanctioned or blacklisted winner | Prize credited and claimable when allowed; never blocks other legs |
| R4 | Creator (payee role removed) that rejects ETH | Leftover reserve credit unwithdrawable. The creator is the owner (Safe), which accepts ETH. |
| R5 | Pyth provider liveness / withholding | Accepted, as v1.2 |
| R6 | B20 pause / policy / delisting **before the buy** | The buy is refused, and the 6 h fallback pays USDC instead |
| R7 | B20 pause / policy **after the buy** | Prize claimable once transfers resume |
| R8 | USDC freeze or upgrade | Systemic |
| R9 | **Slippage up to the floor.** The winner may get up to 1.5% fewer shares than the TWAP price implies, and more only in the sandwich case of T1. | Accepted at launch size; tunable per future raffle |
| R10 | **Thin real depth.** Pool TVL overstates tradeable depth (a $1M buy moved NVDAc ≈20%). | The 1% pool-share cap and the $1,000 launch maximum. **Raising `maxBase` needs a fresh per-pool depth check** (SPEC-v2 §2.5 item 1). |
| R11 | Keeper unavailable | Buys wait. After 6 h anyone falls back to USDC; retries need the Safe. |
| R12 | Contract size: 431 bytes of EIP-170 headroom | Audit fixes that add code may need a trade |
| R13 | No rescue | Stray tokens are unrecoverable (no admin path to funds) |
| R14 | Legal | Owner / legal, outside the code |

## 5. Invariants asserted (and to be challenged)

1. `usdc.balanceOf(raffle) == usdcLiability ==` Σ unsettled ticket money (less `base` for a bought prize) + Σ `usdcOwed`.
2. USDC is conserved across actors, house, Pot, raffle and pools; none stays with the router, and no approval lingers.
3. `address(raffle).balance == ethLiability ==` Σ reserves + Σ `ethOwed`.
4. Per stock: `balanceOf(raffle) == erc20PrizeEscrow ==` Σ bought-but-undelivered prizes.
5. **No draw without a held prize.** Before `PrizeReady` there is no prize amount and no randomness request. From `PrizeReady` on, the prize is held: the fixed stock with amount > 0, or exactly `base` USDC.
6. `sold ≤ N`; once `SoldOut`, `sold == N`; `winningTicket == rnd % N`; `winner == buyerOf(winningTicket)`.
