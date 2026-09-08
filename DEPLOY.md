# DEPLOY.md — Chipworks on Base (8453)

**For the actual launch, read [LAUNCH_CONFIG.md](LAUNCH_CONFIG.md) instead.** It merges this
sequence with the locked economics — $CHIP settings, the initial buy, the computed cost
table, the launch caps — and is the file to execute from. This one explains *why* each
contract is wired the way it is, and stays the reference when a decision needs re-examining.

Read `ASSUMPTIONS.md` first.

Solidity 0.8.24 · EVM `cancun` · OpenZeppelin v5.1.0 · optimizer on, 200 runs.

---

## Address book (fill in before deploying)

| Name | Value | Notes |
|---|---|---|
| `MULTISIG` | _TBD_ | Owner of every governed contract. Existing Chipworks/Goya Safe. |
| `OPS_WALLET` | _TBD_ | Goya's Bankr wallet. Receives the 20% ops share. |
| `LOAN_TREASURY` | _TBD_ | Where liquidated NounLoans collateral goes. May be the Safe. |
| ~~`CLUTCH_VAULT_*`~~ | — | **Gone.** Chipworks runs its own activation vault; see step 4. |
| `LIL_NOUNS` | `0xe3c5Ef27B80481518a2363406e354a9361415556` | Verified on Base: ERC-721, 4,420 supply, EIP-1967 proxy, NOT Enumerable. **A normal family collection: 0.5x earner, never burned.** |
| `CHIPLETS` | `0xC7c114191aa3b2225F9bb053Bc55b3d6F145Bd33` | **VERIFIED ON CHAIN 2026-09-07.** The collection the Furnace consumes AND the 4th earning collection. Not a contract in this repo. `name()` = `CHIPLETS`, `symbol()` = `CHIPP`, `supportsInterface(0x80ac58cd)` = **true**, `burn(uint256)` selector **present**, `owner()` = `0xcd2f7B22…FCEFa`. `totalSupply()` was **0** at the time of checking — the drop had not minted. See step 8. |
| `BASED_NOUNS` | _TBD_ | ERC-721. |
| `DARK_NOUNS` | _TBD_ | ERC-721. |
| `CHIP` | _TBD_ | $CHIP, a standard ERC-20 from the Doppler/Bankr launch. Its `burn` is **owner-gated**, and at launch the owner becomes `ChipBurner` (step 0), so **`totalSupply` does fall** — burns are real. Needed by ChipRounds (split fee), ChipActivation (activation cost) and Furnace (forge cost). See BURN_VISIBILITY.md. |

> ### 🔴 AT LAUNCH, AND NOTHING WILL DO IT FOR YOU
>
> **`chip.transferOwnership(<ChipBurner>)`.** This is what makes $CHIP burns real. Until it
> lands, `burnAll()` reverts and every burned $CHIP simply accumulates at the Burner — nothing
> is lost, but `totalSupply` does not fall and the aggregators overstate circulating supply.
> LAUNCH_CONFIG §6.6 carries the sequence and the **ABI check that must happen first**.
>
> **The CoinGecko/CMC filing this note used to demand is no longer required.** It was mandatory
> when every burn was a transfer to `0xdead` and `totalSupply` could never move. With a real
> burn the aggregators pick the fall up on their own. File `0xdead` only if $CHIP was burned
> there before the hand-off landed — see BURN_VISIBILITY.md, which carries the one-line check.
>
> The site should still show `ChipActivation.effectiveChipSupply()` and say that is what it is
> showing: it counts $CHIP queued at the Burner as already gone, so the published figure does
> not step down whenever a keeper calls `burnAll()`.

**Furnace forging needs a user approval step.** `chiplets.setApprovalForAll(furnace, true)`
before `forge`, exactly like a marketplace listing. The Furnace has no burn role and cannot be
given one; it burns only ids the caller named and owns. Tell the site builder.

**Verify the Chiplets address answers `burn` BEFORE the first forge.** The Furnace falls back
to a transfer to `0xdead` when a fuel collection has no `burn`, and that fallback is silent by
design — it keeps forging working against any ERC-721. But it means a mis-wired or unexpected
Chiplets contract would forge perfectly while never reducing supply, which is the whole point
of the change. Two checks, once, on the live deployment:

```
cast code <CHIPLETS> | grep -c 42966c68        # the burn(uint256) selector, expect >= 1
# then forge once and read:
furnace.totalFuelTrueBurned()                  # must equal furnace.totalFuelBurned()
```

If the two counters diverge, the fuel is being dead-held rather than destroyed. OpenSea's
`ERC721SeaDrop` and `ERC721SeaDropCloneable` both expose `burn(uint256)` as
`_burn(tokenId, true)`, so the expected answer is that they match — see BURN_VISIBILITY.md.

---

## Master sequence

The whole system in one place: what to deploy, in what order, what to wire, and what to check
before moving on. The numbered sections after this one carry the reasoning and the full
argument tables; this is the runbook.

🔴 marks the one wiring call in this sequence that fails **silently** if forgotten. Every
other step below fails closed and loudly. See the can't-miss box after the sequence table.

**Two things to have settled before you start.**

1. **`$CHIP` must exist.** Four contracts take it as a constructor argument and three take
   amounts denominated in it. Nothing below can be deployed sensibly without the token.
2. **The 48-hour timelocks are on the critical path.** ChipActivation cannot price a
   collection, and NounLoans cannot change terms, without a queue-then-execute two days
   apart. Registering three collections is three queues on day one and three executes on day
   three. Plan the launch around that rather than discovering it on the day.

### The placeholders

Everything below marked 🔶 is a number that **cannot be chosen until the token launches**,
because it is denominated in $CHIP and its sensible value depends on the supply and the price
the Doppler/Bankr launch settles at. Every one of them is a constructor argument or a
timelocked setter — none is hardcoded — but every one is also a real economic decision that
is currently a guess.

| 🔶 Placeholder | Where | What decides it |
|---|---|---|
| `splitChangeFeeChip_` | ChipRounds constructor | High enough to stop split-flipping before a round, low enough not to lock a holder into a bad pick |
| Activation cost table, 5 tiers x 3 collections | `ChipActivation.queueCosts` | The headline price of the whole product. 100% burns, so this is also the burn rate |
| Furnace `basedRecipe` / `darkRecipe` $CHIP cost | Furnace constructor | What a forged Noun should cost relative to buying one |
| `maxPrincipal` per collection | `NounLoans.setMaxPrincipal` | **Must sit below Anvil parity** — see step 9. Reviewed against the floor, not set once |
| Pool seed size | `NounLoans.depositPool` | How much default risk the protocol is taking |
| `NounLoans` fee bps per term | NounLoans constructor | Priced against the loan's duration and the floor's volatility |

Everything else — percentages, windows, slippage, depth, holdback — has a recommended value
below that does not depend on the token.

### The sequence

| # | Deploy | Constructor takes | Then wire | Cannot take money until |
|---|---|---|---|---|
| 1 | `FeeSplitter` | multisig, **pot placeholder**, ops, 2000, 2000 | `setPot(Pot)` after step 3 | — it can receive from the start, but nobody should call `distribute` before `setPot` |
| 2 | `StockRegistry` | multisig, USDC, uni factory, slipstream factory | 13 x `addStock` (all disabled) | every stock starts **disabled**; `setEnabled` needs feed + pool + measured depth |
| 3 | `Pot` | multisig, USDC | `setRewards(ChipRounds)` after 5b; `setConversionConfig`; `setRoute(AERO)` | `openRound` reverts while `rewards` is unset |
| 4 | `ChipActivation` | multisig, **$CHIP**, tier bps | `queueCosts` → 48h → `executeCosts` per collection; **`setFlatRateCollection(CHIPLETS)` BEFORE its first `executeCosts`**; 🔴 `setCustodian(NounLoans)` after 9 | **an unpriced collection cannot be activated at all** — `CollectionNotConfigured` |

