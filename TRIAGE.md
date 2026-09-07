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

### SEC-POT-001 re-checked against the B20 expansion — **still settled correctly**

Asked when the stock set expanded, on the belief that stock buys would now route through
Aerodrome Slipstream. Worth answering carefully, because "we changed venue" is exactly the
kind of change that quietly invalidates a closed finding.

**Two different code paths, and only one of them was ever Uniswap-only.**

| Path | Contract | Direction | Venues it encodes |
|---|---|---|---|
| Stock BUYS | `ChipRounds._buy` | quote → stock | **both** — `Venue.UniswapV3` and `Venue.Slipstream`, picked per stock from the registry |
| Conversions | `ConversionRoutes._convert` (Pot, POLTreasury) | asset → quote | **Uniswap v3 only**, by design |

SEC-POT-001 was about the *second* one: pointing a conversion route at a Slipstream router
would revert on the ABI mismatch, so `_setRoute` refuses any router whose `factory()` is not
the Uniswap v3 factory. That finding is about converting WETH and AERO into USDC, and those
two both trade in Uniswap v3 pools (A-16). **A stock's venue has nothing to do with it** — no
conversion route has ever pointed at a stock, and the Pot never buys.

So expanding the stock set changes nothing here even if the buys were on Slipstream:
`ChipRounds` already encodes the 8-field Slipstream `exactInputSingle` with `tickSpacing` and
`deadline`, and `StockRegistry._setVenue` already verifies a Slipstream pool against the CL
factory. Both were built for exactly this.

**As it turns out the buys are not on Slipstream anyway** — see ASSUMPTIONS A-22. There is no
Slipstream pool for any B20 stock on Base, at any tick spacing, against USDC or WETH. Every
one registers as `Venue.UniswapV3`. The Slipstream buy path stays in the contract because it
is correct and because the day a B20 CL pool appears it becomes a `setVenue` call — but it is
dead code at launch, and a reviewer should know that rather than assume it is exercised.

**Nothing changed in `src/`. This entry exists because the question was asked and the answer
needed to be checkable.**

---

### External review — Bankr, batch 8: ClaimRouter.sol — **the core eleven are done**

Against `launch-candidate-12`. No criticals or highs; every core invariant came back safe.
**This closes the eleven-contract audit**, which is worth recording as a milestone rather than
just another batch: every contract that handles money or custody has now had an independent
pass, and the findings arrived in roughly descending order of severity across the eight
batches, which is what you want to see.

| ID | Finding | Theirs | Ours (capped / uncapped) | Verdict | Disposition |
|---|---|---|---|---|---|
| SEC-RTR-001 | `sweepTo` is permissionless and its NatSpec says otherwise | Low | Low / Low | **VALID** | **FIXED** — `onlyOwner`, and the comment rewritten |
| SEC-RTR-002 | Raw call ignores a `false` return, so `Swept` can lie | Low | Low / Low | **VALID** | **FIXED** — books the measured delta |
| SEC-RTR-003 | EIP-150 can mark valid legs failed on low gas | Info | Info / Info | **VALID** | **ACCEPTED** — caller concern, SITE_CLAIM_API.md |
| SEC-RTR-004 | Unbounded batch | Low | Low / Low | **VALID** | **FIXED** — `MAX_CLAIMS = 100` |

---

#### SEC-RTR-001 — the comment was the finding

**VALID, and the interesting half is which of the two things was wrong.** `sweepTo` was
permissionless, which on its own is arguable. What is not arguable is the NatSpec sitting
directly above it:

> *"It sends to `to` rather than to `msg.sender`, so it can rescue a specific user's stranded
> tokens without the caller being able to take them."*

A caller passes its own address as `to`. The sentence describes a protection that does not
exist and never did, and a reviewer reading it would reasonably stop looking. The test suite
had absorbed the same idea — `test_sweepToRescuesStrandedTokens` was written from a
`goodSamaritan` address with a comment saying "never to themselves by default", where *by
default* was carrying the whole lie.

**Fixed with the modifier, not the wording, and the reasoning is not "the multisig is more
trusted".** Permissionless recovery only beats multisig recovery if the person who lost the
tokens can be sure of winning the race to reclaim them, and they cannot — anyone watching the
mempool takes it first. A public bounty on accidental deposits is worse for the victim than a
multisig that can send them back.

It also settles an inconsistency: `Anvil.recoverExcess`, `POLTreasury.recoverExcess` and
`Furnace.recoverNFT` are all owner-only. There is now **one rule for accidental deposits across
the protocol** instead of an exception here that a reviewer has to hold in their head.

Nothing is centralised by this. No normal path puts a token on the router — `claimFor` credits
its `owner` argument and never `msg.sender`, so the router is never the claimant, which
`test_routerHoldsNothingAfterwards` has always asserted.

**Demonstrated before it was fixed:** `test_PROOF_RTR001_anyoneSweepsStrandedTokensToThemselves`
passed on `launch-candidate-12` with a `thief` address taking 77 CHIP.

---

#### SEC-RTR-002 — an event that lies is worse than no event

**VALID.** `Swept` was emitted on `okXfer`, which is "the call did not revert". The ERC-20 spec
permits returning `false` instead, and real tokens do it. The router then announced a transfer
that had not happened.

Low severity in money terms — nothing is lost, the tokens are still there and still
recoverable — and higher than it looks in operational terms, because an indexer, a support
ticket and an incident timeline are all built on these events being true.

