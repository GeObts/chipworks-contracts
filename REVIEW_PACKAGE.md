# REVIEW_PACKAGE.md

**Chipworks — security review package. Check out the latest `launch-candidate-*` tag.**

Self-contained. Everything you need to check out, build, run, and judge is here; the deep
brief is `AUDIT_BRIEF.md` and you should read it before forming an opinion, but you do not
need anything outside this repo.

Not audited. Not deployed. Launch caps are in effect — see §6, which changes how severity
should be read.

---

## 1. Check out and run

```bash
git clone <repo> chipworks-contracts && cd chipworks-contracts
git checkout launch-candidate-14
git submodule update --init --recursive     # forge-std, openzeppelin-contracts

cp .env.example .env                        # then set BASE_RPC_URL
forge build
forge test                                  # everything: 593 tests
```

### One tag now, not two

`review-1` was a separate tag because this package was written after `launch-candidate-1` was
frozen, and tags here are never moved. **That split is retired.** Every `launch-candidate-*`
tag from `-3` onwards carries the review package with it — `REVIEW_PACKAGE.md`, `TRIAGE.md`
and regenerated `review/flattened/` sources — so the current candidate is the only thing to
check out.

**Reference `launch-candidate-14`.** It is the deployable tag and the only one carrying every fix — `launch-candidate-13` predates the Furnace batch. The audit-status summary, the full tally and the two remaining gaps are at the top of `TRIAGE.md`; **`StockRegistry` has never been externally reviewed and is the largest un-reviewed surface here.** Review is iterative rather than a single frozen pass:
findings arrive in batches, each batch is triaged in `TRIAGE.md` and lands in the next
candidate, and the tag numbering is honest history — no tag is ever moved or deleted, so you
can always diff the tree you read against the tree that shipped:

```bash
git diff launch-candidate-13 launch-candidate-14 -- src/
```

`review-1` and `launch-candidate-1` still exist and still resolve; they are simply eight
batches out of date.

**Toolchain:** Foundry, Solidity **0.8.24**, EVM **cancun**, OpenZeppelin **v5.1.0**,
optimizer on at **200 runs**, **no `via_ir`**. Pinned in `foundry.toml`; do not override them,
because the code-size guard in §5 is calibrated against exactly this configuration.

### What needs an RPC, and what does not

```bash
forge test --no-match-contract Fork          # 553 tests, NO RPC NEEDED
forge test --match-path "test/fork/*" -j 1   # 51 tests against a live Base mainnet fork
```

**`-j 1` on the fork paths is not optional advice.** Fork tests are RPC-hungry and running
them in parallel against a rate-limited endpoint produces spurious `429`s that surface as
EVM errors, not as network errors — they look exactly like real failures. Either serialise
with `-j 1` or use a paid endpoint. `BASE_RPC_URL` must be a Base **mainnet archive** node.

**Fork tests run against the latest block, not a pinned one**, so live prices and pool depth
move between runs. Assertions are written to be property-based or driven from mocked feeds
rather than to expect a particular spread. If you want bit-for-bit reproducibility, pin a
block in the `vm.createSelectFork` calls under `test/fork/`.

### Useful subsets

```bash
forge test --match-contract Invariant        # 4 stateful invariants, 128k calls each, ~90s
forge test --match-contract CodeSizeTest -vv # the size guard, prints every runtime size
forge test --match-path "test/activation/*"  # the activation vault + the migration parity proof
forge test --match-path "test/loans/*"       # lending + the custody integration
forge test --match-path "test/anvil/*"       # the Anvil
forge test --match-path "test/b20/*"         # B20 hardening: multiplier, frozen feed, identity
forge test --match-contract DeployOrderTest  # "a half-wired deploy cannot take money", per step
```

### Flattened sources, for tooling

`review/flattened/` holds one self-contained file per deployable contract, for automated
reviewers that want a single file. **Generated, not authoritative** — read `src/` for
anything that matters.

```bash
# regenerate
forge flatten src/ChipRounds.sol --output review/flattened/ChipRounds.flat.sol   # etc.
```

Verified: all eleven compile standalone under the same solc settings, and produce **byte-for-byte
identical runtime sizes** to the in-repo build (compare `forge build --sizes` against §2).

---

## 2. The eleven contracts

Grouped by how much a bug in each one costs. **Review time should be spent roughly in this
order.**