> **Chiplets is flat-rate and the order matters.** `setFlatRateCollection(CHIPLETS)` must run
> **before** the collection's first `executeCosts`; it is refused on a live collection, one-way
> by design, so a mistake here means redeploying `ChipActivation`. The five cost entries must
> all be **equal** — a flat collection has one price and the validator refuses a ladder.
> Activation is `activateFlat(CHIPLETS, tokenId, sacrificeId)`: a flat $CHIP amount plus one
> OTHER Chiplet, truly burned. The site needs `chiplets.setApprovalForAll(chipActivation, true)`
> as step one, the same as the Furnace.
| 5a | `ChipClaims` | multisig, StockRegistry | `setRounds`, `setPolTreasury`, `setClaimSchedule`, `setCreditExpiry` | **`contributeWeights` reverts until `setRounds`** — the ledger rejects an unknown caller |
| 5b | `ChipRounds` | multisig, registry, Pot, **ChipActivation**, ChipClaims, 🔶fee | the config table in step 5b | a round reverts at the first `contributeWeights` until 5a is wired |
| 6 | `POLTreasury` | multisig, USDC, position manager, FeeSplitter, UniV3 factory, **Aerodrome Voter** | `setManager`, `setRewards(ChipClaims)`, POL assets **with feeds**, routes, income tokens | holds nothing until `ChipRounds.setPolTreasury` points at it |
| 7 | `ClaimRouter` | multisig, **ChipClaims**, 1000000 | nothing | holds no funds and needs no permissions, ever |
| 8 | `Furnace` | multisig, **$CHIP**, Lil Nouns, 🔶two recipes | approve + `depositStock` | **`forge` reverts `OutOfStock` until stock is deposited** |
| 9 | `NounLoans` | multisig, **$CHIP**, FeeSplitter, treasury, terms | 🔴 `ChipActivation.setCustodian(this, true)`; 🔶`setMaxPrincipal`; 🔶`depositPool` | **`borrow` reverts `CollectionNotLendable` at `maxPrincipal == 0`**, and `PoolTooSmall` on an empty pool |

### Half-wired cannot take money — the property, and how to check it

Every step above fails **closed**. That is deliberate and it is the single most useful thing
to verify as you go, because a deployment interrupted halfway is the realistic bad day —
someone gets distracted between transactions, and the question is whether the half-built
system can accept a user's funds and lose them.

**All of this is tested, so the claim cannot quietly stop being true**:
`test/DeployOrder.t.sol` runs each check below against a stack wired in the documented order
and stopped short at the relevant step. Check each one by trying the thing that should not
work yet:

```
# 2. A stock with no feed cannot be enabled, even by the owner.
setEnabled(CRCLc, true)                       -> reverts FeedNotSet

# 3. The Pot will not release a budget to nobody.
openRound()                                   -> reverts (rewards unset)

# 4. An unpriced collection cannot be activated, at any tier, by anyone.
activate(BASED_NOUNS, 1, 0)                   -> reverts CollectionNotConfigured

# 5a/5b. THE IMPORTANT ONE. Before claims.setRounds(rounds):
contributeWeights(1, BASED_NOUNS, [1])        -> reverts (ledger rejects an unknown caller)
#      A round cannot book a single weight, so it cannot take anyone's Noun into a round it
#      would then be unable to pay out of.

# 8. A Furnace with no stock cannot consume a Lil.
forge(0, [1,2,3,4,5])                          -> reverts OutOfStock
#      Stock is checked BEFORE inputs are burned, so a doomed forge burns nothing.

# 9. A loan vault with no cap and no pool cannot take collateral.
borrow(BASED_NOUNS, 1, 0, 100e18)              -> reverts CollectionNotLendable
setMaxPrincipal(BASED_NOUNS, X); borrow(...)   -> reverts PoolTooSmall
#      Collateral is pulled AFTER both checks, so a Noun is never locked against a loan the
#      pool cannot fund.
```

### 🔴 CAN'T MISS: `setCustodian` is the one wire with no safety net

> **`chipActivation.setCustodian(nounLoans, true)` — DO NOT SIGN OFF THE DEPLOY WITHOUT THE
> VERIFICATION READ BELOW RETURNING `true`.**
>
> Every other mistake in this sequence reverts. This one does not. Skip it and the system
> looks completely healthy: loans open, $CHIP is disbursed, collateral is held, rounds run,
> other holders are paid. The only symptom is that **every borrower silently stops earning
> the moment they deposit**, exactly as if they had sold their Noun — no error, no event, no
> failed transaction, nothing in a log to notice. It is the headline feature of NounLoans
> failing invisibly.
>
> **The verification read that proves it is set:**
>
> ```
> cast call $CHIP_ACTIVATION "isCustodian(address)(bool)" $NOUN_LOANS --rpc-url $BASE_RPC_URL
> #   -> true            REQUIRED. Anything else means borrowers are earning nothing.
> ```
>
> **And the end-to-end read that proves it WORKS**, which is the one worth the extra minutes,
> because `isCustodian` being true only proves the allowlist entry exists — not that
> `beneficiaryOf` is answering the way ChipActivation expects:
>
> ```
> # on a fork, with a real Noun:
> #   1. chipActivation.activate(collection, tokenId, tier)
> #   2. nounLoans.borrow(collection, tokenId, term, principal)
> #   3. cast call $CHIP_ACTIVATION "isActive(address,uint256)(bool)" $COLLECTION $TOKEN_ID
> #      -> true          the Noun is in the vault AND still earning
> #   4. cast call $CHIP_ACTIVATION "effectiveOwner(address,uint256)(address)" ...
> #      -> the BORROWER, not the loan vault
> ```
>
> If step 3 returns `false`, the wire is missing or the custodian is not answering. **The fix
> is one call, needs no action from any borrower, and is retroactive** — activations come
> back the instant the custodian is registered. Nothing is lost; it just has to be noticed.
>
> Walked end to end by `test_theCustodianWireIsTheOneMistakeThatFailsSilently` in
> `test/DeployOrder.t.sol`, which asserts the silent-failure shape explicitly so it stays
> documented rather than becoming folklore.

`test_theCustodianWireIsTheOneMistakeThatFailsSilently` walks exactly that: the loan opens,
nothing reverts, and the borrower's Noun scores zero weight in the next round. The fix is one
call, needs no action from the borrower, and is retroactive — but nothing will tell you.

### Order constraints, as a graph

Only these actually bind. Everything else can move.

```
$CHIP ────────────────> 0 ChipBurner, 4 ChipActivation, 8 Furnace, 9 NounLoans, 5b ChipRounds (fee)
0 ChipBurner ─────────> 4 ChipActivation, 5b ChipRounds, 8 Furnace   🔴 immutable in all three
2 StockRegistry ──────> 5a ChipClaims, 5b ChipRounds
3 Pot ────────────────> 5b ChipRounds
4 ChipActivation ─────> 5b ChipRounds
5a ChipClaims ────────> 5b ChipRounds, 7 ClaimRouter
5b ChipRounds ────────> 3 Pot.setRewards, 1 FeeSplitter.setPot (via Pot)
6 POLTreasury ────────> 5b setPolTreasury, 5a setPolTreasury
9 NounLoans ──────────> 4 ChipActivation.setCustodian   🔴 no revert if forgotten
```

`ClaimRouter` (7) points at **ChipClaims**, not ChipRounds — `claimFor` lives on the ledger.
`POLTreasury.setRewards` also takes **ChipClaims**, because compound credits are notified by
the ledger. Both are easy to get backwards and neither fails loudly.

**`ChipBurner` (0) is the one new hard edge**, and it is unforgiving in a way the others are
not: `chipBurnTarget` is `immutable` on ChipActivation, ChipRounds and the Furnace, so if the
Burner's address is wrong at deploy there is no setter to fix it — all three redeploy. It is
also the only step whose own dependency, `$CHIP`, is a Bankr artifact rather than ours.

---

## Order

Deploy in this order. Each step lists what it needs from earlier steps.

### 0. ChipBurner — **built**

Needs: `MULTISIG`, `$CHIP`.

**Deploy this before ChipActivation, ChipRounds and the Furnace, because all three take its
address as an immutable constructor argument.** It is the only new dependency in the deploy
graph, and the only one that is genuinely one-way: get it wrong and three contracts have to be
redeployed.

| Arg | Value | Meaning |
|---|---|---|
| `multisig` | `MULTISIG` | The admin owner. May use the two pass-throughs; **may never move a single $CHIP**. |
| `chipToken_` | `CHIP` | Immutable. The token this wrapper owns and burns. |

**What it is for.** Bankr's Doppler $CHIP has no public `burn`, only an owner-gated one. Every
$CHIP "burn" in this protocol used to be a transfer to `0xdead`: unreachable, but still inside
`totalSupply`, so every aggregator overstated circulating supply and the gap grew with every
activation. Making this contract the token's **owner** turns those into real burns —
`totalSupply` falls, on chain, everywhere.

**Burning is permissionless.** Anyone may call `burnAll()`; it destroys this contract's whole
balance and nothing else, and it verifies the burn by reading `totalSupply` before and after
rather than trusting a return value. `totalBurned` therefore counts what left existence, not
what was asked to leave.

**It is structurally burn-only.** No `transfer`, no sweep, no rescue, no generic `call`. $CHIP
that arrives here is gone; the only question is when somebody calls `burnAll()`. `mintInflation`
and `updateMintRate` are deliberately **not** exposed — a permissionless burner that can also
mint is a contradiction. `transferTokenOwnership` is the escape hatch if any of that is ever
genuinely needed, and it is what stops this being a permanent trap.