**Fixed by booking the measured delta rather than the return value**, which is the rule
`ConversionRoutes` and `ChipRounds` already follow for every value that moves in this protocol:
*book what MOVED, never what was intended*. That is strictly stronger than the boolean check
the finding asked for, since a token can return `true` and still move nothing.

**One precision worth stating, because the first draft of the comment overstated it.** The
amount booked is what left the ROUTER, not what landed at `to`. For a fee-on-transfer token
those differ and the event reports the larger figure — asserted deliberately in
`test_RTR002_theEventBooksTheMeasuredAmountNotTheRequestedOne`. That is the honest reading of a
sweep, since the router is saying what it gave up; measuring the recipient instead would mean
trusting a second balance on an address we know nothing about.

**Demonstrated before it was fixed:** `test_PROOF_RTR002_aLyingTokenEmitsAFalseSwept` passed
with `Swept` emitted while the balance had not moved a wei.

---

#### SEC-RTR-003 — the one the contract cannot fix

**VALID, ACCEPTED, and documented rather than coded — with the reasoning, because "frontend
concern" is exactly the disposition that gets abused.**

Each leg is dispatched with `call{gas: legGasLimit}`, and EIP-150 gives a subcall at most 63/64
of the gas remaining at that moment. Send too little overall and later legs get less than their
budget, fail for that reason alone, and are reported as `LegFailed`. **A valid credit shown to
its owner as broken.**

The credit is untouched and stays claimable, so the cost is gas and confidence rather than
money. And the two on-chain fixes are both worse than the problem:

- **Revert on low gas** — throws away the legs that already succeeded. The user pays for a
  reverted transaction instead of keeping partial value.
- **Break out of the loop early** — silently does less than the caller asked for, and returns a
  success. That is the same class of dishonesty as SEC-RTR-002.

So it is the caller's job, and the contract's job is to make the number computable: `MAX_CLAIMS`
bounds the array and `legGasLimit` is readable on chain, so an SDK never hardcodes it
(`test_RTR003_theGasFormulaInputsAreReadable`). **`SITE_CLAIM_API.md` carries the formula** —
`claims.length × (legGasLimit + 30_000)` — plus what `LegFailed` means, why not to retry a whole
batch, and the instruction to batch in tens rather than at the cap.

---

#### SEC-RTR-004 — a bounded batch is what makes the formula writable

**VALID, FIXED.** `MAX_CLAIMS = 100`, reverting `TooManyClaims(requested, max)`.

**Being honest about what the cap does and does not do.** It does not make a large batch safe:
at the launch `legGasLimit` of 1,000,000, a hundred legs asks for more gas than a Base block
will reserve, so the practical limit is set by SEC-RTR-003's formula and is much lower. What the
cap does is turn the worst case from an open question into a knowable number — which is the
precondition for writing the gas formula down at all. The site is told to batch in tens.

---

### External review — Bankr, batch 7: Anvil.sol

Against `launch-candidate-10`. No criticals or highs. **Two mediums that were both live bugs
in the ordinary restock flow**, which is the part worth dwelling on: neither needed an
attacker. The protocol's own shopkeeping triggered them.

| ID | Finding | Theirs | Ours (capped / uncapped) | Verdict | Disposition |
|---|---|---|---|---|---|
| M-1 | FIFO queue-jump via a re-shelved sniped token | Medium | **Medium / Medium** | **VALID** | **FIXED** — slots retire permanently; a re-shelve appends |
| M-2 | O(n) shelf count per purchase, gas DoS at scale | Medium | Low / **Medium** | **VALID** | **FIXED** — maintained `listed` count, O(1) |
| L-1 | `setFeeSplitter` instant while prices are timelocked | Low | Low / **Medium** | **VALID** | **FIXED** — 48h timelock, same shape as prices |
| L-2 | Queued changes never expire | Low | Low / Low | **VALID** | **FIXED** — 14-day grace, then re-queue |
| L-3 | `unshelve` can take the head when `count == 1` | Low | Low / Low | **VALID** | **FIXED** — refused while the shelf is live |
| I-1 | Force-sent `selfdestruct` ETH is permanently burned | Info | Info | **ACCEPTED** | Documented, ASSUMPTIONS A-21 |

---

#### M-1 — the stale slot, and why `require(!isListed)` would not have helped

**VALID, and the reviewer's note about the non-fix is the important half of the finding.**

The shelf recorded two things in two places. **Ordering** lived in the slot array; **availability**
lived in `isListed[tokenId]`. A snipe only cleared the second. The slot the token had occupied
stayed exactly where it was, holding that token's id, waiting.

Then the ordinary thing happens: someone snipes Noun 2 out of the middle, the protocol buys it
back on the open market, and restocks it. `shelve` pushes a new slot at the tail **and** sets
`isListed[2] = true` — which re-lights the old slot at position two. The Noun reappears where it
left, ahead of three Nouns that had been waiting longer, and is counted twice until one of the
two slots is consumed. That is invariant #21 broken by a restock.

Adding `require(!isListed[id])` to `shelve` refuses the double-listing case and does nothing
here, because `isListed[2]` was correctly `false` — the token really had left. **The stale slot
is the bug**, not the flag.

