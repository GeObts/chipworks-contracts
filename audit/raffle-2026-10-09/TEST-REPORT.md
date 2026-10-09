# Raffle — test report

Every result below was **re-run fresh on 2026-10-09** for this package against source commit `5e575e5` (v1.2, after review round 1). Raw output is in `logs/`. Toolchain: forge 1.7.1, solc 0.8.24 (cancun, optimizer 200), OpenZeppelin v5.1.0.

| Suite | Result | Log |
|---|---|---|
| Unit (incl. 1 fuzz test × 512 runs) | **43 / 43 pass** | `logs/01-unit.log` |
| Invariants (5 × 256 runs × depth 80 = 20,480 calls each, fail-on-revert) | **5 / 5 hold**, 0 reverts | `logs/02-invariant.log` |
| Base-mainnet fork (real Entropy, USDC, StockRegistry, Pot, Safe), incl. a draw completed by the REAL Entropy's `revealWithCallback` | **4 / 4 pass** | `logs/03-fork-and-launch-config.log` |
| Launch config on fork (deploy script + chain checks) | **1 / 1 pass** | same |
| Live-node simulation with REAL B20 stock (`eth_simulateV1`, nothing sent) | **all checks ok** (block 52,390,692) | `logs/04-live-node-sim.log` |
| Mutation testing (36 hand-written mutants) | **34 / 34 killed**, plus 2 documented equivalents | `logs/06-mutation-*.log` |
| Gas | see §6 | `logs/05-gas-report.log` |

## 1. Reproduce

```sh
git checkout raffle            # source commit 7b81f9c, package commit on top
forge build
forge test --match-path test/raffle/Raffle.t.sol -vv
rm -rf cache/invariant/failures && forge test --match-path test/raffle/Raffle.invariant.t.sol -vv
BASE_RPC_URL=<base archive rpc> forge test --match-path "test/fork/Raffle*.t.sol" -vv
node tools/raffle/raffle-live-sim.cjs          # reads BASE_RPC_URL from .env; sends nothing
python tools/raffle/mutation.py [first last]   # restores the source afterwards, byte-exact
```

## 2. Unit suite (`tests/Raffle.t.sol`, base `tests/RaffleTestBase.sol`)

Mocks: `MockEntropyV2` (fee, provider, request status, `fulfill`), `MockStockRegistry`, `MockERC20`, `MockNoun` (ERC-721), plus `HostileTokens` (`BlacklistToken`, `FeeOnTransferToken`).

| Area | Tests |
|---|---|
| Constructor | `zeroAddresses`, `rejectsNonSixDecimalUsdc`, `redrawTimeoutBounds`, `launchDefaults` |
| Create | `onlyOwner`, `baseBounds`, `baseZero_reverts`, `prizeMustBeRegistryEnabled`, `rejectsFeeOnTransferPrize`, `reserveTooLow`, `zeroPayee`, `zeroPrize`, `ticketsAndEscrow`, `feeTicketsRoundUp`, `nonRoundBase_ticketsRoundUp` ($15 → 17 tickets), `nftOffAtLaunch` |
| Buy | `guards`, `rangesAndLiability`, `lastTicketRequestsDrawFromReserve`, `feeSpike_lastBuyStillSucceeds_thenAnyoneRequests`, `entropyOutage_lastBuyStillSucceeds` |
| Draw / callback | `callback_onlyEntropy`, `callback_orphanDoesNotRevert`, `callback_recordsUniformIndex`, `retryDraw_onlyAfterTimeout_andOnlyIfNeverRevealed`, `retryDraw_onlyOwnerPayeeOrKeeper`, `retryDraw_timeoutSnapshottedAtCreation` |
| User seed (v1.2) | `draw_passesContractMixedSeedToEntropy` (seed formula restated independently, exact value emitted and received; only the seeded overload used), `draw_everyRequestGetsADistinctSeed` |
| Return data (v1.2) | `tryTransfer_strictReturnData` (two words / a word of 2 / `false` → owed, never a revert; standard → delivered) |
| Settle / credits | `settle_beforeDraw_reverts`, `settle_paysEveryLeg`, `settle_firstAndLastTicket`, `settle_refusedPayee_creditsUsdc`, `settle_refusedWinner_creditsPrize_othersStillPaid`, `withdraw_creditsPayOnlyOnce` |
| Owner boundary | `ownerSetters_boundsAndAccess`, `ownerHasNoPathToEscrow`, `feeChange_doesNotTouchLiveRaffle` |
| Other | `reentrancy_prizeTokenCannotReenter`, `nftPrize_whenEnabled_fullCycle`, `gas_largeRaffle` |
| Fuzz | `testFuzz_buyerOfMatchesNaiveScan` (512 runs): the binary search matches a linear scan for random purchase layouts |