**The ownership hand-off is a launch-day step, not a deploy step.** The token's ownership only
lands with us when Bankr launches, so `chip.transferOwnership(<ChipBurner>)` happens then — see
LAUNCH_CONFIG §6.6, which also carries the ABI check that must happen **before** the hand-off.
Until it lands `burnAll()` reverts and the app's burn paths simply accumulate a balance here.
Nothing is lost; the burn is deferred.

> **`0xdead` is still the right value for one thing: NFTs.** The Burner has no ERC-721 surface
> at all, so a Noun or a Chiplet sent to it would be **stranded forever**. `BURN_ADDRESS` stays
> `0xdead` on all three contracts and `chipBurnTarget` is a separate field. They are not
> interchangeable, and `test/BurnRouting.t.sol` is what keeps them apart.

### 1. FeeSplitter — **built**

Needs: `MULTISIG`, `OPS_WALLET`, and a Pot address.

The Pot does not exist yet at this point, which is a chicken-and-egg. Two options:

- **Recommended:** deploy `FeeSplitter` with `pot_ = MULTISIG` as a placeholder, then after
  step 3 call `setPot(potAddress)` from the multisig. One extra multisig transaction.
  Nothing can be lost in between — any ETH that arrives early just sits in the splitter
  until distribute is called, and nobody should call distribute until the Pot is set.
- Alternative: deploy Pot first with a placeholder splitter, and use the splitter's
  CREATE address predicted via nonce. More fragile. Not recommended.

Constructor arguments:

| Arg | Recommended value | Meaning |
|---|---|---|
| `multisig` | `MULTISIG` | Owner. Two-step ownership transfer. |
| `pot_` | `MULTISIG` at first, then `setPot(Pot)` | Where the 80% goes. |
| `ops_` | `OPS_WALLET` | Where the 20% goes. |
| `opsBps_` | `2000` | 20% ops share. |
| `maxOpsBps_` | `2000` | Permanent ceiling. Multisig can lower `opsBps`, never raise it above this. |

Optionally enable the POL leg once POLTreasury exists (step 6):
- `setPolTreasury(polTreasury)` then `setPolShareBps(1000)` for 10%.
- Defaults to 0, so the split stays 80/20 until deliberately turned on. Hard-capped at 2000.
- With it on, the split is pot / ops / POL, and POL funds its own pairing instead of waiting
  for an unclaimed credit to expire.

After deploy, point every fee source at the FeeSplitter address:
- StonkBrokers Safety Deposit Box: 80%-of-fees recipient
- Secondary royalty recipient on both collections
- `POLTreasury` fee/AERO forwarding (step 5)
- Arcade rake (phase 2)

Post-deploy checks:
- `owner()` is the multisig
- `opsBps()` is 2000 and `potBps()` is 8000
- send 0.001 ETH, call `distributeETH()`, confirm the 80/20 landing

### 2. StockRegistry — **built**

Needs: `MULTISIG`. Independent of FeeSplitter, so order between them does not matter.

Constructor arguments:

| Arg | Value | Meaning |
|---|---|---|
| `multisig` | `MULTISIG` | Owner. |
| `quoteToken_` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | USDC on Base (verified, 6 dp). |
| `uniswapV3Factory_` | `0x33128a8fC17869897dcE68Ed026d694621f6FDfD` | Verifies Uniswap v3 pools. |
| `slipstreamFactory_` | `0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef` | Verifies Aerodrome Slipstream pools. **FACTORY B, and this is the one that matters** — there are two Aerodrome CL factories and every B20 stock pool is on this one. The older `0x5e7BB1…809A` (factory A) resolves none of them, and `slipstreamFactory` is **immutable**, so a registry deployed against factory A cannot register a single stock and must be redeployed. ASSUMPTIONS A-22. |

Then register all nine stocks **disabled**, four with pools and five without:

| Ticker | Token | Venue | Pool | Fee |
|---|---|---|---|---|
| NVDAc | `0xb20000000000000000000078ee7ce2fE4908108C` | UniswapV3 | `0x60661b315553EB81872deEA9a66d567Cf0CCd33B` | 3000 |
| GOOGLc | `0xb2000000000000000000002D0BA3164cc74f58B7` | UniswapV3 | `0x1f52F46BaC657564c31122b12b43A459E09273C8` | 10000 |
| AAPLc | `0xb200000000000000000000C2e324d24d7eEcd1fb` | UniswapV3 | `0x97F35d1E92795327614BE000cd18cba1Be2c1931` | 3000 |
| METAc | `0xb2000000000000000000008bC8786B856E61707C` | UniswapV3 | `0x583919ec1975a1238C50e1940911894ee6912476` | 3000 |
| TSLAc | `0xb2000000000000000000001e800a7f5189430cD0` | None | none yet | - |
| AMZNc | `0xb200000000000000000000d9192b6B456483C2E8` | None | none yet | - |
| MSFTc | `0xB200000000000000000000Ab99cFa739E253872B` | None | none yet | - |
| COINc | `0xb200000000000000000000c85a31389D71F3ecfb` | None | none yet | - |
| MSTRc | `0xb2000000000000000000004884b426556b92883d` | None | none yet | - |

Then the **four beyond the launch set**. All four have live Chainlink feeds; what they lack
is a USDC pool. Register them with the feed set, `venue = None`, `pool = address(0)`:

| Ticker | Token | Feed |
|---|---|---|
| CRCLc | `0xB20000000000000000000019f6E7C675b73C2e4D` | `0x0231cF2635D1E17bB5c2462cc7504Ba1fBd61f33` |
| INTCc | `0xB2000000000000000000004AFF16039bA04bdFBc` | `0xAB657C39bac0D5886250D70849e2E3E008F2EECB` |
| SNDKc | `0xb200000000000000000000397293Cb8cda9a10c5` | `0x388b0dC46C0Fb05A74BeE0994fa5b02c6Fcca2eA` |
| SPCXc | `0xb2000000000000000000007b9fcbd005511aCBd5` | `0x6A634B235903C4ad6376892180d6fF8612e3Fa68` |

**They cannot be enabled by mistake.** `setEnabled(token, true)` requires a feed, a verified
pool AND measured depth, and reverts `PoolNotSet` without a venue — so a stock with no market
is inert no matter who calls what. Registering them now means adding a market later is
`setVenue` + `setEnabled` rather than an `addStock` against an address nobody has reviewed
under time pressure. All thirteen tokens and all thirteen feeds are reconciled against a live
node in ASSUMPTIONS A-13 and A-18, and asserted in `test/fork/ChainlinkFeeds.t.sol`.

All thirteen need `tokenDecimals = 8` and a `minLiquidityUsd` you choose (see below). The four
with pools also need their Chainlink feed, which is still outstanding (ASSUMPTIONS A-13).

**minLiquidityUsd: $50,000 default, overridable per stock.** Deploy every stock with
`minLiquidityUsd = 50_000e18` unless a specific one is given a different value. The
reasoning: `poolLiquidityUsd` reports total pool TVL, but Uniswap v3 is concentrated, so
depth tradeable near spot is a fraction of it. A $10k round across four stocks is a ~$2,500
slice, and $50k is roughly 20x that — enough cushion for the concentration haircut. Today
only GOOGL is anywhere near clearing it, which is the correct answer for a market four days
old. Raise or lower per stock with `setMinLiquidityUsd`.

**Enabling, at launch week:**
```
STOCK_REGISTRY=0x... forge script script/CheckDepth.s.sol --rpc-url $BASE_RPC_URL
```
Prints measured depth vs threshold for every registered stock and the list that clears.
It reads through raw RPC rather than the local fork, because B20 tokens are precompiles
that a forked EVM cannot execute and would otherwise report as $0. Then call
`setEnabled(token, true)` from the multisig for each stock on that list. The contract
re-checks depth itself and reverts if a stock does not clear, so the script and the chain
have to agree.

**Deployment note.** `addStock` probes `decimals()` on the stock token. That works on real
Base but not in local simulation, so `forge script --broadcast` against these tokens should
use `--skip-simulation`, or be executed from the multisig UI.

Post-deploy checks:
- `owner()` is the multisig
- `stockCount()` is 13, `enabledTokens().length` is 0
- `getStock(CRCLc).pool` is `address(0)`, and `setEnabled(CRCLc, true)` reverts `PoolNotSet`
- `getStock(NVDA).pool` matches the table above

### 3. Pot — **built**

Needs: `MULTISIG`, USDC. Deploy before ChipRewards.

