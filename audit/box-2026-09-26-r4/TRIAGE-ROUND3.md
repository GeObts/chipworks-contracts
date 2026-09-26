# Box audit round 3: triage

**Review:** Grok, `ROUND3_81c7e2e.md`, of `81c7e2e`. Its `src/` is identical to `2943917`.
**Verdict:** no Critical, High or Medium. One new Low (BOX-R3-L1), residual Lows, Info items, and brief/pack errors.
Grok verified every round-3 fix, reproduced the fork test on a public RPC, and ran 19 mutants: 18 killed, and X1 is killed only on the fork.

Nothing below was changed until it had been reproduced. Each fix has a test, and each guarded check was mutated and caught.

| ID | Verdict | Action |
|---|---|---|
| **BOX-R3-L1:** the failed-transfer cap sends a box OWED although a later stock could pay, and `claimOwed` re-walks the same two refusals | **CONFIRMED.** Reproduced as Grok's scenario H: stocks [A, B, C], A and B refuse, C accepts, no USDC. | **FIXED (deterministic, not gas-gated).** `settle(to, prizeUsd, entropy, gasBounded)`: Box passes `true` from the Pyth callback and `false` from `claimOwed`. Only the callback stops after `MAX_FAILED_TRANSFERS`; `claimOwed`, an ordinary transaction, walks every stock and then USDC. I rejected Grok's option (a), `gasleft()`-gated, because the recovery path `revealWithCallback` runs with caller-chosen gas and would let the caller pick stock vs USDC. Box +13 bytes → **23,801**. Tests: `test_R3L1_twoRefusalsGoOwed_thenClaimOwedPaysTheThirdStock` (the claim's walk is forced to start on A) and `test_R3L1_claimOwedTriesEveryStock` (exactly 2 refusals in the callback, 5 in the claim). Mutants "cap ignores the flag", "cap never on", "claimOwed passes true" and "callback passes false": **all killed.** |
| **Mainnet gate 1:** the real-node worst case with a refusing recipient | **MEASURED, no longer estimated.** B20 policies block OFAC-listed addresses. A plain NVDA transfer to `0x098B…2f96` reverts on Base (30,190 gas vs 59,046 OK), and Circle's USDC refuses it too. | New `tools/box/box-refusing-opener-sim.cjs` (paste 4), `eth_simulateV1` on the live node. Setup: 13 registered stocks listed, 10 funded by real venue restocks, the box gifted to that address, which opens it. **Callback: 580,918 gas, 2 real refused transfers, USDC refused, OWED.** Plus 3 stocks × 33.1k measured slope = **~680k at MAX_STOCKS = 16**, against the 900k floor and 1M default. `claimOwed` then walks all 10 real refusals plus USDC and reverts `StillUnpayable` (661,960 gas, as an ordinary tx). |
| BOX-R3-I3 (tests): X1 survives in units; the L6 test was warm and uncapped | CONFIRMED. | The mock PM now enforces the price-limit **direction** (`PriceLimitAlreadyExceeded`), so X1 is killed by 25 unit tests. New `test_L6_coldCallbackUnderTheGasCap_worstCases` delivers the callback like Pyth: `call{gas: callbackGasLimit}`, every touched account `vm.cool`ed. Grok's G (1 refuse + 14 thin + pay) = 442,199 mock gas; all-16-refuse → OWED = 362,569. |
| BOX-R3-I1: `min ≥ max` holds only at restock/sweep time | Agreed. | NatSpec softened (`setRestockParams`). No margin added: at the defaults (50/25) any single jackpot still leaves USDC ≥ the cap, and the failure mode is OWED, never short. |
| BOX-R3-I2: the two-address stale-mark option | Agreed; accepted (weekend drift, bounded by the 91% RTP). The R3-L1 fix doesn't change it. | — |
| **BOX-L3 residual:** the 5-day window accepts a weekday corporate-action freeze | Agreed as Low. The feed is total-return, so a split causes no jump; the exposure is market drift while frozen, the same class as a weekend. The docs name Coinbase's on-chain oracle registry (with the `paused` flag) but give **no address**, so it can't be read yet. | **OWNER DECISION:** accept, or add a calendar-aware age (~26h on weekdays plus weekend days plus one holiday day). The Coinbase pause-flag check can come once its address is published. |
| **BOX-L5:** the registry owner is an immediate trust root (+ the gas-burning-feed brick) | Agreed. Registry owner = the ChipWorks Safe `0xe109…73C7`, read live on 2026-09-26. | **OWNER DECISION** (Grok: must be explicit before mainnet). Options: accept and document the Safe as trust root, or a vault-side 48h-timelocked feed cache per stock. |
| BOX-L2, the H-3 residual, M-restock | Unchanged. | **OWNER DECISION.** |
| BOX-I5, E1–E3, I1–I3, BOX-M1 | Unchanged. | — |
| Brief/pack errors 1–10 | All agreed. | Fixed in the round-4 brief: commit naming stated per file class; MANIFEST no longer truncates; paste numbers; gas table and 16-stock figure replaced by fresh measurements; refusal cost reproducible (the new sim); the 2.26% hook cost now "~2.3–2.4%, market-dependent"; buy gas 665k/764k; every `maxPrizeBps` change is timelocked. |

## Forge output at `a73fa4d`

- Non-fork: **957 passed, 0 failed** (49 suites). Box suites: 138 passed.
- `BoxFork.t.sol` on a Base mainnet fork with a keyed RPC: **1 passed** (`test_fullCycle_onRealPools`).
- Mutation run on the round-3 fix and X1: **5 of 5 killed.** They are: cap ignores the flag, cap never on, claimOwed passes true, callback passes false, price limits swapped (X1: 25 unit tests).
- Live node: `box-callback-sim` 467,147 / 465,018 at 10 stocks and 566,543 / 574,176 at 13; `box-refusing-opener-sim` 580,918 (worst case, OWED).
