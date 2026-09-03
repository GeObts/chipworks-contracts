# AUDIT_BRIEF.md — Chipworks phase 1

Chipworks pays Coinbase B20 tokenized stocks to holders of three Base NFT collections,
funded by protocol fee streams, in permissionless 24-hour rounds. Holders opt in by burning
$CHIP to activate a Noun at a tier, and may borrow against that Noun without giving up what
it earns.

**Status:** feature-complete for phase 1. **No longer blocked on anyone.** Chipworks now
runs its own activation vault instead of depending on Clutch; see §7.
**Target:** Base mainnet (8453) · Solidity 0.8.24 · EVM `cancun` · OpenZeppelin v5.1.0 ·
optimizer on, 200 runs · no `via_ir`.
**Size:** ~3,030 lines of non-comment source across 12 contracts + 1 base + 14 interfaces.
**Tests:** 593 passing — unit, fuzz, 4 stateful invariants at 128k calls each, and 40 tests
against a live Base mainnet fork.

`B20_DOCS.md` in this repo is Base's own tokenized-stock documentation, filed verbatim. It is
the source for everything in ASSUMPTIONS A-13, A-15 and A-18, and it is worth reading before
§4.9 — it settles what the Chainlink feeds actually report, which is the fact the whole
pricing path rests on.

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
forge test --match-path "test/activation/*"  # our own vault, incl. the parity proof
forge test --match-path "test/loans/*"       # lending + the custody integration
forge test --match-path "test/b20/*"         # B20 hardening: multiplier, frozen feed, identity
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

Runtime sizes, all inside the 24,000-byte budget the size guard enforces (EIP-170 is 24,576):
ChipRounds 20,834 · POLTreasury 15,190 · NounLoans 13,425 · ChipClaims 12,879 ·
ChipActivation 10,023 · Anvil 9,359 · Pot 9,042 · StockRegistry 8,971 · Furnace 7,711 ·
FeeSplitter 4,782 · ClaimRouter 3,149 · ClutchVaultAdapter 3,151. ChipRounds has the least
headroom at 3,742 bytes and is the one to watch.

| Contract | Code LOC | Holds funds | Role |
|---|---:|---|---|
| `ChipRounds.sol` | 532 | transiently, in-flight budget | Rounds, weights, splits, buying, POL holdback |
| `loans/NounLoans.sol` | 363 | **yes, collateral + pool $CHIP** | Borrow $CHIP against a Noun; the first registered custodian |
| `ChipClaims.sol` | 333 | **yes, user credits** | Credits, claim windows, expiry, sweeps, the ledger |
| `activation/ChipActivation.sol` | 264 | **never** | **Our own soft-staking vault.** Activation, tiers, lazy reset, custodians |
| `POLTreasury.sol` | 244 | **yes, protocol assets** | Slipstream POL positions, gauge staking, income routing |
| `StockRegistry.sol` | 232 | no | Which stocks are buyable, where, and the depth gate |
| `anvil/Anvil.sol` | 291 | **yes, shelved Nouns** | Buy a Noun at a fixed ETH price. FIFO Box + snipe. **Buy side only** |
| `furnace/Furnace.sol` | 210 | **yes, deposited output NFTs** | Burn Lils + $CHIP to forge a Noun. **Outside the money path** |
| `base/ConversionRoutes.sol` | 163 | n/a (abstract) | Chainlink-bounded swap machinery, shared by Pot and POLTreasury |
| `FeeSplitter.sol` | 138 | transiently | Three-way split of every inflow: Pot / ops / POL |
| `Pot.sol` | 103 | **yes, round budget** | Holds round budget, converts inflows to USDC |
| `ClaimRouter.sol` | 84 | **never** | Batches many Chipworks claims into one transaction |
| `adapters/ClutchVaultAdapter.sol` | 76 | no | **RETIRED, not deployed.** The old Clutch seam, kept as an alternative implementation |

Money flows: fee sources → `FeeSplitter` → `Pot` (+ ops, + POL) → `Pot.convert()` → round
budget → `ChipRounds` buys stock → credits → `claim` → holders. Unclaimed after 30 days →
`POLTreasury`. POL income → `FeeSplitter` → back to the Pot. Loan fees → `FeeSplitter`, so a
loan funds the next round like any other inflow.

