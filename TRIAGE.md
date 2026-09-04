# TRIAGE.md

How security findings are processed, and the log of every one received so far.

Applies to findings from any source — an external reviewer, a static analyzer, a bug bounty,
or one of us reading the code on a Sunday. **Same discipline regardless of where it came
from**, because the cheapest way to lose a real finding is to treat some sources as noise by
default.

---

## The protocol

### Every finding gets an entry

No exceptions, including the ones we disagree with. An entry has:

| Field | What goes in it |
|---|---|
| **ID** | `SRC-nnn` for us, `EXT-nnn` for an external reviewer, `SLI-nnn` for static analysis |
| **Source** | Who reported it, and against which tag |
| **Contract** | File and line at the tag it was reported against |
| **Severity (claimed)** | What the reporter said, untouched |
| **Severity (ours)** | Our assessment, **and both readings** — capped exposure and uncapped future state (see `REVIEW_PACKAGE.md` §6) |
| **Verdict** | `VALID` / `DISPUTED` / `PARTIAL` — and if disputed, the reasoning, not just the word |
| **Disposition** | `FIXED` / `ACCEPTED` / `DEFERRED`, with why |
| **Test** | If fixed: the test that now covers it. **Mandatory.** |

**Disputed findings stay in this file permanently.** They are not deleted when we decide we
disagree — a disputed entry with written reasoning is how the next reviewer knows the
question was asked and what the answer was. If our reasoning turns out to be wrong later,
the entry is where that becomes visible.

### The fix rule

> **Any fix reopens the tag.**
>
> `fix` → `test` → `full suite` → `new tag`
>
> **No fix ships without a test that fails on the old code.**

Concretely, for each batch of fixes:

1. **Write the test first.** Check out the tag, add the test, watch it fail. A test that
   passes before the fix is testing something else, and the finding is not actually
   understood yet.
2. **Fix it.** Smallest change that makes the test pass.
3. **Run the full suite**, fork tests included. A fix that breaks an invariant is not a fix.
4. **Cut the next tag** — `launch-candidate-2`, then `-3`, and so on. Tags are never moved
   and never deleted; the numbering is honest history, so a reviewer can always diff what
   changed between the tree they read and the tree that shipped.
5. **Update this file**: the entry gets `FIXED` plus the test name, and the tag it landed in.

**A tag under external review is frozen.** If a finding arrives while reviewers are working,
it is recorded here immediately but the fix waits for the batch, so nobody is reviewing a
tree that is moving under them. The exception is a finding severe enough that shipping the
current tag would be negligent — in which case the review is halted and restarted against
the new tag, deliberately and with everyone told.

### What we do with a finding we cannot reproduce

We try to write it as a failing test first. If we cannot, it is recorded as `DISPUTED` with
our reasoning and an explicit statement of what would change our mind. **It is not dropped.**
We would much rather argue a finding out in writing than quietly let it go.

---

## Finding log

### External review — Bankr, batch 3: FeeSplitter.sol

Against `launch-candidate-4`. All four accepted.

| ID | Finding | Theirs | Ours (capped / uncapped) | Verdict | Disposition |
|---|---|---|---|---|---|
| SEC-FEE-001 | A reverting recipient locks ETH in the splitter | High | **Medium / Medium** | **VALID** | **FIXED** — escrow fallback |
| SEC-FEE-003 | Fee-on-transfer accounting would underflow | Low | Info / Low | **VALID** | **FIXED** — the Pot is the residual claimant |
| SEC-FEE-002 | Reentrancy via token hooks into an intermediate state | Medium | Info / Info | **DISPUTED** | Already mitigated; documented |
| SEC-FEE-004 | Unbounded token array | Low | Low / Low | **VALID** | **FIXED** — `MAX_BATCH = 32` |

---

#### SEC-FEE-001 — THE ETH-PATH DECISION: it stays, and it is not hypothetical

**The ETH path stays. It carries a live, primary revenue stream.**

The suggestion to drop it rests on `quoteonlyfees = TRUE` making creator fees arrive as WETH.
That is true and it is only one source. `grep` for who actually sends native ETH here gives
one answer, and it is decisive:

- **`Anvil._settle` forwards native ETH**: `feeSplitter.call{value: price}("")`. Every Noun
  sold through the Box or a snipe sends ETH to this contract **in the same transaction as the
  sale**, and the Anvil *reverts the sale* if the forward fails. That is not a legacy path; it
  is the shop, built two candidates ago.
- **Secondary royalties** on Base marketplaces pay native ETH.
- Creator fees arrive as WETH, POL income as ERC-20 (AERO). Those use the token path.

So both paths are load-bearing and neither is vestigial. **Simplifying to WETH-only would
mean either breaking the Anvil or adding a wrap step to the hottest path in the shop** — worse
on both counts than fixing the splitter.

Note the interaction, because it makes `receive()` more load-bearing than it looks: the Anvil
reverts a sale whose fee forward fails, so `receive()` staying empty and cheap is what keeps
the shop working. That has always been the design (pull, not push) and this change does not
touch it.

**The fix.** Each ETH leg is now paid with a bounded stipend and, on failure, credited to
`owedEth[recipient]` instead of reverting the batch. A paused Pot, an ops wallet that becomes
a contract without a payable fallback, or a POL treasury mid-upgrade costs that recipient a
delay and costs everybody else nothing. `withdrawEth(recipient)` is permissionless and always
pays the recipient, never the caller — the same rule as `ChipClaims.claimFor`, so a keeper can
clear a stuck balance without anybody handing over a key.

