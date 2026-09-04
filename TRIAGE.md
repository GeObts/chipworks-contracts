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
| **Severity (ours)** | **Low uncapped, Low capped** — but valid, and the fix is free |
| **Verdict** | **VALID** |
| **Disposition** | **DEFERRED to the first fix batch** — see below |

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

**Deferred, not ignored.** `launch-candidate-1` is frozen while external review runs (see
the fix rule). This lands in the first fix batch with:

- `test_depositStockIsGuardedAgainstReentrancy` — a hostile ERC-721 whose `transferFrom`
  re-enters `depositStock`, asserted to revert. **Written against the current tag first, to
  confirm it fails**, per the rule.

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
| **Disposition** | **DEFERRED to the first fix batch** |

`ChipClaims` implements every function of `IChipRewardsClaimable` — `claimFor`, `claimable`,
`isClaimOpen`, `nextWindowOpensAt` — and `ClaimRouter` calls it through that interface, but
the contract does not declare that it implements it. The compiler therefore never checks that
the two agree, which is a small but real gap: a signature drift between the ledger and the
router's expectation would compile cleanly and fail at runtime as a silently-failed leg.

Declaring the inheritance costs nothing and makes the compiler enforce what the router
already assumes. Deferred to the first fix batch only because the tag is frozen; it needs no
new test beyond the existing router suite, which would fail to compile if the signatures
diverged after the change.

---

### External review findings

*None yet — review in progress against `launch-candidate-1`.*

Entries will be added here as they arrive, in the format above, including any we dispute.

---

## Fix batches

| Tag | Contains | Status |
|---|---|---|
| `launch-candidate-1` | The frozen contract state under review | **Current. Frozen.** |
| `review-1` | Identical `src/`, plus the review package and this file | Documentation only — `git diff launch-candidate-1 review-1 -- src/` is empty |
| `launch-candidate-2` | SLI-001 (Furnace guard), SLI-005 (interface declaration), plus whatever external review returns | Not cut |

The review package needed its own tag because it was written after the code was frozen, and
tags in this repo are never moved. A reviewer checks out `review-1`; the contracts they read
are `launch-candidate-1` byte for byte.
