# AUDIT_BRIEF.md — Chipworks phase 1

Chipworks pays Coinbase B20 tokenized stocks to holders of two Base NFT collections, funded
by protocol fee streams, in permissionless 24-hour rounds.

**Status:** feature-complete for phase 1, frozen pending answers from Clutch (see §7).
**Target:** Base mainnet (8453) · Solidity 0.8.24 · EVM `cancun` · OpenZeppelin v5.1.0 ·
optimizer on, 200 runs · no `via_ir`.
**Size:** ~2,120 lines of non-comment source across 8 contracts + 1 base + 13 interfaces.
**Tests:** 361 passing — unit, fuzz, 4 stateful invariants at 128k calls each, and 31 tests
against a live Base mainnet fork.

Fork tests run against the **latest** Base block, not a pinned one, so live prices and pool
depth move between runs. Assertions are written to be property-based rather than to expect a
particular spread; if you prefer bit-for-bit reproducibility, pin a block in the
`vm.createSelectFork` calls under `test/fork/`.

```
forge test                                   # everything (needs BASE_RPC_URL)
forge test --no-match-contract "Fork"        # no RPC needed
forge test --match-contract Invariant        # ~105s
forge test --match-path "test/fork/*" -j 1   # serialise: a free-tier RPC will 429 otherwise
forge test --match-contract CodeSizeTest     # the size guard
```

**Size guard.** `test/CodeSize.t.sol` fails the build if any deployable contract exceeds
**24,000 bytes** — deliberately below the 24,576 EIP-170 limit, so a contract that creeps to
24,500 is caught before it becomes undeployable. It reads `.code.length` rather than relying
on deployment failing, **because Foundry exempts test-deployed contracts from the code size
limit and that is exactly how this was missed the first time**: 362 tests passed against a
contract that no chain would accept.

Fork tests are RPC-hungry. Running the whole suite in parallel against a rate-limited
endpoint produces spurious `429` failures that look like EVM errors; `-j 1` on the fork
paths, or a paid endpoint, avoids it.

---

## 1. What each contract does

| Contract | Code LOC | Holds funds | Role |
|---|---:|---|---|
| `ChipRounds.sol` | 605 | transiently, in-flight budget | Rounds, weights, splits, buying, POL holdback |
| `ChipClaims.sol` | 372 | **yes, user credits** | Credits, claim windows, expiry, sweeps, the ledger |
| `POLTreasury.sol` | 244 | **yes, protocol assets** | Slipstream POL positions, gauge staking, income routing |
| `StockRegistry.sol` | 232 | no | Which stocks are buyable, where, and the depth gate |
| `base/ConversionRoutes.sol` | 163 | n/a (abstract) | Chainlink-bounded swap machinery, shared by Pot and POLTreasury |
| `FeeSplitter.sol` | 138 | transiently | Three-way split of every inflow: Pot / ops / POL |
| `ClaimRouter.sol` | 119 | **never** | One-tx claim across Chipworks and Clutch |
| `Pot.sol` | 103 | **yes, round budget** | Holds round budget, converts inflows to USDC |
| `adapters/ClutchVaultAdapter.sol` | 70 | no | The entire Clutch seam, isolated on purpose |

Money flows: fee sources → `FeeSplitter` → `Pot` (+ ops, + POL) → `Pot.convert()` → round
budget → `ChipRewards` buys stock → credits → `claim` → holders. Unclaimed after 90 days →
`POLTreasury`. POL income → `FeeSplitter` → back to the Pot.

## 2. External dependencies

