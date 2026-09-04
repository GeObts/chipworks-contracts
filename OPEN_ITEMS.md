# OPEN_ITEMS.md

What the full-system fork test surfaced, plus everything still unresolved. Ordered by how
much it matters. Item 0 used to be the **Clutch seam**, the one blocker on the whole repo;
it is now closed, and the section records how, because the reasoning shaped a lot of what
came after.

Updated 2026-09-02 after Clutch was dropped and replaced by our own activation vault. Generated from `test/fork/FullSystem.t.sol`, which runs the whole machine —
fees in → convert → round → claims → expiry sweep → POL mint → POL income back out — on a
Base mainnet fork.

---

## 0. THE CLUTCH SEAM — **CLOSED. The dependency is gone.**

**Was:** the one thing the full-system test could not verify. Everything vault-facing ran
against a mock, seven assumptions (A-1 … A-9) were unverifiable, and the whole repo was
frozen pending answers from Clutch that never came.

**Now:** Chipworks runs its own activation vault, `src/activation/ChipActivation.sol`, behind
the same `IActivationSource` interface `ChipRounds` already read. There is no third party in
the weight path. `ClutchVaultAdapter` is retired in place — it still compiles and still has
tests, and it is not deployed.

Three things settled it, in increasing order of how decisive they were:

1. **No Base deployment, and no reply.** Four known Clutch factory/router addresses, all
   empty on Base (`CLUTCH_RECON.md` §1).
2. **BUSL-1.1.** The V3 generation that has non-custodial soft staking is source-available,
   not open source. The MIT generation on ApeChain has no soft-staking vault at all — it
   ships `NFTStakingVault`, custodial deposit (`CLUTCH_LICENSES.md`).
3. **Their custody semantics cannot express ours**, and this one would have decided it even
   with a Base deployment and a licence. Clutch voids an activation when the NFT moves, full
   stop. Chipworks needs a Noun locked as loan collateral to keep earning **for the
   borrower**, which means the vault has to tell a deposit from a sale. Nothing outside the
   vault can add that.

**What the replacement buys, beyond removing a dependency:**

| | Clutch | ChipActivation |
|---|---|---|
| Voiding | lazy; needs `kick`. 5 of 14 sampled live activations on Robinhood are earning for sellers **right now** | lazy **and atomic** — recomputed on every read, no keeper, no interval of wrongness |
| Custody | a deposit is indistinguishable from a sale | allowlisted custodians; collateral keeps earning for the borrower |
| Cost | 5% skimmed off every activation | **100% burns** to `0xdead` |
| Governance | tier weights retunable in one transaction | costs **and** weights behind a 48h timelock |
| Claiming | `claim` permissioned to the owner of record, so a router reverts | nothing to claim; `ChipClaims.claimFor` is permissionless |

**The seam survived and still earns its keep.** `ChipRounds` reads three values from one
interface and does not know which implementation answers.
`test/activation/ChipActivationParity.t.sol` proves it: the same round assertions, the new
vault, only fixture wiring changed. If Clutch ships on Base with better economics it is one
`setActivationSource` call.

### 0a. CANCELLED: the keeper "kick job"

Was planned because Clutch's voiding is lazy, so somebody had to call `kick` on sold Nouns or
sellers would keep earning. **There is nothing to kick.** `ChipActivation` stores no `active`
flag; `activation()` recomputes the effective owner and compares it to the owner at
activation, so a sold Noun scores zero in the same block it is sold, for everybody, with
nothing running. A keeper job would have no state to advance.

This also removes a liveness dependency from the design: there is now no scheduled task
whose failure would misallocate rewards.

### 0b. CANCELLED: the `VerifyClutchV3` script

Was to re-verify A-8 against `SoftStakingVaultV3`'s real logic, because `CLUTCH_LICENSES.md`
§4b found V3's natspec claiming atomic voiding while the recon observed five stale records
live. **Moot.** We do not call Clutch, the question only affected a vault we no longer use,
and the BUSL licence made reading that code for anything beyond comprehension awkward anyway.

