# Audit brief, ROUND 3: ChipWorks Box (Box + PrizeVault + ChipConverter)

**Chain:** Base mainnet (8453). **Solidity:** 0.8.24, EVM `cancun`, OpenZeppelin 5.1.0, optimizer 200 runs, no `via_ir`.
**Source commit:** `2943917` in `chipworks-contracts`, branch `box-rebuild`. The packaged files are byte-identical to that commit after CRLF→LF.
**Round 3.** Round 2 reviewed `fdb77c4`. What changed since then, and why, is in §R3 below and `TRIAGE-ROUND2.md` (paste 3). Round 1 → 2 is §R and `TRIAGE-ROUND1.md`.
**Please focus on the round-3 diff (§R3)**, then anything the earlier rounds missed.
**Pastes:** 1 = this brief + `Box.sol` · 2 = `PrizeVault`, `ChipConverter` and every interface (1 and 2 are the priority) · 3 = round-1 triage, its verification tests, the rebuild tests · 4 = audit PoCs, the Base fork test and the live-node gas simulation · 5 = remaining tests and mocks · 6 = reference (optional: the v4 swap pattern the converter follows, and Pyth's own `revealWithCallback`).
**Nothing here is deployed.** Your review gates deployment. **User funds and on-chain randomness are involved.**

You are one of two independent reviewers. Please don't look for or use the other review.
We want two separate readings, not one reading twice.

---

## 0. Before you start: prove you received every file whole

Before any findings, reply with **this table filled in** for every file you were given:

| file | line count you see | SHA-256 you compute (or "cannot hash") | last non-empty line, verbatim |
|---|---|---|---|

The expected line count and SHA-256 of each file are on its `===== BEGIN FILE` marker line (and in
`SHA256SUMS` / `MANIFEST.md`). Hashes are over the exact bytes: UTF-8, LF line endings, trailing newline
included. Each paste ends with an `===== END OF` line: if you can't see it, the paste was truncated.
If a count or a last line does not match, **stop and say which file**.

---

## R3. What changed since round 2 (read with TRIAGE-ROUND2.md)

Every item was reproduced first. Each fix has a test, and each guarded check was re-mutated and caught by a test (TRIAGE-ROUND2 part 2).
- **BOX-L1:** `Box.setChipPaused(bool)`, owner, immediate. It stops both `buyWithChip` paths without touching USDC sales. Box is now 23,788 bytes.
- **BOX-L6:** `PrizeVault.MAX_FAILED_TRANSFERS = 2`. After two refused stock transfers, the payout walk goes to USDC. A refused real B20 transfer costs 11,086 gas, measured live.
- **BOX-L3:** `MAX_FEED_AGE = 7 days` ceiling on `setMaxFeedAge`; the default stays 5 days. The live feeds froze Friday 16:00–23:35 UTC, so they are ~2.9 days old by Monday's open.
- **BOX-L4:** `minUsdcBps >= maxPrizeBps`, enforced in `setRestockParams` and `queueMaxPrizeBps`, and re-checked at `executeMaxPrizeBps`.
- **BOX-I4:** the first stock tried is `keccak256(abi.encode(entropy)) % n`, no longer `entropy % n`, which correlated with the tier.
- **Tests:** a lying router and a partial-fill pool manager (M4, M8, M16), $CHIP as currency1 (the production order), specific errors instead of bare `expectRevert()`, and a 16-stock refusing-opener callback.
- **Still open, as owner decisions:** BOX-L2 (immediate vault setters), BOX-L5 (the registry owner is the same Safe), the H-3 residual, and M-restock.

## R. What changed from round 1 to round 2 (read with TRIAGE-ROUND1.md)

- **$CHIP payments swap at buy (H-1, H-2, F-1, M-3).** Round 1 confirmed that a fixed $CHIP price per
  box plus a later keeper sale let a buyer fund the pool $4.75 for a "$10" box when $CHIP halved. Now
  `buyWithChip(skuId, to, wethNeeded, maxChipIn, deadline)` swaps the buyer's $CHIP to the exact USDC
  price in the same transaction. **There is no keeper on the $CHIP path any more**: `sellChip`, the
  caps, the owner price floor and the 48h $CHIP recovery are gone, and SKUs carry `chipEnabled`, not a
  $CHIP price. **The round-1 "one keeper trust point" no longer exists.**
- **F-2:** Entropy requests are keyed by `(provider, sequence)`; `_fulfill` checks the provider.
- **Gate before payment:** the vault-wired and pool-coverage checks run before any USDC is pulled or
  any $CHIP is swapped.
- **L-2:** the vault's self-call guard reverts `OnlySelf`.
- Refuted by test and unchanged: H-3, M-2. Accepted and unchanged: M-1, M-4, L-3, L-4.

---

## 1. What this is, in one paragraph

Sealed, giftable ERC-721 "gacha" boxes. A buyer pays **$1, $10 or $25** in **USDC or $CHIP** for a
sealed box, then opens it: the Box requests randomness from **Pyth Entropy v2**, and Entropy's
callback draws a prize tier from a published on-chain odds table (91% expected return) and has the
**PrizeVault** pay it in a **Coinbase B20 tokenized stock** at its Chainlink mark (USDC if no stock
can cover it). Prizes are **never** paid in $CHIP; $CHIP is a payment option only. A USDC payment is
split 5% fee / 95% vault in the buy transaction. A $CHIP payment is swapped to the box's **exact USDC price inside the buy** by the
**ChipConverter** (the deployed ChipLottery's route) and then split the same way. The vault funds
itself from sales: a keeper converts vault USDC into stocks (`restock`), and a permissionless
`sweepSurplus` sends the house's margin to the fee recipient (the FeeSplitter → Pot). Box is
isolated from the rest of Chipworks: it only READS the StockRegistry and uses the same two stock
routers the rounds engine uses.

**Contracts (paste 1):** `src/box/Box.sol` (ERC-721, buy/open/callback/owed prizes), `src/box/PrizeVault.sol`
(the pool: settle, restock, sweep), `src/box/ChipConverter.sol` ($CHIP → exact USDC, inside the buy), plus interfaces.

---

## 2. $CHIP payments: swapped to the exact price inside the buy

**Start here: this path is new since round 1.** `Box.buyWithChip` / `buyWithChipBatch`:
1. `_gate`: vault wired, pool covers the SKU's top prize (else `SkuNotCovered`), before anything moves.
2. `_payInChip`: deadline; converter wired; the buyer's `maxChipIn` $CHIP moves **straight to the
   converter** (never through the Box); `converter.swapToUsdc(price, wethNeeded, maxChipIn, buyer)`:
   - $CHIP → WETH, **exact output** `wethNeeded`, on the $CHIP/WETH v4 pool (Doppler hook), reverting
     `ChipCostAboveMax` if it costs more than `maxChipIn`; the pool's reported cost is checked against
     the measured balance change;
   - WETH → USDC, **exact output** the price, to the **Box**, spending at most the WETH just bought; the
     Box's USDC delta must equal the price (`UsdcShort`);
   - every unspent $CHIP and WETH back to the buyer. The converter ends every call holding nothing.
3. `_buy`: 5% of the USDC to the fee recipient, 95% to the vault, mint to `to` (gifting).

$CHIP still has no on-chain price, **but nothing here needs one**: the buyer bounds their own cost
(`maxChipIn`, `wethNeeded`, `deadline`), and both legs are exact output, so the pool receives exactly the
price whatever the market does. The pool fees are the buyer's (**2.26%** over the mark measured on the
Base fork for a $10 box; the UI discloses it). The swap code is the deployed ChipLottery's
(`reference/ChipLottery.sol`, paste 6), with the USDC recipient changed.

**Attack this hardest:**
- **Q1.** Can **anyone** make a $CHIP buy mint a box while the pool receives less than 95% of the
  price, or make the fee recipient receive anything but 5% in USDC? (Rounding, a partial fill at the
  price limit, a pool that under-delivers, fee-on-transfer behaviour on $CHIP, batch arithmetic.)
- **Q2.** Is the v4 exact-output swap correct for both currency orders (`chipIsCurrency0`), and is
  `sync → transfer → settle → take` complete? Can anyone reach `unlockCallback` except through our own
  `unlock`, or reach `swapToUsdc` except through the Box?
- **Q3.** Can any $CHIP, WETH or USDC be left on the converter or the Box after a call, or be taken
  from a buyer beyond what their own swap spent? (Refunds; stray balances; the owner's `rescue`.)
- **Q4.** Reentrancy: the buy path calls the converter, which calls the PoolManager (and its hook) and
  the v3 router, before the Box mints. Both contracts are `nonReentrant`. Is there any path back into
  the Box, the vault or the converter mid-buy that matters?

## 3. The Pyth callback: gas, gaming, and what happens when it fails

This is the second priority. **A callback that runs out of gas or can be steered is how a gacha
gets broken.**

**How it works.** `open` requests Entropy with an explicit provider and `callbackGasLimit`, and
records the provider (`_providerOf`). Entropy later calls `_entropyCallback` (verified against the
live Entropy implementation `0x4ced698548f7d068f2f6e92d66f404a8a10db83b`), capped at the request's gas limit.
The callback must never revert: `settle` is wrapped in `try`, and anything unpaid becomes **owed**
(§4). Nothing is swapped inside the callback.

**Measured gas, with real B20s on the live node** (`tools/box/box-callback-sim.cjs`, `eth_simulateV1`;
output in paste 2). B20 stocks are node precompiles that cannot run in a forge fork, so this is the
only real measurement:

| stocks listed in the vault | callback gas, pays first stock | callback gas, skips all others first |
|---|---|---|
| 10 (all currently enabled) | 466,322 | 464,193 |
| 13 (all registered) | 565,717 | 573,350 |

The cost is **pricing the pool** (`PrizeVault._snapshot`: ~22.5k per registry mark, ~36k per listed
stock in total), not the B20 transfer (a B20 `balanceOf` is 2.6k). The first build priced every stock
twice per payout and measured **529k against a 500k limit**. It now prices once, and:

- `PrizeVault.MAX_STOCKS = 16` is a **hard gas bound**: ~683k at 16 by the measured slope. Stocks can
  be disabled but never removed, so the cap counts every stock ever listed.
- `Box.callbackGasLimit` defaults to **1,000,000**, and the owner cannot set it below
  `MIN_CALLBACK_GAS = 900,000` or above 2,000,000.

**When a callback fails anyway.** Pyth publishes the random number in `CallbackFailed` and marks the
request `CALLBACK_FAILED` (3). Anyone can call Entropy's `revealWithCallback` again, which re-runs our
callback with the **same** number and all remaining gas. `Box.retryOpen` asks for NEW randomness, so it
would be a **re-roll**. It is therefore allowed only when the request is still `CALLBACK_NOT_STARTED`
(1, never revealed), only by the opener, and only after `REVEAL_TIMEOUT = 30 days`.

**Attack this:**
- **Q5.** Can **anyone** (an opener, a gift recipient, a stock token, the registry owner, the Box or
  vault owner, a Chainlink feed) make the callback use more gas than it was measured at, or make it
  revert? Consider: the opener being a contract (does anything call into it?), 16 listed stocks,
  stale/reverting feeds, disabled stocks, a stock whose transfer reverts, the `try` around `settle`
  and the self-call `extTransfer` pattern, the 63/64 rule.
- **Q6.** Can an opener **choose their outcome** or re-roll by any path? Consider the reveal being
  computable off-chain before the callback lands (Pyth's Fortuna serves revelations over HTTP),
  `retryOpen`'s status gate (can `getRequestV2` be made to read `NOT_STARTED` for a revealed request,
  e.g. provider change, sequence reuse, a cleared request?), orphan callbacks after a retry, and
  transferring or re-opening a box mid-flight.
- **Q7.** Is the cap in Q5 enforced everywhere it needs to be? (`addStock` is owner-only and bounded
  by `MAX_STOCKS`; `setCallbackGasLimit` is bounded by `MIN_CALLBACK_GAS`.) Is anything else in the
  callback path unbounded?

---

## 4. The owed-prize path ("never paid short")

`PrizeVault.settle` is **all-or-nothing**: if the drawn prize exceeds `prizeCapUsd()` (25% of
inventory) or nothing can cover it, **nothing moves** and it returns `paid == false`. The Box then marks
the box `STATE_OWED` with the **exact drawn prize** (`owedUsd`), moves liability from the box's EV to
that exact prize, and keeps the NFT (bound to the opener; not transferable). `claimOwed(tokenId)` is
permissionless, re-attempts `settle` for exactly `owedUsd`, pays the **opener**, and reverts (moving
nothing) while it still cannot. Separately, a **sell gate** refuses to sell a SKU while the pool could
not pay its top prize (`SkuNotCovered`).

**Attack this:**
- **Q8.** Can an owed prize be paid twice, paid to the wrong address, paid more or less than `owedUsd`,
  or become larger/smaller after the draw? Can a box be both owed and paid?
- **Q9.** Is `outstandingLiabilityUsd` exact through every path (buy, callback paid, callback owed,
  settle revert, claimOwed, retryOpen, orphan callback)? Can it underflow or drift?
- **Q10.** Can someone force a prize into the owed path on purpose (e.g. by moving inventory just
  before a reveal: donations, restock, sweep, a feed going stale), and gain from it?

---

## 5. Pool solvency, restock and the sweep

- **Cap.** One prize ≤ `maxPrizeBps` (25%) of `inventoryUsd()` (USDC + enabled, fresh-marked stocks).
  Raising the cap is 48h-timelocked; ceiling 50%.
- **Restock (keeper).** `restock(stock, usdcIn)` swaps vault USDC into a registered stock via the
  registry's venue (Slipstream router B or Uniswap v3), minimum out = Chainlink mark from the registry
  less `restockSlippageBps` (≤5%), stale mark refused, per-call/per-day caps, and afterwards USDC must be
  ≥ `minUsdcBps` of inventory (the USDC fallback draws on it). Output lands in the vault.
- **Sweep (permissionless).** `sweepSurplus` pays only `box.treasury()`, and only USDC that clears all
  three floors: USDC ≥ 110% of liability; inventory ≥ `jackpotReserveUsd()` = the pool the largest
  prize needs (the larger of every SKU on sale at the current table, and `Box.maxSoldPrizeUsd`, the
  largest prize any **already-sold** box can win); USDC ≥ `minUsdcBps` of what remains. A reverting read
  sweeps nothing.
- **Owner wind-down.** `queueSurplusWithdraw` → 48h → `executeSurplusWithdraw`, checked against the
  same liability and reserve floors.

**Attack this:**
- **Q11.** Can the keeper drain value through `restock` (wrong router, wrong venue, stale or manipulated
  mark, recipient, approvals left behind, the USDC-share check)?
- **Q12.** Can anyone make `sweepSurplus` or the owner withdraw take the pool below what sold boxes are
  owed or could win? (Odds or price changes after a sale, paused SKUs, owed prizes, stale marks
  inflating or deflating inventory, rounding in `sweepableUsdc`.)
- **Q13.** Can inventory be inflated to pass the sell gate or cap and then deflated (donations are
  irreversible; stock marks come from the registry's Chainlink feeds, not the owner)?

---

## 6. $CHIP is never inventory (H-01, redone)

The first draft sent 95% of every $CHIP payment into the vault and then refused $CHIP on every exit,
stranding it. Now $CHIP never rests anywhere: buyer → converter → v4 pool, remainder → buyer, in one
transaction. The vault's `addStock`, `deposit` and `settle` refuse $CHIP (configured CHIP and the live
`DEFAULT_CHIP`); a stray $CHIP transfer into the vault can be `rescue`d. **Q14.** Can $CHIP end up
stuck, or paid as a prize, by any path?

**Q16 (round-1 fix).** F-2: requests are keyed by `(provider, sequence)` and `_fulfill` also checks
`_providerOf[tokenId] == provider`. Is every map write, read and delete (open, retryOpen, fulfil, owed)
consistent? Can a reveal still settle the wrong box?

**Q17 (round-1 fix).** `_gate` now runs before payment, once per call (a batch buys only one gate
check, on the reasoning that buying only grows the pool). Is that reasoning sound? Can a batch mint a
box the pool could not cover?

---

## 7. Everything the owner (the Safe) can do

Immediate: `setPaused`, `setSkuPaused`, `setChipPaused`, `setBaseURI`, `setCallbackGasLimit` (900k–2M), vault
`setKeeper`, `setRestockParams` (slippage ≤5%, maxPrizeBps ≤ USDC share ≤ 90%), `setMaxFeedAge` (1h–7 days), `addStock`
(≤16, registry-registered, never CHIP/USDC), `setStockEnabled`, `rescue` (never USDC or a listed stock);
converter `rescue` (any token: it holds nothing between calls). The converter has no other owner power.
48h timelock, 14-day grace: fee recipient (`queueTreasury`), SKU price/existence, odds table, raising
`maxPrizeBps` (never above the USDC share), vault surplus withdraw. The StockRegistry (feeds, venues) is owned by the same Safe, with no timelock (BOX-L5). Once only: `vault.setBox`,
`converter.setBox`. **Q15.** Can the owner take user funds or break a sold box's promise with an
immediate action? (Pausing and disabling stocks are accepted liveness levers.)

---

## 8. Known and accepted (tell us if you disagree)

1. **$CHIP buyers pay the pool's swap cost** (~2.3%) and carry their own price risk, bounded by their
   `maxChipIn`. The pool is never exposed to it.
2. **B20 marks hold the last close over weekends.** `maxFeedAge` defaults to 5 days; a stock whose
   mark is older is skipped everywhere (not counted, not paid, not bought).
3. **Pyth.** Liveness depends on the provider revealing; the keeper also completes stuck reveals via
   `revealWithCallback` (same number). Only if the provider never reveals for 30 days can the opener
   `retryOpen`.
4. **`maxSoldPrizeUsd` only rises.** After the last big-jackpot box is opened, the reserve stays higher
   than necessary. Conservative by design.
5. **Owed prizes can wait.** If the pool shrinks, an owed prize waits until sales (or a deposit) grow it.
6. **Buys are gas-heavy** (~640k with 10 stocks) because the sell gate values the whole pool. Accepted on Base.
7. **Box.sol is 23,788 bytes** (limit 24,576; our budget 24,000). Proposed fixes to Box must fit in ~200 bytes,
   or move logic out of Box.

---

## 9. What we need back

For each finding: **severity**, **file and line**, **the exact calls that exploit it** (who calls what,
in what order, with what values), and **a fix**. If you find nothing on a question, **say so explicitly
for each** (Q1–Q17). "No finding on Q6" is a result we need.

We will **reproduce every finding with a test before changing anything**, and we will not apply a fix
we cannot show is needed. (A previous review's suggested fix broke a working path; we check each one. Round 1's record is in
TRIAGE-ROUND1.md: 3 confirmed and fixed, 2 refuted by test, the rest accepted with reasons.)

Reproduce locally: `forge test --match-path 'test/box/*'` (no RPC); `forge test --match-contract BoxForkTest -vv`
(needs `BASE_RPC_URL`); `node tools/box/box-callback-sim.cjs` and `STOCKS=all node tools/box/box-callback-sim.cjs`
(needs `BASE_RPC_URL`, sends nothing).
