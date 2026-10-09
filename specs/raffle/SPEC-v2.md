# ChipWorks Raffle v2: the system buys the prize stock (SPEC, for owner sign-off)

**Status:** SIGNED OFF (owner, 2026-10-09; all six §15 choices confirmed) and BUILT on branch `raffle`. NOT deployed. Mainnet waits until the §2.5 pre-deploy items clear AND a fresh external audit passes. §16 lists where the build differs from the text below. It builds on Raffle v1.2 (`5e575e5`, review round 1 fixes). After the build, v2 gets a fresh external audit before any mainnet deploy.

## 0. Summary

The house no longer pre-funds prizes.
- **Creation.** The house (the Safe) opens a raffle for a **prize of $N in a chosen B20 stock**. It escrows nothing except a small ETH reserve for the randomness fee.
- **Tickets.** Players buy **N × 1.10 tickets at 1 USDC**. The extra 10% is the Pot's fee, added on top and not taken from the prize.
- **Buying the prize.** At sellout the contract **buys the stock with exactly N USDC** on the stock's Aerodrome Slipstream pool. It holds the stock and fixes the share count.
- **The draw.** Only then is randomness requested. The winner gets the shares, and the Pot gets the fee USDC.
- **If the buy can't complete.** The keeper retries. After a timeout (6 h at launch, owner-adjustable), anyone can switch the raffle to a **USDC prize of N**, and the draw goes ahead.
- **No refunds, nothing stranded, and a winner is never drawn for stock the contract doesn't hold.**

## 1. Decisions locked (owner, 2026-10-09)

| # | Decision |
|---|---|
| 1 | **Pricing anchor = 24/7 onchain price.** No market-hours equity feed in the swap protection. See §2. |
| 2 | **DEX buy at sellout, before the draw.** Reuse the ChipRounds buy code. Order: sold out → buy stock → stock held → request randomness → pick winner → settle. |
| 3 | **Fee on top.** Prize N buys the stock; tickets = N × 1.10; the extra 10% goes to the Pot. (This is the existing v1 ticket formula, `N + ceil(N × feeBps / 10,000)`, with the "base" now spent on the prize.) |
| 4 | **Stuck-funds fallback.** The keeper retries the buy. After a **6 h** timeout (owner-adjustable, snapshotted per raffle) **anyone** can switch the prize to N USDC and proceed to the draw. |
| 5 | **No NFT prizes in this build.** The structure leaves room for a pre-funded NFT mode later (§8). |

## 2. Pricing anchor (decision 1)

**Anchor:** the stock's own Slipstream pool, read as a **time-weighted average price (TWAP)** through the pool's oracle (`observe`). It trades 24/7 and has no market-hours dependency. **No Chainlink equity feed is read anywhere in the buy path.** The StockRegistry is still used, but only for `isEnabled`, the pool address and the tick spacing.

**Why this is safe at launch size.** Measured 2026-10-09: a **$10k** buy costs about **0.07–0.10%** against the pool's own price on every enabled stock. The pools hold about $0.8M (MSFT, TSLA) to $2.0M (META). The launch cap is **$1,000**, so even if weekend depth were a small fraction of weekday depth, a $1k buy would move the price negligibly. Exact weekend depth and per-pool tuning are a **pre-deploy test item (§2.5)**, not a design blocker.

### 2.1 The three checks (all in `acquirePrize`, all oracle-free)