**Two details that are easy to get wrong and are pinned by tests:**

- **Escrowed ETH is held back from every subsequent split.** `distributeETH` uses
  `distributableEth()` — balance minus `totalOwedEth` — not `address(this).balance`.
  Re-splitting escrow would pay it twice and leave the escrow unbacked
  (`test_escrowedEthIsHeldBackFromEverySubsequentSplit`).
- **A failed withdrawal leaves the escrow intact.** The bookkeeping is written before the
  send, so a send that still fails reverts the whole call and rolls it back. The escrow is
  never consumed by a payment that did not land.

**The gas stipend is sized, not guessed.** 150,000. Too low and the escrow becomes the normal
path rather than a safety net — the 2300-gas `transfer()` stipend is famously too small for a
Safe or any recipient writing a slot, and this contract has always deliberately forwarded more.
Too high, or unbounded, and a hostile recipient burns 63/64 of the remaining gas under EIP-150
and starves the legs after it — the exact wedge the escrow exists to prevent. 150k clears a
recipient doing real work on receipt (the existing `GreedyReceiver`, which writes five cold
slots, needs ~110k and is still paid directly) while bounding three legs to under half a
million.

**Behaviour change worth flagging to reviewers:** `distributeETH` no longer reverts when a
recipient rejects. Four existing tests asserted the old revert and have been rewritten to
assert the escrow instead — they are listed in the commit rather than deleted quietly.

---

#### SEC-FEE-003 — fee-on-transfer accounting

**VALID. FIXED by reordering, which is cheaper than measuring.**

The old sequence paid the Pot first from a precomputed share, then ops, then POL. With a token
that takes a cut in transit the balance is short by the third transfer and `safeTransfer`
reverts — freezing that token's fees in the splitter permanently.

**The Pot is now paid LAST, from the measured remaining balance.** That cannot overdraw by
construction, and it preserves the existing promise exactly: with a well-behaved token ops and
POL take their exact floors and the Pot receives its share plus every wei of rounding dust
(`test_thePotStillTakesTheDustOnAWellBehavedToken`). The Pot is simply the residual claimant in
both directions — it gains the dust and absorbs any transit shortfall, which is the honest
place to put it, since holders are who the fee was collected for.

This matches `ChipRounds._deliver` and `ChipClaims.recordAcquired`, which already measure
rather than assume, so the discipline is now consistent across every contract that moves a
foreign token.

**One thing worth confirming rather than assuming.** LAUNCH_CONFIG sets
`transfer_fee_recipient → FeeSplitter` on $CHIP. We read that as *where accrued fees are sent*,
not as a per-transfer tax on $CHIP itself — `quoteonlyfees = TRUE` means fees accrue in WETH,
which points the same way. **If Bankr's `transfer_fee_recipient` does imply a transfer tax on
$CHIP, then $CHIP is a fee-on-transfer token flowing through this splitter and this stops being
hypothetical.** The fix above makes it safe either way, but the semantics are worth a direct
answer from Bankr, and it is recorded in OPEN_ITEMS 19.

---

#### SEC-FEE-002 — reentrancy via token hooks

**DISPUTED as a live risk; the mitigation was already in place. Documented rather than changed.**

The concern is that a hook mid-distribution re-enters Pot or ChipRounds while the splitter is
part-way through. Checked every downstream entry point a hook could reach:

| Entry point | Guard |
|---|---|
| `Pot.convert()` / `convert(token)` / the `callerMinOut` overloads | `nonReentrant` |
| `Pot.pullBudget` | `onlyRewards` |
| `POLTreasury.convert` / `forwardIncome` | `nonReentrant` |
| `ChipRounds.openRound` / `contributeWeights` / `settleStock` / `finalizeRound` | `nonReentrant` |
| `ChipClaims.claim` / `claimFor` / `sweepExpired` | `nonReentrant` |

**There is no unguarded downstream entry point**, and the splitter holds no accounting state
between legs that a re-entrant call could read inconsistently — it computes the split from a
balance snapshot and transfers. The "intermediate state" the finding worries about does not
exist here in a form anything can observe.

Restricting fee-routed assets to standard ERC-20s is documented in ASSUMPTIONS C-20 rather than
enforced in code: an allowlist would add a governance surface and a way to freeze a fee stream
by forgetting to add a token, to defend against a class the guards already cover.

---

#### SEC-FEE-004 — unbounded token array

**VALID, trivial, FIXED.** `MAX_BATCH = 32` on `distributeTokens` and `distributeAll`. The
batch entry points are permissionless, so an unbounded array is a way for a caller to build a
transaction that cannot fit in a block and then call it a protocol bug. The keeper pages;
nothing here needs a hundred tokens at once.

---

### External review — Bankr, batch 2: Pot.sol / ConversionRoutes.sol

Against `launch-candidate-3`. **All six accepted in some form**; two of them with the harmful
half of the claim disputed, because the escapes they asked us to add already existed.

