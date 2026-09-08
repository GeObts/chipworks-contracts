# RESCAN_NOTE.md — targeted re-review for `launch-candidate-22`

For Bankr. **This is the last audit step before deploy.**

`-22` is `-21` plus the two fixes we flagged to you ourselves in the `-21` note. Nothing else in
`src/` moved. If you already started on `-21`, the delta is small and named in §0.

Scope is **five contracts**, and two of them still have no behavioural change at all — they are
in scope because their *environment* changed, which is the harder thing to catch.

| Contract | Changed since `-19`? | Why it is in scope |
|---|---|---|
| `ChipBurner.sol` | **NEW, and changed again at `-22`** | Becomes the **owner of the $CHIP token**. Largest single authority in the system |
| `ChipRounds.sol` | yes, and again at `-22` | Burn re-route, a public constant removed, **its Slipstream branch is now the live buy path**, and `setRouters` is now validated |
| `ChipActivation.sol` | yes, at `-21` only | $CHIP burns re-routed to an immutable target |
| `StockRegistry.sol` | **runtime bytecode identical since `-14`** | Never externally reviewed (OPEN_ITEMS 25a); now what stands between a correct venue config and a dead one. Source gained two `override` keywords at `-22` — see §0 |
| `POLTreasury.sol` | **no — byte-identical since `-14`** | Now sits on a *different Aerodrome factory* from the stock buys |

### Which ref to check out

**Check out `launch-candidate-22`.** Unlike last time there is no separate package tag: the code
and the review package land together, so this one tag is everything.

```bash
git checkout launch-candidate-22

git diff launch-candidate-21 launch-candidate-22 -- src/     # the two fixes, and nothing else
git diff launch-candidate-19 launch-candidate-21 -- src/     # the -21 delta, if you have not seen it

# the one that did NOT change at all, to confirm rather than take on trust:
git diff launch-candidate-14 launch-candidate-22 -- src/POLTreasury.sol     # empty

forge test        # 807 tests, 51 suites, 0 failures (747 unit + 60 fork against live Base)
```

Fork suites need `BASE_RPC_URL`. They are not optional here — the venue evidence in this note is
produced by them, not asserted by it.

**Flattened sources** for all five are in `review/flattened/`, regenerated at this tag and
verified: each compiles standalone under the pinned settings (solc 0.8.24, cancun, optimizer
200) and its **executable runtime code is byte-for-byte identical** to the in-repo build. Only
the 53-byte CBOR metadata trailer differs, which it must — it encodes the source path.

---

## 0. What changed at `-22`, and why

**Both changes are ours, not a reviewer's.** We raised both in the `-21` note as things we
wanted your verdict on; you have not seen them yet, so they arrive here as code rather than as
questions. Neither was prompted by an external finding.

### 0a. `ChipBurner.burnAll()` is now `nonReentrant`, and the figure is bounded

The `-21` note flagged this and left it unfixed so the re-scan would see the frozen contract.
It is fixed now.

```solidity
function burnAll() external nonReentrant returns (uint256 burned) {
    uint256 balanceBefore = chipToken.balanceOf(address(this));
    ...
    IChipOwnable(address(chipToken)).burn(balanceBefore);
    uint256 supplyAfter  = chipToken.totalSupply();
    uint256 balanceAfter = chipToken.balanceOf(address(this));

    if (supplyAfter  >= supplyBefore)  revert BurnDidNotReduceSupply(...);
    if (balanceAfter >= balanceBefore) revert BurnDidNotReduceBalance(...);   // new

    uint256 supplyDrop  = supplyBefore  - supplyAfter;
    uint256 balanceDrop = balanceBefore - balanceAfter;
    burned = supplyDrop < balanceDrop ? supplyDrop : balanceDrop;             // new
```

Two defects, neither of which could ever have cost anybody a $CHIP — the tokens are destroyed
either way and there is still no path that moves them out. What both corrupt is the **published
number**, which is the entire reason the contract exists.

1. **Re-entry.** A token whose `burn` called back into `burnAll` would have the inner call
   credit `totalBurned`, then the outer call would compute its own figure from a supply delta
   spanning *both* burns and credit it again. `nonReentrant` closes it.