`ClutchVaultAdapter` (76 LOC) is in `src/adapters/` and is **retired and not deployed** —
skip it. `base/ConversionRoutes.sol` (163 LOC) is abstract, inherited by Pot and POLTreasury,
and is reviewed as part of both.

### Tier 1 — the money path

Holds or moves user funds. A bug here loses money directly.

| Contract | LOC | Bytes | What it does |
|---|---:|---:|---|
| `ChipRounds.sol` | 532 | 20,834 | The engine. Opens rounds, scores weights, splits budget, buys stock, sends the POL holdback. Holds quote token only while a round is in flight. |
| `ChipClaims.sol` | 333 | 12,879 | The ledger. **Every token a holder is owed lives here and nowhere else.** Credits, claim windows, expiry, sweeps. |
| `Pot.sol` | 103 | 9,042 | Holds the round budget; converts inflows to USDC under a Chainlink bound. |
| `FeeSplitter.sol` | 138 | 4,782 | Three-way split of every inflow: Pot / ops / POL. Pull, not push. |

### Tier 2 — authorization and custody

Holds no user rewards, but **decides who owns what**, or holds protocol assets. A bug here
misdirects money rather than losing it — which can be worse, because it looks correct.

| Contract | LOC | Bytes | What it does |
|---|---:|---:|---|
| `activation/ChipActivation.sol` | 264 | 10,023 | Our own soft-staking vault. Burn $CHIP to activate a Noun at a tier; lazy atomic reset; **the custodian registry**. |
| `loans/NounLoans.sol` | 363 | 13,425 | Borrow $CHIP against a chipped Noun. Holds collateral NFTs and the lending pool. The first registered custodian. |
| `POLTreasury.sol` | 785 | 23,032 | Slipstream POL positions, gauge staking, income routing. Holds protocol assets, never user credits. **The largest contract and the tightest on size (968 bytes spare). Start here** — external review batch 6 found two HIGHs in it, both drains a leaked hot key could execute in one block, and the fix is the newest and least-reviewed code in the repo. |

### Tier 3 — isolated

Cannot reach a credit, a round or the ledger. Separately scopeable; drop any of them if time
is short.

| Contract | LOC | Bytes | What it does |
|---|---:|---:|---|
| `anvil/Anvil.sol` | 340 | 10,075 | The shop. FIFO shelf of Nouns at a fixed ETH price, plus a +25% snipe. **Takes public money**, so review it before the other two here. The shelf's slot bookkeeping was rewritten in `launch-candidate-11` (batch 7 M-1/M-2); the invariant to attack is one live slot per token. |
| `furnace/Furnace.sol` | 532 | 9,324 | Burn fuel NFTs + $CHIP to forge a Based or Dark Noun from deposited stock. Fuel is **Chiplets, a plain ERC-721**. Outside the money path. |
| `StockRegistry.sol` | 232 | 8,971 | Which stocks are buyable, where, and the depth gate. Holds nothing. |
| `ClaimRouter.sol` | 264 | 3309 | Batches many `ChipClaims.claimFor` calls into one transaction. **Never holds anything** — `claimFor` credits its `owner` argument, never `msg.sender`. Batch capped at 100; the sweep is multisig-only since batch 8. |

**Totals:** ~2,794 LOC across the eleven; ~3,030 including the retired adapter and the shared
conversion base. 593 tests, 40 of them against a live Base mainnet fork.

---

## 3. The deep brief

**`AUDIT_BRIEF.md` is the document to read next**, and §4 of it — "Attack this first" — is
ordered by where findings are most likely. Its own top three, in order:

1. **§4.5a, the custodian registry** — new authorization logic, and the only place where an
   external contract's answer decides who owns a Noun.
2. **§4.2, the claim window gate** — every other bug class loses or misallocates money; a bug
   in this one *locks* it.
3. **§4.0, the ChipRounds/ChipClaims split** — the engine must not be able to extract value
   from the ledger by any path but `claim` / `sweepExpired` / `recoverExcess`.

Supporting documents, in the order they are worth reading:

| Document | What it is |
|---|---|
| `AUDIT_BRIEF.md` | Contract-by-contract attack guide, invariants, deliberate design decisions |
| `OPEN_ITEMS.md` | Everything unresolved or accepted, with reasoning — see §5 below |
| `ASSUMPTIONS.md` | Every guess about a contract we do not control (Part 1 is historical) |
| `B20_DOCS.md` | Base's own tokenized-stock documentation, verbatim. The source A-13/A-15/A-18 are checked against |
| `LAUNCH_CONFIG.md` | The launch runbook and the locked parameters, including the caps in §6 |
| `TRIAGE.md` | How findings are processed, and the completed static-analysis triage |

---

## 4. Invariants claimed

Twenty-two. The first three are enforced by stateful invariant runs
(`test/ChipRewards.invariant.t.sol`, 128,000 calls each); the rest by targeted tests named
after them. **Stated as things you should try to break.**

| # | Invariant |
|---:|---|
| 1 | ChipRewards is always solvent, per token: `balanceOf(token) >= totalOwed[token]` after any sequence of rounds, claims, sweeps, rescues, freezes and time travel. |
| 2 | Quote-token commitment is always backed: `balanceOf(quote) >= totalOwed[quote] + committedQuote`. |
| 3 | A frozen stock cannot corrupt a healthy one. NVDA/GOOGL accounting stays exact whatever AAPL does. |
| 4 | `recoverExcess` can never reach a user credit — booked, expired-but-unswept, or a live round's budget. |
| 5 | POLTreasury's rescue can never move a protocol asset. Exclusion-based, not arithmetic. |
| 5b | **A leaked POLTreasury `manager` key cannot move value anywhere.** No manager function has a destination argument; tokens and pools are allowlisted and derived, gauges are verified against Aerodrome's Voter, and liquidity moves only while the pool agrees with Chainlink. |
| 6 | Routing is never worse than claiming directly. Byte-identical outcomes, including when a leg is broken. |
| 7 | Every conversion is Chainlink-bounded, capped per call, and measured by balance delta. |
| 8 | Value is conserved in every split: `pot + ops + pol == amount`, dust always to the Pot. |
| 9 | A sold Noun stops earning immediately, whether or not anyone has been kicked. |
| 10 | A padded or duplicated token-id list cannot inflate anyone's share. |
| 11 | The ledger is solvent for what it owes; the engine is solvent for what it committed. Two separate statements. |
| 12 | Every finalized round gets at least 3 full claim windows before it expires, under every accepted configuration. |
| 13 | Nothing still claimable is ever swept. Claim and sweep eligibility are disjoint in time. |
| 14 | A sold Noun is inactive in the **same block**, with no keeper. No stored `active` flag exists to go stale. |
| 15 | A custodian can only speak for tokens it actually holds. |
| 16 | `ChipActivation` holds no $CHIP between transactions — 100% of every activation cost burns. |
| 17 | `NounLoans.poolBalance` never exceeds the $CHIP actually held, and collateral leaves by exactly two paths. |
| 18 | A skipped stock always carries its whole slice back to the Pot. No skip ever costs a cent. |
| 19 | No contract in `src/` identifies a stock by anything but its address — enforced by a build-failing scan. |
| 20 | The Anvil never holds ETH. 100% forwarded in the same transaction; no withdraw path exists. |
| 21 | A snipe never reorders the FIFO queue; `buyNext` always returns the oldest token still shelved. |
| 22 | A Noun cannot be borrowed against unless it is actively chipped to the borrower, and the chip survives custody for the life of the loan. |

---

## 5. Open items: accepted-by-design vs genuinely open

Full reasoning for each is in `OPEN_ITEMS.md` under the numbers below. **Please do not spend
review time re-deriving the accepted ones** — but do challenge the reasoning if you think it
is wrong, because that is more valuable than re-finding them.

### Accepted by design — decided, signed off, and not going to change before launch

| # | Item | The decision |
|---|---|---|
| 10 | NounLoans refuses repayment after maturity + 7-day grace | Deliberate. A borrower who turns up late is refused and loses the Noun. The site carries the dates loudly. |
| 12 | The lending pool has exactly one depositor | Keeps solvency-between-lenders out of the contract entirely. The protocol carries 100% of default risk. |
| 13 | The claim path degrades safely rather than provably | If the ledger's balance ever drops below `totalOwed`, the last claimant cannot be paid. Contained; not preventable in code. |
| 14 | `setCustodian` is a deploy-checklist item, not a code fix | The only wiring call that fails silently. Cannot be self-registered without defeating the allowlist. |
| 15 | The Anvil ships one-directional | `sellEnabled` is a `constant false` with **no setter**. The guaranteed exit is a solvency commitment, post-audit. |
| 16 | The chip gate forecloses borrow-then-chip | Checked at borrow time and never re-checked, so a lapsed chip can never trigger a liquidation. |
| — | C-1 … C-19 in `ASSUMPTIONS.md` §3 | Nineteen design decisions an auditor may reasonably flag, each with its reasoning. |