| ID | Finding | Theirs | Ours (capped / uncapped) | Verdict | Disposition |
|---|---|---|---|---|---|
| SEC-POT-001 | Slipstream router would revert on ABI mismatch and lock fees | High | **Info / Low** | **PARTIAL** | **FIXED** — router must be a Uniswap v3 router. "Locks fees" disputed |
| SEC-POT-005 | Chainlink min/maxAnswer pins price, locking a token | Medium | **Low / Medium** | **PARTIAL** | **FIXED** — band check. Escape already existed |
| SEC-POT-003 | No L2 sequencer uptime check | Medium | **Low / Medium** | **VALID** | **FIXED** |
| SEC-POT-002 | Permissionless convert is MEV-exposed | Medium | **Info / Medium** | **VALID** | **FIXED** (caller minOut) + OPEN_ITEMS 18 |
| SEC-POT-004 | Dust conversions grief the pool | Low | Low / Low | **VALID** | **FIXED** — per-route `minPerCall` |
| SEC-POT-006 | Single-step engine wiring | Info | Info | **VALID** | **FIXED** — codesize check |

---

#### SEC-POT-001 — THE ROUTING DECISION: Pot does NOT touch Aerodrome

**Answering the question directly, because it was asked directly.**

**Chipworks converts through Uniswap v3 only. No Pot route touches Aerodrome, and none is
intended to.** The evidence, in order of how strongly it settles the question:

1. **`ConversionRoutes` never mentions Slipstream.** It imports `IUniswapV3SwapRouter` and
   nothing else. **There is no dead branch to remove** — the finding's phrasing implies a
   dormant code path, and there isn't one, only a single hardcoded shape.
2. **ASSUMPTIONS A-16 is the decision**, titled "The liquidity is NOT on Aerodrome Slipstream
   — BLOCKER, verified". Both live routes, WETH and AERO, trade in Uniswap v3 pools; the
   AERO/USDC pool named in DEPLOY is the Uniswap one.
3. **Aerodrome appears exactly once in the protocol, and not for swapping**: `POLTreasury`
   uses the Slipstream position manager and gauges for LP positions. Its *conversion* path
   inherits this same Uniswap-only contract.
4. **`ChipRounds` does encode the Slipstream shape** — stock BUYS may route through either
   venue. Different contract, different job.

**So we did not remove `ISlipstreamSwapRouter`, and could not have.** The user's instruction
said to remove the interface if Pot is Uniswap-only; doing that would break `ChipRounds`,
which genuinely uses it for Slipstream stock buys. Removing it would have deleted a working
feature to tidy an unrelated contract. Flagged rather than done.

**What we did instead is stronger than removal.** `_setRoute` now requires
`router.factory() == uniswapV3Factory`, an immutable set at construction. A Slipstream router
belongs to the Slipstream factory and can never report ours, so the misconfiguration is
**rejected at configuration time** rather than discovered at conversion time. The factory is a
constructor argument, not a wiring call, deliberately: an optional guard that silently does
nothing when forgotten is the anti-pattern this repo already documents once.

**Disputed: "would lock those fees."** It would not, and two independent escapes already
existed before this review. `Pot.disableRoute(token)` turns a bad route off;
`Pot.sweepNonQuote(token, to)` rescues the token outright. A misconfigured route was always a
loud, immediately-visible, fully-recoverable mistake — `convert` reverts, nothing accrues
silently, and one transaction fixes it. Severity is Informational-to-Low, not High.
`test_aSlipstreamRouterIsRejectedWhenTheRouteIsSet` and `test_aUniswapV3RouterIsAccepted` pin
both directions, and the fork suite passes with the **real** Base SwapRouter02, which is the
end-to-end proof the guard does not simply refuse everything.

---

#### SEC-POT-005 — Chainlink min/maxAnswer band

**VALID and cheap, exactly as described. FIXED.**

An aggregator clamps its answer to `minAnswer`/`maxAnswer`. In a crash the feed reports the
FLOOR rather than the market, which here inflates the expected output and makes every
conversion of that token revert for as long as the price stays pinned.

`minOutFor` now reads the band from the aggregator behind the proxy and refuses a pinned
price by name. Both hops are gas-capped staticcalls and a feed that does not expose a band
simply skips the check — this must never be the reason a healthy conversion fails
(`test_aFeedWithoutABandIsUnaffected`).

**The value here is the error, not the refusal.** Before, a pinned feed failed as
`UnderMinOut` — indistinguishable from "the pool moved". Now it fails as `FeedAtBand`, so an
operator can tell an oracle circuit breaker from ordinary slippage and knows to reach for
`disableRoute` rather than widening tolerances into a crash.

**Disputed: "permanently locking it."** The admin route-disable escape the finding asks us to
add **already existed** — `Pot.disableRoute` has been there since the route table was built,
and `sweepNonQuote` rescues the token. `test_aTokenWithAStuckFeedCanBeDisabledAndRescued`
walks the whole recovery.

---

#### SEC-POT-003 — L2 sequencer uptime feed

**VALID, FIXED, and agreed it should not be deferred.**

On an L2 a Chainlink feed keeps returning its last answer while the sequencer is down, so
"fresh enough" is not the same as "true" — and the first blocks after it returns are exactly
when someone wants us trading on a stale mark.

`minOutFor` now checks the uptime feed before pricing: `answer != 0` means down, and a
configurable grace period after it returns stops us trading on the thin blocks. Zero feed
disables the check, so it is inert until configured.

**Base's feed is `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`**, verified live on chain for
this review: `description()` returns "L2 Sequencer Uptime Status Feed" and it currently reads
0 (up). Recorded in ASSUMPTIONS A-19 and wired in LAUNCH_CONFIG with a 1-hour grace.

