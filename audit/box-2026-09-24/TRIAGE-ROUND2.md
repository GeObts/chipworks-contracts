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

Only PASTE-6 was reviewed. Its F1 is LOT-L1 (above); F2–F8 are generic or already covered in round 1. Re-send PASTE-1 … PASTE-5.

## Forge output (after the BOX-L1 fix)

- `forge test --no-match-path 'test/fork/*'`: **944 passed, 0 failed** (48 suites). This includes BoxAuditRound1 and BoxAuditRound2.
- `forge test --match-path test/fork/BoxFork.t.sol` (Base mainnet fork): **1 passed**, `test_fullCycle_onRealPools`.
- Box runtime size: 23,788 bytes.
- Callback gas on the live node (real B20s): see gas/box-callback-sim.out.txt. The figures are ~465k with 10 stocks and ~574k with 13, against the 1M limit and the 900k floor.