| Arg | Value |
|---|---|
| `multisig` | `MULTISIG` |
| `quoteToken_` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| `uniswapV3Factory_` | `0x33128a8fC17869897dcE68Ed026d694621f6FDfD` |

**The factory argument is a security control, not plumbing.** `ConversionRoutes` encodes
Uniswap v3 calldata and nothing else, so `setRoute` refuses any router that does not report
this factory — an Aerodrome Slipstream router is rejected at configuration time rather than
reverting at conversion time. Raised by external review as SEC-POT-001.

After ChipRewards exists, call `setRewards(chipRewards)` from the multisig. **It must be a
contract**: `setRewards` refuses an EOA (SEC-POT-006). Then go back to step 1 and call
`FeeSplitter.setPot(pot)`.

Then configure the ETH conversion, multisig only:

```
setConversionConfig(
  weth              = 0x4200000000000000000000000000000000000006,
  ethUsdFeed        = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70,   // "ETH / USD", 8 dp, verified
  swapRouter        = 0x2626664c2603336E57B271c5C0b26F421741e481,   // Uniswap SwapRouter02, verified
  conversionFee     = 500,        // 0.05% tier
  maxSlippageBps    = 100,        // 1% below the Chainlink mark
  maxConvertPerCall = 5 ether,    // cap per call
  minConvertPerCall = 0.01 ether, // below this, wait for more to accumulate (SEC-POT-004)
  maxFeedAge        = 3600        // 1h staleness limit
)

setSequencerFeed(
  0xBCF85224fc0756B9Fa45aA7892530B47e10b6433,  // Base L2 uptime feed, verified: A-19
  3600                                          // 1h grace after it comes back
)
```

**Fee tier.** Measured WETH/USDC depth on Base: 0.05% holds $3.14M USDC / 2,326 WETH;
0.3% holds $64.2M / 21,364 WETH; 0.01% holds $145k / 83 WETH. The 0.3% tier has more raw
TVL but charges 25bps more, and $3.14M is far beyond anything a capped conversion needs, so
0.05% is the better default. It is one multisig call to change, and a wrong choice fails
safe: the Chainlink bound rejects the swap rather than executing it badly.

**Per-call cap.** Verified on a fork: 2 ETH converted at 4,882 USDC against a 4,838
Chainlink floor, while 500 ETH in one shot breached the bound and was refused. Set the cap
to roughly what a day of fees looks like; raise it only with evidence.

**Other income routes.** Any asset the protocol earns needs its own row before a round can
spend it. Register AERO at deploy time:

```
setRoute(
  token          = 0x940181a94A35A4569E4529A3CDfB74e38FD98631,  // AERO
  feed           = 0x4EC5970fC728C5f65ba413992CD5fF6FD70fcfF0,  // "AERO / USD", 8 dp, verified
  router         = 0x2626664c2603336E57B271c5C0b26F421741e481,
  fee            = 500,
  maxSlippageBps = 300,        // AERO/USDC on Uniswap is thinner than WETH: ~$66k
  maxPerCall     = 50000e18,
  minPerCall     = 100e18,     // dust floor
  maxFeedAge     = 86400
)
```

Daily operation: anyone calls `convert()` and `convert(AERO)` before `openRound()`. The
keeper does all three.
Un-converted ETH does not count toward the $250 gate. `sweepEth` remains the escape hatch
if the route breaks.

### 4. ChipActivation — **built**

Chipworks' own non-custodial soft-staking vault. **This replaces Clutch entirely.**

Needs: `MULTISIG`, `$CHIP`. Deploy before ChipRounds.

| Arg | Value |
|---|---|
| `multisig` | `MULTISIG` |
| `chipToken_` | `CHIP` |
| `chipBurnTarget_` | **`ChipBurner` from step 0** — where activation and upgrade $CHIP is sent. Immutable, non-zero. Not `0xdead`: see step 0. |
| `tierBps_` | `[10000, 12500, 16000, 20000, 33300]` (1.00 / 1.25 / 1.60 / 2.00 / 3.33) |

**No collection can be activated until it is priced**, and pricing is the same call that
registers it. A freshly deployed ChipActivation accepts nothing, which is the intended
failure mode: forgetting a collection makes it earn zero rather than earn for free.

**Every economic parameter is behind a 48-hour timelock**, including the first configuration
of a collection. Budget for that in the launch schedule — it is two transactions per
collection, two days apart:

```
queueCosts(LIL_NOUNS,   [c0, c1, c2, c3, c4])     // $CHIP to hold each tier outright
... wait 48h ...
executeCosts(LIL_NOUNS)                            // also marks the collection live
```

Costs must be **non-decreasing** across tiers, or the call reverts — an upgrade pays the
difference between tiers and a decreasing table would make that meaningless. All-zero is
accepted, if a collection should activate for free. Repeat for `BASED_NOUNS` and
`DARK_NOUNS`. Denominations are set at token launch; nothing is hardcoded.

Changing the weight curve uses the same shape, `queueTierBps` / `executeTierBps`, and is
deliberately stricter than the retired Clutch adapter, which allowed a one-transaction
retune. The curve decides what everybody earns and should not move without notice.

Then, once NounLoans exists (step 8):

```
setCustodian(nounLoans, true)
```

**What a custodian is, and why it matters.** Soft staking voids an activation the moment the
Noun changes hands — correct for a sale, wrong for a deposit. A registered custodian is
asked `beneficiaryOf(collection, tokenId)` and its answer becomes the effective owner, so a
Noun locked as loan collateral keeps earning **for the borrower**. Register only contracts
you have read: a custodian is trusted over the tokens it holds, though **only** over those.
De-registering is immediate and resets every activation that custodian was carrying — that
is the emergency stop, and pulling it costs depositors their activation until they withdraw.

**Users pay in $CHIP and must approve it**: `chip.approve(chipActivation, cost)` before
`activate(collection, tokenId, tier)`. 100% of the cost burns to `0xdead`; there is no
protocol cut, and the contract holds no $CHIP between transactions.

Post-deploy checks:
- `owner()` is the multisig, `chipToken()` is $CHIP
- `allTierBps()` is `[10000, 12500, 16000, 20000, 33300]`
- `isSupportedCollection(BASED_NOUNS)` is **false** before `executeCosts` and true after
- activate one Noun, then transfer it, and confirm `isActive` flips to false with **no
  keeper call in between** — the reset is lazy and needs nothing run against it
- `chip.balanceOf(chipActivation)` is 0 after a test activation

**`ClutchVaultAdapter` is retired, not deleted.** It stays in `src/adapters/` as the
alternative implementation of the same interface and **is not deployed**. If Clutch ever
ships on Base and the economics look better, it is one `setActivationSource` call — which is
also why the seam was built this way in the first place. See AUDIT_BRIEF section 7.

### 5a. ChipClaims — **built** (deploy BEFORE the engine)

The ledger. Every token a holder is owed lives here.

Needs: `MULTISIG`, `StockRegistry`.

| Arg | Value |
|---|---|
| `multisig` | `MULTISIG` |
| `registry_` | StockRegistry from step 2 |

**The claim-window cadence is anchored at THIS contract's deploy timestamp and can never be
moved.** Pick the deploy time deliberately: it fixes which day of the week claims open on,
permanently.

Then, from the multisig:

| Call | Recommended value |
|---|---|
| `setRounds(chipRounds)` | after step 5b — the only contract allowed to write credits. **One-shot**: allowed once while unset, then only via `queueRounds` + 48h + `executeRounds` |
| `setPolTreasury(polTreasury)` | after step 6. **One-shot**, same as above (`queuePolTreasury`) |
| `setClaimSchedule(604800, 172800)` | claims open every 7 days, for 48h |
| `setCreditExpiry(2592000)` | 30 days, then unclaimed credits sweep to POL |

Every configuration must satisfy `creditExpiry >= 3 * windowLength`, which the setters
enforce.

### 5b. ChipRounds — **built**

The engine. Buys stock and hands it to the ledger; it can never pay a holder.

Needs: `MULTISIG`, `StockRegistry`, `Pot`, `ChipActivation`, **`ChipClaims`**.

| Arg | Value |
|---|---|
| `multisig` | `MULTISIG` |
| `registry_` | StockRegistry from step 2 |
| `pot_` | Pot from step 3 |
| `source_` | **ChipActivation** from step 4 |
| `claims_` | ChipClaims from step 5a |
| `splitChangeFeeChip_` | `5000e18` (5,000 CHIP) |
| `chipBurnTarget_` | **`ChipBurner` from step 0** — where the split-change fee is sent. Immutable, non-zero. |