---

#### SEC-POT-002 — permissionless convert and MEV

**VALID. The cheap half is done; the hard half is gated to scale, as suggested.**

`convert` stays permissionless — anyone being able to push the protocol along is a property
worth keeping — but it now takes an optional caller-supplied floor:
`minOut = max(chainlinkFloor, callerMinOut)`. A keeper holding a real quote can refuse a bad
fill instead of accepting anything inside the 2% haircut, and **a caller can only ever tighten
the bound, never widen it** (`test_aCallerCannotWidenTheChainlinkBound`).

The hard half — dynamic slippage from measured depth, or private routing — is recorded in
**OPEN_ITEMS 18** as a cap-raise precondition alongside the identical concern for stock buys
(OPEN_ITEMS 17). Both are the same problem in two places and should be solved once.

---

#### SEC-POT-004 — dust griefing

**VALID, trivial, FIXED.** `minOut == 0` was already refused, which covers the unbounded-swap
case, but not the merely-uneconomic one: a dust conversion pays a full swap's gas and moves
the pool for nothing. Each route now carries a `minPerCall` floor; below it the token simply
waits for more to accumulate. Nothing is stuck, only delayed
(`test_aConversionBelowTheFloorIsRefused`).

---

#### SEC-POT-006 — single-step engine wiring

**VALID, informational, FIXED.** `setRewards` was zero-checked; it now also requires a
contract. Pointing budget-pull rights at an EOA by fat-finger would hand them to a key rather
than to reviewed code, and nothing downstream would notice until a round opened. A codesize
check does not prove it is the *right* contract — the post-deploy read in LAUNCH_CONFIG does
that — but it rules out the whole class of typo that lands on an EOA.

We did not make it two-step. `Pot.rewards` is set once at deploy and effectively never again,
and a two-step handshake would add a partially-wired state to a contract whose failure mode is
already "reverts loudly until wired". The codesize check is the proportionate half.

---

### External review — Bankr, batch 1, against `launch-candidate-1`

Two reports: `ChipClaims.sol` and `ChipRounds.sol`. **The `ChipClaims` report artifact has
not been received yet** — findings C-H-1, C-M-1 and C-M-2 below are triaged from the summary
relayed to us, and **L-1 through L-4 and the informationals cannot be triaged without the
document.** They are listed as PENDING rather than silently omitted.

| ID | Finding | Their severity | Ours (capped / uncapped) | Verdict | Disposition |
|---|---|---|---|---|---|
| EXT-C-H-1 | Owner retarget + `claimFor` drains unclaimed credits | High | **Low / High** | **PARTIAL** | **FIXED** — 48h timelock on retarget; `claimFor` half disputed |
| EXT-C-M-1 | Permissionless dust sweep griefs claimants at the window boundary | Medium | n/a | **DISPUTED** | Not reproducible — states are disjoint |
| EXT-C-M-2 | A credit can land after its round's expiry is computed | Medium | n/a | **DISPUTED** | Not reproducible — both write paths refuse |
| EXT-C-L-1…L-4, informationals | — | Low / Info | — | **PENDING** | **Artifact not received** |
| EXT-R-M-1 | Unhandled revert in ledger handoff wedges rounds permanently | Medium | **High / High** | **VALID** | **FIXED** — try/catch + recovery path |
| EXT-R-M-2 | Hoodie boost sybil via flash-transfer in the accumulation window | Medium | — | **VALID** | **RESOLVED BY FEATURE REMOVAL** |
| EXT-R-L-1 | Fixed 2% slippage is systematic MEV extraction at scale | Low | **Low / Medium** | **VALID** | **ACCEPTED with a plan** — OPEN_ITEMS 17 |
| EXT-R-I-1 | Oracle failure silently under-reports `totalPaidUsd` | Info | Info | **VALID** | **FIXED** — one event |

**Their three verified invariants are recorded as external confirmation:** commitment
solvency, weight bounds, and abandonment safety — invariants 2 and 10 and the `cancelRound`
path in `REVIEW_PACKAGE.md` §4. Noted because a log that only records disagreements loses the
part where someone checked our work and agreed.

---

#### EXT-R-M-2 — Hoodie boost sybil: RESOLVED BY FEATURE REMOVAL

**Not present in `launch-candidate-3`.** The boost was deleted rather than fixed.

The finding is correct: `_hasHoodie` read live ownership at contribution time while the
`counted` guard tracked *Nouns*, not boost tokens, so one NFT passed between addresses inside
the 2-hour accumulation window could boost unlimited Nouns.

**We did not weigh the fix options, because the feature should not have existed.** It came
from the pre-Clutch v0.1 spec, pointed at a collection that is not part of this project and is
not on Base, and was configuration pointing at nothing. Weighing a `hoodieId`-per-round
mapping against a documented accept was the wrong question.

Removed from `ChipRounds` entirely: `_hasHoodie`, `boostBps`, `hoodieCollection`, `setHoodie`
and the boost term. **A Noun's weight is now `tier x collectionBase` and nothing else — no
term depends on any property of the owner**, which is a stronger statement than the boost was
worth, and it deletes a whole class of question about owner-dependent scoring.

