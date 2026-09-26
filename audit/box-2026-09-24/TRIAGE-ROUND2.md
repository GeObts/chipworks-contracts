# Box audit round 2: triage

Reviews:
- **Grok:** `AUDIT_fdb77c4.md`, a full review of source `fdb77c4`.
- **Bankr:** reviewed only PASTE-6 (the reference file). Pastes 1–5 must be re-sent; see the bottom of this file.

Every finding was reproduced before anything changed:
- Box findings were tested in `test/box/BoxAuditRound2.t.sol`.
- Live-lottery findings were tested with `eth_simulateV1` on the live Base node against the deployed ChipLottery `0x2F68874F0D09A1319059Eb34868E4d2e770670F0`.

## Box stack

| ID | Grok severity | Verdict | Action |
|---|---|---|---|
| BOX-L1 no instant $CHIP-only stop | Low | **CONFIRMED** (only a 48h SKU queue, or a pause that also stops USDC) | **FIXED.** Added `Box.setChipPaused(bool)` (owner, immediate) and `chipPaused`. `_liveChipSku` reverts `ChipDisabled`. Test: `test_BOXL1_*`. Box is 23,788 B (budget 24,000). |
| BOX-M1 / LOT-M2 hook fee is buyer-side trust | Medium | **CONFIRMED as a trust assumption, not a bug.** The pool and vault are unaffected: the USDC leg is exact-output and balance-checked. | Documented. The buyer's loss is bounded by their `maxChipIn`, and the site sets it at quote +5% (`CHIP_HEADROOM_BPS=500`), re-quoted just before sending. TODO (monitoring): alert on `SetDopplerHook` / `SetDopplerHookState` for the $CHIP pool. |
| BOX-L2 immediate PrizeVault setters | Low (residual) | **CONFIRMED, owner-trust only.** The floors still hold, and a disabled stock can push open boxes to OWED, never short. | **OWNER DECISION**: accept and document, or timelock `setStockEnabled(false)` on stocks that still hold a balance. |
| M (restock ignores the 110% floor) | accepted | Unchanged. Bounded by ≤5% slippage per call, within the keeper caps. | **OWNER DECISION**: confirm acceptance. |
| BOX-I1 strays | Info | CONFIRMED. Stray $CHIP on the converter goes to the next buyer as change, and it can't block a buy (`test_LOTL1_strayChipOnTheConverterDoesNotBlockABuy`). | Accepted: strays are forfeit. |
| BOX-I2 ABI changes | Info | Checked. The keeper (`box-jobs`) and the /box UI already use `tokenIdOfRequest` and `PaidInChip`. | None. |
| BOX-I3, E1–E3 | Info | Agreed. | E1: the keeper's stuck-reveal job already alerts. E2/E3 are accepted as design. |
| I-PKG stale pack | — | Grok read the round-1 folder. The round-2 package is `audit/box-2026-09-24`. | None. |
| Gate item: forge output | — | Attached below. | — |

## Live ChipLottery (deployed, handles real money)

| ID | Verdict on the live node | Impact now |
|---|---|---|
| **LOT-L1** stray-$CHIP underflow | **CONFIRMED LIVE.** Sending the wrapper 1.5× one buy's $CHIP (~1.08M) makes the next 1-ticket `buyWithChip` revert. Half a buy's worth doesn't revert, but that buyer receives the stray. | Grief costs the attacker more than one buy of $CHIP. The owner's `rescue` clears it and keeps the $CHIP. Wrapper balance is 0 today, so it isn't happening. |
| **LOT-M1** next-drawing price | **CONFIRMED LIVE.** Simulated the Megapot owner (`0xF417…CB88`) calling `setTicketPrice(0.5 USDC)`, and the next `buyWithChip` reverts. | Latent. `ticketPrice()` = the current drawing's price = $1 today. It only bites if Megapot changes price mid-drawing, and then only until the drawing rolls. |
| LOT-L2 stray race | Confirmed (same mechanism as LOT-L1). | Info-level. |
| LOT-I1, I2, I3 | Doc inaccuracies. | None. |

**Recommendation:** redeploy ChipLottery with:
- `chipSpent = measured`;
- delta-based refunds;
- pricing from `getDrawingState(currentDrawingId()).ticketPrice`.

Needs the owner's OK. Until then, the keeper or monitoring should watch `sweepZero()` on the wrapper and call `rescue` if it's non-zero.

## Bankr

Bankr first reviewed only PASTE-6. Its F1 is LOT-L1 (above); F2–F8 are generic or already covered in round 1. PASTE-1 … PASTE-5 were re-sent and reviewed; see part 2.

---

# Part 2: Grok combined review (`ROUND2_COMBINED_fdb77c4.md`) and Bankr pastes 1–5

Grok found no High and no new Medium, and verified the BOX-L1 fix at `b4e5b8c`. Bankr answered Q1–Q17 with "no finding" and verified every paste's hashes. The vault-side fixes below cost the Box no bytes.