$CHIP flows one way only: **out of circulation.** Activations and Furnace forges burn it to
`0xdead`; the split-change fee burns it. Nothing in this repo mints it and no contract here
holds it at rest except the NounLoans pool, which is seeded by the multisig.

## 2. External dependencies

| Dependency | Address (Base) | Trust assumption | Verified? |
|---|---|---|---|
| USDC | `0x8335…2913` | Standard, could policy-block us | on fork |
| B20 stocks (13) | `0xb2…` prefix | **Native precompiles, not contracts** | on fork + RPC |
| Chainlink B20 equity feeds (13) | see ASSUMPTIONS A-13 | 8 dp, V3 aggregator, **total-return**, 24h heartbeat in hours, **none off-hours** | on fork |
| Chainlink ETH/USD | `0x7104…Bb70` | Real heartbeat | on fork |
| Chainlink AERO/USD | `0x4EC5…cfF0` | Real heartbeat | on fork |
| Uniswap v3 factory / SwapRouter02 | `0x3312…FDfD` / `0x2626…e481` | Standard | on fork |
| Aerodrome Slipstream factory / NPM | `0x5e7B…809A` / `0x8279…5b72` | `mint` keyed by tickSpacing + sqrtPriceX96 | **selector-probed against deployed bytecode** |
| AERO | `0x9401…8631` | Standard | on fork |
| ~~Clutch soft-staking vault~~ | — | **NO LONGER A DEPENDENCY.** Replaced by `ChipActivation`; see §7 | n/a |
| $CHIP | _TBD_ | Standard ERC-20, Doppler/Bankr launch, **no `burn()`** | at launch |

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
14. **A sold Noun is inactive in the same block, with no keeper.** `ChipActivation` stores no
    `active` flag; every read recomputes the effective owner. There is no interval in which a
    stale record scores weight, and nothing has to be run for that to be true.
15. **A custodian can only speak for tokens it actually holds.** `beneficiaryOf` is only ever
    called on the address `ownerOf` returned, so a hostile custodian's blast radius is its
    own custody and nothing else.
16. **`ChipActivation` holds no $CHIP between transactions**, so 100% of every activation
    cost burns and the rescue has nothing to protect.
17. **`NounLoans.poolBalance` never exceeds the $CHIP actually held**, through borrow, repay
    and liquidation, and a borrower's collateral leaves by exactly two paths.
18. **A skipped stock always carries its whole slice back to the Pot**, whether it was
    skipped for a stale feed, a broken swap or a disabled market. No skip ever costs a cent.
19. **No contract in `src/` identifies a stock by anything but its address**, enforced by a
    build-failing scan rather than by review.
20. **The Anvil never holds ETH.** 100% of every sale is forwarded in the same transaction
    and there is no withdraw path, so a balance would mean something already went wrong.
21. **A snipe never reorders the FIFO queue**, and `buyNext` always returns the oldest token
    still on the shelf.
22. **A Noun cannot be borrowed against unless it is actively chipped to the borrower**, and
    the chip survives custody untouched for the life of the loan.

## 4. Attack this first

Each is where I would expect a finding. **If you only have time for three, make them these,
and in this order:**

1. **§4.5a, the custodian registry.** New authorization logic, and the only place in the
   repo where *a contract's answer decides who owns a Noun*. It reassigns the effective
   owner, and the effective owner is what every weight, every credit and `setSplit` are
   keyed to. It is also the newest code here.
2. **§4.2, the claim window gate.** Every other bug class loses or misallocates money; a bug
   in this one *locks* it.
3. **§4.0, the ChipRounds/ChipClaims split.** The engine must not be able to extract value
   from the ledger by any path but `claim` / `sweepExpired` / `recoverExcess`.

Sections 4.5 and 4.5b are new since the last candidate and carry the largest share of the
new lines; 4.9 is the B20 surface, where one property is documented as a limit rather than a
guarantee and should be read as such.

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