**So retirement is now a property of the slot.** Each entry holds `tokenId + 1`, zero means
retired, and every exit — bought, sniped, unshelved — zeroes the slot it came from and clears
the token's index. A re-shelve can only append. The `+ 1` offset is what lets zero be the
sentinel while slot zero stays a real position; `type(uint256).max` is refused by `shelve`
rather than allowed to wrap.

**Demonstrated before it was fixed.** `test_PROOF_M1_theStaleSlotJumpsTheQueue` was written
against `launch-candidate-10` and passed: `shelfRemaining` returned **6 for five Nouns**, and
the restocked Noun came out **second** instead of last. The proof file was replaced by
`test/anvil/AnvilQueueIntegrity.t.sol`, which runs the exact buyback-restock sequence and now
asserts the tail position, the count, the drained order, and that a restocked Noun can never be
sold twice however many stale slots existed.

**The `unshelve` path had the same shape** and is covered too: a Noun taken off the shelf and
put back later is a new arrival.

---

#### M-2 — a purchase must not pay for the shelf

**VALID, and it was worse than the finding says.** `_settle` called `shelfRemaining` for its
event, which walked every slot from the cursor. But `shelve` called it too — *inside the
loop*, once per token — so a 400-token restock counted the shelf 400 times. Quadratic, on the
one operation the protocol performs in bulk.

The count is now maintained by the two functions that can change it and `shelfRemaining` is a
single `SLOAD`.

Measured, on `launch-candidate-10` and again after:

| | before | after |
|---|---|---|
| `buyNext`, 5-deep shelf | 175,253 | 164,368 |
| `buyNext`, 400-deep shelf | 354,718 | **74,870** |

The large-shelf buy is now *cheaper* than the small-shelf one, because it no longer pays for
the queue behind it and the small case is the one paying cold-slot costs. Done now rather than
"when the shelf grows", as asked: it is a one-time change, and the shelf growing is the plan.

---

#### L-1 — redirecting all revenue deserves at least as much notice as a price

**VALID.** Every wei of every sale goes to `feeSplitter` in the same transaction. Changing that
address redirects 100% of Anvil revenue, and it was a one-transaction instant change while
*prices* — a strictly smaller act — had 48 hours of notice. A compromised multisig could point
the till at itself with no warning at all.

`queueFeeSplitter` / `executeFeeSplitter` / `cancelFeeSplitter`, same shape as prices and the
premium. **`setFeeSplitter` is gone**, which is a breaking ABI change; DEPLOY step 7 carries it.

The asymmetry with `setPaused` is deliberate and worth stating: pausing stays immediate,
because stopping sales is a safety action and it is the lever to reach for during the two days
a splitter change is maturing.

**Note for a later batch, not fixed here:** `NounLoans.setFeeSplitter` and
`POLTreasury.setFeeSplitter` are instant for the same reason and with the same consequence.
That is the same finding in two more contracts, and expanding a scoped Anvil batch into them
unasked is how a review loses track of what was checked. Recorded in OPEN_ITEMS 23.

---

#### L-2 — a queued change should go stale

**VALID.** The value of the 48 hours is that the notice is *fresh*. A change queued in March
and executed in September is a surprise wearing a timelock's reputation, and a forgotten queued
entry is a dormant capability sitting in storage.

`CONFIG_GRACE` is 14 days. After `executableAt + CONFIG_GRACE` the change reverts
`TimelockExpired` and must be re-queued, which restarts the notice. Applied to all three
timelocked settings through one `_requireInWindow` helper, so they cannot drift apart. Both
edges of the window are tested — executable at the exact maturity second, and at the last
second of the grace.

---

#### L-3 — the head is also the tail when one is left

**VALID.** `unshelve` removes from the tail specifically so the multisig can shrink the shelf
without taking the Noun the next buyer is about to receive. Every live slot sits at or after
the cursor, so the first live slot is the head and the last is the tail — and at exactly one
live slot **they are the same Noun**. The guarantee stopped holding at the one depth where a
buyer is most likely to be racing for it.

**Fixed, with a deliberate escape hatch, and this is a decision rather than just a fix.**
Refusing outright would have been wrong: `recoverNFT` declines a shelved token, so an absolute
rule would strand the last Noun on the shelf permanently, with no path off it but a sale. So
the head is protected **while the shelf is live**, and a *paused* collection can be emptied.
Pausing is what says "nobody is about to buy anything here". Winding down is now two deliberate
transactions instead of one, which is the right shape for winding down anyway.

---

#### I-1 — force-sent ETH

**ACCEPTED AS DESIGNED, documented rather than changed.** There is no `receive()`, so an
ordinary send bounces. `selfdestruct` and coinbase payments cannot be refused by any contract,
and such a balance is unrecoverable because the Anvil deliberately has no ETH withdraw path.

That is the correct trade and it is worth being explicit about why: the alternative is a
standing ETH withdraw function on the contract that handles every sale, added to protect
against somebody choosing to destroy their own money. The one-line fix is worse than the
problem. ASSUMPTIONS A-21.

---

### External review — Bankr, batch 6: POLTreasury.sol — **the most serious of the audit**

Against `launch-candidate-9`. **Two HIGHs, both real, both closed in `launch-candidate-10`.**

This batch is different from the five before it, and the difference is worth stating before
the table. Every earlier finding was about a contract behaving wrongly. These two were about
a contract behaving exactly as written, for parameters it had no business accepting. The
earlier per-operation allowance hardening on this contract was real work and it solved the
wrong layer: **allowances were never the vector. The parameters were.** Both attacks below
drain the treasury with correctly-scoped, promptly-cleared approvals throughout.