2. **Somebody else's supply.** A token that destroyed another holder's balance during our
   `burn` would widen the supply delta and the Burner would take credit for it. `burned` is now
   the **smaller** of the supply drop and this contract's own balance drop, which cannot
   over-report in either direction whatever the token does.

**Why we did not accept Slither's "benign".** It is benign for funds and not benign for the
figure. More to the point, the contract's whole premise is *do not trust the token* — it
verifies the burn by reading `totalSupply` rather than believing a return value — so relying on
that same token not to re-enter was the one place it took the token at its word.

New tests: `test/ChipBurnerReentrancy.t.sol`, 5 tests. The re-entry test asserts the hostile
token **actually re-entered and was actually refused** (`reentryAttempted`, `reentryReverted`),
so it is not a vacuous pass, and the hostile token deliberately *swallows* the revert — a token
that let it propagate would just fail the whole burn, which proves nothing about the accounting.

### 0b. `ChipRounds.setRouters` is validated

Also flagged by us at `-21`. It had no validation of any kind — no zero check, no `factory()`
check — and the venue flip made it the live buy path.

```solidity
function setRouters(address uni, address slip) external onlyOwner {
    _requireRouterOnFactory(uni,  registry.uniswapV3Factory());
    _requireRouterOnFactory(slip, registry.slipstreamFactory());
    ...
}
```

`_requireRouterOnFactory` rejects zero, rejects an address with no code (`NotAContract`), and
rejects a router whose `factory()` is not the expected one
(`RouterNotOnFactory(router, expected, actual)`). It mirrors
`ConversionRoutes._requireUniswapV3Router`, the SEC-POT-001 fix, deliberately: same shape, not
gas-capped, not tolerant of failure, because this is configuration time.

**The expected factories are read from the registry, not hardcoded.** They are immutables over
there, so the router and the registry are a matched pair by construction — "can this router
reach the pools we registered" rather than "is this a specific address". A registry redeployed
onto a different factory automatically re-scopes the check.

**This is what forced the `StockRegistry` source change.** `IStockRegistry` gained
`uniswapV3Factory()` and `slipstreamFactory()` getters, so the two public immutables gained the
`override` keyword. **The runtime bytecode is unchanged** — we verified it byte-for-byte against
the `-21` build, since a public immutable's getter already existed. It is a two-keyword source
annotation and nothing else, but we are not going to describe a file as untouched when its
source moved.

New tests: `test/RouterGuards.t.sol`, 11 tests, covering both slots in both directions, zero,
an EOA, a contract with no `factory()`, access control, and that a rejected call leaves the
existing pair in place.

**Three test call sites had been passing invalid configurations** and now cannot: two shared one
mock router across both venue slots, and the full-system fork test passed `address(0)` for the
Slipstream slot. They were updated, not weakened — the fork test now uses the real factory-A
Slipstream router, which is what its registry is built on.

### What to attack in the fixes themselves

- Can the `min(supplyDrop, balanceDrop)` bound ever **under**-report a legitimate burn? We
  believe not for any token that simply burns what it was asked to.
- `nonReentrant` on a permissionless function is a griefing surface in principle — can anyone
  use it to block a legitimate `burnAll`? (Within one transaction only; there is no cross-tx
  lock.)
- Does reading the factories from the registry create a circular or stale-config hazard we have
  not seen?
- `ChipRounds` grew by 633 bytes to **22,582**, leaving **1,994** under the EIP-170 limit. The
  `CodeSizeTest` guard still passes. Is that headroom enough for anything you would ask us to
  add?

---

## 1. `ChipBurner.sol` — NEW at `-21`. Read this first.

**It becomes the owner of the $CHIP token.** That is the highest-authority thing in this system,
and outside of §0a it has never been reviewed.

**Why it exists.** The premise of every prior document was that $CHIP could never be truly
burned — Bankr's Doppler token exposes no `burn`, so every burn was a `transfer` to `0xdead`:
unreachable but still inside `totalSupply`. **That premise was wrong, and the correction is the
reason this contract exists.** The token has no *public* `burn`; it has an **owner-gated** one.
"No public burn" had been read as "no burn". A contract we own can call it.