### Genuinely open — findings here are welcome and wanted

| # | Item | Why it is still open |
|---|---|---|
| 3 | Gauge address has no on-chain verification | The manager passes it per call. A wrong gauge is an unguarded operator mistake. |
| 4 | A round stuck in `Buying` has no escape hatch | `settleStock` is permissionless and cannot revert for a frozen stock, so in practice anyone can push it along. **C-10 is the exception** and the one place failure isolation does not hold: if USDC itself policy-blocked ChipRounds, a round could not settle or finalize. |
| 5 | B20-specific behaviour is covered by mocks only | Narrowed by `test/b20/`, not closed. No amount of local testing fixes it. |
| 7 | Compound shares have no redemption path | Phase 2. Should be answered before auto-compound is marketed. |
| 8 | The claim window shortens the effective time to claim | 30-day expiry, but only four 48-hour windows — ~8 days of real opportunity. A UX problem with a contract-shaped cause. |
| 11 | `maxPrincipal` vs Anvil parity is operational, not enforced | The Anvil prices in ETH, the cap is in $CHIP. Enforcing it would import a manipulable oracle into the borrow path. |

---

## 6. Launch caps — and how to judge severity against them

**Launch caps are in effect and every one of them is a multisig setting, not a constant.**
They lift when this review completes.

| Cap | Launch value | Where |
|---|---|---|
| Round minimum | $100 | `ChipRounds.setRoundParams` |
| Round maximum | **$1,000** | `ChipRounds.setRoundParams` |
| POL holdback | 15% | `ChipRounds.setHoldbackBps` |
| NounLoans `maxPrincipal` | ~60% of the Anvil queue price, per collection | `NounLoans.setMaxPrincipal` |
| NounLoans pool | seeded from a 0.25–0.5 ETH initial buy | `NounLoans.depositPool` |
| Furnace Dark recipe | deployed but **paused** | `Furnace.setPaused(1, true)` |

### Please give severity twice

This is the one thing we would ask you to do differently from a normal engagement.

**Rate each finding against capped exposure AND against uncapped future state, and say both.**
A bug that costs at most one $1,000 round today is not a $1,000 bug — it is a bug in a system
that will run uncapped rounds once this review clears, and the caps are the *reason* the
review is happening, not a mitigation we are claiming credit for.

Concretely:

- **Do not downgrade** a finding because a cap bounds it today. Say "critical uncapped,
  bounded to $1,000 at launch settings" and let us decide.
- **Do flag** anything whose severity is *created* by the caps — a griefing vector that only
  works because rounds are small, or a rounding error that only matters at $100 minimums.
- **Do flag** anything that would become severe at a specific threshold, and name the
  threshold. "Safe under $10k rounds, unsafe above" is far more useful than a severity letter,
  because it tells us what the caps have to be.
- **A cap that is load-bearing for a security property is itself a finding.** If lifting a
  number would open a hole, that number is doing security work it was never designed for, and
  we would rather know now.

The disclosure line we ship with says: *"$CHIP's token and pool are Bankr/Doppler audited
infrastructure. Chipworks' own contracts are awaiting independent audit; launch caps are in
effect until it completes."* If your findings mean that sentence should not come down when
you finish, say so plainly.

---

## 7. Sending findings

`TRIAGE.md` describes what happens to them. In short: every finding gets a written entry with
our assessment — **including the ones we dispute, and why** — and any fix reopens the tag,
requiring a test that fails on the old code before the new tag is cut.

Please send:

- **File and line** at the candidate tag you reviewed, or a failing test.
- **A concrete failure scenario** — inputs, state, and what ends up wrong. We will try to
  reproduce it as a test before agreeing.
- **Both severities** per §6.

A finding we cannot reproduce as a test is not dismissed, but it does get recorded as
disputed with our reasoning, and we would rather argue it out than quietly drop it.