### 4.4 Rescue exclusions — FIVE `recoverExcess` implementations
Five now, protecting different quantities. `ChipClaims` subtracts `totalOwed` (booked
credits). `ChipRounds` subtracts `committedQuote` (a live round's budget) and nothing else,
because credits are not held there at all — so stranded stock in the engine IS recoverable
while committed budget is NOT. `POLTreasury` uses a strict exclusion list. `NounLoans` subtracts `poolBalance` for $CHIP and
sweeps anything else whole, and separately refuses to move an NFT that is live collateral.
`ChipActivation` subtracts **nothing at all**, on the claim that it never holds a user asset
in the first place — no $CHIP between transactions and no custody of a Noun — which is the
one to test hardest, because it is the only one whose safety is an argument rather than an
arithmetic. Attack all five: can an attacker or the multisig get value out through a path
other than the intended one? In POLTreasury check `decreaseLiquidity` → does anything let
withdrawn tokens leave to a wallet? (Intended: no.) Check that marking a token as POL/income
is enough to protect it retroactively.

### 4.5 ACTIVATION — `activation/ChipActivation.sol` (264 LOC), NEW AND CORE

This replaced the Clutch adapter and is now the source of every weight in the system. It was
the thinnest, most-hedged part of the design; it is now one of the largest. Scope it as core.

**What it does.** Burn $CHIP to activate a Noun at a tier. The Noun never moves. The
activation is void the instant the Noun changes hands.

**Attack the reset first.** There is no stored `active` flag and no `kick`: `activation()`
recomputes the effective owner on every read and compares it to `ownerAtActivation`. The
claim is that this makes a sold Noun score zero in the same block, unconditionally and with
nobody running anything. Try to find a state where a stale record scores: a re-entered read,
a collection that returns garbage, a token id that was never minted, an `ownerOf` that
returns the zero address.

- **The tier-0 collision.** ASSUMPTIONS A-12: the spec calls a reset Noun "tier 0" while the
  tier table calls index 0 the 1.00x base tier. This contract resolves it by never inferring
  activation from tier — a reset returns `active = false`, not `tierBps = 10000`. **Verify
  there is no path that treats tier index 0 as inactive**, which would silently zero every
  base-tier Noun, and none that treats a reset as tier 0's weight, which would pay sellers.
- **Resurrection is deliberate.** A Noun sold and bought back by the same address reads
  active again. That is safe here because the record only ever pays the address that bought
  the tier and that address is the live owner again — but check the reasoning holds when a
  custodian is in the path.

**And the burn.** `_burnChip` measures `balanceOf(0xdead)` either side of the transfer and
reverts on a shortfall, so a lying $CHIP cannot buy an activation for free. The contract
holds no $CHIP between transactions — which is why `recoverExcess` needs no exclusion list,
and is a claim worth trying to falsify.

Costs and the tier curve both move only through a 48h queue/execute, **stricter than the
retired adapter**, which allowed a one-transaction retune of tier weights. Check that a
queued change cannot bite before execution and that executing never reaches a live
activation retroactively.

### 4.5a THE CUSTODIAN REGISTRY — NEW AUTHORIZATION LOGIC, START HERE

Inside `ChipActivation`, and pulled out into its own section because it is not really part of
activation: **it is an authorization mechanism, and it is the only one in this repo that lets
an external contract decide who owns something.**

The rule: when `IERC721.ownerOf` returns an address on the multisig-managed allowlist, that
address is asked `beneficiaryOf(collection, tokenId)` and **its answer replaces the owner.**
Everything downstream is keyed to that answer — which Noun scores weight, whose address a
credit is booked to, and who may call `setSplit`.

**Why it exists.** Plain soft staking voids an activation whenever the NFT moves, which is
right for a sale and wrong for a deposit. From the collection's point of view the two are
identical, so only the vault can tell them apart, and telling them apart is what lets a Noun
locked as loan collateral keep earning for its borrower.

**The stated trust bound, which is the thing to attack.** A custodian is trusted, but *only
over the tokens it actually holds*, because `ChipActivation` only ever asks the address that
`ownerOf` just returned. So the worst a hostile custodian can do is misdirect rewards for a
Noun already in its custody — which it could achieve anyway by simply refusing to give the
Noun back. Try to break that bound:

- Can a registered custodian name a beneficiary for a token it does **not** hold — in this
  collection, or in another one, or for a token that does not exist?
- Can it get its answer used for a token held by a *different* custodian?
- `test_aLyingCustodianOnlyAffectsTokensItHolds` and
  `test_aLyingCustodianOverItsOwnCustodyIsBoundedToThatToken` are the two tests that claim
  this. Check they claim what they appear to.

**Failure modes to push on:**

- Both foreign calls are gas-capped staticcalls, and any failure — revert, short return
  data, gas bomb — returns zero, which reads as "nobody" and resets the activation. Confirm
  a hostile custodian cannot wedge `contributeWeights` for a whole round, which is the shape
  that would take everyone else down with it.
- A custodian returning `address(0)` must read as no owner, never as the custodian itself.
- **De-registering is immediate and total**: every activation that custodian was carrying
  goes inactive in the same transaction. That is deliberate — it is the emergency stop — but
  confirm it cannot be triggered halfway, and that it cannot touch a credit already booked.
- Registering mid-activation *revives* a deposit that had reset. Confirm that is safe: the
  record still names the original activator, and it only comes back if that address is the
  beneficiary.

**Governance surface.** `setCustodian` is multisig-only and deliberately **not** timelocked
in either direction: revoking a custodian that has gone bad must not wait 48 hours, and the
same switch makes registering symmetric. Whether registering should be the slow direction is
a fair thing to argue with.

**The one consequence outside this contract.** `ChipRounds.setSplit` now authorises against
`IActivationSource.effectiveOwner` rather than `IERC721.ownerOf`, so a borrower keeps the
right to re-pick their stocks while collateralised. That puts `setSplit` authorisation behind
the multisig-set activation source. The argument that this is not a new power: the same
contract already decides whose weight counts in every round, which is strictly more. Judge
that argument.

### 4.5b LENDING — `loans/NounLoans.sol` (363 LOC), NEW AND HOLDS ASSETS

Borrow $CHIP against a Noun at a flat fee for a fixed term. It holds collateral NFTs and the
lending pool, so it holds real value; but its accounting is deliberately simple — a flat fee
taken up front, principal-only repayment, no accrual, no rate, no compounding, and exactly
one depositor (the multisig) so there is no solvency-between-lenders problem to get wrong.

Attack, in order:

- **The pool accounting.** `poolBalance` is the only number that matters. Principal out on
  loan is deducted at `borrow` and added back at `repay`. Can you make `poolBalance` exceed
  `chip.balanceOf(this)`? Can `withdrawPool` reach money that is out on loan? Can a
  liquidation bounty overdraw it? (It is capped at the balance rather than reverting, on
  purpose: collateral must be recoverable from an empty pool.)
- **The collateral exits.** A borrower's Noun leaves in exactly two ways — `repay` to the
  borrower, `liquidate` to the treasury. `recoverNFT` reverts on live collateral. **Look for
  a third path.**
- **`beneficiaryOf` truthfulness.** It must name the borrower while the loan is open and
  nobody once it is not, and must never speak for a token it is not holding under an open
  loan. A bug here misdirects rewards through ChipActivation, which is the one way this
  contract can affect the money path at all.
- **Reentrancy across the seam.** `borrow` takes the NFT before paying out; `repay` measures
  the $CHIP delta before returning the NFT. Both are `nonReentrant`. Attack the ERC-721
  callbacks and a hostile $CHIP.
- **The repay deadline.** Repayment is refused after maturity plus the 7-day grace, even if
  nobody has liquidated yet. That is a deliberate, and harsh, product rule — see OPEN_ITEMS.
- **The chip gate.** `borrow` requires the collateral to be actively chipped **to the
  borrower** at that moment, read from the activation source rather than from a flag of this
  contract's own — so there is only one notion of "chipped" and it cannot drift. Check the
  gate cannot be satisfied by a lapsed or someone else's activation. Note it is checked at
  borrow time and **never re-checked**: a borrower who loses their chip mid-loan keeps their
  loan and simply stops earning. Re-checking would make a lapsed chip a liquidation trigger
  and hand that trigger to whoever controls the vault, which is a far worse property than the
  one it would buy.

**Not enforceable on chain:** `maxPrincipal` must sit below Anvil parity so borrowing is
never a better exit than selling. The Anvil is not a contract on Base, so there is nothing to
read and this is an operational parameter, not a `require`. Flag it if you disagree with that
call, but there is no on-chain fix available.

### 4.6 Conversions — `base/ConversionRoutes.sol` (163 LOC)
The most security-sensitive shared code. Attack: decimal handling across (token, feed,
quote) triples; a feed with unusual decimals; the dust floor where `minOut` rounds to zero
(refused — verify there is no path around it); whether the per-call cap can be bypassed;
whether a malicious router can be registered to drain (it is multisig-set, but confirm the
blast radius).

### 4.7 Everything else
`FeeSplitter` three-way split and share-bound arithmetic; `StockRegistry` pool verification
against the real factory; `ClaimRouter` leg isolation and the sweep.

**`ClaimRouter` lost its second leg.** It used to claim against a Clutch vault as well. That
call was permissioned to the owner of record and would have reverted for a router on every
invocation (CLUTCH_RECON section 4), and there is no second reward stream now in any case —
activation is a burned cost, not a position that accrues. The router is a batch of
`ChipClaims.claimFor` calls and nothing else: no vault registry, no `sweepTokens` argument,
4,213 bytes down to 3,149. The properties that were never about Clutch all still hold and
are still tested — leg independence, per-leg gas bounding, routed-equals-direct, a failed leg
leaving the credit claimable, and no bypass of the claim window.

### 4.8 The Furnace — separately scopeable, and scope it that way

`src/furnace/Furnace.sol` shares no storage, no inheritance and no call path with
ChipRounds, ChipClaims, Pot or POLTreasury, and nothing in that set references it. **A bug
here loses forge stock; it cannot lose a reward.** It can be audited on its own, or dropped
from scope entirely, without weakening any statement made about the rest of this document.

What it does: burn `lilCost` Lil Based Nouns and `chipCost` $CHIP, receive one Based Noun or
DarkNOUN from stock the multisig has deposited.

Four properties to attack, each of which is structural rather than policy:

- **"Burned means burned" is structural.** Inputs are transferred straight to `0xdead`
  *inside* `forge`, so the contract holds neither a Lil nor a $CHIP between transactions.
  There is no admin function that could reach them because there is nothing to reach.
  Confirm that: is there any ordering where an input lands on the contract and stays?
- **FIFO, and the admin cannot jump the queue.** `forge` takes `_stock[c][forgedFrom[c]]`;
  `withdrawStock` pops from the **tail**. The claim is that the multisig can shrink the pool
  but can never take the specific token the next forger is about to get. Check the boundary
  where `count == available`, and whether `rescueStrayNFT` can reach live stock (it scans
  the unforged range and reverts — verify the range bounds).
- **Reentrancy on the output hand-off.** The output NFT leaves **last**, after `forgedFrom`
  has already advanced, and `forge` is `nonReentrant`. Attack the `onERC721Received` hook on
  a contract recipient: can it re-enter and claim stock this call already consumed?
- **The $CHIP burn is measured, not assumed.** `forge` reads `balanceOf(0xdead)` either side
  of the transfer and reverts on a shortfall, so a fee-on-transfer or lying $CHIP cannot buy
  a forge under-paid. Failing closed is deliberate: the forge reverts and nothing is
  consumed. Check the case where $CHIP's `balanceOf(0xdead)` is itself manipulable.

Also worth a look: duplicate detection in `lilIds` is an O(n²) inner loop bounded by
`MAX_LIL_COST = 100`; recipe cost changes are behind a 48h timelock with events at queue and
execute, while **pausing is deliberately immediate** because halting a recipe is a safety
action; and an NFT that arrives via `safeTransferFrom` is accepted but never registered as
stock, so it cannot silently become someone's output.

28 tests in `test/furnace/Furnace.t.sol`. Runtime size 7,711 bytes, and it is now covered by
the `test/CodeSize.t.sol` guard alongside the money-path contracts.

### 4.8b THE ANVIL — `anvil/Anvil.sol` (291 LOC), HOLDS NOUNS AND TAKES ETH

The protocol's shop: a FIFO shelf of Nouns at a fixed ETH price. Like the Furnace it is
outside the reward path — it cannot touch a credit, a round or the ledger — but unlike the
Furnace it **takes money from the public**, so scope it accordingly.

**Attack the payment tail first.** `_settle` is the only place ETH moves:

- 100% of the price is forwarded to the FeeSplitter **in the same transaction**, and the
  contract has **no ETH withdraw path at all**. Confirm there is genuinely none — that is
  what makes "the Anvil holds no ETH" a structural claim rather than a policy.
- A failed forward **reverts the sale** rather than holding the money. Deliberate: with no
  withdraw path, a sale that could not forward would strand the proceeds permanently.
- Overpayment is refunded, and that refund is the **only** callback in the contract. The
  Noun is handed over with `transferFrom`, not `safeTransferFrom`, so there is no ERC-721
  receiver hook to re-enter through. Both paths are tested; check the ordering holds.

**Then the queue, which is the product.** `buyNext` is FIFO and `nextOnShelf` makes the head
readable before anyone commits — the claim is that this is a queue, not a lottery. `snipe`
takes a specific token at +25% and **unlists it in place**, so the cursor skips it and nobody
is promoted past anybody. Attack: can a snipe reorder the queue, can a token be bought twice
by the two routes racing, can the cursor be made to skip a still-listed token or to revisit a
sold one? The cursor is persisted as it advances, which is what keeps `buyNext` from becoming
quadratic on a heavily-sniped shelf — check it can never move backwards.

**`unshelve` takes from the TAIL**, same rule as the Furnace: the multisig can shrink the
shelf but never take the Noun the next buyer is about to receive. It also has to cope with
tail entries that were already sniped; confirm the skipping cannot lose a listed token.

**The sell side does not exist and cannot be switched on.** `sellEnabled` is a `constant`
`false` with no setter, and `sellToAnvil` always reverts `SellNotOpen`. That is the honest
shape for an unbuilt solvency commitment: a flag the site can read, and no lever that could
expose an unimplemented function. Verify there is no path to enabling it.

**A purchased Noun arrives un-chipped**, structurally rather than by policy — the Anvil is
not a registered custodian, so shelving voids any prior activation. Nothing here calls the
activation vault at all, which is the property to confirm.

### 4.9 THE B20 SURFACE — where one claim is weaker than the rest

`test/b20/` is the hardening pass for the one dependency nothing local can fully cover. Read
it for what it does NOT prove as much as for what it does.

**`B20_DOCS.md` is now in this repo** — Base's own tokenized-stock documentation, filed
verbatim next to the reconciliation it sources. Read it before this section; it settles three
things that used to be inference.

**The multiplier (`MultiplierIndifference.t.sol`).** A B20 token is not permanently one
share. The load-bearing question is what the Chainlink feed reports, and the docs answer it:

> `Token Price = Underlying Equity Market Price × Multiplier` … the feed publishes underlying
> price × multiplier.

**The feed reports the price of one TOKEN, not one share.** So `StockRegistry.priceUsd` uses
the answer directly, with no multiplier fetch and no adjustment — and that is correct.
Worth pausing on, because the correct code and the broken code are identical: had the feed
reported the *share* price, every purchase and every USD figure would have been silently
wrong by the multiplier the moment any stock split, with nothing to notice it. The first half
of that test file pins the behaviour that follows — move the feed, and what a holder is owed
does not change, because they are owed tokens.

A corollary worth knowing: because the feed is total-return there is **no price discontinuity
at a corporate action**; underlying and multiplier move opposite ways and cancel.

The second half rebases balances underneath the ledger. **The docs say that does not happen**
— corporate actions are reflected *"without changing their balance of the B20 token"*. Upward
and mid-round rebases are absorbed cleanly. **A downward one is not**, and that test is kept
deliberately:

> `test_hedge_aDOWNWARDrebaseCanUnderfundTheLedger` marks the boundary between what this
> suite guarantees and what it merely expects. If the ledger's balance ever drops below
> `totalOwed` — by a rebase or by anything else — the last claimant in that round cannot be
> paid. The failure is contained: the claim reverts rather than paying out someone else's
> tokens, the credit stays on the books, `hasClaimed` is not set, other stocks are untouched.
> But a holder is genuinely unable to be made whole. **This is the only place in the suite
> where the answer is "it degrades safely" rather than "it cannot happen."** The premise is
> now documented away rather than open, so the item is an unproven negative rather than a
> live risk — acknowledged and left standing at OPEN_ITEMS item 13.

**The feed freezes during corporate actions**, and the docs are blunt about the consequence:
*"never settle or liquidate against a frozen feed."* That is exactly what
`ChipRounds.maxFeedAge` does — skip and carry. It was built from first principles before this
document was to hand, and it lands where the issuer says it should.

**Identity (`IdentifyByAddress.t.sol`).** A build-failing scan of `src/` for `symbol()` and
`name()`. Base's own guidance, now in the repo: *"Tokens should be identified by address
rather than ticker or symbol. Metadata is mutable onchain and should be indexed
accordingly."* Mutable is the word that matters — `updateName` and `updateSymbol` exist, so a
symbol is not even stable, let alone unique. Add that an incidental `symbol()` on a
precompile is a gas bomb as well as a spoofing surface. The rule is enforced as a test rather
than a review note because it is about what must be *absent*, which is what review misses.
Confirm the scan cannot be trivially evaded, and that nothing resolves a stock by anything
but its address.

**Frozen feeds (`FrozenFeed.t.sol`).** See OPEN_ITEMS item 6 for the full reasoning. A dead
feed skips and carries; `MIN_FEED_AGE` is a 72-hour floor that exists purely to stop the
setting being tightened into skipping every Monday, since these feeds are legitimately ~65
hours old after any weekend. The residual is stated there and is a genuine trade, not a fix.

**Table reconciliation (`test/fork/ChainlinkFeeds.t.sol`).** Feed descriptions are asserted
rather than logged, so a transposed row fails the build — previously it could not, because
every address in the table is a real live feed and only the *mapping* was wrong. All thirteen
tokens are pinned to the `0xef` precompile shape, and calling one from a fork is asserted to
fail, so nobody "fixes" the registry into probing `decimals()` in simulation.

**And the tables were wrong in the other direction too.** A-13 listed nine feeds and A-18
recorded the remaining four tickers as having "none published" — inferred from A-13's own
incompleteness rather than checked. `B20_DOCS.md` lists thirteen, and all four verify live.
Corrected, and the fork test now asserts all thirteen. The lesson generalises: the
description assertion catches a row that is *wrong*, nothing was catching a table that was
*short*.

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
| 0 | ~~The Clutch seam~~ | **CLOSED — dependency removed, see §7** |
| 1 | POL income stranded as AERO | **CLOSED** — per-token route table |
| 2 | Nothing routed USDC to POL | **CLOSED** — optional splitter leg + POL converter |
| 3 | Gauge address has no on-chain verification | Open, low risk |
| 4 | A round stuck in `Buying` has no escape hatch | Open, judged acceptable |
| 5 | B20-specific behaviour covered by mocks only | Open, narrowed by `test/b20/` — §4.9 |
| 6 | Equity feed staleness policy | **CLOSED** — skip-and-carry, `maxFeedAge`, 72h floor |
| 7 | Compound shares have no redemption path | Open, phase 2 |
| 10 | Keeper "kick job" | **CANCELLED** — the reset is lazy and atomic |
| 11 | `VerifyClutchV3` script | **CANCELLED** — nothing left to verify |
| 12 | NounLoans: no repay after grace | **Open — product decision** |
| 13 | `maxPrincipal` vs Anvil parity is operational | Open, not enforceable on chain |
| 14 | A downward B20 rebase could underfund the ledger | Open — §4.9, a limit not a guarantee |

Also unresolved: **C-10**, the one place failure isolation does not hold — if USDC itself
policy-blocked `ChipRounds`, a round in `Buying` could not settle or finalize. Every stock
path degrades gracefully; the quote token has no fallback.

## 6b. Deploy config now lists THREE collections

Lil Based Nouns (`0xe3c5Ef27B80481518a2363406e354a9361415556`, 4,420 supply) joins Based and
Dark at a 0.5x collection base. **No contract changed.** Everything collection-shaped is a
mapping keyed by address, so a collection is two multisig actions — `setCollectionBaseBps` on
`ChipRounds` and the timelocked `queueCosts`/`executeCosts` on `ChipActivation`. It fails
closed on both sides: no base means zero weight, and no cost table means the collection
cannot be activated at all.

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

## 7. Clutch is gone — what used to be here, and why it matters to scoping

**This section used to be the reason the audit could not be fully scoped.** It said seven
assumptions about a Clutch Anvil soft-staking vault were unverifiable because no such vault
exists on Base, and asked you to treat `ClutchVaultAdapter` as an interface boundary with a
stated contract rather than as reviewed code.

**None of that applies any more. Chipworks runs its own activation vault.** The dependency is
removed, not deferred, and `ClutchVaultAdapter` is retired in place: it still compiles and
still has tests, it implements the same `IActivationSource`, and it **is not deployed**. If
you want to skip it, skip it; nothing on Base will point at it.

Three things settled it, all of them recorded in `CLUTCH_RECON.md` and `CLUTCH_LICENSES.md`:

1. **No Base deployment, and no reply.** Clutch ships on ApeChain (33139) and Robinhood
   (4663) only. All four known factory and router addresses are empty on Base. Deploying
   there was theirs to decide and they did not.
2. **BUSL-1.1.** The V3 generation — the one with non-custodial soft staking — is
   source-available, not open source. The MIT generation on ApeChain does not contain a
   soft-staking vault at all; it ships `NFTStakingVault`, which is custodial deposit. So
   "just fork the MIT version" does not reach the thing we wanted.
3. **Their custody semantics cannot express ours.** This is the one that would have mattered
   even with a Base deployment and a licence. Clutch voids an activation when the NFT moves,
   full stop. Chipworks needs a Noun locked as loan collateral to keep earning for its
   borrower, and that requires the vault to distinguish a deposit from a sale. It cannot be
   bolted on from outside: the vault is the thing that decides.

**What this changes for an audit, concretely:**

| Before | Now |
|---|---|
| 7 unverifiable assumptions (A-1 … A-9) | **Zero.** All were about a third party we no longer call. |
| The riskiest contract was 70 lines and swappable | The riskiest contract is 264 lines and core: §4.5 |
| `ClaimRouter` had a leg that could never work | That leg is deleted: §4.7 |
| A keeper "kick job" was planned | **Cancelled.** The reset is lazy and atomic; nothing to run. |
| Scope excluded the vault | **Scope includes the vault.** It is ours now. |

The one thing that got *harder*: there is more of our own code to review, and the part that
grew is the part that decides who earns. That is the correct trade — an unverifiable
dependency became reviewable code — but it should be reflected in the hours.

**Two mitigations that were built for Clutch survived, and are still load-bearing:**

- The `IActivationSource` seam itself. `ChipRounds` reads three values from one interface and
  does not know which implementation answers. `test/activation/ChipActivationParity.t.sol`
  proves that by running the same round assertions against the new vault with only fixture
  wiring changed. If Clutch ever ships on Base with better economics, it is one
  `setActivationSource` call.
- The independent live-owner check. It was written to defend against Clutch's lazy voiding
  (five of fourteen sampled Robinhood activations are earning for sellers right now). It is
  now not a defence but the mechanism itself: the comparison IS the reset.

## 8. Deployment posture

`DEPLOY.md` has the full order, constructor arguments and verified addresses. Two notes that
affect review:

- **`forge script` simulation cannot touch B20 tokens** (precompiles). Deploys that do must
  use `--skip-simulation` or run from the multisig UI.
- **Every tunable is a constructor argument or a multisig setter.** There are no hardcoded
  percentages, thresholds, windows or addresses in business logic. The ceilings listed in §5
  are the only fixed numbers, and they exist to bound governance.
- **Two of those bounds are floors rather than ceilings**, which is unusual enough to call
  out: `ChipRounds.MIN_FEED_AGE` (72h) and the non-decreasing requirements on
  `ChipActivation`'s cost and tier tables. They bound governance in the *liveness* direction
  — stopping a setting that would silently switch something off — rather than the safety one.
- **$CHIP denominations are the one thing not yet decided.** Activation costs, the Furnace
  recipes, the split-change fee and the loan caps are all deploy-time or timelocked
  parameters awaiting the token launch. DEPLOY.md marks every one of them as a placeholder.

Recommended: first mainnet round funded small. Confidence in B20-specific behaviour is
structurally lower than everything else here, and no amount of local testing changes that.