| Dependency | Address (Base) | Trust assumption | Verified? |
|---|---|---|---|
| USDC | `0x8335…2913` | Standard, could policy-block us | on fork |
| B20 stocks (9) | `0xb2…` prefix | **Native precompiles, not contracts** | on fork |
| Chainlink B20 equity feeds (9) | see ASSUMPTIONS A-13 | 8 dp, V3 aggregator, **no off-hours heartbeat** | on fork |
| Chainlink ETH/USD | `0x7104…Bb70` | Real heartbeat | on fork |
| Chainlink AERO/USD | `0x4EC5…cfF0` | Real heartbeat | on fork |
| Uniswap v3 factory / SwapRouter02 | `0x3312…FDfD` / `0x2626…e481` | Standard | on fork |
| Aerodrome Slipstream factory / NPM | `0x5e7B…809A` / `0x8279…5b72` | `mint` keyed by tickSpacing + sqrtPriceX96 | **selector-probed against deployed bytecode** |
| AERO | `0x9401…8631` | Standard | on fork |
| **Clutch soft-staking vault** | **does not exist on Base** | **entirely assumed** | **NO — see §7** |

Two dependency facts that shape the whole codebase:

**B20 tokens are native precompiles.** One byte of code (`0xef`), no EVM storage, yet they
answer `balanceOf` correctly on a real node. A forked EVM cannot execute them, and a failed
call to one **consumes all forwarded gas**. Every optional call to a foreign token is
therefore a gas-capped `staticcall`, never a bare `try/catch`. Base's docs confirm secondary
trading is permissionless but that policies can block addresses and the standard includes a
pause.

**B20 equity feeds have no heartbeat outside market hours.** They legitimately hold the last
close all weekend. Staleness is deliberately not judged in `StockRegistry`; see open item 6.

## 3. Invariants claimed

Stated as the auditor should test them. The first three are enforced by stateful invariant
runs (`test/ChipRewards.invariant.t.sol`, 128,000 calls each).

1. **ChipRewards is always solvent, per token.**
   `balanceOf(token) >= totalOwed[token]` after any sequence of rounds, claims, sweeps,
   rescues, freezes and time travel.
2. **Quote-token commitment is always backed.**
   `balanceOf(quote) >= totalOwed[quote] + committedQuote`. A live round's budget is
   committed the moment it leaves the Pot.
3. **A frozen stock cannot corrupt a healthy one.** NVDA/GOOGL accounting stays exact no
   matter what AAPL does.
4. **`recoverExcess` can never reach a user credit** — booked, expired-but-unswept, or a
   live round's budget. Only strictly-excess tokens.
5. **POLTreasury's rescue can never move a protocol asset** — not the quote token, a
   registered POL asset, a registered income token, or a position NFT. Exclusion-based, not
   arithmetic, because POL has no per-user "owed" figure to subtract.
6. **Routing is never worse than claiming directly.** Byte-identical outcomes, including
   when a leg is broken; a failed leg leaves the credit fully claimable.
7. **Every conversion is Chainlink-bounded, capped per call, and measured by balance delta.**
8. **Value is conserved in every split.** `pot + ops + pol == amount`, dust always to the Pot.
9. **A sold Noun stops earning immediately**, whether or not Clutch has been kicked.
10. **A padded or duplicated token-id list cannot inflate anyone's share.**
11. **The ledger is solvent for what it owes, and the engine is solvent for what it has
    committed.** Two separate statements post-split, neither able to cover for the other.
12. **Every finalized round gets at least 3 full claim windows before it expires**, under
    every accepted configuration and whatever moment it finalized at. Enforced by
    `_requireScheduleSane`, frozen per round at finalize, and asserted both by fuzz
    (`testFuzz_everyAcceptedConfigGivesAtLeastThreeWindows`) and by a stateful invariant
    that randomly retunes the schedule mid-run.
13. **Nothing still claimable is ever swept.** Claim and sweep eligibility are disjoint in
    time, and an expired credit earns no compound-share ledger entry for anyone.

## 4. Attack this first

In priority order. Each is where I would expect a finding.

### 4.0 THE SPLIT — read this before anything else

Chipworks used to be one contract. It reached 27,551 bytes of runtime code, ~3KB past the
EIP-170 limit, and **could not be deployed at all**. It is now two:

- **`ChipRounds`** spends money. Rounds, weights, splits, Chainlink-bounded swaps, venue
  selection, the POL holdback. It holds quote token only while a round is in flight.