## 3. Invariant suite (`tests/Raffle.invariant.t.sol`)

The handler drives random sequences:
- the house creates raffles (a plain prize or a blacklistable one);
- 4 actors buy random quantities;
- Entropy reveals, stalls, or the fee spikes (`feeSpikeAndRequest`);
- stalled draws are retried after the timeout (`stallAndRetry`);
- anyone settles, claims or withdraws;
- recipients get blacklisted and un-blacklisted on both USDC and a prize token.

| Invariant | Asserts |
|---|---|
| `invariant_usdcAlwaysBalances` | `usdcLiability == Σ unsettled ticket money + Σ credits == USDC held`, to the unit |
| `invariant_usdcConserved` | Σ USDC across actors, house, payee, Pot and the Raffle == minted: none created or lost |
| `invariant_ethAlwaysBalances` | `ethLiability == Σ reserves + Σ ethOwed == ETH held`, to the wei |
| `invariant_prizesAlwaysBalance` | per token, `erc20PrizeEscrow == balance held` == escrowed + owed prizes |
| `invariant_drawIsHonest` | `sold ≤ N`; `sold == N` once at or past SoldOut; `winningTicket == rnd % N`; `winner == buyerOf(winningTicket)` |

## 4. Fork tests (`tests/fork/`)

These run on a Base fork with the **real** Entropy V2 (fee, default provider, `requestV2`, `getRequestV2` status), Circle USDC, StockRegistry, Pot, and the Safe as house.
- B20s cannot execute in a forked EVM (anvil lacks an opcode they use). NVDAc is therefore etched with a runnable ERC-20 at its real address, and the registry check still runs against the real registry.
- The reveal is delivered as the real Entropy address, because the provider's revelation is off chain.