| Check | Rule | Launch value | Owner bounds |
|---|---|---|---|
| **TWAP reference** | `twapTick` = arithmetic mean tick over the last `twapWindow` seconds, from `pool.observe([twapWindow, 0])` (rounded toward −∞ for negative means, as Uniswap's OracleLibrary does). `refPrice` = price at `twapTick`. | 30 min | [5 min, 2 h] |
| **Manipulation guard** | `abs(spotTick − twapTick) ≤ maxDeviationTicks`, where spot comes from `slot0`. One tick is about 1 bp, so 100 ticks ≈ 1%. If spot has been pushed away from its 30-min average, refuse (`AcquireSkipped("spot deviates")`) and retry later. | 100 ticks ≈ 1% | ≤ 500 |
| **Slippage floor** | `minOut = budget × (stock per USDC at refPrice) × (1 − maxSlippageBps)`, passed to the router as `amountOutMinimum`. It must cover the allowed deviation plus price impact plus the 0.05% fee. | 150 bps | ≤ 500 |
| **Size cap** | `budget ≤ maxPoolShareBps × USDC.balanceOf(pool)`. This is the pool's raw USDC, not oracle-valued. It is checked at **create** (reject an oversized raffle up front) and again at **acquire**. | 100 bps = 1% of the pool's USDC | ≤ 500 |

All four values are **snapshotted into the raffle at creation**. Later owner changes affect only new raffles.

**Worst case extractable by a sandwich:**
- A sandwich can only push spot by up to 1% from the 30-min average, or the guard refuses.
- Our buy then accepts at most 1.5% below the average. On a $1,000 prize that is ≤ $15, and only by someone who can order transactions around the keeper's call.
- Moving a 30-min TWAP itself means holding the price off-market for 30 minutes against arbitrage, which is far costlier than $15.
- The buy is keeper/owner-only (§5), so the timing is ours.

### 2.2 Pool identity

The pool read for the TWAP must be **the pool the router swaps in**. At create and at acquire, the contract checks all of the following:
- `registry.getStock(stock).pool == factory.getPool(USDC, stock, tickSpacing)`, where `factory` is the router's factory, checked equal to `registry.slipstreamFactory()` in the constructor;
- `token0` and `token1` are {USDC, stock};
- the venue is Slipstream.

Any mismatch makes `createRaffle` revert, or `acquirePrize` skip.

### 2.3 TWAP availability: the one operational precondition

A pool only answers `observe(30 min)` if its **observation buffer** is large enough to reach 30 minutes back. A pool still at the default buffer of 1 slot reverts. Handling:
- `acquirePrize` wraps `observe` in a `try`. A revert, or a buffer that doesn't reach back far enough, is `AcquireSkipped("twap unavailable")`. It never reverts the raffle, and the 6 h USDC fallback still applies.
- `createRaffle` **refuses a stock whose pool can't produce the TWAP right now**: it calls `observe([twapWindow, 0])`. So the house can't open a raffle that would only ever fall back to USDC.
- **Pre-deploy ops step:** for every stock the house intends to raffle, call the pool's permissionless `increaseObservationCardinalityNext(n)` once, with `n` sized from the pool's swap frequency. It costs gas once, paid by the house, and is not a contract change. Then confirm `observe(1800)` succeeds before listing that stock.

### 2.4 What a skip looks like

`AcquireSkipped(raffleId, reason)` with one of:
- `"stock disabled"`
- `"pool mismatch"`
- `"twap unavailable"`
- `"spot deviates"`
- `"too large for pool"`
- `"swap failed: <router reason>"`

Nothing moves on a skip. The keeper retries each cycle and alerts after 1 h. After the 6 h acquire timeout, anyone can switch the raffle to the USDC prize.

### 2.5 Pre-deploy testing items (NOT blockers for this spec)

1. **Weekend depth and pricing:**
   - sample every pool across at least one full weekend (active liquidity, USDC balance, spot vs TWAP, swap count);
   - confirm a $1,000 buy passes all checks at the weekend minimum;
   - confirm liquidity isn't pulled on weekends. If it is, tighten `maxPoolShareBps` per stock or don't list that stock.
2. **Observation buffers:** cardinality per pool; raise it where needed (§2.3); prove `observe(1800)` on each.
3. **Parameter tuning:** confirm 30 min / 100 ticks / 150 bps / 1% against real swaps via live-node `eth_simulateV1`, including a forced deviation case.
4. **Tick-maths library licence:** the TWAP→price maths needs `TickMath` / `FullMath`. Uniswap v3-core's are GPL-2.0-or-later; use an MIT-compatible implementation, or confirm that the licence is acceptable for this MIT repo.

## 3. Lifecycle

```
createRaffle (Safe) ──► Open ──last ticket──► SoldOut ──acquirePrize ok──► Drawing ──callback──► Drawn ──settle──► Settled
                                                │                            ▲
                                                │  acquire timeout passed     │
                                                └──── fallbackToUsdc (anyone) ┘
```

- **No `Acquired` resting state.** A successful `acquirePrize` requests the draw in the same transaction, using v1's non-reverting `_tryRequestDraw`. If Entropy can't be called right then (fee spike, outage), the raffle sits in **`PrizeReady`** and anyone may `requestDraw` (v1 behaviour).
- **Randomness is requested only after the prize is held** (stock escrowed, or the USDC prize fixed). No winner ever exists for an unheld prize.
- **The last `buy` does not swap.** If it did, the last buyer would choose the swap's timing and could sandwich it, and they would pay about 150k extra gas. It only marks the raffle `SoldOut` and emits `SoldOut`.
- **The draw itself is unchanged from v1.2:**
  - seeded `requestV2`;
  - `_entropyCallback` only records the number;
  - `retryDraw` is owner/keeper only, never-revealed requests only, after the snapshotted redraw timeout;
  - `settle` is permissionless, push-or-credit;
  - FAILED callbacks are completed with Pyth's `revealWithCallback` (same number).

## 4. Tickets and money

- `N` = prize in whole USD, within `[minBase, maxBase]` (launch $10–$1,000).
- Tickets `T = N + ceil(N × feeBps / 10,000)`; launch `feeBps` = 1,000. Examples: $100 → 110 tickets, $15 → 17 (fee rounds up).
- **At sellout the contract holds `T` USDC:**
  - **prize budget `N × 1e6`** is spent on the swap;
  - **fee `(T − N) × 1e6`** goes to the Pot at settle (push, falling back to a credit).
- **Swap costs** (0.05% pool fee plus price impact, measured about 0.07–0.10% at $10k) come out of the prize, so the winner gets "what N USDC bought". The fee is never touched.
- **ETH reserve:** the house posts ≥ 3 × the Entropy fee at creation (v1). The leftover goes back to the creator as an `ethOwed` credit at settle. **There is no `payee` role any more**: nobody receives `N` (it buys the prize), and the reserve is returned to the creating owner.

## 5. Acquiring the prize

**Who:** `acquirePrize(raffleId)` is **owner or keeper only.**
- If anyone could buy, the caller would choose the swap's timing, for example right after pushing the pool within the price bounds.
- The keeper calls it on its next cycle after sellout (≤ 30 min today; see §11 for a faster trigger).
- Liveness never depends on the keeper: after the acquire timeout, anyone can fall back to USDC (§6).

**What it does, all or nothing:**
1. Requires `SoldOut`, and the stock still enabled in the StockRegistry.
2. **Price check (§2):** reads the onchain reference price, computes `minOut`, and refuses if the pool's spot price has moved too far from that reference (pushed or manipulated). A refusal emits `AcquireSkipped(reason)` and changes nothing; the keeper retries next cycle.
3. **Size check, no oracle:** the prize budget must be ≤ `maxPoolShareBps` of the **USDC sitting in the pool** (launch 100 bps = 1%). This replaces ChipRounds' `poolLiquidityUsd × impact` cap, which multiplies by the Chainlink price.
4. **The swap** is ChipRounds `_buy`, reused:
   - `forceApprove(router, budget)`;
   - `ISlipstreamSwapRouter.exactInputSingle{tokenIn: USDC, tokenOut: stock, tickSpacing, recipient: this, deadline: now, amountIn: budget, amountOutMinimum: minOut}` inside `try`;
   - approval reset to 0;
   - received and spent measured by balance change.

   A revert means nothing moved and the raffle stays `SoldOut`.
5. **On success:**
   - `prizeAmount = received`;
   - escrow and liability updated: USDC liability down by the amount spent, stock escrow up by the amount received;
   - `PrizeAcquired(raffleId, stock, usdcSpent, received, refPrice)` emitted;
   - `_tryRequestDraw`.

   The share count is fixed from here on.

**Router:** Slipstream "factory B" router `0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F`, an immutable constructor argument. The constructor checks that `router.factory() == registry.slipstreamFactory()`, as ChipRounds' `setRouters` does. **Uniswap v3 stocks are out of scope:** all 10 enabled stocks are on Slipstream, and `createRaffle` refuses any other venue.

## 6. Stuck-funds fallback (decision 4)

- `acquireTimeout`: owner-adjustable within **[1 h, 7 d]**, launch **6 h**, **snapshotted into each raffle at creation** (as v1.2 does for the redraw timeout).
- `fallbackToUsdc(raffleId)` is **permissionless.** It requires `SoldOut` and `block.timestamp ≥ soldOutAt + acquireTimeout`. It sets the prize to **USDC, amount `N × 1e6`** (already held, so nothing can fail), emits `PrizeFellBackToUsdc`, then calls `_tryRequestDraw`.
- At settle, a USDC prize is pushed to the winner, or credited to them if the push is refused (v1 push-or-credit). The Pot gets its fee as normal.

**Why this cannot strand funds:**
- Every raffle that sells out reaches `Drawing` within the acquire timeout.
- From there, v1.2's guarantees apply: same-number reveal, keeper alerts, retry after 24 h.

What is still locked until sellout, and that is unchanged: the **no-refund-before-sellout** design (THREAT-MODEL R1). A raffle that never sells out keeps its ticket USDC.

**Races:**
- `acquirePrize` and `fallbackToUsdc` both require `SoldOut`, and whichever lands first moves the state, so they can't both happen.
- A keeper buy landing after the timeout is still allowed (stock is the preferred prize) as long as nobody has fallen back yet.

## 7. Settle and claims

Unchanged from v1.2 except:
- the prize may be a **stock** (bought) or **USDC** (fallback);
- the only USDC legs are the fee to the Pot and, in the fallback case, the prize.

## 8. Prize kinds and future NFT mode (decision 5)

```
enum PrizeKind  { Stock, Usdc }          // v2. A future Erc721 kind is appended, never reordered.
enum PrizeSource { Acquire }             // v2. A future PreFunded source is appended.
struct Prize { PrizeKind kind; address token; uint256 amount; }
```

- **All movement goes through two internal hooks:**
  - `_obtainPrize(id)`: Acquire = swap, Usdc = assign.
  - `_deliverPrize(id, winner, strict)`: switches on `kind`.
- **A future pre-funded NFT mode** adds a `PreFunded` source, whose prize is escrowed at create and skips `SoldOut → acquire`, plus an `Erc721` kind in both hooks. The state machine, draw and settle stay as they are.
- **Honest caveat:** the contract is non-upgradeable, so adding that mode means **a new deployment with the same code base**, not a switch on the deployed contract.
- **v2 deletes** the v1 ERC-721 code, `nftPrizesEnabled` and the allow-list from the bytecode. That is less to audit now, and it's easy to bring back.

## 9. Owner powers (all bounded; none reaches escrowed value)

| Setter | Bounds | Applies to |
|---|---|---|
| `setFeeBps` | ≤ 2,000 | future raffles (snapshotted) |
| `setBaseLimits` | min ≥ 1, max ≤ 1,000,000 | future raffles |
| `setRedrawTimeout` | [1 h, 30 d] | future raffles (snapshotted) |
| `setAcquireTimeout` | [1 h, 7 d] | future raffles (snapshotted) |
| `setPriceGuard(maxSlippageBps, maxDeviationTicks, twapWindow)` | slippage ≤ 500 bps, deviation ≤ 500 ticks, window [5 min, 2 h] | future raffles (snapshotted) |
| `setMaxPoolShareBps` | ≤ 500 | future raffles (snapshotted) |
| `setCallbackGasLimit` | [100k, 1M] | at request time (v1) |
| `setKeeper` | any / zero | `acquirePrize`, `retryDraw` |

There is no pause, no rescue, and no path to prizes, ticket money or reserves. The router, USDC, Entropy, StockRegistry and Pot are immutable.

## 10. Failure modes

| What fails | Effect | Ends how |
|---|---|---|
| Price check refuses (spot pushed away from the reference, or stale reference) | `AcquireSkipped`, nothing moved | keeper retries; after 6 h, USDC fallback |
| Swap reverts (thin pool, minOut not met, B20 paused, router down) | atomic, nothing moved | same |
| Stock disabled in the registry or delisted | acquire refused | USDC fallback after 6 h |
| Keeper down | nobody acquires | anyone falls back after 6 h |
| Entropy down or fee spike after the prize is held | `PrizeReady`, anyone `requestDraw`s (top-up) | v1 behaviour |
| Entropy never reveals | 24 h, then owner/keeper `retryDraw` | v1.2 |
| Callback FAILED | keeper `revealWithCallback` from the `Revealed` event (same number) | v1.2 |
| Winner refused by the B20 or USDC policy | prize credited, claimable later | v1 |
| Swap delivered less than expected but above minOut | booked as received (balance change) | by design |

## 11. Keeper changes (chipworks-keeper `raffle-job`)

- **`SoldOut` raffle:** call `acquirePrize` each cycle (simulate first, send when `RAFFLE_SEND`). Alert if a raffle stays `SoldOut` > 1 h. Call `fallbackToUsdc` once the timeout passes.
- **Faster than 30 min:** the keeper cron is fixed at `*/30` (shared). Keep that and accept up to 30 min between sellout and buy, or add a second, raffle-only cron (for example `*/5`). **Owner decision; recommend `*/5`.**
- **ABI refresh** for v2. `/raffle.json` shows acquire status and the reason for the last skip.

## 12. Reused / changed / removed vs v1.2

| | |
|---|---|
| **Reused** | Ownable2Step, ReentrancyGuard, ticket ranges + binary search, push-or-credit legs, strict `_tryTransfer`, Entropy request/callback/retry/seed, snapshotted timeouts, liabilities accounting, ChipRounds `_buy` pattern |
| **New** | `acquirePrize`, `fallbackToUsdc`, the TWAP/deviation price guard, the pool-USDC size cap, `PrizeReady` state, acquire timeout, router immutable, events `PrizeAcquired` / `AcquireSkipped` / `PrizeFellBackToUsdc` |
| **Removed** | prize escrow at create, `payee`, ERC-721 path, NFT switch and allow-list |

## 13. Test plan

- **Unit and fuzz:**
  - mock Slipstream pool (observe/slot0) and mock router;
  - every acquire branch (ok, slippage, deviation, stale or short TWAP, too large, disabled, swap revert, under-delivery);
  - fallback timing, snapshot of every parameter, races;
  - the fee-on-top math;
  - access control.
- **Invariants (extended):**
  - USDC held equals ticket money of unsettled raffles minus spent budgets plus credits;
  - stock held equals escrowed prizes;
  - no raffle in `Drawing` or later without a held prize;
  - conservation.
- **Mutation:** the 36 existing mutants re-pointed, plus new ones on the price guard, size cap, fallback timing and acquire access.
- **Real-chain proof:**
  - **Live-node `eth_simulateV1`:** a full acquire against the **real** pool and router with real NVDAc and the real TWAP, then draw and settle. B20s can't execute in forge or anvil forks, so the real swap can't be a forge fork test.
  - **Forge fork:** the Entropy path (seeded request, real reveal) and the USDC-fallback path.
- **Keeper:** unit tests plus a fork E2E for acquire → draw → settle.

## 14. Audit surface and estimate

- **New surface:**
  - the swap integration (router trust, approval hygiene, minOut maths);
  - the TWAP read (observation availability, tick → price maths, window choice);
  - the manipulation check;
  - the fallback state transition.
- **Smaller than v1.2:** no pre-funded escrow, no ERC-721.
- **Estimate:**

  | Work | Days |
  |---|---|
  | Contract | 1.5 |
  | Tests incl. mutation and live-node sim | 2–2.5 |
  | Keeper | 0.5–1 |
  | Audit package | 0.5 |
  | **Total** | **≈ 4.5–5.5 working days**, then the external audit |

## 16. As built (differences from the text above)

1. **A refusal is a revert, not an event.**
   - §2.4 and §5 describe an `AcquireSkipped(reason)` event. As built, `acquirePrize` reverts with `AcquireRefused(raffleId, Refusal reason)`, or with `SwapReverted(raffleId, routerError)` when the router itself reverts.
   - Nothing moves either way.
   - Reverting lets the keeper simulate first and send nothing while a guard refuses, instead of paying for a "skip" transaction every 5 minutes for up to 6 h.
2. **Reasons are an enum.** `Refusal { None, StockDisabled, NotSlipstream, PoolMismatch, TwapUnavailable, SpotDeviates, TooLargeForPool, NoOutput, PartialSpend, UnderDelivered }`, also used by `createRaffle`'s `StockNotBuyable(stock, Refusal)`. String reasons put the contract 526 bytes over EIP-170. As built the runtime is **24,145 bytes, a 431-byte margin.**
3. **One price-guard setter.** `setPriceGuard(PriceGuard{twapWindow, maxDeviationTicks, maxSlippageBps, maxPoolShareBps})` replaces `setPriceGuard` + `setMaxPoolShareBps`. Bounds as in §9, none may be zero.
4. **TWAP maths without a tick table.**
   - The TWAP price is computed as the exact spot output (slot0 `sqrtPriceX96`) × 1.0001^(twapTick − spotTick). The exponent is bounded by the deviation guard (≤ 500 ticks), and the power is an in-house binary exponentiation using OpenZeppelin `Math.mulDiv`.
   - It is accurate to within one tick (about 1 bp).
   - **This clears §2.5 item 4:** no Uniswap GPL code is used.
5. **`quotePrize(stock, usdcAmount)` view.**
   - It returns the stock `usdcAmount` buys at the current TWAP, for the site's "≈ X shares" display (§3).
   - It returns 0, never reverts, when the stock can't be quoted.
6. **`createRaffle(address stock, uint64 base)`.** The prize is named by its stock only; there is no prize struct argument.
7. **Keeper cron.** `5-25/5,35-55/5 * * * *` rather than `*/5`. It skips :00 and :30, when the 30-minute cycle runs the raffle job itself, so the keeper key never has two senders in one minute. The raffle job keeps its state in its own KV record.
8. **The keeper stops buying at the timeout.** The contract still allows a late buy while nobody has fallen back. The keeper calls `fallbackToUsdc` instead once the raffle's acquire timeout has passed, and it decides on **block time**, the contract's clock.
9. **Gas** (live node, real router, real NVDAc, Entropy request included): `acquirePrize` costs about **611k** gas.
10. **Observation (pre-deploy item 1).** Headline pool TVL is not tradeable depth. On 2026-10-09 a $1M buy moved the real NVDAc pool about 2,000 ticks (≈ 20%). At launch size this is irrelevant: a $100 buy filled 5 bps from the TWAP. But **maxBase must not be raised far** without re-measuring depth per pool.

## 15. For sign-off

Sign off on the spec as written, plus these choices I made where you hadn't specified:

1. **Price-guard launch values:** TWAP 30 min; reject if spot is > 1% (100 ticks) from the TWAP; slippage floor 1.5% below the TWAP; buy ≤ 1% of the pool's USDC. All owner-adjustable within the bounds in §9 and snapshotted per raffle.
2. **`acquirePrize` is owner/keeper only.** Anyone can trigger only the 6 h USDC fallback.
3. **The `payee` role is removed.** `N` is spent on the prize. The leftover ETH reserve goes back to the creating owner. `retryDraw` becomes owner/keeper (it was owner/payee/keeper in v1.2).
4. **The stock is fixed at creation.** The house picks it from the enabled Slipstream stocks whose pool passes the TWAP check (§2.3). It can't be changed afterwards.
5. **Keeper cadence:** add a raffle-only `*/5` cron so the buy happens within about 5 min of sellout, instead of waiting for the shared `*/30` cycle.
6. **Pre-deploy items (§2.5)** gate the mainnet deploy, not the build: weekend depth, observation buffers, parameter tuning, tick-maths licence.