The observed stale records stand as evidence for why our own reset is computed rather than
stored — which is the only lasting thing that question was ever going to tell us.

## 1. POL income stranded as AERO — **CLOSED**

Was: the loop closed on paper but `convert()` only knew ETH and WETH, so recycled AERO
reached the Pot and no round could spend a cent of it.

Now: conversion is a **per-token route table** — Chainlink feed, router, fee tier, slippage
bound, per-call cap and staleness limit, one row per asset. `convert(token)` is
permissionless for every registered token. AERO's route is registered against the live
AERO/USD feed (`0x4EC5970fC728C5f65ba413992CD5fF6FD70fcfF0`) and the Uniswap AERO/USDC pool.

Proven in `test/fork/FullSystem.t.sol`: 1,000 AERO of POL income → splitter → 700 to the Pot
→ converted → **funds the next round**. The test previously ended with 800 stranded AERO and
1 wei of spendable budget.

Residual note: the AERO/USDC pool on Uniswap holds ~$66k, thinner than the WETH pools.
The per-call cap and the Chainlink bound are what keep that safe; size the cap accordingly.

## 2. Nothing routed USDC to POL — **CLOSED**

Was: POL received the stock holdback but had no quote token to pair it with, except by
accident when an unclaimed credit expired into it.

Now, two mechanisms:
- **`FeeSplitter.polShareBps`** — an optional third leg, default 0, hard-capped at 2000 and
  requiring a treasury to be set before a non-zero share can be configured. Same flush
  semantics, same permissionless calls, dust still to the Pot.
- **POLTreasury shares the Pot's converter.** The splitter leg arrives in whatever asset was
  flowing (ETH from the locker, AERO from gauges), so POL realises it into the quote token
  itself using the same Chainlink-bounded, capped route table.

Without the second half the leg would have delivered ETH that POL cannot pair — the same
class of bug as item 1. Proven in the full-system fork test: POL self-funded $732 of pairable
USDC from its own ETH slice, with no expired credit and no manual transfer.

The conversion machinery lives in `src/base/ConversionRoutes.sol` and there is exactly one
copy of it, shared by `Pot` and `POLTreasury`. Duplicating a Chainlink-bounded swap would
have doubled the audit surface and guaranteed drift.

## 3. AERO accrual is not exercised, only its routing

The test injects AERO rather than earning it, because emissions accrue over epochs. Our
routing of it is proven; Aerodrome's accrual is not our code. What is genuinely unverified
is the **gauge address per pool** — there is no registry for it, the manager passes it per
call. Low risk, but a wrong gauge address is a manager mistake with no on-chain guard.
Consider verifying the gauge against the Aerodrome voter contract the way StockRegistry
verifies pools against the factory.

## 4. A round stuck in `Buying` has no escape hatch

`cancelRound` covers a round opened and never closed. But a round that closed accumulation
and then has a stock nobody settles stays in `Buying` forever, and `finalizeRound` requires
every stock settled — so claims for that round never open.

In practice `settleStock` is permissionless and cannot revert for a frozen stock (it skips),
so anyone can push it along. The one genuine wedge is C-10: if USDC itself policy-blocked
ChipRewards, `settleStock` could not approve or transfer and the round would hang.

**Judged acceptable** (USDC blocking a public contract would be an ecosystem-wide event) but
it is the single place where "isolated failure" does not hold, and it is worth a `cancelBuying`
that returns the remaining budget and marks the round finalized with whatever was acquired.

## 5. B20 behaviour is covered by mocks, not by the real token

The full-system test substitutes WETH for a B20 stock, because B20 tokens are native
precompiles a forked EVM cannot execute (A-15). That gives a real swap, real feed, real
pool — but it does not exercise B20's own policy blocklist, pause, or dividend multiplier.

Those are covered by `ChipRewardsHostile`, `FeeSplitterHostile` and `POLTreasury` hostile
suites using `BlacklistToken` / `PausableToken` / `LyingToken`, which model documented B20
behaviour. **Confidence in anything B20-specific is therefore lower than everything else in
this repo**, and no amount of local testing fixes that. First mainnet round should be small.

