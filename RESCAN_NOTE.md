# RESCAN_NOTE.md — targeted re-review for `launch-candidate-21`

For Bankr. **This is the last audit step before deploy.**

Scope is **five contracts**, and it is deliberately not the same shape as the last re-scan:
two of the five have not changed a single byte. They are in scope because their *environment*
changed underneath them, which is the harder thing to catch.

| Contract | Code changed since `-19`? | Why it is in scope |
|---|---|---|
| `ChipBurner.sol` | **NEW — never reviewed by anyone** | Becomes the **owner of the $CHIP token**. Largest single authority in the system |
| `ChipActivation.sol` | yes, +56 −19 | $CHIP burns re-routed to an immutable target |
| `ChipRounds.sol` | yes, +37 −17 | Same re-route, a public constant removed, **and its Slipstream branch went from dead code to the live buy path** |
| `StockRegistry.sol` | **no — byte-identical since `-14`** | Never externally reviewed (OPEN_ITEMS 25a), and it is now what stands between a correct venue config and a dead one |
| `POLTreasury.sol` | **no — byte-identical since `-14`** | Now sits on a *different Aerodrome factory* from the stock buys |

### Which ref to check out

**Check out `rescan-21`.** It is this note, the regenerated flattened sources and the Slither
artifacts, sitting on top of `launch-candidate-21`.

**`launch-candidate-21` is the code under review and it has not moved.** `rescan-21` adds only
documents and generated artifacts — `src/` is **byte-identical** between the two, and the first
command below proves it rather than asking you to take it on trust.

```bash
git checkout rescan-21

git diff launch-candidate-21 rescan-21 -- src/                      # EMPTY. The code is the tag's
git diff launch-candidate-19 launch-candidate-21 -- src/            # the whole code delta
git diff launch-candidate-19 launch-candidate-21 -- src/ChipRounds.sol
git diff launch-candidate-19 launch-candidate-21 -- src/activation/ChipActivation.sol

# the two that did NOT change, to confirm it rather than take it on trust:
git diff launch-candidate-14 launch-candidate-21 -- src/StockRegistry.sol   # empty
git diff launch-candidate-14 launch-candidate-21 -- src/POLTreasury.sol     # empty

forge test        # 791 tests, 49 suites, 0 failures (731 unit + 60 fork against live Base)
```

Fork suites need `BASE_RPC_URL`. They are not optional here — the venue evidence in this note
is produced by them, not asserted by it.

**Flattened sources** for all five are in `review/flattened/`. Regenerated at this tag and
verified: each compiles standalone under the pinned settings (solc 0.8.24, cancun, optimizer
200) and its **executable runtime code is byte-for-byte identical** to the in-repo build. Only
the 53-byte CBOR metadata trailer differs, which it must — it encodes the source path.

**The code delta contains a fourth file, `Furnace.sol` (+36 −9), which is NOT in this scope.**
It received the identical $CHIP burn re-route as the other two. It sits outside the money path
and outside the original eleven-contract audit, so it is excluded here — but if you would
rather see the burn change in all three places at once, it is the same diff.

---

## 1. `ChipBurner.sol` — NEW. Read this first.

**It becomes the owner of the $CHIP token.** That is the highest-authority thing in this
system, and it has never been reviewed.

**Why it exists.** The premise of every prior document was that $CHIP could never be truly
burned — Bankr's Doppler token exposes no `burn`, so every burn was a `transfer` to `0xdead`:
unreachable but still inside `totalSupply`. **That premise was wrong, and the correction is the
reason this contract exists.** The token has no *public* `burn`; it has an **owner-gated** one.
"No public burn" had been read as "no burn". A contract we own can call it.

**The trap it is designed around.** `transferOwnership` on the token moves **every** `onlyOwner`
power, not just `burn` — `updateTokenURI`, `updateMintRate`, `lockPool`/`unlockPool`,
`mintInflation`, and `transferOwnership` itself. A burn-only sink would therefore be a one-way
door: the token's metadata could never be updated again and ownership could never be moved,
by anyone, forever. So this is an owner **wrapper**, not a sink.

**Two roles, asymmetric on purpose:**
- **Anyone** may call `burnAll()`. It can only ever destroy this contract's own balance.
- **The multisig** may call `updateTokenUri` and `transferTokenOwnership`. Neither can move a
  single $CHIP.

**What to attack:**
- **Can any path move $CHIP out of the Burner without destroying it?** The claim is no: there is
  no `transfer`, no sweep, no rescue, and deliberately no generic `call(bytes)`. Not even the
  multisig can move it. If that claim is false anywhere, it is the finding.