| ID | Finding | Theirs | Ours (capped / uncapped) | Verdict | Disposition |
|---|---|---|---|---|---|
| H-01 | Fake-gauge NFT theft via `stakePosition` | High | **High / High** | **VALID** | **FIXED** — voter-verified gauge, pool derived from the position |
| H-02 | Attacker-pool mint and unbounded exit | High | **High / High** | **VALID** | **FIXED** — token allowlist, derived pool, Chainlink band, stated minimums |
| M-01 | `convert` hardcodes `callerMinOut = 0`, so SEC-POT-002's keeper floor is unreachable | Medium | **Medium / Medium** | **VALID** | **FIXED** — `convert(token, minOut)` overload |
| M-02 | `setIncomeToken` overlaps POL assets, making `forwardIncome` a drain | Medium | **Medium / High** | **VALID** | **FIXED** — disjointness enforced both ways |
| M-03 | Dust-donation griefing bloats `positionIds` toward gas death | Medium | Low / **Medium** | **VALID** | **FIXED** — self-mint-only registration plus a prune path |
| L-01 | `recoverExcess` relies on the NFPM lacking an ERC-20 shape | Low | Low / Low | **VALID** | **FIXED** — explicit exclusion |
| L-02 | `stakePosition` can leave a live ERC-721 approval | Low | **Low / High** | **VALID** | **FIXED** — post-deposit custody assertion |
| L-03 | `increaseLiquidity` trusts caller-supplied `token0`/`token1` | Low | Low / Low | **VALID** | **FIXED** — read from `positions(tokenId)` |
| L-04 | `claimGaugeRewards` is an arbitrary-call primitive | Info | **Low / Low** | **VALID** | **FIXED** — reaches only the gauge we staked into |

---

#### The session-key claim, stated so it can be checked

`manager` is a hot key. It lives on the Bankr optimizer's server so it can move ranges
without holding configuration rights, and the honest way to reason about it is that **it is
already leaked**. Before this batch the protocol's safety under that assumption rested on key
hygiene, which is not a property of the code and is not something a reviewer can verify.

It now rests on four properties that are enforced on-chain and testable:

1. **Tokens are allowlisted.** Every position is the quote token paired with a registered POL
   asset. No manager path touches an arbitrary token.
2. **Pools are derived, not supplied.** The pool comes from the position manager's own
   factory for that exact pair and tick spacing, and `sqrtPriceX96` is forced to zero, so a
   caller can neither name a pool nor create one at a price of their choosing.
3. **Gauges are verified against the Voter.** `voter.gauges(pool)` with the pool derived from
   `positions(tokenId)` is the only thing that makes an address a gauge.
4. **Execution is bounded by Chainlink.** The pool's own price must sit inside a band around
   the POL asset's feed before liquidity moves in either direction.

What a leaked manager key can still do is move liquidity between honest ranges of honest
pools at honest prices, and it can churn gas doing it. What it cannot do is send value
anywhere, because **no manager function has a destination argument at all**. That is the
whole claim, and `test/POLTreasuryExploit.t.sol` is where it is checked.

---

#### H-01 — fake-gauge NFT theft

**VALID, and the cheapest attack in the repo.** `stakePosition` granted the caller-supplied
gauge an ERC-721 approval and then called into it. A contract with a `deposit(uint256)` that
spends that approval takes the position. One call, one block, no cleverness.

**Demonstrated before it was fixed.** The attack was written against `launch-candidate-9`
first and run: `test_PROOF_H01_fakeGaugeStealsThePosition` passed, ending with
`ownerOf(tokenId) == attacker`. That run is the reason this entry says the finding is real
rather than plausible. The proof file was then replaced by the permanent post-fix suite.

**The fix is the Voter.** A gauge address proves nothing on its own — anyone can deploy one.
`voter.gauges(pool)` is the only on-chain statement that a given gauge is *the* gauge for a
given pool, and the pool is derived from `positions(tokenId)` rather than supplied, so
naming a pool you do control does not help either
(`test_H01_exploit_aGaugeForAnotherPoolIsStillRefused`).

**Two smaller holes closed with it.** `unstakePosition` now withdraws only to the gauge we
recorded at stake time — remembering is stricter than re-deriving, because it holds even if
the Voter's answer for that pool changes later. And `claimGaugeRewards` no longer takes a
gauge argument at all: as an arbitrary `getReward(uint256)` against any address, made from
the contract that holds the treasury's assets, it was a free call primitive pointed wherever
a caller liked (L-04).

**And the approval is checked back in.** After `deposit` the gauge must own the position
(L-02). A canonical gauge always takes custody, so this asserts the stake happened *and*
guarantees no live approval is left behind, since the ERC-721 transfer clears it. A gauge
that accepts the call and quietly declines the NFT is refused
(`test_H01_exploit_aGaugeThatDoesNotCustodyIsRefused`).

**Verified against real Aerodrome, not just mocks.** `test_realAerodromeAnswersThePoolAndGaugeChecks`
forks Base and asserts that the Slipstream factory resolves the WETH/USDC pool our derivation
produces, that the live Voter names a gauge for it, and that the live pool price sits inside
the band around the live Chainlink mark — so the check does not simply refuse everything.
`test_realVoterRefusesANonCanonicalGauge` runs the attack against the real Voter.

