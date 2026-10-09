# Raffle v2 — test report

Every result below was run fresh on 2026-10-09 against source commit `7e99239`. Raw output is in `logs/`.

| Suite | Result | Log |
|---|---|---|
| Unit (incl. 2 fuzz tests × 512 runs) | **57 / 57** | `01-unit.log` |
| Invariants (6 × 256 runs × depth 80 = 20,480 calls each, fail-on-revert) | **6 / 6 hold**, 0 reverts | `02-invariant.log` |
| Base-mainnet fork (real registry, pools, oracles, router, factory, Entropy, USDC, Pot, Safe) | **5 / 5** | `03-fork-and-launch-config.log` |
| Launch config on a fork | **1 / 1** | same |
| **Live-node `eth_simulateV1`: the REAL swap** in the real NVDAc pool, then draw and settle; plus a real-pool manipulation refusal | **all checks ok** | `04-live-node-sim.log` |
| Mutation (66 mutants) | **63 / 63 killed** + 3 documented equivalents | `06-mutation-*.log` |
| Keeper E2E (anvil Base fork, real Entropy and USDC) | **19 / 19** | `07-keeper-e2e.log` |
| Gas | see §6 | `05-gas-report.log` |

## 1. Reproduce

```sh
git checkout 7e9923973cbbae0ecad2d04cd2fcbea823b70e79
forge build
forge test --match-path test/raffle/Raffle.t.sol -vv
rm -rf cache/invariant/failures && forge test --match-path test/raffle/Raffle.invariant.t.sol -vv
BASE_RPC_URL=<base archive rpc> forge test --match-path "test/fork/Raffle*.t.sol" -vv
node tools/raffle/raffle-live-sim.cjs        # reads BASE_RPC_URL from .env; sends nothing
python tools/raffle/mutation.py [first last] # restores the source afterwards
```

## 2. Unit suite (mocks: `MockSlipstreamPool` / `Factory` / `Router`, `MockEntropyV2`, `MockStockRegistry`, `BlacklistToken`, `ReturnShapeToken`)

The router mock fills an amount the **test** sets. Every `minOut` is checked against the test's own reference (NVDAc at $250 = 0.4 raw stock per raw USDC; `sqrtPriceX96` built independently), never against a copy of the contract's maths.

| Area | Tests |
|---|---|
| Constructor | every zero address; non-6-dp USDC; USDC must be the registry quote; the router must swap in the registry's factory; timeout bounds |
| Create | owner-only; escrows only the reserve, snapshots everything; fee on top ($100 → 110, $15 → 17); base bounds incl. 0; refuses: disabled/unregistered, not Slipstream, pool ≠ factory pool, wrong pair, wrong spacing, TWAP unavailable (reverting oracle, short buffer), too large for pool; reserve too low |
| Buy | guards; ranges and liability; **the last ticket only marks SoldOut** (no swap, no Entropy request) |
| Acquire | exact budget spent, stock held, **then** Drawing; owner/keeper only; wrong state; `minOut` = TWAP output × 98.5%; TWAP above/below spot scales the floor by 1.0001^±80; the guard refuses at 101 ticks both ways and allows exactly 100; TWAP floor rounding toward −∞; refusals move nothing (router floor, router revert, lying router, partial spend) and the raffle then recovers; conditions changed since creation (disabled, oracle down, pool re-pointed, pool drained); stock-as-token0 pool both ways; Entropy outage → PrizeReady → `requestDraw`; broken Entropy never blocks the buy |
| Fallback | only after the snapshotted timeout, by anyone, then draws; uses the raffle snapshot, not the live setting; Entropy outage → PrizeReady; races with acquire, both ways; settles in USDC; refused winner credited |
| Snapshots | owner changes never touch a live raffle (timeouts, guard, fee) |
| Draw / seed | callback only from Entropy; orphan; uniform index; the exact contract-mixed seed reaches Entropy; distinct seeds per request and retry; `retryDraw` owner/keeper only, timeout, never re-rolls FAILED; snapshotted redraw timeout |
| Settle | stock to the winner, fee to the Pot, reserve to the creator; first/last ticket; refused winner → `prizeOwedTo` → claim; refused Pot → credit; credits pay once; reentrant prize token blocked; strict transfer return data |
| Owner boundary | every setter's bounds and access; no owner path to escrow |
| Views / fuzz | `quotePrize` matches the TWAP price; `buyerOf` matches a naive scan (512 runs); the quote scales exactly by 1.0001^k for k ∈ [−500, 500] (512 runs) |
| Gas | 11,000-ticket raffle: buy, acquire, settle |

## 3. Invariants (`tests/Raffle.invariant.t.sol`)

The handler drives random sequences across two stocks and pools:
- **house:** creates raffles;
- **actors:** buy random quantities;
- **keeper:** buys prizes. One time in four the pool is pushed 101–150 ticks off its TWAP; one time in four the fill is under the floor; one time in five the router is down.
- **fallbacks:** after the timeout;
- **Entropy:** reveals, stalls, or the fee spikes;
- **retries:** after the timeout;
- **settlement:** settles, claims and withdrawals;
- **blacklists:** toggled on USDC and both stocks, for actors and the Pot.

A fixed 3,000-step run of the same handler shows both prize paths happen: 3 prizes bought, 1 refusal, 5 USDC fallbacks, and all 8 raffles settled.