- **`ChipClaims`** owes money. Credits, claim windows, expiry, sweeps. **Every token a
  holder is owed lives here and nothing else does.**

No proxy, no delegatecall: two plain contracts wired at deploy. The engine's entire reach
into the ledger is three `onlyRounds` functions — `creditWeight`, `recordAcquired`,
`freezeSchedule` — **none of which can move a token out**. That is the property to attack
first: if you can find a path where the engine, or anyone, extracts value from the ledger
other than through `claim` / `sweepExpired` / `recoverExcess`, the split has failed at its
one job.

Two consequences worth checking explicitly:

- **`recordAcquired` verifies before it believes.** The engine transfers tokens, then reports
  the amount. The ledger checks its own balance covers `totalOwed + amount` and reverts
  otherwise. The engine is trusted to be the engine, not trusted to be correct.
- **The handover is a NEW failure point that did not exist before.** `settleStock` transfers
  stock to the ledger, and a policy-blocked ledger would revert the whole round. **This was a
  real bug in the first cut of the split**, caught by running the pre-split hostile suite
  against it. The transfer is now attempted, measured by balance delta, and any shortfall
  stranded in the engine and reported via `StockStranded` rather than wedging the round. See
  `test_aBlockedLedgerStrandsOneStockWithoutWedgingTheRound`.

### 4.1 Rounds and credit accounting — `ChipRounds.sol` + `ChipClaims.sol`
The credit model is per-round weight shares, not a masterchef accumulator:
```
claimable = acquired[round][stock] * weightOf[round][stock][owner] / totalWeight[round][stock]
```
Attack: rounding across the three-way weight → slice → credit → claim chain; can the sum of
all claims exceed `acquired`? Can `totalWeight` be manipulated between `contributeWeights`
and `settleStock`? `closeAccumulation` is permissionless after a 2h window — is that window
enough to stop a griefer opening a round, adding only their Noun, and closing it?

Look hard at `settleStock`. **A prior version booked a swap that consumed input but
delivered nothing as a "skip", leaving the round claiming to hold quote token it no longer
had and permanently unfinishable.** Now both directions are measured deltas. Verify the fix
is complete, including `committedQuote` bookkeeping and the `StockUnderdelivered` path.

### 4.2 THE CLAIM WINDOW GATE — newest code, and it BLOCKS claims
Added after the first freeze. Claims unlock on a 7-day cadence anchored at deploy and stay
open 48h; outside a window `claim` reverts with `ClaimsClosed(now, nextOpenAt)`.

**Treat this as the highest-risk area in the repo.** Every other bug class here loses or
misallocates money; a bug in this gate *locks* money — a holder who cannot claim during any
window before day 30 loses the credit outright to the expiry sweep. Attack it from that
direction:

- Off-by-one at every boundary: at the opening instant, at `open + duration - 1`, at
  `open + duration`, at `anchor` itself, and before `anchor`.
- `openDuration == windowLength` must mean permanently open, not permanently shut.
- Modular arithmetic in `_isOpenAt` / `_windowStateAt` / `_openingsIn` — confirm
  `_openingsIn` really counts openings in the half-open interval `(from, to]`.
- **The config rule.** `_requireScheduleSane` enforces
  `creditExpiry >= MIN_WINDOWS_BEFORE_EXPIRY * windowLength` (3). The claim is that this
  makes "at least 3 windows" unconditional for any finalize moment, because openings fall on
  a fixed cadence so any interval of length `E` contains at least `floor(E/W)` of them.
  **Check that reasoning.** It is the load-bearing argument for the whole gate.
- **Per-round freezing.** A round snapshots `expiresAt`, `windowLengthAt` and
  `openDurationAt` at finalize, so governance cannot retroactively narrow an existing round.
  Verify there is no path that reads live config for an existing round's gate.
- `windowAnchor` is immutable. Confirm nothing can move it — if it could, governance could
  slide windows forward forever and block claims without changing a single duration.
- Interaction with expiry: claims allowed while `now <= expiresAt`, sweeps only while
  `now > expiresAt`. Confirm those are strictly disjoint, with no instant where both hold.