> **`setRouters` now validates, so run it AFTER the registry is deployed and BEFORE the first
> round.** It reads `registry.uniswapV3Factory()` and `registry.slipstreamFactory()` and
> requires each router to report the matching one. That makes the router and the registry a
> matched pair by construction: if the registry is ever redeployed onto a different factory,
> the old router stops being accepted. There is no way to set only one of the two.

Then configure, all from the multisig:

| Call | Recommended value |
|---|---|
| `setRoundParams(duration, window, minPot)` | `86400, 7200, 100e6` — **three arguments; `maxBudget` was removed with the impact trim.** LAUNCH_CONFIG §5 |
| `setCollectionBaseBps(CHIPLETS, 1000)` | **Chiplets = 0.1x.** This IS the 0.1x — `ChipActivation` reports a flat 1.00x and the base supplies the rate, exactly as for Lil. No code change was needed in `ChipRounds`. |
| `setCollectionBaseBps(LIL_NOUNS, 5000)` | Lil = 0.5x |
| `setCollectionBaseBps(BASED_NOUNS, 10000)` | Based = 1.0x |
| `setCollectionBaseBps(DARK_NOUNS, 20000)` | Dark = 2.0x |
| `setRouters(uniswapRouter, slipstreamRouter)` | `0x2626664c2603336E57B271c5C0b26F421741e481` (Uniswap v3 SwapRouter02) and **`0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F`** — the Slipstream router bound to **factory B**. The better-known `0xBE6D8f…18a5` serves factory A and could never reach a B20 pool; proved both ways in `test/fork/FactoryBRouter.t.sol`. **Since `-22` this is enforced on chain**: each router's `factory()` is checked against the matching factory on the registry, and neither may be zero, so a wrong router reverts here instead of reverting every buy later. |
| `setPolTreasury(polTreasury)` | after step 6 — receives the holdback |
| `setChip(chipToken)` | after the $CHIP launch. **One argument** — the burn destination is `chipBurnTarget`, a constructor argument, and there is deliberately no setter for it. |
| `setHoldbackBps(1500)` | the spec's 15%. Range 0–2500, ceiling immutable |
| `setDefaultMaxSlippageBps(200)` | 2% around the Chainlink mark |
| `setMaxFeedAge(432000)` | **120 hours.** Skip a stock whose feed has frozen; its slice carries |
| `setMaxSlippageBps(stock, bps)` | per-stock override where needed |

**On `setMaxFeedAge`, because the obvious number is wrong.** B20 equity feeds have no
heartbeat outside market hours: after an ordinary weekend every one of them is ~65 hours old
while being perfectly healthy, and after Thanksgiving ~113. A tight setting would skip every
Monday round, silently, because a skip is the safe quiet path. 120 hours clears a holiday
weekend with margin and still catches a feed dead for a working week. The contract enforces
a 72-hour floor (`MIN_FEED_AGE`) so this cannot be tightened into an outage. Zero disables
the check entirely. See OPEN_ITEMS item 6.

**WIRING ORDER MATTERS, and getting it wrong fails loudly rather than silently:**

1. Deploy `ChipClaims`.
2. Deploy `ChipRounds` with the claims address.
3. `claims.setRounds(rounds)` — **until this is called, every round reverts at the first
   `contributeWeights`**, because the ledger rejects writes from an unknown caller. That is
   the intended behaviour: a half-wired deployment cannot take anyone's money.
4. `pot.setRewards(rounds)` — the engine is what pulls the budget.
5. `polTreasury.setRewards(claims)` — compound credits are notified by the **ledger**, not
   the engine.
6. `ClaimRouter` points at **`claims`**, not the engine: `claimFor` lives on the ledger.

**Three collections, no code change.** Everything collection-shaped is a mapping keyed by
address, so adding one is two multisig calls: `setCollectionBaseBps` here and the timelocked
`queueCosts` / `executeCosts` on ChipActivation. Proven by `test/ThreeCollections.t.sol`,
which also checks that a FOURTH needs nothing new. **A collection with no base configured
earns zero rather than defaulting to 1.0x**, so forgetting the call fails closed — and it
fails closed on both sides, because ChipActivation refuses to activate an unpriced
collection too.

**Daily operation** (keeper bot, all permissionless — anyone can run these):
1. `pot.convert()` and `pot.convert(AERO)`
2. `rounds.openRound()`
3. `rounds.contributeWeights(roundId, collection, tokenIds[])` — batched, both collections
4. `rounds.closeAccumulation(roundId)` — only after the 2h window
5. `rounds.settleStock(roundId, stock)` — once per stock in the round
6. `rounds.finalizeRound(roundId)`

If a round is opened and then abandoned, anyone can call `rounds.cancelRound(roundId)` after
24h to return its budget to the Pot.