**Narrowed by the B20 hardening pass (`test/b20/`), which closed three of the gaps:**

- **The multiplier.** A B20 token is not permanently one share.
  `MultiplierIndifference.t.sol` tests the documented mechanism — the multiplier lives in
  the valuation, so a corporate action moves the FEED — and then hedges the mechanism we
  cannot rule out, where balances rebase instead. One of those hedge tests documents a real
  limit rather than a guarantee: a DOWNWARD rebase leaves the ledger short and the last
  claimant cannot be paid. We do not believe B20 does this, and the failure is contained
  (the claim reverts, the credit survives, other stocks are untouched), but it is the one
  place in the suite where the answer is "it degrades safely" rather than "it cannot happen".
- **Identity.** `IdentifyByAddress.t.sol` scans `src/` and fails the build if any contract
  calls `symbol()` or `name()`. Nothing makes a B20 symbol unique, and an incidental
  `symbol()` on a precompile is a gas bomb as well as a spoofing surface.
- **The tables.** All thirteen tokens and all nine feeds now reconcile against a live node,
  with feed descriptions asserted rather than logged, so a transposed row fails the build.

## 6. Chainlink equity feeds go stale outside market hours — **RESOLVED**

A-14. The feeds hold the last close and have no heartbeat when equity markets are closed.
**The recommendation this item used to carry — "say 36h" — was wrong, and the reason is
below.**

**Decision taken: skip and carry, off by default, floored at 72 hours.**
`ChipRounds.maxFeedAge` skips any stock whose feed has not updated within the window and
carries its slice to the next round. Zero disables the check. `setMaxFeedAge` is multisig
only and rejects any non-zero value below `MIN_FEED_AGE = 72 hours`.

**Why a skip and not a revert.** A revert wedges the round for every other stock. A skip
costs nobody anything — the slice returns to the Pot and buys next time — so the check can
be conservative without a downside. Proven in `test/b20/FrozenFeed.t.sol`: a dead NVDA feed
skips, GOOGL still buys, the budget carries to the cent, and finalize still works.

**THE OLD RECOMMENDATION HERE WAS "say 36h" AND IT WOULD HAVE BROKEN EVERY MONDAY.**
Worth recording, because the number looks reasonable and is not:

| | Feed age at the next round |
|---|---|
| Ordinary weekend, Friday 16:00 close to Monday 09:30 open | **~65 h** |
| Three-day weekend | **~89 h** |
| Thanksgiving (Wed close, Mon open) | **~113 h** |

At 36 hours every Monday round would have skipped every equity stock, silently, because a
skip is the safe quiet path. The protocol would have bought nothing one day in five and the
only symptom would have been a carried budget nobody was looking at.

Hence the 72-hour floor: not a safety bound but a **liveness** one, stopping a well-meaning
"tighten it up" from switching the protocol off two days a week. **Recommended setting: 120
hours**, which clears a Thanksgiving weekend with margin and still catches a feed that has
been dead a working week.

The residual: at 120 hours a feed that dies on Friday is bought against until Wednesday. The
Chainlink bound is enforced against that stale mark, so the exposure is real but bounded by
how far the market moves. Tightening it trades that against skipped Mondays; there is no
setting that avoids both, which is why it is configurable and why the floor is where it is.

## 8. NEW: the claim window shortens the effective time to claim

Credits expire 30 days after a round finalizes, but can only be taken during a 48-hour
window every 7 days. So a holder does not get 30 days of claiming — they get **four 48-hour
windows**, roughly 8 days of actual opportunity.

The contract guarantees at least three windows for any accepted configuration
(`creditExpiry >= 3 * windowLength`, enforced on every setter, frozen per round at finalize,
asserted by fuzz and by a stateful invariant that retunes the schedule mid-run). But three or
four chances is a much narrower promise than "30 days", and the gap is a UX problem:

- The site must show the next window prominently and a per-round countdown to expiry.
- `claim` reverts with `ClaimsClosed(now, nextOpenAt)` so the UI can render the exact return
  time. `ClaimRouter.claimWindowStatus()` exposes the same for greying out the button.
- A holder who misses every window forfeits outright: expiry writes no ledger entry, so
  there is no consolation POL share.

**Worth considering before launch:** `claimFor` is permissionless and always pays the owner,
so a keeper could claim on behalf of everyone during the last window of each round at its own
gas cost. That converts a forfeit risk into an operational cost. Not built.

**Also unresolved:** the three-window rule bounds the COUNT of windows, not their spacing.
With 7-day windows and a 30-day expiry the last window can land only hours before expiry.

## 9. RESOLVED: ChipRewards was undeployable

`ChipRewards` reached 27,551 bytes of runtime code against EIP-170's 24,576 limit. It could
not have been deployed to Base. **362 tests passed against it**, because Foundry exempts
test-deployed contracts from the size limit; it was found only when the keeper tried a real
`anvil` deployment.

Fixed structurally rather than by shaving bytes. `ChipRounds` (the engine, 20,230 bytes) and
`ChipClaims` (the ledger, 12,879 bytes) are two plain contracts wired at deploy, split so the
half holding holders' money is the smaller and simpler one.

A permanent guard now fails the build if any deployable contract exceeds 24,000 bytes:
`test/CodeSize.t.sol`. The 576-byte gap below the real limit is deliberate headroom.

The split introduced one new failure mode and it is fixed: handing stock to the ledger is a
second place a policy-blocked token can fail, and in the first cut it reverted the whole
round. Now measured and tolerated, with the shortfall stranded and reported.

## 7. Smaller things

- **Deploy simulation.** Any `forge script` touching a B20 token fails simulation; use
  `--skip-simulation` or execute from the multisig UI. Already in DEPLOY.md.
- **Conversion fee tier.** Defaulted to Uniswap 0.05% ($3.14M USDC). The 0.3% tier holds
  more raw TVL ($64.2M) but costs 25bps more. One multisig call to change; a wrong choice
  fails safe because the Chainlink bound rejects rather than executes badly.
- **`recoverExcess` on a live round.** Cannot touch committed budget or booked credits, but
  the multisig can still take genuinely stray tokens. Documented in C-9.
- **Compound ledger is mirrored.** ChipRewards' `polCreditUsd` is authoritative; POLTreasury's
  `compoundShares` is a best-effort mirror that can never block a claim. If they ever diverge,
  trust ChipRewards.
- **No redemption path for compound shares.** The ledger records who compounded; the spec
  does not define how they get value back out. Phase 2 question, worth answering before you
  market auto-compound. Note expiry does NOT feed this ledger — an expired credit is a
  forfeit, not a compound, and the two are deliberately distinguishable.
- **Sweep gas scales with holders.** The expiry sweep walks a per-(round, stock) holder list
  to emit per-holder amounts. It is batched with a cursor and idempotent, but a popular round
  needs several calls. The token movement alone would have been O(1); the iteration exists
  only so the site can show who lost what.

---

## Verified, so no longer open

- Chainlink B20 equity feeds — all nine live on Base, addresses in ASSUMPTIONS A-13
- Slipstream position manager ABI — probed against deployed bytecode, real position minted
- Uniswap SwapRouter02, ETH/USD feed, WETH/USDC pools, USDC, AERO — all checked on fork
- B20 token addresses and decimals — all nine verified, 8 decimals
- Contracts may hold B20 — confirmed by Base docs, secondary trading is permissionless
- AERO/USD feed and AERO/USDC pool — verified on fork, route registered

---

## 10. RESOLVED: NounLoans refused repayment after the grace period

**Closed by external review batch 5 (TRIAGE SEC-LN-003), in `launch-candidate-8`.**

Was: `repay` reverted once past maturity plus grace, whether or not anyone had liquidated. A
borrower turning up on day 8 of a 7-day loan holding the full principal was refused, then kept
waiting — still owning the Noun — for a liquidator who might not come for days. The protocol
gained nothing from that window.

