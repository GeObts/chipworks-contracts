# Raffle v2 — audit brief

## 1. What it is

One non-upgradeable contract (`Raffle`, `Ownable2Step` + `ReentrancyGuard`) runs many raffles whose prize is a **B20 tokenized stock the contract buys itself**.

```
createRaffle (owner) → Open → buy … last ticket → SoldOut
   SoldOut ──acquirePrize (owner/keeper): buy the stock, HOLD it──► request draw ─► Drawing
   SoldOut ──after acquireTimeout, fallbackToUsdc (anyone): prize = base USDC──► request draw ─► Drawing
   (if Entropy can't be called right then: PrizeReady, and anyone may requestDraw)
   Drawing ──Entropy callback (records the number only)──► Drawn ──settle (anyone)──► Settled
```

- **Create (owner only).** The house picks a stock and a prize size `base` (whole USD), and posts an ETH reserve for the Entropy fee. **No prize is escrowed.** Creation reverts with `StockNotBuyable(stock, Refusal)` unless all of these hold:
  - the stock is registered and enabled in the StockRegistry;
  - it is routed on Slipstream;
  - its registry pool is `factory.getPool(USDC, stock, tickSpacing)`, the router's own factory;
  - the pool pairs USDC with the stock and has the same tick spacing;
  - the pool's oracle can produce the TWAP window now;
  - `base` ≤ the pool-share cap.
- **Tickets.** `N = base + ceil(base × feeBps / 10,000)` at 1 USDC each. **The fee is on top** (launch 10%): $100 → 110 tickets. The last ticket only marks `SoldOut`; it never swaps and never requests randomness.
- **Acquire (owner or keeper).** Buys the stock with **exactly `base` USDC**, all or nothing:
  1. Price checks (§3).
  2. `forceApprove(router, base)`, then `exactInputSingle(USDC → stock, amountIn = base, amountOutMinimum = minOut)` in a `try`, then the approval is reset to 0.
  3. Spend and receipt are measured by balance delta. It requires `spent == base` and `received ≥ minOut`.
  4. On success the stock is **held** (`erc20PrizeEscrow`) and the share count is fixed. **Only then** is randomness requested, using v1.2's non-reverting request path with a contract-mixed `userRandomNumber`.
  5. Any refusal reverts (`AcquireRefused(id, Refusal)` or `SwapReverted(id, routerError)`), moving nothing.
- **Fallback (anyone).** After the raffle's snapshotted `acquireTimeout` (launch 6 h), the prize becomes the `base` USDC the contract already holds, and the draw is requested. **Nothing can fail here**, so every sold-out raffle reaches a draw.
- **Draw.** This is v1.2 unchanged:
  - The callback only records the number; `winningTicket = rnd % N`.
  - `retryDraw` (owner/keeper, after the snapshotted redraw timeout, `CALLBACK_NOT_STARTED` only) requests fresh randomness.
  - A FAILED callback is re-delivered with the same number through Pyth's `revealWithCallback`.
- **Settle (anyone).**
  - Prize to the winner: stock, or USDC after a fallback. A refusal becomes a credit.
  - Fee USDC to the Pot, push or credit.
  - Leftover ETH reserve to the creator (credit).
- **No exit before sellout, by design.** No refund, cancel or deadline. The owner cannot move prizes, ticket money or reserves.

## 2. Money flow (one $100 raffle)

| | USDC held by the raffle | Stock held | Notes |
|---|---|---|---|
| sold out | 110 | 0 | 110 tickets |
| after `acquirePrize` | 10 | X (measured) | 100 USDC went into the pool via the router |
| after `fallbackToUsdc` (instead) | 110 | 0 | prize = 100 USDC |
| after `settle` | 0 | 0 | winner gets X stock (or 100 USDC); Pot gets 10 USDC |

`usdcLiability` is the ticket money not yet spent or paid, plus `usdcOwed`. `erc20PrizeEscrow[stock]` covers bought-but-undelivered prizes. `ethLiability` is reserves plus `ethOwed`. Each must equal the balance held, to the unit.

## 3. The price guard (24/7 onchain; no market-hours feed anywhere)

All four values are owner-settable within bounds and **snapshotted per raffle** at creation.

| Check | Rule | Launch | Bounds |
|---|---|---|---|
| TWAP reference | mean tick over `twapWindow` from `pool.observe([w, 0])`, floored toward −∞ | 30 min | [5 min, 2 h] |
| Manipulation guard | `abs(spotTick − twapTick) ≤ maxDeviationTicks`, else `SpotDeviates` | 100 ticks ≈ 1% | 1–500 |
| Slippage floor | `minOut = refOut × (1 − maxSlippageBps)` | 150 bps | 1–500 |
| Size cap | `base × 1e6 ≤ usdc.balanceOf(pool) × maxPoolShareBps / 1e4` (create **and** acquire) | 100 bps | 1–500 |

**How `refOut` is computed.**
1. Take the exact spot output from slot0's `sqrtPriceX96`: `amountIn × sqrtP² / 2¹⁹²` for token0→token1, the inverse for the other direction, branched to stay inside 256 bits.
2. Scale it by `1.0001^(twapTick − spotTick)`, with the sign flipped when USDC is token1.