Tests updated rather than dropped: `test_weight_isTierTimesCollectionBaseAndNothingElse`,
`test_theHalfBaseAppliesUniformlyToEveryHolder` and
`test_parity_weightHasNoOwnerDependentTerm` now assert the *absence*.
`test_gasBombHoodieDegradesToNoBoost` went with its subject — it was the only place weight
scoring called an address the protocol did not choose, and the equivalent hostile surface is
covered by `test_aGasBombCollectionCannotWedgeAread`.

ChipRounds shrank 20,834 → 20,377 bytes.

---

#### EXT-R-M-1 — Unhandled revert in the ledger handoff

| | |
|---|---|
| **Contract** | `src/ChipRounds.sol` — `_deliver` |
| **Severity (ours)** | **High capped, High uncapped** — a permanent wedge is not bounded by round size |
| **Verdict** | **VALID, and genuinely new** |
| **Disposition** | **FIXED** in `launch-candidate-3` |
| **Test** | `test_aLedgerThatRefusesToBookDoesNotWedgeTheRound`, `test_aRefusedBookingStillReleasesTheCommittedBudget` |

**Genuinely new, and we checked before agreeing.** The existing
`test_aBlockedLedgerStrandsOneStockWithoutWedgingTheRound` covers the *transfer* failing —
`ok == false`, nothing moves, no ledger call is made. It does not cover the transfer
**succeeding** while the booking reverts. The earlier fuzzer-found wedges were all in the buy
path, not the handoff.

Reproduced first, exactly as described:
`Underfunded(stock, held 490050000, needed 495000000)`. A fee-on-transfer stock makes the
engine's balance fall by the full amount while the ledger receives 1% less, and
`recordAcquired` verifies against the ledger's own balance. The revert propagated:
`settleStock` reverted, so the stock could never be settled, `finalizeRound` requires every
stock settled, `cancelRound` is blocked by the `Buying` state, and `committedQuote` stranded
permanently. **One misbehaving stock froze every holder in the round.**

**Fixed, and the recovery designed rather than just announced** — their recommendation stops
at emitting an event. The booking call is wrapped in `try/catch`, the round completes, and the
tokens are reported by a new `LedgerRefusedBooking` event.

**Where they end up matters, and it is not where the recommendation assumed.** The tokens are
at the *ledger*, not stranded in the engine, so `StockStranded` would have named the wrong
address and sent the multisig to the wrong rescue. Because `totalOwed` never rose, they are
**excess by the ledger's own definition** — `ChipClaims.recoverExcess` already reaches them
and by construction cannot touch a booked credit, since it subtracts `totalOwed` and re-checks
solvency after transferring. **The recovery path already existed; the fix was making it
reachable.** The test walks the whole rescue and pins that a taxed token taxes its own rescue
too.

**No redelivery, deliberately.** It would have to re-enter `recordAcquired` after the round
finalized, which reverts `AlreadyFinalized` — and rightly, since a round's shares are fixed at
finalize and re-opening them is a much larger hole than the one it would close.

---

#### EXT-C-H-1 — Owner retarget combined with `claimFor`

| | |
|---|---|
| **Contract** | `src/ChipClaims.sol` — `setRounds`, `setPolTreasury` |
| **Severity (ours)** | **Low capped, High uncapped** — needs the multisig, but reaches holder credits |
| **Verdict** | **PARTIAL — the conclusion is right, the mechanism traced is not** |
| **Disposition** | **FIXED** (timelock) / **DISPUTED** (router allowlist) |
| **Test** | `test/ChipClaimsGovernance.t.sol`, 10 tests |

**The half that is wrong: `claimFor` is not a lever.** `claimFor(owner, roundId, stock)` pays
the credit belonging to `owner` **to** `owner`. No argument redirects a payout; a stranger
calling it can only help (ASSUMPTIONS C-16). And the retarget they traced is the
**FeeSplitter's**, which moves the ops share of inflows — protocol revenue upstream of any
credit, in a different contract, with no path into `ChipClaims` at all. That half reads like
the flattened file without deploy context. Pinned by
`test_claimForCannotRedirectAPayoutToTheCaller` and
`test_recoverExcessCannotReachABookedCredit`.

