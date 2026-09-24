# Audit brief: ChipWorks Box (Box + PrizeVault + ChipConverter)

**Chain:** Base mainnet (8453). **Solidity:** 0.8.24, EVM `cancun`, OpenZeppelin 5.1.0, optimizer 200 runs, no `via_ir`.
**Source commit:** `c98ee57` in `chipworks-contracts`, branch `box-rebuild`. The packaged files are byte-identical to that commit after CRLF→LF.
**Pastes:** 1 = this brief + `Box.sol` · 2 = `PrizeVault`, `ChipConverter` and every interface (1 and 2 are the priority) · 3 = the rebuild tests, audit PoCs, the Base fork test and the live-node gas simulation · 4 = remaining tests and mocks · 5 = reference (optional: the v4 swap pattern the converter follows, and Pyth's own `revealWithCallback`).
**Nothing here is deployed.** Your review gates deployment. **User funds and on-chain randomness are involved.**

You are one of two independent reviewers. Please don't look for or use the other review.
We want two separate readings, not one reading twice.

---

## 0. Before you start: prove you received every file whole

An earlier review was done on a paste that had been cut off. Before any findings, reply with
**this table filled in** for every file you were given:

| file | line count you see | SHA-256 you compute (or "cannot hash") | last non-empty line, verbatim |
|---|---|---|---|

The expected line count and SHA-256 of each file are on its `===== BEGIN FILE` marker line (and in
`SHA256SUMS` / `MANIFEST.md`). Hashes are over the exact bytes: UTF-8, LF line endings, trailing newline
included, i.e. everything strictly between the BEGIN and END marker lines. Each paste ends with an
`===== END OF` line: if you can't see it, the paste was truncated. If a count or a last line does not
match, **stop and say which file**. A review of a truncated file is worse than none.

---

## 1. What this is, in one paragraph

Sealed, giftable ERC-721 "gacha" boxes. A buyer pays **$1, $10 or $25** in **USDC or $CHIP** for a
sealed box, then opens it: the Box requests randomness from **Pyth Entropy v2**, and Entropy's
callback draws a prize tier from a published on-chain odds table (91% expected return) and has the
**PrizeVault** pay it in a **Coinbase B20 tokenized stock** at its Chainlink mark (USDC if no stock
can cover it). Prizes are **never** paid in $CHIP; $CHIP is a payment option only. A USDC payment is
split 5% fee / 95% vault in the buy transaction. A $CHIP payment goes **whole** to the
**ChipConverter**, which a keeper later sells for USDC and splits the same way. The vault funds
itself from sales: a keeper converts vault USDC into stocks (`restock`), and a permissionless
`sweepSurplus` sends the house's margin to the fee recipient (the FeeSplitter → Pot). Box is
isolated from the rest of Chipworks: it only READS the StockRegistry and uses the same two stock
routers the rounds engine uses.

**Contracts (paste 1):** `src/box/Box.sol` (ERC-721, buy/open/callback/owed prizes), `src/box/PrizeVault.sol`
(the pool: settle, restock, sweep), `src/box/ChipConverter.sol` ($CHIP → USDC), plus interfaces.

---

## 2. ⚠ THE ONE KEEPER TRUST POINT: the minimum accepted when selling box $CHIP

**Start here.** `ChipConverter.sellChip(chipIn, minUsdcOut, deadline)` is keeper-only. **$CHIP has
no on-chain price**: its only market is a Uniswap v4 pool behind a Doppler hook with no oracle, no
cumulatives, no Chainlink feed. So the $CHIP→WETH leg is bounded by the **keeper-supplied**
`minUsdcOut`, not an oracle. The WETH→USDC leg IS bounded by Chainlink ETH/USD (`_wethToUsdc`).
A compromised keeper key could sell box $CHIP too cheap (e.g. sandwich itself). What is meant to
bound the loss:

- the keeper can only **sell**: USDC out goes only to `box.treasury()` (5%) and `box.vault()` (95%),
  both read live from the Box; there is no path from the converter to the keeper;
- per-call and per-UTC-day caps (`maxChipPerSell`, `maxChipSoldPerDay`), owner-set;
- an optional owner floor `minUsdcPerMillionChip` no keeper number can go under;
- `rescue` can never take $CHIP; only a 48h-timelocked owner recovery (`queueChipRecovery`) can, for
  a broken pool route.

**Attack this hardest:**
- **Q1.** Can the keeper, the owner, or anyone else make `sellChip` send value anywhere except the
  fee recipient and the vault, or move more $CHIP than the caps allow (day-boundary tricks, reentrancy
  through the v4 unlock, a partial fill at the price limit, `chipSpent` vs `chipIn`)?
- **Q2.** Can anyone reach `unlockCallback` other than through our own `poolManager.unlock` (it checks
  `msg.sender == poolManager`)? Is the v4 delta decoding correct for both currency orders
  (`chipIsCurrency0`)? Is `sync → transfer → settle → take` complete, so nothing is left unsettled?
- **Q3.** Is the floor check (`usdcOut * 1e24 / chipSpent`) sound, and can it be bypassed?
- **Q4.** Is the ETH leg's Chainlink bound correct (decimals, staleness, `answer <= 0`)?

The keeper's off-chain price source is a sampled median (the pool has no TWAP); it is out of scope
here, but tell us if the on-chain bounds assume anything about it that they should not.

---

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
stranding it. Now: a $CHIP buy transfers the whole price to the converter (`Box._buy`); the vault's
`addStock`, `deposit` and `settle` refuse $CHIP (configured CHIP and the live `DEFAULT_CHIP`); a stray
$CHIP transfer into the vault can be `rescue`d. **Q14.** Can $CHIP end up stuck, or paid as a prize, by
any path?

---

## 7. Everything the owner (the Safe) can do

Immediate: `setPaused`, `setSkuPaused`, `setBaseURI`, `setCallbackGasLimit` (900k–2M), vault
`setKeeper`, `setRestockParams` (slippage ≤5%, USDC share ≤90%), `setMaxFeedAge` (≥1h), `addStock`
(≤16, registry-registered, never CHIP/USDC), `setStockEnabled`, `rescue` (never USDC or a listed stock);
converter `setKeeper`, `setLimits`, `setPriceFloor`, `setEthLeg` (≤3%), `rescue` (never CHIP).
48h timelock, 14-day grace: fee recipient (`queueTreasury`), SKU price/existence, odds table, raising
`maxPrizeBps`, vault surplus withdraw, converter $CHIP recovery. Once only: `vault.setBox`,
`converter.setBox`. **Q15.** Can the owner take user funds or break a sold box's promise with an
immediate action? (Pausing and disabling stocks are accepted liveness levers.)

---

## 8. Known and accepted (tell us if you disagree)

1. **The keeper's $CHIP minimum (§2).** The accepted trust point, bounded as described.
2. **B20 marks hold the last close over weekends.** `maxFeedAge` defaults to 5 days; a stock whose
   mark is older is skipped everywhere (not counted, not paid, not bought).
3. **Pyth.** Liveness depends on the provider revealing; the keeper also completes stuck reveals via
   `revealWithCallback` (same number). Only if the provider never reveals for 30 days can the opener
   `retryOpen`.
4. **`maxSoldPrizeUsd` only rises.** After the last big-jackpot box is opened, the reserve stays higher
   than necessary. Conservative by design.
5. **Owed prizes can wait.** If the pool shrinks, an owed prize waits until sales (or a deposit) grow it.
6. **Buys are gas-heavy** (~640k with 10 stocks) because the sell gate values the whole pool. Accepted on Base.
7. **Box.sol is 22,955 bytes** (limit 24,576). Proposed fixes to Box must fit in ~1.6 KB.

---

## 9. What we need back

For each finding: **severity**, **file and line**, **the exact calls that exploit it** (who calls what,
in what order, with what values), and **a fix**. If you find nothing on a question, **say so explicitly
for each** (Q1–Q15). "No finding on Q6" is a result we need.

We will **reproduce every finding with a test before changing anything**, and we will not apply a fix
we cannot show is needed. (A previous review's suggested fix broke a working path; we check each one.)

Reproduce locally: `forge test --match-path 'test/box/*'` (no RPC); `forge test --match-contract BoxForkTest -vv`
(needs `BASE_RPC_URL`); `node tools/box/box-callback-sim.cjs` and `STOCKS=all node tools/box/box-callback-sim.cjs`
(needs `BASE_RPC_URL`, sends nothing).