| ID | Source | Verdict | Action |
|---|---|---|---|
| BOX-L6 callback gas with refusing stocks | Grok (Bankr: "callback gas not asserted") | **CONFIRMED as unbounded.** Every refused transfer is a caught revert. Real B20 revert = **11,086 gas**, measured on all 13 registry B20s via `eth_simulateV1` (the mock costs ~9.8k), so 15 refusals ≈ 0.83M. | **FIXED.** `MAX_FAILED_TRANSFERS = 2`: after two refused transfers the walk goes to USDC. Test `test_BOXL6_sixteenRefusingStocks_twoTriesThenUsdc` covers 16 blacklisting stocks, exactly 2 tries, $1 paid in USDC and < 900k gas. Live sim rerun: 466,863 / 464,734 at 10 stocks and 566,259 / 573,892 at 13. |
| BOX-L3 `maxFeedAge` unbounded | Grok; Bankr ("5 days too permissive") | **Grok: CONFIRMED. Bankr's "lower it": REFUTED on live data.** Saturday 2026-09-26 15:58 UTC, all 13 registry feeds last updated Fri 16:00–23:35 UTC, so they will be ~2.9 days old at Monday's open and ~3.9 days after a holiday Monday. Anything under ~4 days marks every stock unpriced on long weekends. | **FIXED:** `MAX_FEED_AGE = 7 days` ceiling; the default stays 5 days. Weekend drift is bounded by the 91% RTP: a buyer needs a >~10% weekend move in their favour to be +EV, and `setSkuPaused` is immediate. |
| BOX-L4 gate is value-based, not deliverable | Grok | **CONFIRMED** (config). | **FIXED:** `minUsdcBps ≥ maxPrizeBps`, enforced in `setRestockParams`, in `queueMaxPrizeBps`, and re-checked at `executeMaxPrizeBps`, because the share can move during the 48h wait. Tests `test_BOXL4_*` and `test_sweep_usdcShareFloor_coversTheLargestPrize`. The wind-down withdraw deliberately does not keep the share (NatSpec now says so). |
| BOX-I4 tier/stock correlation | Grok | **CONFIRMED.** With n dividing 10,000, the first stock was a function of the roll. | **FIXED:** start = `keccak256(abi.encode(entropy)) % n`. Test `test_BOXI4_*`. The test helper `_rollForTier` now also picks a roll whose hash starts on stock #0. |
| M4 / M8 / M16 surviving mutants | Grok | **CONFIRMED** as test gaps (the mocks did the checks for us). | Added a lying-router mode and a partial-fill mode to the mocks, and tests `test_M4_*`, `test_M8_*`, `test_M16_*`. **Re-ran the mutants: all killed**, as were L1, L3, L4 (both), L6 and I4. Without M8's check the buy still reverts later, on the Box's USDC balance. |
| Production currency order untested | Grok | **CONFIRMED** gap. | `test_converter_chipAsCurrency1_asOnBase`: a $CHIP that sorts after WETH, so `chipIsCurrency0 == false` as on Base. It passes. |
| Bare `vm.expectRevert()` | Grok | CONFIRMED (test quality). | Replaced with specific errors across Box.t, BoxVault.t and BoxRebuild.t. |
| BOX-I6 NatSpec drift | Grok | CONFIRMED. | Fixed (the withdraw floors, and the IUniswapV4 "ticket" wording). |
| BOX-L5 registry owner is a trust root | Grok | **CONFIRMED; owner-trust.** Registry owner = the ChipWorks Safe `0xe109…73C7`, read live, the same key that owns the Box and vault. | **OWNER DECISION** (with L2): accept and document the Safe as the trust root, or timelock. |
| BOX-L2 / H-3 residual | Grok | Unchanged. | **OWNER DECISION.** |
| M-restock | Grok | Unchanged; leak ≤ slippage × daily cap. | **OWNER DECISION.** |
| BOX-I5 `setSkuPaused` blocks opening sold boxes | Grok | CONFIRMED; intended as an emergency lever. | Document in the UI. |
| Bankr: over-quoted `wethNeeded` | Bankr | Buyer's own parameter. The excess comes back as WETH in the same tx. | UI quotes +1% (`WETH_HEADROOM_BPS=100`). No change. |
| Bankr: unbounded stock list | Bankr | **REFUTED:** `MAX_STOCKS = 16` (Bankr's own PASTE-3 notes say so). | None. |
| Bankr: owed prize locked to an undeliverable token | Bankr | **REFUTED:** `claimOwed` calls `settle` again, which re-walks every stock and then USDC. Nothing is locked to the token that failed. An opener refused by every asset, USDC included, stays OWED. | None. |
| Bankr: coverage (reentrancy, entropy fee change, 18 decimals) | Bankr | Fee change: `open` reads the fee live and refunds excess, and underpaying reverts `Underpaid`. Reentrancy: every entry point is `nonReentrant` (Grok agrees). | Noted. |
| Fork not reproduced by Grok | Grok | Public RPCs rate-limited them. | Our run with a keyed RPC passes (below). |

Pack: regenerated for the new head (`audit/box-2026-09-26`).

## Forge output (after the BOX-L1 fix)

- `forge test --no-match-path 'test/fork/*'`: **944 passed, 0 failed** (48 suites). This includes BoxAuditRound1 and BoxAuditRound2.
- `forge test --match-path test/fork/BoxFork.t.sol` (Base mainnet fork): **1 passed**, `test_fullCycle_onRealPools`.
- Box runtime size: 23,788 bytes.
- Callback gas on the live node (real B20s): see gas/box-callback-sim.out.txt. The figures are ~465k with 10 stocks and ~574k with 13, against the 1M limit and the 900k floor.