---

#### H-02 — attacker-pool mint and unbounded exit

**VALID, and the larger of the two by value.** `mintPosition` validated `recipient` and
nothing else. The token pair, the tick spacing, the pool's initial price and both minimums
were all the caller's to choose. A leaked key could mint the entire USDC balance against a
token it had just printed, into a pool it initialised at a price of its choosing, with
`amountMin = 0`, and then buy the USDC out for nothing.

**Also demonstrated before it was fixed.** `test_PROOF_H02_arbitraryTokenAndBlindMinimumsAreAccepted`
passed on `launch-candidate-9` with the full treasury balance committed against an
unregistered token.

The finding asked for four things and all four landed, though **(c) landed differently from
how it was specified and that difference matters**:

**(a) Token allowlist — done, and tightened.** Both sides must be the quote token or a
registered POL asset. We went further: **exactly one side must be the quote token.** A
POL/POL pair is not something this treasury has any reason to hold, and requiring the quote
side is what makes the pool's price checkable against a single USD feed. Adding an asset
stays a multisig call; adding a pair *shape* is now a code change.

**(b) Pool verified through the factory — done.** The pool comes from
`positionManager.factory()`, read at construction rather than passed in, so the pool check
can never be pointed at a factory that disagrees with the manager the positions live in. And
`sqrtPriceX96` is forced to zero on the way through: that field exists only to create and
initialise a pool, and this function may only join one that already exists.

**(c) Chainlink-bounded execution — done, but as a POOL PRICE BAND, not an amount ratio.**
This is the part worth reading carefully.

The finding asked to "bound executed amounts against the Chainlink feeds the contract already
holds". The first implementation did exactly that — every `amountMin` had to sit within a
configured slippage of its `amountDesired` — and **it was wrong**. In concentrated liquidity
`amountDesired` is a *maximum*, not a target: a range sitting on one side of the current
price legitimately consumes zero of the other token. A ratio rule would have refused ordinary
range orders, which is to say it would have been an outage disguised as a fix. It was caught
by writing the fork test, where a real full-range WETH/USDC mint does not consume both sides
in the ratio requested.

What replaced it is stronger. `_requirePoolOnMark` reads the pool's own `slot0` price and
requires it to sit inside a per-asset band around that asset's Chainlink feed, before
liquidity moves **in either direction**. Since the pair is allowlisted, nothing in it can
reenter and move the pool between the check and the position-manager call, so liquidity
enters and leaves at a price the treasury has verified. That, not the caller's minimums, is
what bounds the value that moves.

This also closes a case the pool-derivation alone would miss: a **real** pool for the same
pair at a different tick spacing, which the attacker has just pushed to an absurd price. It
is canonical; it is simply lying (`test_H02_exploit_cannotMintIntoAPoolPushedOffItsMark`).

Blank minimums are still refused, on every liquidity operation, and the code says plainly
that this is operator hygiene rather than the protection — an operator who states no
expectation cannot notice they did not get it. A check that *looks* like the bound but is not
would be worse than none.

**The feed is mandatory, which is the deploy-time half of this.** `setPolAsset` now takes
`(token, feed, maxDeviationBps, maxFeedAge)` and refuses a zero feed or a zero band. An
optional price check that silently does nothing when the feed was forgotten is exactly the
shape of guard this repo has already been bitten by once — the `setCustodian` wiring trap in
LAUNCH_CONFIG — and the whole point of H-02 is that we stop relying on someone remembering.
**This is a breaking change to the deploy sequence: see DEPLOY step 6.**

**(d) Same treatment on increase and decrease — done.** Both now derive the pool, check the
band, and refuse blank minimums. `increaseLiquidity` additionally reads the pair from
`positions(tokenId)` instead of taking it from the caller (L-03): a caller-supplied pair let
a manager approve one token while topping up a position in another, and there was no
legitimate use for the freedom.

---

#### M-01 — the keeper floor was unreachable, so SEC-POT-002 was not actually closed

**VALID, and a good catch about our own previous fix.** Batch 3 accepted SEC-POT-002 by
adding `callerMinOut` to `ConversionRoutes._convert`, so a keeper holding a real quote could
refuse a bad fill on a permissionless conversion. `Pot` exposes overloads that pass it.
**`POLTreasury` did not** — its only `convert` passed a hardcoded zero. The parameter
existed; on this contract the defence did not.

`convert(address token, uint256 callerMinOut)` now exists here too. The floor can only ever
be raised: `_convert` takes the maximum of the caller's number and the Chainlink minimum, so
a caller can tighten the bound and never widen it
(`test_M01_aCallerCannotWidenTheChainlinkBound`).

**SEC-POT-002 is now closed on both contracts.** Its batch-3 entry stands, but it was only
half true for POLTreasury between `launch-candidate-3` and `-9`, and that is recorded here
rather than quietly corrected over there.

---

#### M-02 — income tokens and POL assets must be disjoint

**VALID, and the severity is higher uncapped than the finding says.** `forwardIncome` is
permissionless and moves the **entire balance** of an income token to the FeeSplitter. If a
token were both an income token and a POL asset — or worse, the quote token — that
permissionless call would become a drain of the treasury's pairing inventory. Not a theft:
the funds go to the splitter and re-enter the Pot. But POL would be stripped of the ability
to do its job by anyone, at any time, for the price of gas.

