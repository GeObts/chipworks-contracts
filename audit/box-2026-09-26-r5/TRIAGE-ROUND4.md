# Box audit round 4: triage and owner decisions

**Review:** Grok, `ROUND4_a73fa4d.md`, of `a73fa4d`.
**Grok's verdict:** no Critical, High or Medium in the Box stack, apart from the buyer-side BOX-M1. The BOX-R3-L1 fix is verified correct and deterministic.
**What Grok reproduced and ran:**
- It reproduced the live-node worst case exactly: 580,918 gas.
- It measured per-stock slopes at K = 3…13, which puts 16 stocks at about 685k tx / 670k minimum callee cap. That leaves ≥200k of headroom under the 900k floor.
- It ran 29 mutants, and all 29 were killed.

## Owner decisions (2026-09-26, the ChipWorks Safe owner)

The Safe is a 2-of-3 multisig and the trusted operator. In every case below the pool stays solvent against what sold boxes are owed.

| Item | Decision | Rationale (owner) |
|---|---|---|
| **BOX-R4-L1:** an OWED box whose opener every asset refuses (a sanctioned address) stays OWED, with 110% of the prize reserved in USDC | **ACCEPT + DOCUMENT.** No write-off function. | Refusing to pay a sanctioned address is correct, and the token issuers enforce it. It is a rare edge case. A write-off would need counsel. Keepers must `eth_call` `claimOwed` before sending, so they never burn gas on a claim that reverts. |
| **BOX-L5:** the StockRegistry owner (the same Safe) can re-point feeds and venues immediately | **ACCEPT + DOCUMENT** | The Safe is the trusted party. |
| **BOX-L3 residual:** the 5-day window accepts a weekday corporate-action freeze | **ACCEPT + DOCUMENT.** The default stays 5 days (ceiling 7). | Anything under ~4 days marks every stock unpriced on long weekends. The feeds are total-return, so a freeze causes no price jump. |
| **BOX-L2:** PrizeVault setters take effect immediately | **ACCEPT + DOCUMENT** | Every one is bounded, and the floors hold. |
| **H-3 residual:** a disabled or stale stock can be withdrawn behind the 48h timelock without the reserve check seeing it | **ACCEPT + DOCUMENT** | The floors hold on what remains, and the pool stays solvent. |
| **M-restock:** restock ignores the 110% floor (≤5% slippage per call, within the caps) | **ACCEPT** (decided earlier the same day) | — |
| ChipLottery redeploy (LOT-M1, LOT-L1) | **DEFERRED** | Monitor the wrapper's balance and `rescue` any stray tokens. |
| Second independent reviewer | **REQUIRED before mainnet; not waived** | Two independent reviews, because this code handles user funds and on-chain randomness. |

## Product changes since round 4 (owner-requested, reviewed in round 5)

- **Launch odds, "option B":**

  | Share of boxes | Pays |
  |---|---|
  | 35% | 0.5× |
  | 50% | 0.6× |
  | 9.5% | 1× |
  | 4% | 2× |
  | 1% | 8× |
  | 0.5% | 36× |

  Weights sum to 10,000, and RTP is 9,100 bps (91.00%). The jackpot is unchanged, so the reserve for each size is unchanged.
- **Box sizes:** `MAX_SKUS` goes from 3 to 8.
  - At launch, $1/$10/$25 are on sale. $50 (id 3) and $100 (id 4) exist but are **paused**.
  - A paused size that has never sold contributes nothing to `maxLivePrizeUsd`, so it doesn't hold back the sweep.
  - `setSkuPaused` puts it on sale immediately. The sell gate then opens it once the pool covers its jackpot: $1,800 needs a pool of $7,200, and $3,600 needs $14,400.
  - Box is **23,843 bytes**.

## Round-4 Info items

| ID | Action |
|---|---|
| R4-I3: the sim reports tx `gasUsed` including 21,760 intrinsic gas, uses the unfunded slope, and has no capped/G-real variant | Documented in the brief: the figures are tx gas. Grok's independent capped delivery (min cap 567,577 at 13; ok at 900k and 1M) and its funded slope (33.86k) are cited. No extra sim, because Grok's harness already covers it and the headroom conclusion is unchanged. |
| R4-I4: the cold test ran at 1M and didn't check who paid | **FIXED:** it runs at `MIN_CALLBACK_GAS` (900k) and asserts that the paying stock is the last one. It is not EIP-2200-clean (setup happens in the same tx); the live-node sims remain the authoritative numbers. |
| R4-I5 P1: ChipLottery "paste 6" | **FIXED** (paste 7 in this pack). |
| P2/P4: cold-test numbers and the "957 pass" count don't reproduce on Foundry 1.8.3 | Explained by the toolchain: **our runs use Foundry 1.7.1** (`forge Version: 1.7.1`). On 1.8.3 the non-Box `AnvilQueueIntegrity::test_M2_restockingIsNotQuadratic` gas threshold fails (24,157,467 ≥ 24M), as Grok saw; it passes on 1.7.1. The cold-test gas is toolchain-dependent; the pass/fail assertions are not. |
| P5: the round-3 test cited the wrong triage file | **FIXED.** |
| P6: `box-callback-sim.cjs` hardcoded the viem path | **FIXED:** it honours `VIEM_FROM`. |
| P7: 580,918 is tx gas, not callee execution | Stated in the brief (execution ≈ 559k). |
| P8: head ≠ source + pack | Stated per file class in the brief header. |
| R3 errors 6 and 10 (partial) | **FIXED:** per-stock cost is now "~33.1k unfunded / 33.9k funded"; the column says the skipped stocks are empty; §5 says every `maxPrizeBps` change is timelocked. |
| BOX-R4-I1/I2 (the caller chooses when `claimOwed` / recovery runs) | Accepted. USD value is fixed, and gas cannot steer the outcome (Grok's sweep: 921/921 paid in stock). |

## Forge output at the round-5 source commit

- Toolchain: **Foundry 1.7.1**, solc 0.8.24.
- Non-fork: **959 passed, 0 failed** (50 suites). Box suites: **140 passed**, including `BoxLaunchConfig.t.sol` (the option-B table, and the $50/$100 unlock at exactly $7,200/$14,400).
- `BoxFork.t.sol`, Base mainnet fork: **1 passed**.
- Live node, rerun at the round-5 source:
  - `box-callback-sim`: 467,147 / 465,018 at 10 stocks and 566,543 / 574,176 at 13.
  - `box-refusing-opener-sim`: 580,918 (OWED).
  - All are unchanged, because the stock walk did not change.
