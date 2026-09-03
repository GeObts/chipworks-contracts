# DEPLOY.md — Chipworks on Base (8453)

Grows as each contract lands. Read `ASSUMPTIONS.md` first; several blockers there must be
closed before anything is deployed to mainnet.

Solidity 0.8.24 · EVM `cancun` · OpenZeppelin v5.1.0 · optimizer on, 200 runs.

---

## Address book (fill in before deploying)

| Name | Value | Notes |
|---|---|---|
| `MULTISIG` | _TBD_ | Owner of every governed contract. Existing Chipworks/Goya Safe. |
| `OPS_WALLET` | _TBD_ | Goya's Bankr wallet. Receives the 20% ops share. |
| `LOAN_TREASURY` | _TBD_ | Where liquidated NounLoans collateral goes. May be the Safe. |
| ~~`CLUTCH_VAULT_*`~~ | — | **Gone.** Chipworks runs its own activation vault; see step 4. |
| `LIL_NOUNS` | `0xe3c5Ef27B80481518a2363406e354a9361415556` | Verified on Base: ERC-721, 4,420 supply, EIP-1967 proxy, NOT Enumerable. |
| `BASED_NOUNS` | _TBD_ | ERC-721. |
| `DARK_NOUNS` | _TBD_ | ERC-721. |
| `CHIP` | _TBD_ | $CHIP, a standard ERC-20 from the Doppler/Bankr launch. **No `burn()`**, so every burn in this repo is a transfer to `0xdead`. Needed by ChipRounds (split fee), ChipActivation (activation cost) and Furnace (forge cost). |

---

## Order

Deploy in this order. Each step lists what it needs from earlier steps.

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
| `slipstreamFactory_` | `0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A` | Verifies Aerodrome Slipstream pools. |

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

All nine need `tokenDecimals = 8` and a `minLiquidityUsd` you choose (see below). The four
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
- `stockCount()` is 9, `enabledTokens().length` is 0
- `getStock(NVDA).pool` matches the table above

### 3. Pot — **built**

Needs: `MULTISIG`, USDC. Deploy before ChipRewards.

| Arg | Value |
|---|---|
| `multisig` | `MULTISIG` |
| `quoteToken_` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |

After ChipRewards exists, call `setRewards(chipRewards)` from the multisig. Then go back to
step 1 and call `FeeSplitter.setPot(pot)`.

Then configure the ETH conversion, multisig only:

```
setConversionConfig(
  weth              = 0x4200000000000000000000000000000000000006,
  ethUsdFeed        = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70,   // "ETH / USD", 8 dp, verified
  swapRouter        = 0x2626664c2603336E57B271c5C0b26F421741e481,   // Uniswap SwapRouter02, verified
  conversionFee     = 500,        // 0.05% tier
  maxSlippageBps    = 100,        // 1% below the Chainlink mark
  maxConvertPerCall = 5 ether,    // cap per call
  maxFeedAge        = 3600        // 1h staleness limit
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
| `setRounds(chipRounds)` | after step 5b — the only contract allowed to write credits |
| `setPolTreasury(polTreasury)` | after step 6 |
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

Then configure, all from the multisig:

| Call | Recommended value |
|---|---|
| `setRoundParams(duration, window, minPot, maxBudget)` | `86400, 7200, 250e6, 10000e6` |
| `setCollectionBaseBps(LIL_NOUNS, 5000)` | Lil = 0.5x |
| `setCollectionBaseBps(BASED_NOUNS, 10000)` | Based = 1.0x |
| `setCollectionBaseBps(DARK_NOUNS, 20000)` | Dark = 2.0x |
| `setRouters(uniswapRouter, slipstreamRouter)` | Uniswap v3 SwapRouter02; Slipstream router |
| `setPolTreasury(polTreasury)` | after step 6 — receives the holdback |
| `setChip(chipToken, 0x…dead)` | after the $CHIP launch |
| `setHoodie(hoodieCollection, 11000)` | 1.10x boost |
| `setHoldbackBps(1500)` | the spec's 15%. Range 0–2500, ceiling immutable |
| `setDefaultMaxSlippageBps(200)` | 2% around the Chainlink mark |
| `setMaxSlippageBps(stock, bps)` | per-stock override where needed |

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

### 6. POLTreasury — **built**

Needs: `MULTISIG`, USDC, the Slipstream position manager, and the FeeSplitter from step 1.

| Arg | Value |
|---|---|
| `multisig` | `MULTISIG` |
| `quoteToken_` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| `positionManager_` | `0x827922686190790b37229fd06084350E74485b72` (verified: Slipstream `mint` with tickSpacing + sqrtPriceX96) |
| `feeSplitter_` | FeeSplitter from step 1 |

Then, from the multisig:
- `setManager(BANKR_OPTIMIZER)` — may manage positions, cannot change configuration
- `setRewards(chipClaims)` — the ledger is what notifies compound credits
- `setPolAsset(token, true)` for each stock POL will hold (protects it from the rescue)
- `setWeth(WETH)` and `setRoute(WETH, ETH_USD_FEED, …)` so POL can realise its ETH slice
- `setRoute(AERO, AERO_USD_FEED, …)` if POL keeps any of its own AERO
- `setIncomeToken(AERO, true)` and any fee tokens (enables `forwardIncome`)

And on ChipRewards:
- `setPolTreasury(polTreasury)`
- `setHoldbackBps(1500)` — the spec's 15%. Range 0–2500; the 25% ceiling is immutable.

Income loop, all permissionless: `collectAllFees()` → `forwardIncomeMany([AERO, ...])` →
FeeSplitter → 80% Pot → next round. Nobody needs permission to push income back to holders.

Post-deploy checks:
- `isProtected(USDC)`, `isProtected(NVDAc)` and `isProtected(AERO)` all true
- `manager` is the optimizer, and calling `setFeeSplitter` from it reverts
- mint one small position and confirm `positionCount()` is 1 and the NFT is held here

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

Needs: `MULTISIG`, `$CHIP`, `LIL_NOUNS`, and the two output collections.

**Deploy this last, and understand that it is not part of the money path.** The Furnace
shares no storage, no inheritance and no call path with ChipRounds, ChipClaims, Pot or
POLTreasury, and nothing in that set references it. It can be deployed, paused, or never
deployed at all without touching a single reward. Order relative to steps 1–7 does not
matter; it is listed last because it depends on `$CHIP` existing.

| Arg | Value | Meaning |
|---|---|---|
| `multisig` | `MULTISIG` | Owner. Two-step ownership transfer. |
| `chipToken_` | `$CHIP` | Burned alongside the Lils. Must exist first. |
| `lilCollection_` | `LIL_NOUNS` | The fuel. `0xe3c5Ef27B80481518a2363406e354a9361415556`. |
| `basedRecipe` | `{outputCollection: BASED_NOUNS, lilCost, chipCost}` | Recipe id 0, `FORGE_BASED`. |
| `darkRecipe` | `{outputCollection: DARK_NOUNS, lilCost, chipCost}` | Recipe id 1, `FORGE_DARK`. |

Pass `exists: true, paused: false` in both structs; the constructor rewrites both flags, so
their value in calldata is ignored. `lilCost` must be in `1..100` (`MAX_LIL_COST`) or the
constructor reverts. `chipCost` may be zero, which makes a recipe Lils-only.

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
queueRecipeChange(recipeId, lilCost, chipCost)     // emits RecipeChangeQueued(.., executableAt)
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
| `terms_` | `{length: [30d, 90d, 180d], feeBps: [200, 500, 900], bountyBps: 200}` | Terms, fees, bounty. |

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
- `liquidate(loanId)` — after maturity + 7 days grace, pays a bounty from the pool.

Post-deploy checks:
- `owner()` is the multisig, `feeSplitter()` and `treasury()` are right
- `chipActivation.isCustodian(nounLoans)` is **true**
- `poolBalance()` equals what you deposited, and equals `chip.balanceOf(nounLoans)`
- take one small loan on a fork and confirm the Noun still scores weight in a round — that
  is the whole product, and it is the thing to check before anyone borrows for real
- `recoverExcess(CHIP, ...)` moves nothing while the pool is exactly backed

---

## Verification

```
forge verify-contract --chain base <address> src/FeeSplitter.sol:FeeSplitter \
  --constructor-args $(cast abi-encode "constructor(address,address,address,uint32,uint32)" \
  $MULTISIG $POT $OPS_WALLET 2000 2000)
```