- **`burnAll` verifies by supply, not by return value** — it reads `totalSupply` before and
  after and reverts unless it fell. Can a token satisfy that check without really burning? This
  is what makes `totalBurned` publishable, so it matters more than it looks.
- **`mintInflation` is deliberately not exposed.** A permissionless burner that can also mint is
  a contradiction, and "gated behind the multisig with an event" still means the capability
  exists. Is leaving it out actually safe given `transferTokenOwnership` is the escape hatch —
  or does the escape hatch reintroduce what the omission removed?
- **The three token signatures are encoded by string** (`burn(uint256)`,
  `updateTokenURI(string)`, `transferOwnership(address)`). A mismatch is not discovered until
  the first burn, by which point the token is already owned by a contract that cannot drive it.
  **The ordering is the risk, not the code.** LAUNCH_CONFIG §6.6 carries the pre-hand-off ABI
  check; tell us if that check is insufficient.

## 2. `ChipActivation.sol` and `ChipRounds.sol` — the burn re-route

All **five** $CHIP burn paths moved together, in one change: activate, activate-flat, upgrade
tier (all `ChipActivation`), forge (`Furnace`), and the split-change fee (`ChipRounds`).

Destination is `chipBurnTarget` — an **immutable** constructor argument on all three, with a
zero-check and **no setter anywhere**.

**Splitting the paths was the failure mode we were explicitly avoiding.** Routing one through
the Burner and leaving four at `0xdead` would have split the accounting and made
`chipBurnedToDead()` silently incomplete — worse than the honest limitation it replaced.

**`0xdead` is still correct, for NFTs, and the two are separate fields.** `BURN_ADDRESS` remains
`0xdead` on `ChipActivation` and `Furnace`: it is where an NFT goes when its collection exposes
no `burn` of its own. **An NFT sent to the Burner would be stranded forever** — no ERC-721
surface, no rescue, no owner able to move it. `test/BurnRouting.t.sol` exists to keep the two
apart.

**`ChipRounds.BURN_ADDRESS` was removed.** `ChipRounds` burns no NFTs, so after the re-route it
was a public constant that nothing used and that named the wrong destination for the
split-change fee. Removed rather than left to rot. **This is an ABI change** on a contract you
have already seen; flagging it so it is not read as an accident.

**What to attack:**
- Can the two burn destinations be confused — an NFT reaching `chipBurnTarget`, or $CHIP
  reaching `0xdead` — through any path?
- All five sites are **delta-verified**: balance of the target read before and after, reverting
  `ChipBurnShortfall` if less arrived than was owed. Can a token defeat that?
- `chipBurnedToDead()` now sums **two** balances (`0xdead` + `chipBurnTarget`), and returns the
  single balance when they are the same address. Can it double-count?
- `effectiveChipSupply()` counts $CHIP queued at the Burner as already gone. Is that honest
  across the moment `burnAll()` runs, in both directions?

## 3. 🔴 `ChipRounds.sol` — the Slipstream branch is now the LIVE buy path

**This is the change most likely to produce a finding, and it is not visible in the diff.**

When you last saw `ChipRounds`, its `Venue.Slipstream` branch was effectively dead: every B20
stock registered as `Venue.UniswapV3`, on the strength of a sweep that found no Aerodrome CL
pool for any of them. **That sweep was run against one Aerodrome CL factory and there are two.**
All thirteen B20 pools are on the other one, `0xf8f2eB…061Ef`, at tick spacing 10, and they are
7–16x deeper than the Uniswap pools we were going to use. ASSUMPTIONS A-22 carries the
correction; A-16 carries the original error with a supersede header, kept deliberately.

So at `launch-candidate-21`: **ten of thirteen tickers register as `Venue.Slipstream` and the
Slipstream branch is the live buy path for all of them.** The Uniswap branch is now the one that
goes unexercised.

### The finding we are handing you rather than waiting for you to find

**`ChipRounds.setRouters(uni, slip)` performs no validation of any kind.** No zero check, and no
`factory()` check.

```solidity
function setRouters(address uni, address slip) external onlyOwner {
    uniswapRouter = IUniswapV3SwapRouter(uni);
    slipstreamRouter = ISlipstreamSwapRouter(slip);
    ...
}
```

Compare `ConversionRoutes._setRoute`, which — as the fix for **SEC-POT-001** — requires
`router.factory() == uniswapV3Factory` and rejects the misconfiguration at configuration time.
`ChipRounds` never got the equivalent guard, because when SEC-POT-001 was triaged the Slipstream
path was not being used. **It is being used now.** Point `slip` at the wrong router and every
stock buy reverts, on every round, for every ticker — and the symptom reads like a depth problem
rather than a wiring one.