| Test | Proves |
|---|---|
| `test_fork_fullCycle_realEntropyRealUsdc` | create → buy-out → real seeded `requestV2` (provider rounds 200k gas → 500k, fee 0.000015 ETH; the real Entropy's `Requested` log carries our seed) → callback → settle; every leg paid in real USDC |
| `test_fork_retryDraw_againstRealEntropyStatus` | `retryDraw` gating against the real Entropy request status; a ticket holder is refused, the Safe retries |
| `test_fork_realReveal_seedIncluded_drawCompletes` | Forks at block 52,359,528, so our draw takes the real sequence 584696. Completes it through the **real** Entropy's `revealWithCallback` with the public provider revelation; Entropy verifies it and runs our callback. Result == `keccak(ourSeed, revelation, 0)`, different from the real Box number for that sequence. Then settles. |
| `test_fork_onlyTheSafeCreates` | creation is owner-only with the Safe as owner |
| `test_launchConfig_24hRedraw_andChainChecks` | the deploy script's `checkChain()` passes on live state; the deployed instance has owner = Safe, `redrawTimeout` = 24 h, fee 10%, base $10–$1,000, NFT off, keeper unset (a post-deploy Safe call) |

## 5. Live-node simulation with real B20 (`tools/raffle-live-sim.cjs`)

`eth_simulateV1` runs on the live Base node, so the real B20 bytecode executes. Nothing is broadcast. The Raffle is deployed in the simulation with **real NVDAc** taken from the Box vault, the raffle is bought out, the **real Entropy** assigns sequence 584747, and then it settles.

```
ok   settled: winning ticket 77, winner 0x…B0002
ok   winner received 0.01863478 REAL NVDAc (B20 transfer out of the raffle)
ok   Pot received 10 USDC (fee tickets)
ok   payee received 100 USDC (base)
ok   raffle holds no NVDAc and no USDC afterwards
```

## 6. Gas

From the normal run (`test_gas_largeRaffle`, 2,003 purchases / 11,000 tickets):

| Operation | Gas |
|---|---|
| `buy` (1 ticket, 2k purchases deep) | 44,263 |
| last `buy`, incl. seeded Entropy request (mock; v1.1 was 203,044, the increase is the seed and the nonce write) | 226,965 |
| `settle` (binary search over 2,003 purchases) | 139,477 |
| `_entropyCallback` | 22–26k (limit 200k, rounded to 500k by provider) |

**Note on `logs/05-gas-report.log`.** `forge test --gas-report` runs each external call in isolation mode, which adds per-call base and cold-access costs to `gasleft()` deltas. Under it, `test_gas_largeRaffle`'s 250k ceiling on the last buy can exceed 250k and fail; under a normal run it measures 226,965 and passes (`01-unit.log`). The gas-report table was therefore produced with that one test excluded (42/42 pass). That test also switches off the mock Entropy's seed bookkeeping (three storage writes, the mock's cost, not the Raffle's). This is a measurement artifact, not a regression.

## 7. Mutation testing (`tools/mutation.py`)

Each mutant is one targeted source change. The unit and invariant suites must fail for the mutant to count as killed. The run was done in chunks because of host memory and time limits, and the source was verified restored after every chunk.

| # | Mutant | Result |
|---|---|---|
| 1 | fee tickets round down instead of up | killed |
| 2 | buy: cannot buy the exact remainder | killed |
| 3 | buy: liability not increased | killed |
| 4 | binary search boundary `>` → `>=` | killed |
| 5 | winning index modulo N−1 | killed |
| 6 | callback: anyone can call it | killed |
| 7 | callback: stale/duplicate delivery not ignored | **equivalent** (see below) |
| 8 | retryDraw allowed after a FAILED callback (re-roll) | killed |
| 9 | retryDraw timeout boundary `<` → `<=` | killed |
| 10 | settle: payee and Pot amounts swapped | killed |
| 11 | settle: liability not released | killed |
| 12 | settle: can settle twice | killed |
| 13 | credit: liability not re-added | killed |
| 14 | refused prize: escrow not restored | killed |
| 15 | tryRequest: ETH liability not reduced | killed |
| 16 | create: not owner-only | killed |
| 17 | prize: registry check removed | killed |
| 18 | escrow: received amount not checked | killed |
| 19 | withdrawUsdc: credit not zeroed (double pay) | killed |
| 20 | withdrawEth: credit not zeroed (double pay) | killed |
| 21 | NFT kill switch ignored | killed |
| 22 | fee cap removed | killed |
| 23 | leftover reserve not credited | killed |
| 24 | seed: final buy requests without the user seed (unseeded overload) | killed |
| 25 | seed: `requestDraw`/retry requests without the user seed | killed |
| 26 | seed: nonce not advanced | killed |
| 27 | seed: last buyer not mixed in | killed |
| 28 | `retryDraw` open to anyone again | killed |
| 29 | `retryDraw`: keeper not allowed | killed |
| 30 | `retryDraw`: payee not allowed | killed |
| 31 | `setKeeper` not owner-only | killed |
| 32 | redraw timeout not snapshotted at creation | killed |
| 33 | retry reads the live global timeout, not the snapshot | killed |
| 34 | `_tryTransfer` back to `>= 32 bytes` + bool decode | killed |
| 35 | `_tryTransfer`: any non-zero word counts as success | killed |
| 36 | create: explicit `base == 0` check removed | **equivalent** (see below) |

**#36 is equivalent by construction.** `setBaseLimits` refuses `minBase == 0` and the default is 10, so `base == 0` always also fails `base < minBase`. The explicit check was added at the reviewer's request as defence in depth.

**#7 is equivalent by construction.** `_raffleOfRequest[key]` exists only while its raffle is `Drawing` with that `(provider, sequence)`. It is deleted on delivery and on retry, so a stale or duplicate delivery already returns as an orphan before the removed defensive check would run. We kept the check as defence in depth and want auditors to confirm the reasoning.

History: the first mutation run (2026-10-08) killed 19/22 and exposed two test gaps, fee rounding for non-round bases and double-paid credits. Both were closed (`test_create_nonRoundBase_ticketsRoundUp`, `test_withdraw_creditsPayOnlyOnce`), and the source was refactored to one shared `_ticketsFor`. Confirming runs on 2026-10-09 killed 22/22 on v1.1. After the review round 1 fixes (v1.2), 13 mutants were added for the new code; the fresh run kills 34/34 with 2 documented equivalents.

## 8. Not covered by automated tests

- **Real-B20 behaviour inside a forge fork.** It is impossible there (missing opcode), so it is covered by the live-node `eth_simulateV1` run in §5.
- **The real provider's off-chain reveal on a fork.** Most forge fork tests deliver the reveal as Entropy. `test_fork_realReveal_seedIncluded_drawCompletes` instead completes a draw through the real Entropy's `revealWithCallback` with a real past revelation, and so does the keeper's end-to-end test (KEEPER.md).
- **ERC-721 with a real collection.** Only `MockNoun` is used. NFT prizes are off at launch.