The power is an in-house binary exponentiation over OpenZeppelin `Math.mulDiv`. The guard bounds the exponent to |k| ≤ 500. The result is accurate to about one tick, because slot0's tick is the floor of the spot price's tick. No Uniswap (GPL) tick-math code is used.

## 4. Scope

| File | In scope |
|---|---|
| `src/raffle/Raffle.sol` | **yes** |
| `src/interfaces/ISlipstreamPool.sol` | yes: ABI correctness against the deployed Slipstream pool, factory and router (slot0 has **six** words) |
| `src/interfaces/ISwapRouters.sol` (`ISlipstreamSwapRouter`) | `exactInputSingle` struct layout |
| `src/interfaces/IEntropyV2.sol`, `IStockRegistry.sol` | the functions used |
| `script/raffle/DeployRaffle.s.sol` | launch-config review |

Out of scope: Pyth Entropy, USDC, B20 stocks, the StockRegistry, Aerodrome Slipstream (pools, factory, router), the Pot, the keeper and the frontend.

## 5. Launch configuration

Pinned in `script/DeployRaffle.s.sol` and asserted on a Base fork by `tests/fork/RaffleLaunchConfig.t.sol`.

| Parameter | Launch value |
|---|---|
| Owner / house | Safe `0xe1096B727499a3f70FaD8bc0267F5e69d01373C7` (2-of-3) |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (6 decimals; must be the registry's quote token) |
| Entropy V2 | `0x6E7D74FA7d5c90FEF9F0512987605a6d546181Bb` |
| StockRegistry | `0x5e4b6CbAc2D9b581428eE7f22E7bd4bf03675458` |
| Pot | `0x3918a9B479Ce9B58238584c645079AB3bB49855B` |
| Router | Slipstream SwapRouter `0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F`; its `factory()` must equal the registry's `slipstreamFactory()` = `0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef` (checked in the constructor) |
| `redrawTimeout` / `acquireTimeout` | 24 h / **6 h** (owner bounds [1 h, 30 d] / [1 h, 7 d]) |
| Price guard | 30 min / 100 ticks / 150 bps / 100 bps |
| `feeBps`, base range | 1,000 (10% on top), $10–$1,000 |
| `keeper` | unset at deploy; the Safe then calls `setKeeper(0x6571E3412553Fada40C3D96e61E7Cfd20A0695B9)` |

## 6. External dependencies (read live on Base, 2026-10-09)

**All 10 enabled stocks** (NVDA, GOOGL, AAPL, META, TSLA, AMZN, MSFT, MSTR, SNDK, SPCX):
- trade in USDC pools on Slipstream factory B, with tick spacing 10 and a 0.05% fee;
- USDC is token0 in every pool;
- every pool answers `observe(1800)`, with observation buffers of 1,000–2,048 slots;
- pool USDC ranges from $354k to $1.23M, so the 1% cap allows $3.5k–$12k per buy (launch maximum $1,000).

The fork test creates a raffle for every one of them, and the contract's TWAP quote for $1,000 lands within about 0.3% of Chainlink for each. That comparison is a test-only cross-check; the contract never reads Chainlink.

## 7. Questions we want answered

1. **Price guard soundness.** Can an attacker who cannot choose the moment of the buy (it is owner/keeper only) still extract more than the slippage floor? Consider:
   - moving spot within ±100 ticks before the keeper's transaction;
   - multi-block TWAP manipulation, given the 30-minute window;
   - `observe` edge cases: a window just at the buffer's edge, or ticks from a block with no swaps.
2. **`refOut` maths.** Check rounding, overflow branches, both token orders, the sign of k, and the one-tick approximation. Can `minOut` be inflated so that a fair swap is always refused (liveness: the 6 h fallback), or deflated so a bad one passes?
3. **Pool identity.** Are the checks sufficient for the TWAP to be read from exactly the pool the router swaps in (`registry.pool == factory.getPool(USDC, stock, spacing)`, the token pair, the spacing, `router.factory() == registry.slipstreamFactory()`)? The registry can be re-pointed by its owner (the Safe): acquire refuses a pool that differs from the one snapshotted at create.
4. **Swap integration.** Approval hygiene; measuring by balance delta; `spent == base`; the router's return value being ignored; the behaviour of a B20 that pauses or policy-blocks the Raffle mid-swap.
5. **State machine and accounting.**
   - `SoldOut → PrizeReady → Drawing`, the `acquire`/`fallback` race, and `_tryRequestDraw` from both paths.
   - Can a raffle ever be in `Drawing` or later without its prize held? The invariant suite asserts it cannot.
   - Can USDC, stock or ETH accounting drift on any path, including refusals and credits?
6. **Everything carried from v1.2:** the Entropy seed, the callback never reverting, orphan handling, the retry gate, push-or-credit, strict `_tryTransfer`, and owner powers bounded to future raffles.

## 8. Prior review

- **v1.2** (pre-funded prizes): internal suites plus one security review round. All of that round's findings were addressed; see `audit/raffle-2026-10-09/REVIEW-1-RESPONSE.md` and source `5e575e5`. Those fixes are carried into v2.
- **v2:** internal suites only (TEST-REPORT.md). **This is v2's first external review.** The owner's rule: no mainnet until it passes and the SPEC-v2 §2.5 pre-deploy items clear.