The six invariants are listed in THREAT-MODEL §5. They include `invariant_noDrawWithoutAHeldPrize` and conservation of USDC across the pools, with no USDC left at the router and no lingering approval.

## 4. Base-fork tests (`tests/fork/`)

A forge or anvil fork **cannot execute B20 stocks** (missing opcode), so the real swap can't run there. §5 proves it on the live node instead. Everything around the swap runs against the real contracts:

| Test | Proves |
|---|---|
| `test_fork_everyEnabledStock_isRaffleable_andPricedSanely` | all 10 enabled stocks pass the real pool checks and the real 30-min TWAP. The TWAP quote for $1,000 is within ~0.3% of Chainlink for every one, a test-only sanity check (e.g. NVDA 435,376,871 vs 434,284,311 raw). |
| `test_fork_buyOut_fallback_realSeededEntropy_settlesInUsdc` | real pool at create; the ticket holder can't buy or fall back early; the swap attempt refuses cleanly (fork limit) and moves nothing; after 6 h anyone falls back; **the real Entropy logs our seed**; settles $100 USDC to the winner and $10 to the real Pot |
| `test_fork_retryDraw_ownerOrKeeper_againstRealEntropyStatus` | retry gating against the real Entropy status; a ticket holder is refused |
| `test_fork_onlyTheSafeCreates` | owner-only creation |
| `test_fork_realReveal_seedIncluded_drawCompletes` | fork at block 52,359,528; a raffle created against the real NVDAc pool (TWAP read at that block) takes the real sequence 584696; completed through the **real** Entropy's `revealWithCallback` with the public revelation. Result = `keccak(ourSeed, revelation, 0)` |
| `test_launchConfig_v2_andChainChecks` | deploy script `checkChain()` (incl. router factory == registry factory) and every launch value |

## 5. Live node: the real swap (`tools/raffle-live-sim.cjs`, `eth_simulateV1`, nothing sent)

**Pass A** deploys v2 against the real registry, router, Entropy, USDC and Pot, then creates a $100 NVDAc raffle and sells all 110 tickets. The keeper's `acquirePrize` then runs against the **real** router and pool:

```
acquirePrize gas: 611368 | TWAP quote for $100: 0.43536811 NVDAc | bought: 0.43515037 NVDAc
ok   after the buy the raffle is Drawing (state 4) - randomness requested only now
ok   the REAL pool received exactly 100 USDC (the prize budget)
ok   the raffle HOLDS the 0.43515037 REAL NVDAc it bought before any winner exists
ok   only the 10 USDC fee remains in USDC
ok   fill is -5 bps vs the TWAP quote (floor allows -150)
ok   REAL Entropy sequence 584797 from provider 0x52De…6506
ok   settled: winning ticket 77, winner …B0002
ok   winner received the 0.43515037 REAL NVDAc that was bought
ok   Pot received 10 USDC (the 10% on top)
ok   raffle holds no NVDAc and no USDC afterwards
ok   leftover reserve 30000000000000 wei credited to the creator
```

**Pass B** uses the same setup, but a $1M whale buy pushes the real pool in the same block before the keeper's buy:

```
a $1000000 whale buy moved the real pool's tick -8317 -> -10347 (-2030 ticks)
ok   refused with AcquireRefused(1, 5) - 5 = SpotDeviates
ok   nothing moved: still SoldOut, all 110 USDC still held
```

## 6. Gas

| Operation | Gas | Source |
|---|---|---|
| `acquirePrize`, REAL router + REAL pool + real NVDAc + Entropy request | **611,368** | live node |
| `acquirePrize`, mock router + mock Entropy | 420,873 | `01-unit.log` |
| `buy` (1 ticket, 2k purchases deep) | 35,922 | unit |
| `settle` (2,003 purchases / 11,000 tickets) | 118,408 | unit |
| `createRaffle` (with the pool checks and TWAP read) | ~320k | gas report |

`--gas-report` is produced without `test_gas_largeRaffle`, because isolation mode distorts `gasleft()` deltas (see the v1.2 report).

## 7. Mutation testing (`tools/mutation.py`, 66 mutants)

Each mutant must make the unit or invariant suite fail. All are listed with their results in `logs/06-mutation-*.log`.
- 23 carried from v1.2;
- 13 for the review-round-1 code;
- 30 new for v2: create validation, pool identity, the guard (removed, boundary, no slippage, spot-only, TWAP direction, token order, floor rounding, tick base), swap accounting, sellout time, all fallback paths and owner bounds.

**Three documented equivalents:**
- **#7: stale or duplicate callback.** Unreachable by construction: the request key exists only while that raffle is Drawing with that (provider, sequence).
- **#33: explicit `base == 0` check.** `setBaseLimits` refuses `minBase == 0`, and the default is 10.
- **#55: approval reset.**
  - The approval equals exactly `base`.
  - The router's pull of exactly `base` brings it to zero.
  - Every other outcome reverts the whole call, approval included.
  - Kept as defence in depth.

## 8. Not covered by automated tests

- **The real swap inside forge.** Impossible (B20); covered on the live node (§5).
- **Weekend depth and per-pool tuning.** SPEC-v2 §2.5 pre-deploy items 1–3. This gates the mainnet deploy, not the audit.
- **The keeper's `*/5` cron dispatch inside Cloudflare.** The job logic is E2E-tested; the cron wiring is checked by review only.