**Please treat this as in scope and tell us the right shape of fix.** The obvious one is to
mirror `_setRoute`, but `ChipRounds` holds no factory immutable to check against, and the two
routers belong to two different factories, so it is not a one-line copy.

### Do not conflate this with SEC-POT-001

**SEC-POT-001's disposition does not change and its guard is untouched.** The **Pot** still
converts through Uniswap v3 only; `ConversionRoutes` imports no Slipstream interface and has no
dormant branch. What is now live is a **different path in a different contract** doing a
different job — stock buys in `ChipRounds`, which SEC-POT-001 never covered. TRIAGE carries this
distinction inline under that finding.

**What to attack:**
- The 8-field Slipstream `exactInputSingle` shape `_buy` encodes, against a real factory-B pool.
  We prove it fills in `test/fork/FactoryBRouter.t.sol` — $10,000 USDC in, 43.129 NVDA out, an
  implied $231 against a $229.96 Chainlink mark — and prove the factory-A router reverts on the
  identical call. Is the shape right in every case, not just that one?
- `_minOutFor` is the only per-buy protection and it is all-or-nothing. Does it behave the same
  on the Slipstream path as on the Uniswap one?
- Is there anywhere that still assumes stocks are on Uniswap, or that one router serves both
  venues?

## 4. `StockRegistry.sol` — unchanged code, newly load-bearing

**Byte-identical since `launch-candidate-14`, and it has never had an external review**
(OPEN_ITEMS 25a). It was already the largest un-reviewed surface. The venue flip makes it more
so.

`_setVenue` is now what stands between a correct config and a dead one. For a Slipstream venue
it requires `tickSpacing != 0` and verifies
`ISlipstreamFactory(slipstreamFactory).getPool(token, quoteToken, tickSpacing) == pool`.

🔴 **`slipstreamFactory` is `immutable`.** A registry deployed against the wrong Aerodrome
factory cannot register a single B20 stock as Slipstream and must be redeployed. It does fail
loudly — `PoolNotFoundInFactory` — and `test_aFactoryARegistryCannotRegisterTheB20Venue` pins
that. This is now the one deploy argument in the system that cannot be corrected after the fact.

**What to attack:**
- Can a pool be registered that the factory does not actually derive? Can the check be passed
  with a pool from the *other* factory?
- `poolLiquidityUsd` is venue-agnostic — it reads balances. Is that still right for a
  concentrated Slipstream pool, where headline TVL across both sides overstates tradeable depth
  near spot by more than it does on Uniswap?
- The depth gate is the input the launch decision is made from. Ten of thirteen now clear
  $25,000, the smallest by more than four times, where only two cleared before. Is anything
  about that gate weaker than it looks?

## 5. `POLTreasury.sol` — unchanged code, now on a different factory from the buys

**Byte-identical since `launch-candidate-14`.** In scope for one reason: **POL positions and
stock buys now sit on different Aerodrome CL factories.**

`POLTreasury` derives its factory from the Slipstream NPM, which reports factory **A**
(`0x5e7BB1…809A`). Stock buys are on factory **B**. We believe this is correct rather than a
mismatch to fix — they are different books:

- POL is protocol-owned liquidity in WETH/USDC-shaped pairs, which exist on factory A and are
  what the NPM and the Voter's gauges know about.
- Stock buys are one-shot swaps against B20 pools, which exist only on factory B.
- Nothing reads across: `POLTreasury` never consults `StockRegistry`, and `ChipRounds._buy`
  never touches the NPM.

**What to attack — this is the question we most want answered:**
- **Is there anywhere that assumes one Aerodrome factory serves both?** That is the failure this
  split would produce, and it would be quiet.
- Gauge derivation and `voter.gauges(pool) == gauge` (batch 6 H-01) are factory-A facts. Does
  anything in the POL path degrade if a factory-B pool address is ever handed to it?
- If a B20 stock were ever added as a **POL asset**, it would need a factory-A Slipstream pool,
  and its pools are on factory B. Does that path fail closed?

---

## 6. Slither — the delta, and one finding we want your verdict on

Slither 0.11.6 was re-run at both ends so the delta isolates *this* change rather than
everything since the artifacts were last generated. `review/slither-raw.md` and
`review/slither-findings.txt` are the `-21` run.