**The half that is right, by a different route than described.** `setRounds` was immediate,
and whatever sits in `rounds` may write weights — weight being the numerator of every claim.
Retarget it to a hostile contract **while a round is still open** and that contract can mint
itself weight against stock the round has already bought, diluting the holders who earned it.
It cannot conjure stock (`recordAcquired` verifies against the ledger's balance) and it cannot
touch a finalized round (both write paths refuse one), but the live-round window was real —
and we would not have found it from their description alone, which is worth saying plainly.

**Fixed with the repo's existing 48h pattern**, which is what they asked for and the right
shape: `queueRounds` / `executeRounds` / `cancelRounds`, and the same for `polTreasury`. 48
hours is longer than a round lives, so any round a retarget could attack has finalized and
become claimable before the change binds.

**The first wiring stays immediate**, once, while the address is unset — a 48-hour gap at
deploy would only leave a half-wired ledger exposed for longer, and there is nothing to protect
yet. `AlreadyWired` enforces the one-shot; every later change is timelocked.

**Disputed: `claimFor` restricted to registered routers.** It does not address the actual path
— weight fabrication, not claiming — and it would break a property we rely on: `claimFor` is
permissionless so a keeper can claim on behalf of holders during the last window before expiry,
turning a forfeit risk into an operational cost (OPEN_ITEMS 8). It would add a governance
surface to the one function that currently has none, to defend against an attack it does not
defend against.

---

#### EXT-C-M-1 — Dust sweep griefing at the window boundary

**DISPUTED. Not reproducible; the two states are provably disjoint.**

`claim` requires `block.timestamp <= expiresAt`; `sweepExpired` requires
`block.timestamp > expiresAt`. **There is no block in which both are legal**, so there is no
boundary to race at. `test_claimAndSweepAreStrictlyDisjointAtTheBoundary` pins both sides: at
exactly `expiresAt` the sweep reverts `NotExpiredYet`, and one second later the claim reverts
`CreditsExpired`. This is invariant 13 and it was already asserted; the finding appears to
assume an overlap the code does not have.

On the "dust amounts" half: `sweepExpired(roundId, stock, maxHolders)` batches over a cursor at
the **caller's** gas cost, marks each holder once, and changes nobody's amount. Once the last
holder is processed it reverts `AlreadySwept` rather than silently no-opping, so a griefer
cannot even burn gas pretending to make progress.
`test_dustSizedSweepBatchesCannotGriefAnyone` sweeps three holders one at a time from a griefer
address and asserts every token reached POL exactly once.

**What would change our mind:** a sequence where a holder who could have claimed ends up swept,
or where repeated batching changes any holder's amount. We could not construct one.

---

#### EXT-C-M-2 — A credit landing after the expiry timestamp is computed

**DISPUTED. Both write paths refuse a finalized round.**

`freezeSchedule` sets `expiresAt` inside `finalizeRound`, and `finalizeRound` requires every
stock already settled — so every `recordAcquired` has happened before the schedule exists.
Both `creditWeight` and `recordAcquired` then guard `finalizedAt != 0` and revert
`AlreadyFinalized`, so nothing can land afterwards even from the real engine.
`test_noCreditCanLandAfterTheScheduleIsFrozen` asserts both, pranked as `rounds` itself.

Assessed against **invariant 11** as asked (the ledger is solvent for what it owes, the engine
for what it committed): the invariant holds, because a credit that cannot be written cannot
make the ledger owe more than it holds. The stateful invariant run exercises finalize ordering
across 128,000 calls and has never produced a counterexample.

**What would change our mind:** a path that calls `freezeSchedule` before the last
`recordAcquired`, or any second route into the credit maps. We looked for both.

---

#### EXT-R-L-1 — Fixed 2% slippage

**VALID, accepted with a plan.** No code change. Recorded in **OPEN_ITEMS 17** as a
**cap-raise precondition**: the round cap does not go above $10,000 until dynamic slippage or
private routing is in place. Below launch caps the arithmetic is against the attacker — 2% of
a ~$250 slice is $5 — but it scales linearly with the cap while the defence does not move at
all. This is the first cap doing security work it was not designed for, which is exactly what
`REVIEW_PACKAGE.md` §6 asks reviewers to surface.

---

#### EXT-R-I-1 — Oracle failure silently under-reports `totalPaidUsd`

**VALID, FIXED.** It was one event. `_roundValueUsd` had a bare `catch {}` that dropped a
stock's value from the round's USD figure with no trace, so nobody could tell "this round paid
less" from "this round could not be priced". It is no longer `view` and emits
`RoundValueUnpriced(roundId, stock, amount)` per unpriceable stock. The round still finalizes
and credits are untouched — refusing to finalize over a reporting number would be the wrong
trade. Test: `test_anUnpriceableStockIsAnnouncedRatherThanSilentlyDropped`.

---

### Static analysis — Slither 0.11.6, run against `launch-candidate-1`

```bash
python -m pip install slither-analyzer
python -m slither . --exclude-dependencies --checklist > review/slither-raw.md 2> review/slither-findings.txt
```

**168 findings, all in `src/`** (OpenZeppelin excluded). Both output files are committed —
`review/slither-raw.md` is the summary checklist, `review/slither-findings.txt` the full
per-finding detail — so a reviewer can check this triage rather than take it on trust. The
6.5 MB `--json` form is not committed; regenerate it with
`python -m slither . --exclude-dependencies --json review/slither.json` if you want to query
it programmatically.

**Summary: 1 valid finding, 1 accepted-with-reasoning, 166 disputed as false positives or
detector noise.** That ratio is normal for a codebase that deliberately uses gas-capped
low-level calls and balance-delta accounting — the two patterns Slither is loudest about are
the two this repo uses on purpose. The reasoning for each class is below; the discipline is
writing it down, not the ratio.

| Detector | Impact | N | Verdict | One-line reason |
|---|---|---:|---|---|
| `reentrancy-no-eth` (Furnace) | Medium | 1 | **VALID** | See SLI-001 |
| `return-bomb` | Low | 11 | **ACCEPTED** | See SLI-002 |
| `weak-prng` | High | 2 | DISPUTED | Modulo on a timestamp is the claim-window cadence, not randomness |
| `reentrancy-balance` | High | 3 | DISPUTED | All reachable only through `nonReentrant` externals |
| `reentrancy-no-eth` (rest) | Medium | 5 | DISPUTED | All five are `nonReentrant`; Slither misses the guard through inheritance |
| `unused-return` | Medium | 14 | DISPUTED | Deliberate: we measure balance deltas rather than trust return values |
| `uninitialized-local` | Medium | 13 | DISPUTED | Zero-initialised accumulators, all written before read |
| `incorrect-equality` | Medium | 10 | DISPUTED | All are `== 0` "nothing to do" guards, not value comparisons |
| `divide-before-multiply` | Medium | 4 | DISPUTED | See SLI-003 — bounded, and two of the four are exact |
| `erc20-interface` | Medium | 1 | DISPUTED | `IERC721Approve` is an ERC-721 interface Slither reads as a malformed ERC-20 |
| `calls-loop` | Low | 28 | DISPUTED | Deliberate batching; every call is gas-capped or failure-isolated per item |
| `timestamp` | Low | 25 | DISPUTED | Rounds, windows and timelocks are day-scale; validator drift is seconds |
| `shadowing-local` | Low | 15 | DISPUTED | A local named `owner` shadowing `Ownable.owner()` — a getter, never called in these scopes |
| `missing-zero-check` | Low | 6 | DISPUTED | Five are deliberate "zero disables"; one is SLI-004 |
| `reentrancy-benign` / `-events` | Low | 8 | DISPUTED | Event ordering after external calls; no state depends on it |
| `low-level-calls` | Info | 15 | DISPUTED | The gas-capped `staticcall` pattern is the whole defence against B20 precompiles |
| `missing-inheritance` | Info | 1 | **ACCEPTED** | See SLI-005 |
| `cyclomatic-complexity` | Info | 2 | DISPUTED | `settleStock` and `_buy`; the complexity is the failure isolation |
| `pragma` / `redundant-statements` / `var-read-using-this` | Info/Opt | 4 | DISPUTED | Style; one is a deliberate unused-variable silencer |

---

#### SLI-001 — `Furnace.depositStock` is missing `nonReentrant`

| | |
|---|---|
| **Source** | Slither `reentrancy-no-eth`, self-review |
| **Contract** | `src/furnace/Furnace.sol:259` |
| **Severity (claimed)** | Medium |
| **Severity (ours)** | **Informational** — downgraded from Low on closer reading, see below |
| **Verdict** | **VALID as an inconsistency, NOT exploitable** |
| **Disposition** | **FIXED** in `launch-candidate-3` |

`depositStock` calls `IERC721(collection).transferFrom(...)` in a loop and pushes to
`_stock[collection]` after each transfer. Every other NFT-moving function in the Furnace —
`forge`, `withdrawStock`, `rescueStrayNFT` — is `nonReentrant`. This one is not, and there is
no reason for the inconsistency; it is an omission, not a decision.

**Why it is Low and not Medium.** The function is `onlyOwner`, so reaching it requires the
multisig. Exploiting it would require the multisig to call `depositStock` against a
collection it chose to stock that is also hostile, and the payoff would be a corrupted
`_stock` array on a contract that is outside the money path and cannot reach a reward. That
is a narrow path behind a trusted role.

**Why it is still valid.** "A trusted role has to do something silly first" is exactly the
argument that ages badly, the guard costs nothing, and every sibling function already has it.
An inconsistency like this is also a bad signal to a reviewer: it invites the question of
what else was missed.

**DOWNGRADED ON CLOSER READING, AND AN EXPLICIT EXCEPTION TO THE FIX RULE.**

Writing the failing test showed there is no path to fail. A callback from a hostile collection
arrives with `msg.sender == collection`, and `depositStock` is `onlyOwner` — so re-entry is
already rejected before the guard would ever be consulted. The multisig cannot be induced to
re-enter by a token it is depositing.

So this is a **consistency omission, not a vulnerability**, and no test can fail on the old
code because the old code was not exploitable. The rule says no fix ships without such a test;
this is a deliberate, recorded exception rather than a quiet one. The guard is added anyway
because the inconsistency was an omission rather than a decision, it costs nothing, and every
sibling function has it — leaving one function different invites a reviewer to ask what else
was missed, which is exactly the question that cost us the time to answer here.

---

#### SLI-002 — `return-bomb`: gas-capped calls copy unbounded returndata

| | |
|---|---|
| **Source** | Slither `return-bomb` |
| **Contract** | 11 sites: `ChipActivation:319,326`, `ChipRounds:455,820`, `ChipClaims:548,280`, `ClaimRouter:159,172`, `StockRegistry:360`, `ClutchVaultAdapter` (retired) |
| **Severity (claimed)** | Low |
| **Severity (ours)** | **Low capped, Low–Medium uncapped** |
| **Verdict** | **VALID CONCERN, ACCEPTED for launch** |
| **Disposition** | **ACCEPTED**, candidate hardening post-audit |

Every foreign call in this repo is a gas-capped `staticcall` decoded into `bytes memory ret`.
Solidity copies **all** returndata into memory before the decode, and that copy is charged to
*us*, not to the callee. A hostile contract can return a large blob and make us pay for it.

**Why it is bounded rather than unbounded**, which is the part Slither cannot see: the callee
only has `PROBE_GAS` (100,000) to work with, and building returndata costs it memory
expansion, so it cannot produce an arbitrarily large blob. The realistic ceiling is tens of
kilobytes, and our copy of that is a large-but-finite gas cost, not a halt.

**Why it still matters.** The place it bites is `contributeWeights`, which loops over
caller-supplied token ids and calls `_effectiveOwner` for each. A hostile collection or
custodian could make each iteration expensive and reduce how many Nouns fit in one
transaction. That is a **griefing and gas-cost issue, not a loss**: weights are per-item, the
batch is caller-chosen, and anything that fails is skipped rather than reverting the round.

**Why we are not fixing it now.** The fix is to replace the `(bool, bytes memory)` pattern
with assembly that copies at most 96 bytes. That is a mechanical change to **nine call sites
across five contracts**, all of them on the critical read path that decides who earns —
exactly the code an external review is currently looking at. Changing it mid-review to
address a bounded griefing vector is the wrong trade.

**What would change our mind:** a demonstration that the effective ceiling is high enough to
make a round's `contributeWeights` uneconomic at realistic batch sizes. We would take that as
Medium and fix it immediately.

---

#### SLI-003 — `divide-before-multiply` in weight and minOut arithmetic

| | |
|---|---|
| **Contract** | `ChipRounds._weight:441`, `ChipRounds._minOutFor:628` (x2), `ConversionRoutes.minOutFor:126` |
| **Severity (ours)** | **Informational** |
| **Verdict** | **DISPUTED** — two are exact, two lose at most 0.005% |

**The two `minOutFor` sites are exact.** `(spendAmount * 1e18) / (10 ** quoteDecimals)`
multiplies *first*; with 6-decimal USDC the divisor is `1e6` and `1e18 / 1e6` is an integer
scale factor, so nothing truncates. Slither is pattern-matching the statement order across
lines, not the arithmetic.

**`_weight` does truncate, by a bounded and immaterial amount.** It computes
`w = (tierBps * base) / BPS`, then applies the hoodie boost as a second multiply-divide. With
the shipped tables — tiers 10000/12500/16000/20000/33300, bases 5000/10000/20000 — every
product divides exactly. A hand-set odd `tierBps` against the 0.5x Lil base could truncate by
at most 0.5 of a basis point on a weight of ~10,000, i.e. **0.005%**.

**And weights are relative.** Every holder's share is `weight / totalWeight`, so a uniform
half-bps truncation very nearly cancels. To matter it would have to truncate asymmetrically
between holders at a scale that changes a payout, which 0.005% cannot.

Recorded rather than fixed because reordering to multiply-first would change the shipped
weight values, and "no change to what anybody earns" is worth more here than removing a
pattern-match.

---

#### SLI-004 — `setChip` accepts a zero burn address

| | |
|---|---|
| **Contract** | `src/ChipRounds.sol:221` |
| **Severity (ours)** | **Low, governance-only, fails loudly** |
| **Verdict** | **DISPUTED as a security finding, noted as a config hazard** |

`setChip(token, burnAddress)` zero-checks neither argument. A zero `token` is **deliberate** —
it disables the split-change fee, and `setSplit` guards on `chipToken != address(0)`.

A zero `burnAddress` with a non-zero token is a genuine misconfiguration: `safeTransferFrom`
to `address(0)` reverts on any OZ-style ERC-20, so **every split change would revert** until
the multisig fixed it. That is a governance foot-gun.

Disputed as a *security* finding because it is multisig-only, reverts loudly and immediately,
costs nobody anything, and is fixed by one transaction. It is in the same class as the dozens
of other ways a multisig can set a wrong address, and singling this one out for a `require`
would imply the others are checked when they are not. Called out in `LAUNCH_CONFIG.md`'s
verification reads instead, which is where a config hazard belongs.

---

#### SLI-005 — `ChipClaims` does not declare `IChipRewardsClaimable`

| | |
|---|---|
| **Contract** | `src/ChipClaims.sol:38` |
| **Severity (ours)** | **Informational** |
| **Verdict** | **ACCEPTED** — a real if cosmetic improvement |
| **Disposition** | **FIXED** in `launch-candidate-3` |

`ChipClaims` implements every function of `IChipRewardsClaimable` — `claimFor`, `claimable`,
`isClaimOpen`, `nextWindowOpensAt` — and `ClaimRouter` calls it through that interface, but
the contract does not declare that it implements it. The compiler therefore never checks that
the two agree, which is a small but real gap: a signature drift between the ledger and the
router's expectation would compile cleanly and fail at runtime as a silently-failed leg.

Declaring the inheritance costs nothing and makes the compiler enforce what the router
already assumes. `ChipClaims` now declares `IChipRewardsClaimable`, and it compiled without a
single signature change — which is the useful result: the two were already in agreement, and
now they cannot silently drift apart. No new test: the compiler is the test, and it now runs
on every build.

---

---

## Fix batches

| Tag | Contains | Status |
|---|---|---|
| `launch-candidate-1` | The frozen contract state under review | **Current. Frozen.** |
| `review-1` | Identical `src/`, plus the review package and this file | Documentation only — `git diff launch-candidate-1 review-1 -- src/` is empty |
| `launch-candidate-2` | Skipped — batch 1 arrived before it was cut, so its contents folded into -3 | Never cut |
| `launch-candidate-3` | EXT-R-M-1, EXT-R-M-2 (removal), EXT-R-I-1, EXT-C-H-1, **plus** SLI-001 and SLI-005 | Superseded |
| `launch-candidate-4` | SEC-POT-001 … 006 (all six) | Superseded |
| `launch-candidate-5` | SEC-FEE-001 … 004 | **Current** |

The review package needed its own tag because it was written after the code was frozen, and
tags in this repo are never moved. A reviewer checks out `review-1`; the contracts they read
are `launch-candidate-1` byte for byte.