### 4.3 Expiry sweeps
`sweepExpired` moves unclaimed credits to POL 30 days after finalize, batched over a holder
list with a cursor, emitting one `CreditExpired` per holder. Attack: double-sweep,
sweep-then-claim, claim-then-sweep, interleaved batches double-counting a holder, the
final-batch dust settlement over- or under-paying, `sweptTotal` / `claimedTotal` drift, a
holder appearing twice in `_holders`, and whether an expired credit can be rescued out from
under the sweep (it must not be — `totalOwed` still counts it until swept).

Note the deliberate asymmetry: the sweep marks `hasClaimed` for each holder it processes.
That is what makes interleaved batches safe, but confirm it can never be reached while a
claim is still legal.

### 4.4 Rescue exclusions — THREE `recoverExcess` implementations
Three now, protecting different quantities. `ChipClaims` subtracts `totalOwed` (booked
credits). `ChipRounds` subtracts `committedQuote` (a live round's budget) and nothing else,
because credits are not held there at all — so stranded stock in the engine IS recoverable
while committed budget is NOT. `POLTreasury` uses a strict exclusion list. Attack all three: can an attacker or the
multisig get value out through a path other than the intended one? In POLTreasury check
`decreaseLiquidity` → does anything let withdrawn tokens leave to a wallet? (Intended: no.)
Check that marking a token as POL/income is enough to protect it retroactively.

### 4.5 The adapter seam — `ClutchVaultAdapter.sol` (70 LOC)
Small but load-bearing. It independently re-checks `IERC721.ownerOf` against the vault's
owner of record, so a lazily-kicked activation cannot pay a seller. Attack: can a vault
return values that make an unowned Noun score weight? Are all four foreign calls gas-capped?
Does a de-registered vault fail closed?

### 4.6 Conversions — `base/ConversionRoutes.sol` (163 LOC)
The most security-sensitive shared code. Attack: decimal handling across (token, feed,
quote) triples; a feed with unusual decimals; the dust floor where `minOut` rounds to zero
(refused — verify there is no path around it); whether the per-call cap can be bypassed;
whether a malicious router can be registered to drain (it is multisig-set, but confirm the
blast radius).

### 4.7 Everything else
`FeeSplitter` three-way split and share-bound arithmetic; `StockRegistry` pool verification
against the real factory; `ClaimRouter` leg isolation and the sweep.

## 5. Deliberate design decisions an auditor may flag

Each is intentional and documented in `ASSUMPTIONS.md` §3 (C-1 … C-17):

- **Pull, not push.** `FeeSplitter.receive()` does no work, so 2300-gas senders succeed.
- **Reverting, not force-sending, ETH.** A rejecting recipient wedges a flush; recoverable
  by retargeting, and tested. Chosen over a self-destruct force-send.
- **No masterchef accumulator.** It cannot express per-round 90-day expiry, and we must
  iterate Nouns anyway because the Clutch vault cannot enumerate them.
- **Hoodie boost read live, not poked.** Correct by construction; a borrowed hoodie still
  boosts that round, which caching would not fix either.
- **`claimFor` is permissionless.** Proceeds always go to the owner, so a stranger calling
  it can only help.
- **`settleStock` and `claim` are one call per stock.** Failure isolation is structural.
- **Immutable ceilings** on the ops share (`maxOpsBps`), the POL share (2000), and the POL
  holdback (2500). A compromised multisig cannot exceed them.

## 6. Known open items

Full list with reasoning in `OPEN_ITEMS.md`. Summary:

| # | Item | Status |
|---|---|---|
| 0 | **The Clutch seam** | **Blocked — see §7** |
| 1 | POL income stranded as AERO | **CLOSED** — per-token route table |
| 2 | Nothing routed USDC to POL | **CLOSED** — optional splitter leg + POL converter |
| 3 | Gauge address has no on-chain verification | Open, low risk |
| 4 | A round stuck in `Buying` has no escape hatch | Open, judged acceptable |
| 5 | B20-specific behaviour covered by mocks only | Open, unfixable locally |
| 6 | Equity feed staleness policy undecided | **Open — needs a decision** |
| 7 | Compound shares have no redemption path | Open, phase 2 |

Also unresolved: **C-10**, the one place failure isolation does not hold — if USDC itself
policy-blocked ChipRewards, a round in `Buying` could not settle or finalize. Every stock
path degrades gracefully; the quote token has no fallback.

## 6b. Deploy config now lists THREE collections

Lil Based Nouns (`0xe3c5Ef27B80481518a2363406e354a9361415556`, 4,420 supply) joins Based and
Dark at a 0.5x collection base. **No contract changed.** Everything collection-shaped is a
mapping keyed by address, so a collection is two multisig calls — `setCollectionBaseBps` on
`ChipRounds` and `setVault` on `ClutchVaultAdapter`.

For an auditor this is a config surface, not new code, but two properties are worth
confirming and both have tests in `test/ThreeCollections.t.sol`:

- **A collection with no base earns zero**, rather than defaulting to 1.0x. Forgetting the
  call fails closed.
- **Collections do not collide.** Weights, splits and the `counted` guard are all keyed by
  `(collection, tokenId)`, so the same token id in three collections is three Nouns.

Lil is also the first base below 1.0, so the fractional weight arithmetic is exercised
directly (tiers, hoodie boost, and payout ratios at 0.5x).

Verified on a Base fork in `test/fork/LilNouns.t.sol`: real ERC-721, 4,420 supply, EIP-1967
proxy, **not Enumerable**. Not-Enumerable is fine for the contracts, which never enumerate,
but the site and keeper cannot enumerate holders on chain either and must index events.

## 7. The Clutch seam — read this before scoping

Chipworks reads NFT activation state from a **Clutch Anvil soft-staking vault that does not
exist on Base**. Clutch publishes deployments on ApeChain (33139) and Robinhood Chain (4663)
only, and their public docs describe Anvil **v2**, with no mention of the "V3" the spec
assumes.

Consequences for an audit:

- Everything vault-facing is tested against `MockSoftStakingVault`, not reality.
- Seven assumptions (A-1 … A-9) are unverified. They are enumerated in `ASSUMPTIONS.md`.
- **All of them are confined to `ClutchVaultAdapter.sol`, 70 lines.** If the real ABI
  differs, that one contract is redeployed and `ChipRewards` and `ClaimRouter` are
  repointed. No credit migration, no redeploy of anything holding money.
- Two assumptions are already neutralised whichever way they resolve: A-8 (the adapter
  re-checks the live NFT owner) and A-9 (the router sweeps to the owner regardless of who
  Clutch pays).

**Update 2026-08-30:** on-chain recon settled most of this — see `CLUTCH_RECON.md`. There is
still no Clutch market on Base, but five real vaults on Robinhood Chain were read directly.
A-3, A-8 and A-11 are confirmed; A-4, A-5 and A-6 are refuted as function names but their
substance survives in a single `activations()` call; A-9 is confirmed in a way that breaks
ClaimRouter's Clutch leg. All of it still lands inside `ClutchVaultAdapter`.

**Suggested scoping:** audit the seven contracts as written, and treat the adapter as an
interface boundary with a stated contract. When Clutch answers, the adapter gets a short
follow-up review rather than reopening the whole scope.

## 8. Deployment posture

`DEPLOY.md` has the full order, constructor arguments and verified addresses. Two notes that
affect review:

- **`forge script` simulation cannot touch B20 tokens** (precompiles). Deploys that do must
  use `--skip-simulation` or run from the multisig UI.
- **Every tunable is a constructor argument or a multisig setter.** There are no hardcoded
  percentages, thresholds, windows or addresses in business logic. The ceilings listed in §5
  are the only fixed numbers, and they exist to bound governance.

Recommended: first mainnet round funded small. Confidence in B20-specific behaviour is
structurally lower than everything else here, and no amount of local testing changes that.