Now: **repayment ends when somebody actually liquidates, not at a deadline.** Past the
deadline a `lateFeeBps` surcharge applies (1% of principal at launch), so lateness has a price
and the term ladder still means something, but the borrower keeps the right to pay until the
collateral is genuinely seized. A late borrower races a liquidator.

The site guidance from the original item stands and is now more useful rather than less: show
the deadline, not just maturity, and warn ahead of it. Missing it is no longer terminal, but it
does start a race and it does cost 1%.

## 11. NEW: `maxPrincipal` vs Anvil parity is operational, not enforced

The invariant is that a loan must never pay more than selling would, or defaulting becomes
the rational move and the pool systematically buys Nouns at above market.

**Updated 2026-09-03: the Anvil now exists**, so for the first time there is a concrete
number to measure against — `Anvil.queuePrice(collection)`. LAUNCH_CONFIG sets
`maxPrincipal` at **~60% of the Anvil queue price**.

It still **cannot** be a `require`. The Anvil prices in ETH and the loan cap is denominated
in $CHIP, so enforcing the relationship on chain would mean trusting a $CHIP/ETH price inside
the borrow path — importing an oracle dependency, and a manipulable one, to defend against a
governance mistake. That is the wrong trade. It stays a number the multisig sets and must
re-check whenever **either** side moves. `setMaxPrincipal` is deliberately un-timelocked in
both directions so it can be cut to zero the moment a floor moves.

**External review batch 5 (SEC-LN-001) reached the same conclusion**: an on-chain NFT floor
oracle is more manipulable than the risk it solves. Accepted with process.

**The short-term ladder helped more than expected.** An underwater position on a 7-day term is
resolved within 10.5 days of being taken, against 37 on the old shortest term — the maximum
time the protocol can be exposed to a stale `maxPrincipal` fell by roughly two thirds as a side
effect of the term rework. Still worth a keeper alert comparing outstanding principal per
collection against the observed floor; that remains unbuilt.

**Worth building before volume:** an off-chain monitor that compares outstanding principal
per collection against the observed floor and alerts when the ratio drifts. Not built.

## 12. NEW: the lending pool has one depositor, on purpose

V1 has no public lender side: `depositPool` and `withdrawPool` are multisig only. That is
what keeps `NounLoans` free of the hardest problem in lending — solvency between depositors —
because there is exactly one and it is the protocol.

It also means the protocol carries 100% of default risk, and that `withdrawPool` can drain
the pool below what pending liquidation bounties would cost. The second is handled (the
bounty is capped at the balance rather than reverting, so collateral is always recoverable);
the first is a business decision, not a bug.

**Phase 2 question:** if a public lender side is ever added, the fixed-fee model has to
become a yield model and the exclusion-based rescue has to become share accounting. Do not
retrofit that onto this contract.

---

## 13. ACKNOWLEDGED: the claim path degrades safely rather than provably

**Signed off 2026-09-03: stands as designed.** Recorded here so the decision is on the record
rather than in a chat log.

The property: if a stock token's balance were ever to shrink underneath `ChipClaims` — the
downward-rebase case in `test/b20/MultiplierIndifference.t.sol` — the last claimant in that
round cannot be paid. The claim reverts rather than paying out somebody else's tokens, the
credit stays on the books, `hasClaimed` is not set, and every other stock in the same ledger
is untouched. But a holder is genuinely unable to be made whole, and no code in this repo can
conjure the missing tokens back.

**This was accepted as a residual, and then the premise was largely removed.** `B20_DOCS.md`,
now filed in this repo, says corporate actions are reflected *"without changing their balance
of the B20 token"* — `balanceOf` returns raw units that a dividend or split does not move,
and `scaledBalanceOf` is the adjusted view. So a B20 stock should never rebase a holder's
balance at all, and the scenario that produces this residual should not arise.

**The item stays open anyway, downgraded from "unresolved risk" to "unproven negative",** for
three reasons:

1. **It is documentation, not verification.** B20 tokens are node-native precompiles with no
   readable implementation (A-15). We are trusting a sentence, and we have already been
   burned once this week by trusting a table for being complete.
2. **The failure mode is not unique to a rebase.** Any path that reduces the ledger's balance
   below `totalOwed` produces it — a policy block that somehow moved tokens out, an issuer
   action nobody has thought of, a bug in a future contract given ledger access. The tests
   describe the shape of that failure, not just its rebase cause.
3. **Keeping the tests costs nothing.** They pass today, they document the boundary between
   what is guaranteed and what is merely expected, and they are the tripwire if any of the
   above turns out to be wrong.

**What would close it:** confirmation from Coinbase or from observing a real corporate action
on chain that `balanceOf` is untouched. Until then this is the one place in the suite where
the honest answer is "it degrades safely" rather than "it cannot happen", and the audit brief
says so in those words at §4.9.

## 14. ACKNOWLEDGED: the `setCustodian` wire is a deploy-checklist item

**Signed off 2026-09-03: accepted as a checklist item, not a code change.**

`ChipActivation.setCustodian(nounLoans, true)` is the only wiring call in the deploy sequence
that does not fail closed. Forgetting it leaves a system that looks entirely healthy while
every borrower silently earns nothing from the moment they deposit.

**Not fixed in code, and that is a deliberate choice.** The alternatives were worse:
NounLoans cannot register itself, because a contract that could add itself to the custodian
allowlist would defeat the point of the allowlist. ChipActivation cannot require a custodian
at deploy, because it is deployed first and must work with none. A constructor cross-check
would just move the same forgettable call earlier.

So it is handled where it belongs — in the runbook. DEPLOY.md carries it as a red can't-miss
block with the `isCustodian` read that proves it is set and the end-to-end fork check that
proves it works, and `test_theCustodianWireIsTheOneMistakeThatFailsSilently` asserts the
silent-failure shape so it stays documented rather than becoming folklore.

**Recovery is total and cheap**, which is what makes this acceptable: one call, retroactive,
no action needed from any borrower, nothing lost in the meantime beyond the rounds that
passed unnoticed.

---

## 15. NEW: the Anvil ships one-directional

`sellToAnvil` always reverts `SellNotOpen`, and `sellEnabled` is a `constant false` **with no
setter**. The buy side is live; the guaranteed exit is not built.

**Why it is not a flag someone can flip.** A switch that exposes an unimplemented function is
worse than no switch — it invites exactly one bad afternoon. Turning the sell side on means
deploying the version that implements it, and the interface stub exists so the ABI and the
site can be honest in the meantime rather than silently omitting a feature that has been
talked about.

**What has to be answered before it ships**, none of which is a contract question:

- **What backs the bid.** A guaranteed exit is a standing offer to buy, and something has to
  fund it. POL? A dedicated reserve? Round revenue?
- **What happens when the backing runs out.** A floor that disappears under load is worse
  than no floor, because people will have sized decisions against it.
- **Who is left holding it.** If the protocol buys back at a floor while the market is below
  it, the protocol is the counterparty to every seller at once.

Those are solvency questions, not Solidity ones, and they should be answered on paper before
anybody writes the function. Post-audit.

## 16. NEW: the chip gate makes lending a holder benefit, and forecloses one ordering

`NounLoans.borrow` now requires the collateral to be actively chipped **to the borrower**.

**What it buys:** the pool's collateral is drawn from holders who have already burned $CHIP
against that exact token, and "your collateral keeps earning" is not a claim made to somebody
whose Noun was never earning.

**What it costs:** *borrow first, chip later* is no longer possible through NounLoans. The
ordering is forced — chip, then borrow. The underlying capability is unchanged and still
tested (`ChipActivation.activate` resolves through a registered custodian, so a Noun already
in the vault can be chipped and upgraded), but a user cannot enter that state via a loan any
more. The site must lead with "chip it first", or the first thing a new borrower meets is a
revert.