**Expiry** (any time after a round's `expiresAt`, permissionless):
`claims.sweepExpired(roundId, stock, maxHolders)` — batched, pass 0 for all holders at once.

Post-deploy checks:
- `claims.rounds()` is ChipRounds, `rounds.claims()` is ChipClaims
- `pot.rewards()` is ChipRounds
- `collectionBaseBps` is 5000 / 10000 / 20000 for Lil / Based / Dark
- `rounds.activationSource()` is ChipActivation
- open a tiny test round end to end on a fork before funding the real Pot

### The full B20 set — registry config, derived from chain 2026-09-07

**THIS TABLE WAS REPLACED. The venue is Aerodrome Slipstream, not Uniswap v3.**

The previous version of this section registered all ten tradeable tickers as `Venue.UniswapV3`
and said no B20 stock had a Slipstream pool at any tick spacing. That was measured against
Aerodrome CL factory `0x5e7BB1…809A` and it was true of *that factory* — there are **two**
Aerodrome CL factories and every B20 pool is on the other one, `0xf8f2eB…061Ef`. ASSUMPTIONS
A-22 carries the correction, the identifying probes, and the router that reaches it.

All thirteen tickers register: ten as `Venue.Slipstream` at **tick spacing 10** (fee 500), and
COIN, CRCL and INTC as `Venue.None` because they have no pool on either factory or on Uniswap.
`test/fork/B20RegistryConfig.t.sol` re-derives every pool below from factory B on each run, and
asks each pool what factory it thinks it belongs to, so this table cannot silently go stale.

Depth is `poolLiquidityUsd` — both sides, stock valued at its Chainlink mark. Measured
2026-09-07 at the latest block.

| Ticker | Token | Chainlink feed | Venue | Pool (factory B, ts=10) | Depth USD |
|---|---|---|---|---|---|
| NVDA | `0xb20000000000000000000078ee7ce2fE4908108C` | `0x04689a41629776563E6822F76f2e57D148d28513` | Slipstream | `0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9` | **2,455,345** |
| GOOGL | `0xb2000000000000000000002D0BA3164cc74f58B7` | `0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2` | Slipstream | `0xB1987CAD1682841b4b641d50E520777eC5Ab5542` | **1,597,689** |
| AAPL | `0xb200000000000000000000C2e324d24d7eEcd1fb` | `0x787f13dEa48Db0897CbCDD985de77809D837F988` | Slipstream | `0xA3b1E3f9747065e2073722Ff4c9027d3eA4994F0` | **1,368,360** |
| META | `0xb2000000000000000000008bC8786B856E61707C` | `0x6526aE6797A76123638b863AeE4dD27Ba4E4b27D` | Slipstream | `0xEAF57753BC382E0324a1D43F72E7027705a2273E` | **1,089,917** |
| SPCX | `0xb2000000000000000000007b9fcbd005511aCBd5` | `0x6A634B235903C4ad6376892180d6fF8612e3Fa68` | Slipstream | `0x0bf58fe0FAc935Ac69595c19B12Ba0d75E3F8c0E` | **208,271** |
| SNDK | `0xb200000000000000000000397293Cb8cda9a10c5` | `0x388b0dC46C0Fb05A74BeE0994fa5b02c6Fcca2eA` | Slipstream | `0x5A8236f575471e7BfCA2C8462a200c28f737246E` | **188,143** |
| TSLA | `0xb2000000000000000000001e800a7f5189430cD0` | `0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4` | Slipstream | `0x469337fDcc5E8f38e2E4B670B04F57865D13a7BB` | **169,762** |
| AMZN | `0xb200000000000000000000d9192b6B456483C2E8` | `0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295` | Slipstream | `0xd03Bc8C7F2FAedCe2aac81bF0444AEA08Ea06E9b` | **168,718** |
| MSFT | `0xB200000000000000000000Ab99cFa739E253872B` | `0xeB10A6c9aa7E537aEd766C08c35Dae35B321b18c` | Slipstream | `0x7103eB3c9590d1281f7dc03b2A9EE27C39dF5D54` | **151,152** |
| MSTR | `0xb2000000000000000000004884b426556b92883d` | `0xB3cE282CD188b35DA0E38D8Bc7d58e33173D202a` | Slipstream | `0x8b27f626ab668197000BC722A1012022CAeD10E2` | **117,519** |
| COIN | `0xb200000000000000000000c85a31389D71F3ecfb` | `0x408e44f504A7371a345F03a73dDC96A4b48e8aa7` | **None** | — | no pool |
| CRCL | `0xB20000000000000000000019f6E7C675b73C2e4D` | `0x0231cF2635D1E17bB5c2462cc7504Ba1fBd61f33` | **None** | — | no pool |
| INTC | `0xB2000000000000000000004AFF16039bA04bdFBc` | `0xAB657C39bac0D5886250D70849e2E3E008F2EECB` | **None** | — | no pool |

`fee` is not in this table because the Slipstream path does not read it — the pool is derived
from the tick spacing. All ten pools are fee 500.

All thirteen feeds are 8dp, live, and return sane prices — asserted by
`test_allThirteenRegisterDisabledWithRealFeeds`, which replaces the stand-in feed the registry
suite used while A-13 was open.

**The two empty Uniswap pools are gone from the picture.** MSTR and SNDK had deployed Uniswap
pool contracts holding no USDC; on factory B both hold real depth on both sides. The property
that an existing-but-empty pool is as blocked as a missing one still matters and is still
pinned by `test_anEmptyPoolIsAsBlockedAsAMissingOne`, which now empties a live pool to show it
rather than relying on a ticker happening to be empty.

### Which of these can actually be enabled

**At a 25,000 USD threshold, ten of thirteen — everything with a pool.** The smallest, MSTR at
$117k, clears by more than four times; the deepest four are over $1M each.

**This is the single biggest change the factory correction made.** Against the Uniswap pools
only GOOGL and SPCX cleared the same threshold and the whole set totalled a little over $200k.
The B20 secondary market on Base is roughly 35x deeper than the old table showed, because the
old table was looking at the wrong venue.

Two consequences for the launch runbook, both unchanged in substance:

1. **Enable per ticker, on the day, from `liquidityReport()`.** Do not assume the table above
   still holds. This matters less than it did at $12k depths, but `poolLiquidityUsd` is still
   headline TVL across both sides rather than tradeable depth near spot.
2. **The per-buy protection is the Chainlink-derived minimum output, and it is
   all-or-nothing.** `ChipRounds._minOutFor` requires a buy to clear the stock's Chainlink
   mark less `maxSlippageBps` (2% by default); a buy that cannot is refused *in full* by the
   router, and the whole slice carries back to the Pot. Setting `minLiquidityUsd` low to get
   more tickers enabled does not make thin pools tradeable — it just moves the refusal from
   the registry to the swap, where the symptom is a stock that silently never fills.

   > **CORRECTION.** An earlier revision of this line claimed a "per-stock max-impact check
   > in `ChipRounds`". **There is no such check and there never has been** — no `maxImpactBps`
   > exists anywhere in `src/`. The sentence was written during the B20 registry work and
   > asserted a protection that does not exist, which is exactly the failure SEC-RTR-001 was
   > about. The real behaviour is described above and asserted in `test/UncappedRounds.t.sol`.
   > A genuine impact cap that *trims* a buy rather than refusing it is OPEN_ITEMS 26.

The three pool-less tickers **cannot be enabled at all**, at any threshold including zero,
because `setEnabled(true)` requires a venue before it reaches the number
(`test_theEnableGateBlocksThePoollessTickersByConstruction`). When their pools appear it is
`setVenue` then `setEnabled`, and the gate re-measures.

---

### 6. POLTreasury — **built**

> **CHANGED IN `launch-candidate-10`.** The constructor takes a sixth argument and
> `setPolAsset` takes four. If you are working from an older runbook, both calls will fail —
> see TRIAGE batch 6 (H-01, H-02) for why. **A POL asset now cannot be registered without a
> Chainlink feed**, because the feed is what bounds every LP operation on it, and an optional
> price check that silently does nothing when the feed was forgotten is the failure mode this
> repo already documents once (the `setCustodian` trap, below).

Needs: `MULTISIG`, USDC, the Slipstream position manager, the FeeSplitter from step 1, and
the Aerodrome Voter.

| Arg | Value |
|---|---|
| `multisig` | `MULTISIG` |
| `quoteToken_` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| `positionManager_` | `0x827922686190790b37229fd06084350E74485b72` (verified: Slipstream `mint` with tickSpacing + sqrtPriceX96) |
| `feeSplitter_` | FeeSplitter from step 1 |
| `uniswapV3Factory_` | `0x33128a8fC17869897dcE68Ed026d694621f6FDfD` — POL converts through Uniswap too |
| `voter_` | `0x16613524e02ad97eDfeF371bC883F2F5d6C480A5` — Aerodrome Voter. **Verified on chain**: 33.8 KB of code, and `gauges(0xb2cc…DC59)` returns `0xF33a…e0c8` for the WETH/USDC tickSpacing-100 pool. See ASSUMPTIONS A-20. |

There is no `slipstreamFactory_` argument on purpose: it is read from
`positionManager.factory()` at construction, so the factory the pool checks use can never
disagree with the manager the positions actually live in.

Then, from the multisig:
- `setManager(BANKR_OPTIMIZER)` — may manage positions, cannot change configuration
- `setRewards(chipClaims)` — the ledger is what notifies compound credits
- **`setPolAsset(token, feed, maxDeviationBps, maxFeedAge)` for each stock POL will hold.**
  Registers it, protects it from the rescue, and supplies the Chainlink mark that bounds
  every mint, top-up and exit involving it. `maxDeviationBps` is capped at 1,000 (10%) and
  cannot be zero. Use the same `<stock>/USD` feeds from the §A-13 table the registry uses.
- `setWeth(WETH)` and `setRoute(WETH, ETH_USD_FEED, …)` so POL can realise its ETH slice
- `setRoute(AERO, AERO_USD_FEED, …)` if POL keeps any of its own AERO
- `setIncomeToken(AERO, true)` and any fee tokens (enables `forwardIncome`)

**Income tokens and POL assets are disjoint sets, enforced in both directions.** Attempting
`setIncomeToken(USDC, true)` or `setIncomeToken(NVDAc, true)` reverts `TokenNotDisjoint`, and
so does registering an income token as POL. `forwardIncome` moves a token's whole balance to
the splitter, so an overlap would let anyone strip POL of its pairing inventory for the price
of gas (TRIAGE M-02).

**A pool must exist before its first mint.** Positions are quote-paired only — one side is
always USDC — and the pool comes from the Slipstream factory for that exact pair and tick
spacing. `mintPosition` cannot create one: `sqrtPriceX96` is forced to zero on the way
through. If the USDC pair for a stock has no Slipstream pool at the tick spacing you intend,
the mint reverts `PoolNotCanonical` and the pool has to be created outside this contract
first.

And on ChipRewards:
- `setPolTreasury(polTreasury)`
- `setHoldbackBps(1500)` — the spec's 15%. Range 0–2500; the 25% ceiling is immutable.

Income loop, all permissionless: `collectAllFees()` → `forwardIncomeMany([AERO, ...])` →
FeeSplitter → 80% Pot → next round. Nobody needs permission to push income back to holders.

Post-deploy checks:
- `isProtected(USDC)`, `isProtected(NVDAc)`, `isProtected(AERO)` and
  `isProtected(POSITION_MANAGER)` all true
- `manager` is the optimizer, and calling `setFeeSplitter` from it reverts
- `positionFactory()` equals `0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A`
- `markAndPoolPrice(NVDAc, <its USDC pool>)` returns two numbers within the band. **Do this
  before the first mint**, not after it fails: it is the one call that tells you the feed and
  the pool agree, and it is also how you diagnose a `PoolPriceOffMark` refusal later.
- mint one small position and confirm `positionCount()` is 1 and the NFT is held here
- **`stakePosition(id, <any address that is not the canonical gauge>)` reverts
  `GaugeNotCanonical`.** This is the H-01 check; do it once on the live deployment.
- `canonicalGaugeOf(id)` matches `voter.gauges(pool)` read directly

**Session-key note for the runbook.** `manager` is a hot key and the contract is written on
the assumption that it will leak eventually. Since `launch-candidate-10` there is no manager
function with a destination argument, tokens and pools are allowlisted and derived rather
than supplied, gauges are voter-verified, and liquidity only moves while the pool agrees with
Chainlink. Rotating a suspected-leaked key is still the right response — `setManager` is
immediate and un-timelocked — but it is no longer the thing standing between an attacker and
the POL book.

### 7. ClaimRouter — **built**

Needs: `MULTISIG`, `ChipClaims`.

| Arg | Value |
|---|---|
| `multisig` | `MULTISIG` |
| `rewards_` | **ChipClaims** from step 5a — `claimFor` lives on the ledger |
| `legGasLimit_` | `1000000` |

**One leg now.** The router used to make a second claim against a Clutch vault. That leg is
gone: Clutch's `claim` is permissioned to the owner of record and reverts `NotOwner()` for
any other caller, so a router could never have used it (CLUTCH_RECON section 4), and
Chipworks' own activation vault has nothing to claim — activation is a burned cost, not a
position that accrues. There is no vault registry argument any more and no `sweepTokens`
parameter on the claim.

No further wiring. The router holds no funds and needs no permissions: ChipClaims pays
holders directly through the permissionless `claimFor`.

Front-end usage: `claimEverything(chipClaims)`. Legs fail independently and are reported per
leg; the call reverts only if every leg failed. `claimWindowStatus()` tells the site whether
to grey out the button.

Post-deploy checks:
- `rewards()` is **ChipClaims**, not ChipRounds
- `claimWindowStatus()` agrees with `claims.isClaimOpen()`
- claim one credit through the router and confirm the router's balance is still zero

### 8. Furnace — **built**

Needs: `MULTISIG`, `$CHIP`, `ChipBurner` (step 0), `CHIPLETS`, and the two output collections.

**Deploy this last, and understand that it is not part of the money path.** The Furnace
shares no storage, no inheritance and no call path with ChipRounds, ChipClaims, Pot or
POLTreasury, and nothing in that set references it. It can be deployed, paused, or never
deployed at all without touching a single reward. Order relative to steps 1–7 does not
matter; it is listed last because it depends on `$CHIP` existing.

| Arg | Value | Meaning |
|---|---|---|
| `multisig` | `MULTISIG` | Owner. Two-step ownership transfer. |
| `chipToken_` | `$CHIP` | Burned alongside the fuel. Must exist first. |
| `chipBurnTarget_` | **`ChipBurner` from step 0** | Where the forge's $CHIP goes. Immutable, non-zero. **Not** `fuelCollection_`'s destination — burned fuel still goes to `0xdead` when the collection has no `burn`. |
| `fuelCollection_` | `0xC7c114191aa3b2225F9bb053Bc55b3d6F145Bd33` | The collection consumed as fuel. Verified: real ERC-721, exposes `burn(uint256)`, so forging **truly reduces its supply**. No longer a blocker. |
| `basedRecipe` | `{outputCollection: BASED_NOUNS, fuelCost: 25, chipCost: <placeholder>}` | Recipe id 0, `FORGE_BASED`. **25 Chiplets.** The $CHIP portion is set at launch — see the note below. |
| `darkRecipe` | `{outputCollection: DARK_NOUNS, fuelCost: 50, chipCost: <placeholder>}` | Recipe id 1, `FORGE_DARK`. **50 Chiplets** — twice the Based count, matching the 2.0x collection base a DarkNOUN earns at (`setCollectionBaseBps(DARK_NOUNS, 20000)` in step 5b). The $CHIP portion is set at launch, same as recipe 0. |

Pass `exists: true, paused: false` in both structs; the constructor rewrites both flags, so
their value in calldata is ignored. `fuelCost` must be in `1..100` (`MAX_FUEL_COST`) — 25 is well
inside it — or the constructor reverts.

> ### ⚠️ THE $CHIP PORTION CANNOT BE LEFT UNSET AT DEPLOY, AND THAT COSTS 48 HOURS
>
> Both Chiplet counts are decided — **25 for a Based Noun, 50 for a DarkNOUN** — so the **fuel**
> zero-check is satisfied and the counts no longer block the deploy. But there is a **second**
> zero-check: `_setRecipe` refuses `chipCost == 0`
> as well, added in `launch-candidate-15` on the decision that **every forge must burn $CHIP**.
> A free forge is a sink we do not want.
>
> So the Furnace cannot be deployed with the $CHIP amount blank. The sequence is:
>
> 1. Deploy with a deliberate **placeholder** `chipCost` — high enough that nobody would
>    forge at it by accident, and recorded in LAUNCH_CONFIG as a placeholder.
> 2. **Pause both recipes immediately** (`setPaused(0, true)`, `setPaused(1, true)`) so nobody
>    can forge at the placeholder at all. Pausing is not timelocked, so this is instant.
> 3. At launch, once the token price is observed: `queueRecipeChange(0, 25, <real chipCost>)`
>    and `queueRecipeChange(1, 50, <real chipCost>)` → **48 hours** →
>    `executeRecipeChange(0)` and `executeRecipeChange(1)`, then unpause both.
>
> **Plan the 48 hours.** This is the same timelock every other economic parameter gets, and it
> is deliberate — but it means the real forge price cannot land on launch day unless it was
> queued two days earlier. Queue it against the observed price as soon as that price exists.
>
> The **DarkNOUN** recipe needs the same placeholder-and-pause treatment as recipe 0 — its
> `fuelCost` of 50 is settled, but its `chipCost` is discovered at the same moment recipe 0's is.
> **`chipCost` must be non-zero** — a recipe that forges for fuel alone is
refused by both the constructor and `queueRecipeChange` (`BadConfig`). Every forge burns $CHIP;
that was decided in response to external review batch 9, on the grounds that a free forge is a
sink the protocol does not want and an abuse vector.

**Re-pointing the fuel means a REDEPLOY.** `fuelCollection` is immutable and stays that way
(external review SEC-FUR-002): a settable fuel input would let whoever holds it point the burn
at a collection they can mint for free and forge out the deposited stock. The migration route,
if the fuel ever changes, is: `setPaused` both recipes → `withdrawStock` the output queue to
the multisig → deploy a fresh Furnace with the new `fuelCollection_` → `depositStock` again.
Nothing is stranded, because burned inputs are at `0xdead` and the only assets the Furnace
holds are the outputs it was given.

**Two operational notes from batch 9:**
- **`fuelIds` must be sorted strictly ascending** when calling `forge`, or it reverts
  `FuelIdsNotAscending`. The site must sort before submitting.
- **A stuck output token no longer bricks a recipe.** If a deposited Noun becomes
  untransferable, `queueStockSkip(collection)` → 48h → `executeStockSkip(collection)` advances
  past it. The skip pins the token id at queue time, so it cannot be aimed at a different
  token later. Pause the recipe while it matures.

**Recipe amounts are deploy arguments on purpose.** Do not treat them as final: they are
the one thing here that will be tuned after launch, and tuning them costs two multisig
transactions 48 hours apart (below).

After deploy, from the multisig:

1. **Approve, then stock.** `BASED_NOUNS.setApprovalForAll(furnace, true)` and the same for
   `DARK_NOUNS`, then `depositStock(collection, tokenIds[])` for each. `depositStock` pulls
   with `transferFrom`, so without the approval it reverts.
2. **Check the queue.** `stockRemaining(0)` and `stockRemaining(1)` should equal what you
   deposited, and `nextOutput(id)` should name the token you expect to go first.

**Forging is FIFO and the multisig cannot jump the queue.** `forge` always hands out the
oldest unforged token; `withdrawStock` removes from the **tail**, the most recently
deposited end. So the multisig can shrink the pool but can never pull the specific token a
user is about to forge out from under them. Deposit in the order you want tokens to leave.

**Changing prices — 48h timelock, two transactions:**

```
queueRecipeChange(recipeId, fuelCost, chipCost)    // emits RecipeChangeQueued(.., executableAt)
... wait 48h ...
executeRecipeChange(recipeId)                       // emits RecipeChangeExecuted
```

`cancelRecipeChange(recipeId)` drops a queued change. **Pausing is deliberately NOT
timelocked**: `setPaused(recipeId, true)` bites immediately, because halting a recipe is a
safety action. Pause first, then queue the price change, if a price is actively wrong.

**Users must approve two things** before forging, and the site should ask for both:
`lilCollection.setApprovalForAll(furnace, true)` and `chip.approve(furnace, chipCost)`.

Post-deploy checks:
- `owner()` is the multisig, `chipToken()` and `lilCollection()` are right
- `recipe(0).outputCollection` is Based, `recipe(1).outputCollection` is Dark, neither paused
- `costOf(0)` and `costOf(1)` match what you intended
- `chip.balanceOf(furnace)` is **0**, and stays 0 after a test forge — inputs go straight to
  `0xdead` inside `forge`, so the contract never holds a Lil or a $CHIP at rest
- forge one token end to end on a fork before stocking the real thing

**If an NFT arrives without `depositStock`** — someone `safeTransferFrom`s one in — it is
accepted but **not** registered as stock, so it can never silently become a user's output.
Recover it with `rescueStrayNFT(collection, tokenId, to)`, which reverts if the token is in
the live unforged queue.

### 9. NounLoans — **built**

Borrow $CHIP against a Noun. **Deploy after ChipActivation, and register it there.**

Needs: `MULTISIG`, `$CHIP`, `FeeSplitter` (step 1), a treasury for liquidated collateral.

| Arg | Value | Meaning |
|---|---|---|
| `multisig` | `MULTISIG` | Owner. |
| `chipToken_` | `CHIP` | What is lent and repaid. |
| `feeSplitter_` | FeeSplitter from step 1 | Fees flow here, so a loan funds the next round. |
| `treasury_` | `LOAN_TREASURY` | Where liquidated collateral goes. |
| `terms_` | `{length: [7d, 14d, 30d, 90d, 180d], feeBps: [50, 100, 200, 500, 900], bountyBps: 200, lateFeeBps: 100}` | Five terms, fees, bounty, late fee. |

Term lengths must strictly increase and fees must not decrease across them; `feeBps` is
capped at `MAX_FEE_BPS` (5000) and `bountyBps` at `MAX_BOUNTY_BPS` (1000). Those two ceilings
are immutable — a compromised multisig cannot exceed them.

Then, from the multisig:

| Call | Meaning |
|---|---|
| `chipActivation.setCustodian(nounLoans, true)` | **The one that makes collateral keep earning.** |
| `setMaxPrincipal(LIL_NOUNS, amount)` | Per collection, in $CHIP. Zero means "cannot borrow". |
| `setMaxPrincipal(BASED_NOUNS, amount)` | Same. |
| `setMaxPrincipal(DARK_NOUNS, amount)` | Same. |
| `chip.approve(nounLoans, amount)` then `depositPool(amount)` | Seed the lending pool. |

**`maxPrincipal` MUST be set below Anvil parity.** The invariant is that borrowing is never a
better exit than selling, or defaulting becomes the rational move. The Anvil does not exist
as a contract on Base, so there is nothing to read and this cannot be enforced on chain — it
is an operational parameter the multisig sets and must keep reviewing against the floor.
Setting it to zero disables a collection immediately, in one transaction, with no timelock.

**V1 is a seeded pool, not a lending market.** `depositPool` and `withdrawPool` are multisig
only; there are no public lenders and no LP shares. `poolBalance` counts only $CHIP actually
on hand — principal out on loan is already deducted — so `withdrawPool` cannot spend money
that is not there.

**Fees are flat and paid up front.** A borrower receives principal minus the term's fee and
repays principal only. Nothing accrues, so nothing grows while a borrower is not looking.

**Daily operation** (all permissionless, anyone may run them):
- `repay(loanId)` — **anyone** may repay; the Noun always returns to the borrower.
- `liquidate(loanId)` — after maturity plus the loan's own grace, pays a bounty from the pool.

**Repayment ends at liquidation, not at a deadline.** Past maturity plus grace anyone may
seize the collateral, but the borrower may still repay until somebody does — for a
`lateFeeBps` surcharge. Fund `bountyReserve` separately from the pool so a liquidator is paid
even when lending capital is exhausted.

**Grace is derived, not configured: `min(7 days, term / 2)`.** So a 7-day loan is seizable on
day 10.5 rather than day 14, while everything from 30 days up keeps the same 7 days it always
had. It is snapshotted at borrow, so re-configuring the ladder never moves a live loan's
deadline. Read it with `graceFor(termIndex)` before borrowing, or `deadlineOf(loanId)` after.

Post-deploy checks:
- `owner()` is the multisig, `feeSplitter()` and `treasury()` are right
- `chipActivation.isCustodian(nounLoans)` is **true**
- `poolBalance()` equals what you deposited, and equals `chip.balanceOf(nounLoans)`
- take one small loan on a fork and confirm the Noun still scores weight in a round — that
  is the whole product, and it is the thing to check before anyone borrows for real
- `recoverExcess(CHIP, ...)` moves nothing while the pool is exactly backed

### 10. Anvil — **built**

Buy a Noun from the protocol's shelf at a fixed price, in ETH. **Buy side only at launch.**

Needs: `MULTISIG`, `FeeSplitter` (step 1), and Nouns to shelve.

| Arg | Value | Meaning |
|---|---|---|
| `multisig` | `MULTISIG` | Owner. |
| `feeSplitter_` | FeeSplitter from step 1 | **100% of revenue**, forwarded in the same transaction. |
| `premiumBps` | `2500` | +25% to pick a specific Noun rather than take the next in line. |

Then, from the multisig:

| Call | Meaning |
|---|---|
| `collection.setApprovalForAll(anvil, true)` then `shelve(collection, ids[])` | **Deposit order IS sale order.** |
| `queueQueuePrice(collection, wei)` → 48h → `executeQueuePrice(collection)` | The Box price. Zero means not for sale. |
| `setPaused(collection, bool)` | Immediate halt. Does not disturb the shelf. |
| `queueFeeSplitter(addr)` → 48h → `executeFeeSplitter()` | **CHANGED in `launch-candidate-11`.** `setFeeSplitter` no longer exists: redirecting 100% of revenue now gets the same notice a price change does. See TRIAGE batch 7 L-1. |

> **Every queued change now EXPIRES.** A matured price, premium or splitter change stays
> executable for `CONFIG_GRACE` — **14 days** — and then reverts `TimelockExpired` and must be
> re-queued. Queue-then-forget no longer leaves a dormant capability in storage. Plan the
> 48-hour wait and the execution in the same operational window.

**Two ways to buy, and the difference is the product.** `buyNext` is the Box: it pays
`queuePrice` for **the oldest Noun on the shelf**, and you do not choose. It is FIFO by
design — `nextOnShelf(collection)` returns exactly which token you will receive before you
call, so it is a queue with a readable head, **not a lottery**. Say that plainly on the site;
"mystery box" invites the opposite assumption. `snipe` lets you pick any shelved Noun for
`queuePrice × 1.25`, and sniping does **not** reorder the queue — the token's slot is retired
in place and the FIFO cursor skips the hole.

**A RESTOCKED NOUN GOES TO THE BACK.** If the protocol buys back a Noun that was sniped or
unshelved and re-shelves it, it joins at the tail, because that is when it re-joined. Before
`launch-candidate-11` it reappeared at the position it had left (TRIAGE batch 7 M-1). Worth
knowing operationally: **restocking a specific Noun cannot be used to promote it**, and the
site's shelf order is the real sale order.

**The sell side is not built.** `sellToAnvil` always reverts `SellNotOpen` and `sellEnabled`
is a constant `false` **with no setter**, so it cannot be switched on by mistake. A
guaranteed exit is a solvency commitment; it ships after the audit, in a deployment that
implements it. The site reads `sellEnabled()` and says so.

**A purchased Noun arrives un-chipped**, structurally: the Anvil is not a registered
custodian, so shelving voids any prior activation and the buyer chips it themselves.

**Withdrawals come off the TAIL.** `unshelve` pops from the most-recently-shelved end, so the
multisig can shrink the shelf but can never take the Noun the next buyer is about to receive.

**WINDING A SHELF DOWN TAKES TWO TRANSACTIONS.** At exactly one Noun left the tail *is* the
head, so `unshelve` reverts `WouldTakeTheHead` on a live shelf (TRIAGE batch 7 L-3). To empty
a collection: `setPaused(collection, true)` first — that is the statement that nobody is about
to buy anything here — then `unshelve`. A paused shelf can be taken to zero. Do not plan a
wind-down as a single transaction.

Post-deploy checks:
- `owner()` is the multisig, `feeSplitter()` is right
- `sellEnabled()` is **false**, and `sellToAnvil` reverts `SellNotOpen`
- `nextOnShelf(collection)` names the token you expect to go first
- `prices(collection)` returns `(queuePrice, queuePrice + 25%)`
- buy one at the exact price: confirm 100% landed at the FeeSplitter and
  `address(anvil).balance` is **0** — the Anvil has no ETH withdraw path by design
- `shelfQueue(collection)` matches the order you shelved in, and `shelfRemaining` matches its
  length. These are now O(1)/exact rather than counted, so a mismatch means a real problem
- snipe one from the middle and confirm `shelfQueue` loses exactly that entry and nothing
  moves position
- `unshelve(collection, <everything>, ...)` reverts `WouldTakeTheHead` while unpaused

---

## Verification

```
forge verify-contract --chain base <address> src/FeeSplitter.sol:FeeSplitter \
  --constructor-args $(cast abi-encode "constructor(address,address,address,uint32,uint32)" \
  $MULTISIG $POT $OPS_WALLET 2000 2000)
```