Disjointness is enforced **in both directions**, which the finding did not ask for but is
necessary: guarding only `setIncomeToken` would leave the same overlap reachable by
registering in the other order (`test_M02_theDisjointnessHoldsInBothDirections`).

---

#### M-03 — donated positions and an append-only list

**VALID.** `onERC721Received` registered any position the NFPM delivered, and `positionIds`
had no removal path, so anything that ever landed here was walked by `collectAllFees`
forever. Dust donations were a one-way ratchet toward a gas-dead sweep.

Registration on receipt is now limited to `from == address(0)` — a fresh mint into this
contract. A transfer in is still *accepted*, because refusing it would let a griefer make our
own migrations fail, but it is not tracked. Deliberate transfers in are picked up by
`registerPosition` (owner-gated: the cost of a junk entry is paid by every future sweep), and
`prunePosition` removes an entry for a position this contract genuinely no longer owns and
has not staked — so it can never be used to hide a live position from the fee sweep
(`test_M03_pruningRequiresThePositionToBeReallyGone`).

---

#### L-01 — the rescue names the position manager

**VALID and fixed, and the reasoning generalises.** `recoverExcess` was safe from moving
position NFTs because an ERC-721 has no ERC-20 `transfer` shape for `safeTransfer` to hit.
That is a property of **somebody else's contract**, not ours, and it stops being true the day
the NFPM gains an ERC-20-shaped method. `isProtected` now names `positionManager` explicitly.

---

#### A note on what was deliberately NOT added

Aerodrome's Voter also exposes `isAlive(gauge)`. Staking into a killed gauge earns nothing,
so checking it is tempting — but it is an **economics** concern, not a custody one: a killed
gauge is still the canonical gauge, and `withdraw` still returns the position. Adding the
call would turn an availability dependency into the staking path for no security gain, and a
Voter interface change would then break staking rather than just cost yield. Recorded in
OPEN_ITEMS as a keeper-side check instead.

---

### External review — Bankr, batch 5: NounLoans.sol

Against `launch-candidate-7`.

**External validation, recorded:** the cross-contract trust attacks against ChipActivation all
came back safe — a Noun cannot earn without collateral being genuinely held, a repaying
borrower is never stranded, and principal is conserved across the borrow/repay/liquidate
cycle. That is the seam between the two newest contracts in the repo, so an independent pass
over it is worth more than most single findings.

| ID | Finding | Theirs | Ours (capped / uncapped) | Verdict | Disposition |
|---|---|---|---|---|---|
| SEC-LN-003 | Rigid grace blocks day-8 repayment with no liquidator | Medium | **Medium / Medium** | **VALID** | **FIXED** — repay stays open until liquidation |
| SEC-LN-002 | Bounty is zero when the pool is drained | Medium | **Low / Medium** | **VALID** | **FIXED** — non-withdrawable bounty reserve |
| SEC-LN-001 | `maxPrincipal` is manual vs a crashing floor | Medium | Low / Medium | **ACCEPTED with process** | OPEN_ITEMS 11, no code change |
| SEC-LN-004 | Custodian de-registration kills yield mid-loan | Medium | Low / Low | **COVERED** — but **not by the fix assumed** |

---

#### SEC-LN-003 — repayment now ends at liquidation, not at a deadline

**VALID, and the old rule was worse than the finding says.** A borrower who turned up on day 8
of a 7-day loan holding the full principal was refused — and then kept waiting, still owning
the Noun, until a liquidator happened to appear. The protocol gained nothing from that window:
it was refusing money it was owed on collateral it had not seized.

**`repay` is now bounded by the thing that actually takes the Noun away.** Past maturity plus
grace anyone may liquidate, but the borrower may still repay right up until somebody does. A
late borrower races a liquidator, which is the honest description of their position, rather
than being told the money they are holding is no longer wanted.

**With a late fee, and the fee is load-bearing.** `lateFeeBps` (1% of principal at launch) is
charged on any repayment past the deadline. Without it a term would be advisory — the cheapest
strategy would be to never repay on time — so the surcharge is what keeps the ladder meaning
something now that the hard cut-off is gone. It is snapshotted at borrow like everything else,
capped at `MAX_FEE_BPS`, and routed to the FeeSplitter rather than the pool, so a late
repayment funds the next round.

This **closes OPEN_ITEMS 10**, which recorded the old rule as the one place a borrower could
lose a Noun while actively trying to pay.

---

#### SEC-LN-002 — the bounty must survive a drained pool

**VALID, and sharper than it looks.** A protocol whose pool is empty is one with bad loans
outstanding — which is the worst possible moment for searchers to lose interest in seizing
collateral. The old bounty came out of `poolBalance` and was capped at it, so the incentive
evaporated exactly when it was needed.

**`bountyReserve` is a separate, non-withdrawable-by-accident buffer.** It pays first;
`poolBalance` only tops up a shortfall. `withdrawPool` cannot touch it — asserted by
`test_withdrawPoolCannotDrainTheBountyReserve`, which drains the entire pool and shows the
buffer still there — and `recoverExcess` now excludes both balances.

Emptying the buffer is still possible, through the separately-named
`withdrawBountyReserve`. That is deliberate: stopping paying liquidators should be an explicit
decision, never a side effect of pulling lending capital back out.