**The trap it is designed around.** `transferOwnership` on the token moves **every** `onlyOwner`
power, not just `burn` — `updateTokenURI`, `updateMintRate`, `lockPool`/`unlockPool`,
`mintInflation`, and `transferOwnership` itself. A burn-only sink would therefore be a one-way
door: the token's metadata could never be updated again and ownership could never be moved, by
anyone, forever. So this is an owner **wrapper**, not a sink.

**Two roles, asymmetric on purpose:**
- **Anyone** may call `burnAll()`. It can only ever destroy this contract's own balance.
- **The multisig** may call `updateTokenUri` and `transferTokenOwnership`. Neither can move a
  single $CHIP.

**What to attack:**
- **Can any path move $CHIP out of the Burner without destroying it?** The claim is no: there is
  no `transfer`, no sweep, no rescue, and deliberately no generic `call(bytes)`. Not even the
  multisig can move it. If that claim is false anywhere, it is the finding.
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
- `chipBurnedToDead()` sums **two** balances (`0xdead` + `chipBurnTarget`), returning the single
  balance when they are the same address. Can it double-count?
- `effectiveChipSupply()` counts $CHIP queued at the Burner as already gone. Is that honest
  across the moment `burnAll()` runs, in both directions?

## 3. 🔴 `ChipRounds.sol` — the Slipstream branch is the LIVE buy path

**This is the change most likely to produce a finding, and it is not visible in the diff.**

When you last saw `ChipRounds`, its `Venue.Slipstream` branch was effectively dead: every B20
stock registered as `Venue.UniswapV3`, on the strength of a sweep that found no Aerodrome CL
pool for any of them. **That sweep was run against one Aerodrome CL factory and there are two.**
All thirteen B20 pools are on the other one, `0xf8f2eB…061Ef`, at tick spacing 10, and they are
7–16x deeper than the Uniswap pools we were going to use. ASSUMPTIONS A-22 carries the
correction; A-16 carries the original error with a supersede header, kept deliberately.

So: **ten of thirteen tickers register as `Venue.Slipstream` and the Slipstream branch is the
live buy path for all of them.** The Uniswap branch is now the one that goes unexercised.

§0b closes the configuration hole this opened. The path itself still wants your eyes.

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
- Is there anywhere that still assumes stocks are on Uniswap?

## 4. `StockRegistry.sol` — no behavioural change, newly load-bearing

**Runtime bytecode identical since `launch-candidate-14`** (the `-22` source change is the two
`override` keywords in §0b and nothing else), **and it has never had an external review**
(OPEN_ITEMS 25a). It was already the largest un-reviewed surface. The venue flip makes it more
so.

`_setVenue` is what stands between a correct config and a dead one. For a Slipstream venue it
requires `tickSpacing != 0` and verifies
`ISlipstreamFactory(slipstreamFactory).getPool(token, quoteToken, tickSpacing) == pool`.

🔴 **`slipstreamFactory` is `immutable`.** A registry deployed against the wrong Aerodrome
factory cannot register a single B20 stock as Slipstream and must be redeployed. It does fail
loudly — `PoolNotFoundInFactory` — and `test_aFactoryARegistryCannotRegisterTheB20Venue` pins
that. This is the one deploy argument in the system that cannot be corrected after the fact.

**What to attack:**
- Can a pool be registered that the factory does not actually derive? Can the check be passed
  with a pool from the *other* factory?
- `poolLiquidityUsd` is venue-agnostic — it reads balances. Is that still right for a
  concentrated Slipstream pool, where headline TVL across both sides overstates tradeable depth
  near spot by more than it does on Uniswap?
- **The enable gate is a point-in-time check, not a continuous one.** `setEnabled` verifies
  depth at the moment of enabling; nothing re-checks it afterwards, so a stock whose pool
  drains stays enabled until somebody notices. An external PR proposed re-checking inside
  `setMinLiquidityUsd`; we have not merged it, and the general case is untouched either way.
  Tell us whether you think the gate should be continuous, and where.

## 5. `POLTreasury.sol` — unchanged code, on a different factory from the buys

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

## 6. Slither — the delta, and why the new High is not a new risk