**Deliberately checked at borrow time only, and never re-checked.** A borrower who lets their
chip lapse keeps their loan and simply stops earning. Re-checking would turn a lapsed chip
into a liquidation trigger — a wildly disproportionate penalty, and one that would hand the
trigger to whoever controls the activation vault. `test_theGateIsBorrowTimeOnlyAndCannotTriggerALiquidation`
pins that.

---

## 17. NEW: fixed 2% slippage is a cap-raise precondition

External review (TRIAGE EXT-R-L-1). `defaultMaxSlippageBps` is 2%, flat, per stock, and the
buy is a single `exactInputSingle` on a public mempool. At launch-cap budgets that is fine —
a $1,000 round split across four stocks is a ~$250 slice, and 2% of $250 is $5, below the gas
cost of sandwiching it.

**It does not stay fine as budgets grow.** The 2% is a standing, publicly-readable invitation:
anyone can compute the exact slice a round will spend, and 2% of a large round is worth
taking. This is systematic extraction, not a one-off exploit, and it scales linearly with the
cap while the defence does not move at all.

**Accepted with a plan, no code change now.** Fixing it properly means dynamic slippage
derived from measured pool depth, or private-order routing, or splitting a buy across blocks
— all of which are real work on the most security-sensitive path in the repo, and none of
which should land in the same tag as an external review's other fixes.

**Recorded as a precondition rather than a wish:** the round cap does not go above **$10,000**
until one of those is in place. That is a number to argue with, but it should be argued with
explicitly rather than drifted past — which is exactly what `REVIEW_PACKAGE.md` §6 asks
reviewers to flag, and this is the first cap that is doing security work it was not designed
for.

---

## 18. NEW: permissionless `convert` is MEV-exposed at scale

External review batch 2 (TRIAGE SEC-POT-002). `Pot.convert` is permissionless and executes
against whatever the pool says when it lands, bounded only by the Chainlink haircut. At
launch caps that is worth $10–20 a call and the gas makes it uneconomic to chase; uncapped it
is systematic slippage capture, and it scales with volume while the defence does not move.

**Half fixed now:** `convert(token, callerMinOut)` lets a keeper holding a real quote insist
on a tighter floor. The floor is `max(chainlinkFloor, callerMinOut)`, so a caller can only
tighten it. That converts "whoever calls it accepts whatever the pool gives" into "the keeper
can refuse a bad fill", without giving up permissionlessness.

**Half deferred, and it is the same problem as OPEN_ITEMS 17.** Dynamic slippage from measured
pool depth, or private routing, is the real answer — and it is needed in two places, the
conversion path here and the stock-buy path in `ChipRounds`. **They should be solved once, not
twice**, and that work is the shared precondition for lifting the round cap above $10,000.

Note the asymmetry worth watching: the keeper's tighter `minOut` only helps when a keeper is
the one calling. Anyone else can still call `convert()` with no floor beyond Chainlink's, so
this reduces the protocol's exposure when things are running normally and does nothing when
they are not. That is an argument for the real fix, not against the cheap one.

---

## 19. NEW: confirm whether $CHIP is fee-on-transfer

`LAUNCH_CONFIG` §2 sets `transfer_fee_recipient → FeeSplitter` on the Bankr launch. We read
that as *where accrued fees are sent*, not as a per-transfer tax on $CHIP itself, and
`quoteonlyfees = TRUE` — "fees accrue in WETH only" — points the same way.

**If that reading is wrong, $CHIP is a fee-on-transfer token and it flows through several
contracts that move it**: the FeeSplitter, ChipActivation's burn, the Furnace's burn, and the
NounLoans pool.

Every one of those already measures rather than assumes — `_burnChip` checks the delivered
balance at `0xdead`, `NounLoans` measures on both deposit and repay, and the splitter now pays
the Pot from the remaining balance (SEC-FEE-003). So the answer does not change whether
anything is *safe*; it changes whether users are quietly losing a percentage on every
activation and every loan, and whether the cost tables in §4 need to account for it.

**Ask Bankr directly.** It is one question and it affects a number in the runbook rather than
a line of code.