**And the degenerate case still works.** With neither pool nor buffer, `liquidate` pays a zero
bounty rather than reverting — collateral must always be seizable, even when there is nothing
left to reward it with.

Not funded from FeeSplitter directly, as the finding offered as an alternative: fees flow
FeeSplitter → Pot → rounds, and diverting them would need a new push path into this contract.
Topping the buffer up is an ops action, recorded in LAUNCH_CONFIG.

---

#### SEC-LN-001 — `maxPrincipal` vs a crashing floor

**ACCEPTED with process, no code change — and we agree with the reasoning as stated.** An
on-chain NFT floor oracle is more manipulable than the risk it solves; the same argument
already settled the Anvil parity question. It stays a multisig parameter reviewed against the
observed floor.

**The short terms genuinely help**, and it is worth saying why rather than just noting it: an
underwater position on a 7-day term is resolved within ten and a half days of being taken,
against thirty-seven on the old shortest term. The maximum time the protocol can be exposed to
a stale `maxPrincipal` fell by roughly two thirds as a side effect of the term rework.

Recorded in OPEN_ITEMS 11 with a keeper-alert recommendation rather than a contract change.

---

#### SEC-LN-004 — custodian de-registration mid-loan

**COVERED — but NOT by the fix the finding assumes, and that distinction matters.**

The finding cross-references "the round-open snapshot fix" in ChipActivation. **No such fix
exists.** SEC-ACT-001 was triaged as PARTIAL and the snapshot-at-open change was explicitly
*not* made: it would require enumerating every activated Noun at `openRound`, and there is no
such enumeration (ASSUMPTIONS A-10) — that absence is why `contributeWeights` takes a
caller-supplied list in the first place.

**The protection is real but comes from somewhere else.** Weight is snapshotted when it is
*contributed*, not read at settlement: `ChipRounds` calls `activation()` in exactly one place,
`contributeWeights`, and writes the result into the ledger. So a mid-loan de-registration
cannot strip a borrower of a round whose weight is already booked
(`test_deregisteringAfterWeightsAreBookedCannotStripTheBorrower`).

The residual is identical to SEC-ACT-001's: the window between `openRound` and
`contributeWeights`, at most two hours, costing at most one round, recoverable inside the same
window because a zero-scored token is never marked counted. Same exposure, same reasoning,
same three tests — this is one finding seen from two contracts, not two findings.

**Flagged rather than quietly accepted** because a reviewer marking SEC-LN-004 closed on the
strength of a fix that was never written would carry a false belief into the next batch.

---

### External review — Bankr, batch 4: ChipActivation.sol

Against `launch-candidate-5`.

**External validation, recorded because it matters as much as the findings:** every attack on
the custodian trust model came back structurally safe. The bound stated in
`IActivationCustodian` — that a custodian can only speak for tokens `ownerOf` says it holds —
held under review. That is the newest authorization logic in the repo and the thing
`REVIEW_PACKAGE.md` §3 asked reviewers to hit first, so an independent "no finding" there is
the single most useful result in this batch.

| ID | Finding | Theirs | Ours (capped / uncapped) | Verdict | Disposition |
|---|---|---|---|---|---|
| SEC-ACT-001 | Custodian de-registration zeroes borrowers mid-round | High | **Low / Low** | **PARTIAL** | Premise refined; **exposure documented + tested**, fix disputed |
| SEC-ACT-002 | Retroactive revival on repurchase | Medium | Info | **ACKNOWLEDGED** | **Intended tokenomics**, documented + pinned |
| SEC-ACT-003 | Early-adopter upgrade discount | Low | Info | **ACKNOWLEDGED** | **Intended incentive**, documented + pinned |
| SEC-ACT-004 | Instant custodian whitelist | Low | Low / Low | **VALID, bounded** | **Documented**, deliberately not timelocked |

---

#### SEC-ACT-001 — de-registration mid-round

**PARTIAL. The conclusion is much smaller than the finding, and the proposed fix is not
implementable in this design.**

**Round scoring already snapshots — AT CONTRIBUTION TIME, not at round open.** The
distinction matters and is easy to blur: there is no open-snapshot anywhere in this system and
there cannot be (see below). `ChipRounds` calls `activationSource.activation` in
exactly one place — `contributeWeights` — and writes the result into the ledger.
`settleStock` and `finalizeRound` never touch the activation source at all. So the premise
"reads live at settle" is wrong, and **once a borrower's weight is booked, pulling the
custodian cannot reach it**: not mid-round, not after settlement, not ever
(`test_deregisteringAfterWeightsAreBookedCannotStripTheBorrower`).

**"Snapshot at round OPEN" cannot be built.** It would require enumerating every activated
Noun on chain at `openRound`, and there is no such enumeration — ASSUMPTIONS **A-10**. That
absence is why `contributeWeights` is a caller-supplied, batched list in the first place; it
shapes the whole design. At `openRound` the round knows nothing about any Noun, so there is
nothing to snapshot.

**The real exposure is one window, and it is a delay rather than a loss.** If a custodian is
de-registered between `openRound` and `contributeWeights` — at most the 2-hour accumulation
window — a not-yet-booked borrower scores zero for that round. They keep the Noun, the loan,
the chip record, and earn again the moment the custodian is restored, with no action of their
own (`test_deregisteringBeforeWeightsAreBookedCostsThatRoundOnly`).