> The 168-finding baseline triaged in `TRIAGE.md` is from `f0d6421` (2026-09-03) and is **seven
> tags stale** — diffing against it conflates the impact trim, the cap removal, the flat-rate
> activation and the Furnace true-burn work with the change under review. So `-19` was re-run
> from a worktree to get a like-for-like baseline. Against `f0d6421` the total is +44; against
> `-19` it is **+6**, and that +6 is what this change actually did.

| | `-19` | `-21` | delta |
|---|---:|---:|---:|
| **TOTAL** | 206 | 212 | **+6** |
| `reentrancy-events` (Low) | 2 | 5 | +3 |
| `incorrect-equality` (Medium) | 12 | 13 | +1 |
| `low-level-calls` (Info) | 24 | 25 | +1 |
| `reentrancy-benign` (Low) | 8 | 9 | +1 |
| every other detector | — | — | **0** |

**All seven new findings are in `ChipBurner.sol`. Not one is in `ChipRounds` or
`ChipActivation`** — the burn re-route added no new static-analysis surface, which is the result
we wanted from a change that touched five money-adjacent call sites.

Our first-pass triage, for you to overturn:

| Finding | Ours | Reasoning |
|---|---|---|
| `incorrect-equality` — `burnAll()` | **Info** | It is `if (balance == 0) revert NothingToBurn()`. A zero guard, not a value comparison driving logic |
| `low-level-calls` — `_passThrough` | **Info, deliberate** | It bubbles the token's revert reason instead of swallowing it. Documented, and deliberately **not** a generic `execute(bytes)` |
| `reentrancy-events` x3 | **Info** | Events after external calls in `burnAll`, `updateTokenUri`, `transferTokenOwnership` |
| `pragma` | **Pre-existing** | Present at `-19` too; the text shifts because the version list changed |
| `reentrancy-benign` — `burnAll()` | **⚠️ see below — we do not think this one is benign** | |

### 🔴 `burnAll()` is not `nonReentrant`, and `totalBurned` spans the external call

```solidity
uint256 supplyBefore = chipToken.totalSupply();
IChipOwnable(address(chipToken)).burn(balance);   // <-- external, untrusted
uint256 supplyAfter  = chipToken.totalSupply();
burned = supplyBefore - supplyAfter;
totalBurned += burned;
```

`ChipBurner` is `Ownable2Step` only — **there is no `ReentrancyGuard`**. If $CHIP's `burn` can
re-enter `burnAll`, the inner call burns whatever balance it sees and credits `totalBurned`;
the outer call then computes `burned` from a supply delta that spans **both** burns and credits
it again. `totalBurned` and `burnCount` come out wrong.

**No $CHIP can be stolen or stranded by this** — the tokens are destroyed either way, and there
is still no path that moves $CHIP out of this contract. What breaks is the **published number**,
which is the one thing this contract exists to make trustworthy. The site displays it.

**Why we are flagging it rather than dismissing it.** For a stock Doppler ERC-20 with no
transfer hooks this is not reachable, and Slither's "benign" is defensible on that basis. But
the contract's entire design premise is *do not trust the token*: it verifies the burn by
reading `totalSupply` rather than believing a return value, precisely because a token could
lie. Relying on that same untrusted token not to re-enter is inconsistent with its own threat
model. A `nonReentrant` on `burnAll` is a few hundred gas on a permissionless keeper call.

**We have not applied a fix** — the contract is frozen at `launch-candidate-21` for this
re-scan. Tell us whether you want it, and we will land it as `-22` with the guard and a test
that drives a re-entrant token through it.

---

## What did NOT change, and why that is worth knowing

**No prior finding is reopened.** SEC-POT-001, EXT-R-L-1 and SEC-POT-002 all stand as triaged;
the update under SEC-POT-001 narrows a citation, it does not change a disposition.

**The weight and payout arithmetic was not touched.** Neither was `ChipClaims`, `Pot`,
`FeeSplitter`, `ClaimRouter`, `NounLoans` or `Anvil` — all byte-identical.

**The Furnace recipe numbers are now settled** (25 Chiplets for a Based Noun, 50 for a
DarkNOUN), but they are constructor arguments, not code.

**$CHIP is still not a contract in this repo**, and neither is Chiplets. We hold only their
addresses. The Burner assumes exactly three signatures on $CHIP and nothing else.

## Still open, and not introduced by these changes

- **`ChipClaims` lows `EXT-C-L-1`…`-L-4` were never received** (OPEN_ITEMS 25b) and have never
  been read.
- **The Anvil sell side is not built** and ships after the audit.
- **`maxPrincipal` vs Anvil parity is operational and unenforced** (OPEN_ITEMS 11).