Slither 0.11.6 was re-run at each tag so every delta isolates one change.
`review/slither-raw.md` and `review/slither-findings.txt` are the `-22` run.

> The 168-finding baseline triaged in `TRIAGE.md` is from `f0d6421` (2026-09-03) and is stale by
> several tags; diffing against it conflates unrelated work. `-19` and `-21` were re-run from
> worktrees to get like-for-like baselines.

| | `-19` | `-21` | `-22` |
|---|---:|---:|---:|
| **TOTAL** | 206 | 212 | **213** |

**`-19` → `-21`: +6, all seven new findings in `ChipBurner`.** Nothing new in `ChipRounds` or
`ChipActivation` — the burn re-route added no static-analysis surface across five money-adjacent
call sites.

**`-21` → `-22`: +1 net.** Four new, three gone (the three are the same `burnAll` findings
re-reported at new line numbers).

| New at `-22` | Impact | Ours |
|---|---|---|
| `reentrancy-balance` — `burnAll()` | **High** | **Expected. It is describing the fix.** |
| `reentrancy-benign` — `burnAll()` | Low | Noise; see below |
| `incorrect-equality` — `burnAll()` | Medium | The `balanceBefore == 0` guard |
| `low-level-calls` — `_requireRouterOnFactory` | Info | The `factory()` staticcall, deliberate |

### The new High is the guard, not a hole

```
Reentrancy in ChipBurner.burnAll():
  Balance read before the call:  balanceBefore = chipToken.balanceOf(address(this))
  Possible stale balance used after the call in a condition: balanceAfter >= balanceBefore
```

That **is** the fix from §0a: read the balance before, compare it after, take the smaller delta.
Slither cannot tell a deliberate before/after measurement from an accidental stale read.

It is also **the fourth instance of a pattern already accepted three times** — the other three
`reentrancy-balance` findings at `-22` are all `ConversionRoutes._convert`, which measures
exactly the same way and was triaged on exactly these grounds. The same before/after shape is
what `ChipBurnShortfall` uses at all five $CHIP burn sites.

### Slither does not honour `nonReentrant` in this repo

Worth knowing before reading any reentrancy finding here. `ChipRounds.settleStock`,
`ChipRounds.openRound`, `ChipRounds.finalizeRound` and `Furnace._forge` are **all**
`nonReentrant` and **all** still appear under `reentrancy-benign` in this run. So `burnAll`
continuing to appear there after being guarded is the same noise, not evidence the guard did
not take. `test/ChipBurnerReentrancy.t.sol` is the evidence that it did.

---

## What did NOT change, and why that is worth knowing

**No prior finding is reopened.** SEC-POT-001, EXT-R-L-1 and SEC-POT-002 all stand as triaged;
the update under SEC-POT-001 narrows a citation, it does not change a disposition.

**The weight and payout arithmetic was not touched.** Neither was `ChipClaims`, `Pot`,
`FeeSplitter`, `ClaimRouter`, `NounLoans` or `Anvil` — all byte-identical.

**`Furnace.sol` changed at `-21`** (+36 −9), taking the identical $CHIP burn re-route, and is
**not** in this scope — outside the money path and outside the original eleven-contract audit.
Say the word if you would rather see the burn change in all three places at once.

**The Furnace recipe numbers are settled** (25 Chiplets for a Based Noun, 50 for a DarkNOUN),
but they are constructor arguments, not code.

**$CHIP is still not a contract in this repo**, and neither is Chiplets. We hold only their
addresses. The Burner assumes exactly three signatures on $CHIP and nothing else.

**Two external PRs are open and neither is merged.** One is documentation-only and stale; one
proposes re-checking the depth gate inside `StockRegistry.setMinLiquidityUsd` (§4). Neither is
in `-22`. If either is folded in it will be deliberate, with tests, and it will come back
through this same process.

## Still open, and not introduced by these changes

- **`ChipClaims` lows `EXT-C-L-1`…`-L-4` were never received** (OPEN_ITEMS 25b) and have never
  been read.
- **The Anvil sell side is not built** and ships after the audit.
- **`maxPrincipal` vs Anvil parity is operational and unenforced** (OPEN_ITEMS 11).