**And it is recoverable inside the window.** `contributeWeights` sets `counted[...]` only
after the weight check passes, so a token that scored zero is never marked counted and can
simply be contributed again once the custodian is back
(`test_aZeroScoredNounCanBeReContributedInTheSameWindow`). That reduces the claim from "loses
a round" to "loses a round only if nobody notices for two hours".

**Both fallbacks rejected, with reasons:**

- **Timelocking `setCustodian(false)` defeats its purpose.** It is the emergency stop for a
  custodian discovered to be lying. A 48-hour delay means a hostile custodian keeps
  misdirecting rewards for two days — trading a *bounded, recoverable one-round delay* for an
  *unbounded live misdirection*. Strictly worse.
- **Blocking it during an active round couples the wrong things.** `ChipActivation` does not
  know rounds exist, and it should not: the activation vault depending on the rounds engine
  inverts the dependency the whole `IActivationSource` seam was built to keep one-way. It
  would also mean the emergency stop is unavailable exactly when a round is running, which is
  when it is most likely to be needed.

Documented and tested rather than fixed. If a reviewer disagrees, the argument to beat is the
dependency inversion, not the exposure size.

---

#### SEC-ACT-002 — free revival on repurchase

**ACKNOWLEDGED as intended tokenomics. Documented and pinned by tests.**

**The compromise cannot be implemented cleanly.** Revival is a *read-time* property — an
activation is live whenever the effective owner matches the recorded one — so there is no
transaction at revival time in which to charge a top-up. Making one requires either:

- **Comparing stored `costPaid` against the current tier cost at read time.** This would
  deactivate **every continuously-holding user** the moment the table rose, not just
  repurchasers. Far worse than the thing it fixes.
- **Marking the activation dead on transfer**, which needs a hook the collection does not
  give us. The absence of that hook is the entire reason the reset is computed rather than
  stored — it is the design, not an oversight.

**The exploit is bounded to absurdity.** To dodge a price rise you must sell your own Noun on
the open market and buy that exact token back, paying marketplace fees and taking the risk it
does not return. Nobody does that to save a chip top-up. And revival is bound to the original
activator, so a buyer never inherits a tier — the property is loyalty, not a transferable
asset (`test_intended_revivalNeverTransfersToABuyer`).

---

#### SEC-ACT-003 — early-adopter upgrade discount

**ACKNOWLEDGED as a deliberate incentive.** `upgrade` charges
`cost[newTier] - cost[currentTier]` from the **current** table, so someone who activated
before a price rise is credited the new lower tier rather than what they actually paid.
Measured in `test_intended_upgradingAfterAPriceRiseCreditsTheCurrentLowerTier`: after a 2x
rise, an early tier-0 holder reaches tier 4 for 7,800 where a newcomer pays 8,000.

Kept because the alternative is backwards. Crediting the amount actually paid would require
storing a per-activation cost and would charge early adopters **more** to upgrade than
latecomers — penalising exactly the behaviour the tier ladder exists to reward. Documented in
AUDIT_BRIEF §5.

---

#### SEC-ACT-004 — instant custodian whitelist

**VALID and bounded. Documented; deliberately not timelocked.**

We agree with the reviewer's own severity reasoning: the blast radius is limited to tokens
physically held by that custodian, and to hold any, users must have deposited into a contract
they chose to trust. Registering a hostile custodian requires the multisig, which is already
trusted for strictly more.

**Not timelocked, and the reason is specific to this codebase rather than general.**
`ChipActivation.setCustodian(nounLoans, true)` is already the single most forgettable call in
the deploy sequence — it is the one wiring step that **fails silently**, carried as a red
can't-miss block in `LAUNCH_CONFIG` §7 and asserted by
`test_theCustodianWireIsTheOneMistakeThatFailsSilently`. Splitting it into two transactions 48
hours apart would make the one step that already fails without a revert harder to complete,
and would buy a delay against an attack that needs a compromised multisig *and* users
depositing into the hostile contract afterwards. That trade is not worth it.

---

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
| `launch-candidate-5` | SEC-FEE-001 … 004 | Superseded |
| `launch-candidate-6` | SEC-ACT-001 … 004 — documentation and tests; **no contract logic changed** | Superseded |
| `launch-candidate-7` | Short term ladder 7/14/30/90/180 and derived grace — product change, not a finding | Superseded |
| `launch-candidate-8` | SEC-LN-002, SEC-LN-003; SEC-LN-001 and SEC-LN-004 documented | Superseded |
| `launch-candidate-9` | Contribution-time snapshot described accurately everywhere; Lils stop being Furnace fuel | Superseded |
| `launch-candidate-10` | **Batch 6: H-01, H-02, M-01, M-02, M-03, L-01–L-04.** SEC-POT-002 finally closed on POLTreasury too | Superseded |
| `launch-candidate-11` | **Batch 7 (Anvil): M-1, M-2, L-1, L-2, L-3**; I-1 documented | Superseded |
| `launch-candidate-12` | Full B20 registry config with real feeds; Chiplets is a plain ERC-721. No `src/` logic change | Superseded |
| `launch-candidate-13` | **Batch 8 (ClaimRouter): SEC-RTR-001, -002, -004**; -003 documented. **Core audit complete** | **Current** |

The review package needed its own tag because it was written after the code was frozen, and
tags in this repo are never moved. A reviewer checks out `review-1`; the contracts they read
are `launch-candidate-1` byte for byte.
