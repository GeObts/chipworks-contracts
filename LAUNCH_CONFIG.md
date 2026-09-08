# LAUNCH_CONFIG.md — the runbook

Every locked parameter, in the order it is used, merged with `DEPLOY.md`'s sequence.
`DEPLOY.md` explains *why* each contract is wired the way it is; **this file is what you
execute on the day.** Where they disagree, this file is newer.

Solidity 0.8.24 · EVM `cancun` · OpenZeppelin v5.1.0 · optimizer 200 runs · Base mainnet 8453.

---

## 0. The disclosure line

Verbatim, on the site, in the docs, and in the launch thread. Do not paraphrase it.

> $CHIP's token and pool are Bankr/Doppler audited infrastructure. Chipworks' own contracts
> are awaiting independent audit; launch caps are in effect until it completes.

It is two sentences because it makes two different promises, and collapsing them into one
would blur the line between what someone else audited and what nobody has yet. The caps in
§5 are what make the second sentence true — if you raise them before the audit lands, this
line stops being accurate and has to come down.

> ⚠️ **The line above is still accurate. Copy that names a per-round dollar cap is not.**
> There is no round maximum any more — see the red box in §5. Before posting the launch
> thread or shipping the site's launch-caps section, check both against §5's replacement
> wording. This affects **external copy only**; no contract or setting changes.

---

## 1. The critical path, and what actually blocks it

Three things gate everything else. Read this before booking a launch date.

| Blocker | Duration | What it blocks |
|---|---|---|
| **$CHIP must launch first** | — | 4 contracts take it as a constructor argument |
| **ChipBurner must exist first** | — | ChipActivation, ChipRounds and the Furnace take it as an **immutable** argument |
| **Price discovery: 24–48h observed** | 1–2 days | The entire cost table (§4). ChipActivation cannot deploy before it |
| **48h timelocks** | 2 days each, parallel | Pricing each collection in ChipActivation; NounLoans terms |

**These do not fully overlap.** ChipActivation deploys with a cost table computed from the
observed price, so the timelock cannot start until price discovery finishes. Realistic shape:

```
Day 0     $CHIP launches. Initial buy inside the window (§3).
          Deploy ChipBurner, then chip.transferOwnership(ChipBurner) (§6.6).
Day 1–2   Observe. Do NOT compute the table from day-0 volatility.
Day 2     Compute the cost table (§4). Deploy ChipActivation. setFlatRateCollection
          (CHIPLETS), then queue costs for all FOUR collections. Queue NounLoans
          terms. Queue Anvil prices.
          Queue both Furnace recipe prices (25 / 50 Chiplets).
Day 4     Execute all queued config. Deploy the rest. Wire. Verify.
Day 5     First round.
```

**The Burner is deployed before it is given the token.** `ChipBurner(MULTISIG, CHIP)` needs
only the token's address, so it can go out the moment $CHIP exists; the `transferOwnership`
hand-off is separate and is what §6.6 gates. Doing both on day 0 keeps the three contracts that
take its address unblocked.

Anything that can be deployed before $CHIP exists — FeeSplitter, StockRegistry, Pot,
POLTreasury — can be done on day 0 to shorten the tail.

---

## 2. $CHIP via Bankr — locked settings

| Setting | Value | Why it is this |
|---|---|---|
| Mode | **standard** (NOT degen) | Degen mode is the wrong shape for a token with a burn sink and a lending pool behind it |
| Quote asset | **WETH** | Matches the Anvil, which prices in ETH, so there is one unit of account across the protocol |
| Vesting | **ON** | |
| `quoteonlyfees` | **TRUE** | Fees accrue in WETH only. Keeps the fee stream in the asset the FeeSplitter already routes, instead of accruing $CHIP the protocol would have to sell |
| `schedulestarttime` | **the announced launch time** | Set it explicitly. Do not let it default |
| `rewardowneraddress` | **MULTISIG** at launch | Not the deploy wallet, not an EOA |
| `transfer_fee_recipient` | **FeeSplitter**, as an explicit POST-LAUNCH step | See below |

### transfer_fee_recipient is a post-launch step, on purpose

The FeeSplitter must exist and be wired before it is named as the fee recipient. Pointing a
live fee stream at an address that is not yet routing anywhere is how fees get stranded.

```
1. Launch $CHIP with the default fee recipient.
2. Deploy FeeSplitter (§6 step 1) and confirm `distributeETH()` lands 80/20.
3. THEN set transfer_fee_recipient -> FeeSplitter.
4. Confirm a fee actually arrives and splits.
```

### The keeper job: claim_token_fees

Fees do not sweep themselves. **A keeper must call `claim_token_fees` on a cadence** or the
fee stream silently accrues and never reaches the Pot.

- **Cadence: daily**, same job that runs `pot.convert()` and `openRound()`.
- It is permissionless in the same spirit as the rest of the keeper work — if the bot dies,
  anyone can run it, and nothing is lost in the meantime, only delayed.
- **Add it to the keeper's alerting.** A silent no-op here looks exactly like "no volume",
  which is the failure mode that goes unnoticed for a month.

---

## 3. The initial buy

| | |
|---|---|
| Size | **0.25–0.5 ETH** |
| Source | the deploy wallet |
| When | inside the launch window |
| Destination split | **~80% NounLoans pool seed / ~20% multisig reserve** |

The 80% is what makes lending work on day one: `NounLoans` is a seeded pool with exactly one
depositor, and with an empty pool `borrow` reverts `PoolTooSmall` and the headline feature is
dead on arrival. The 20% reserve is for the operational things that always come up — a
mispriced parameter that needs a timelocked correction, a gas float, a market that needs
seeding.

**This buy is also the price signal that §4 reads.** Do not compute the cost table from the
first hour; see §4.

---

## 4. The cost table — computed POST-launch, from observed price

**ChipActivation deploys with this table already computed.** It is not a placeholder to fill
in later: the collection cannot be activated until its costs are executed, and executing
costs a 48h timelock.

### The formula

1. **Observe the price for 24–48 hours.** Not the launch candle. Not the first hour.
2. **Base unit: the tier-0 chip cost is a round, 50,000-style number of $CHIP** — the
   round number nearest to **$5** at the observed price. Round to something a person can say
   out loud: 50,000 / 100,000 / 250,000, not 63,412.
3. **The tier ladder is 10 / 22 / 45 / 90 / 240 %** of… nothing abstract — read it as the
   multiples below. Tier 0 is the base unit; each tier is priced at that shape:

| Tier | Weight | Shape | Cost, if the base unit is 50,000 |
|---|---|---|---|
| 0 | 1.00x | base (10%) | 50,000 |
| 1 | 1.25x | 22% | 110,000 |
| 2 | 1.60x | 45% | 225,000 |
| 3 | 2.00x | 90% | 450,000 |
| 4 | 3.33x | 240% | 1,200,000 |

Scale every row by the same factor if the base unit is not 50,000. **Costs must be
non-decreasing across tiers or `queueCosts` reverts `BadConfig`** — the shape above always
satisfies that, but a hand-edited table might not.

4. **Furnace recipes** scale the same way: the Based recipe is the **25,000-shape** and the
   Dark recipe the **60,000-shape** — i.e. 0.5x and 1.2x the base unit.
5. **Split-change fee = 10% of the tier-0 chip cost.** At a 50,000 base that is 5,000 $CHIP,
   which is the `splitChangeFeeChip_` constructor argument on ChipRounds.
6. **Chiplets activation = a FLAT 10% of the base unit.** At a 50,000 base that is **5,000
   $CHIP**, and it is one price rather than a ladder: Chiplets are registered with
   `setFlatRateCollection` and `queueCosts` demands **five equal entries**, so the whole table
   is `[5_000e18 x5]`. Scale it with the base unit like everything else.

   > It is the same **number** as the split-change fee at a 50,000 base, and they are not the
   > same **thing** — one is what a Chiplet costs to activate, the other is what changing a
   > split costs. They move together only because both are 10% of the base unit.

### Worked example, at a base unit of 50,000

```
ChipActivation.setFlatRateCollection(CHIPLETS)          # FIRST, before its executeCosts
ChipActivation.queueCosts(LIL_NOUNS,   [50_000e18, 110_000e18, 225_000e18, 450_000e18, 1_200_000e18])
ChipActivation.queueCosts(BASED_NOUNS, [ same ])
ChipActivation.queueCosts(DARK_NOUNS,  [ same ])
ChipActivation.queueCosts(CHIPLETS,    [5_000e18, 5_000e18, 5_000e18, 5_000e18, 5_000e18])
Furnace basedRecipe.chipCost =  25_000e18
Furnace darkRecipe.chipCost  =  60_000e18
ChipRounds splitChangeFeeChip_ = 5_000e18
```

**The same table for all three collections.** The collection multiplier lives in
`ChipRounds.collectionBaseBps` (0.5x / 1.0x / 2.0x), so pricing per collection as well would
apply the difference twice.

---

## 5. LAUNCH CAPS — all config, all reversible

These are what the disclosure line in §0 refers to. **Every one is a multisig setting, not a
constant**, so they lift when the audit lands without touching a contract.

| Cap | Value | Where |
|---|---|---|
| Round minimum | **$100** | `ChipRounds.setRoundParams(86400, 7200, 100e6)` — `minPot` |
| ~~Round maximum~~ | 🔴 **GONE. THERE IS NO ROUND CAP.** See below | — |
| Per-buy impact bound | **0.25% of measured pool depth**, the replacement | `defaultMaxImpactBps`, **already 25 from the constructor** |
| POL holdback | **15%** — unchanged | `ChipRounds.setHoldbackBps(1500)` |
| NounLoans `maxPrincipal` | **≈60% of the Anvil queue price**, per collection, denominated in $CHIP | `NounLoans.setMaxPrincipal` |
| NounLoans pool | seeded from the initial buy (§3) | `NounLoans.depositPool` |
| Furnace Based stock | deploy argument | `Furnace.depositStock` |
| Furnace Dark recipe | **deployed but PAUSED** | `Furnace.setPaused(1, true)` |

### 🔴 THE ROUND CAP NO LONGER EXISTS, AND THIS FILE USED TO SAY IT DID

`setRoundParams` takes **three** arguments — `(duration, window, minPot)`. `maxBudget` was
removed when the depth-aware impact trim landed (OPEN_ITEMS 26, `test/UncappedRounds.t.sol`),
so **the $1,000 round maximum this table used to list could never have been set.** The
four-argument call in a previous revision of §6 would have reverted on the day.

**What bounds exposure instead, and why it is a better bound.** `maxImpactBps` sizes every buy
from `poolLiquidityUsd` — measured pool depth — so what is extractable from any one stock is a
function of the POOL, not of the round. Doubling the round no longer doubles the exposure; it
spreads the same bounded buys over more rounds. That is precisely why the cap could come off,
and it is the mitigation the two accepted findings (EXT-R-L-1, SEC-POT-002) were conditioned
on. **The constructor already sets `defaultMaxImpactBps = 25`**, ceiling
`MAX_IMPACT_CEILING_BPS = 500`, so the protection is on by default and needs no deploy step.

> ⚠️ **THIS CHANGES WHAT §0'S DISCLOSURE LINE CAN HONESTLY CLAIM, AND WHAT THE SITE AND THE
> LAUNCH THREAD MAY SAY.** Three places still describe a round cap that does not exist, and all
> three are external-facing:
>
> 1. **§0's disclosure line** — *"launch caps are in effect until it completes"*. Still true,
>    but the caps are the ones remaining in this table (round MINIMUM, POL holdback,
>    `maxPrincipal`, paused Dark recipe) plus the per-buy impact bound. Do not let a reader
>    infer a per-round ceiling.
> 2. **The site's launch-caps copy**, wherever it names a dollar figure per round.
> 3. **The launch-thread / article copy**, same.
>
> **The honest replacement sentence:** *"each buy is limited to a fraction of the pool's
> measured depth, and the first rounds are funded small."* The second half is an operational
> promise, not a contract guarantee — keep the wording that way. **Fix this copy before
> posting anything.**

**Fund the first mainnet rounds small.** With no ceiling in the contract, round size is bounded
by what you put in the Pot. That is now an operational control rather than a configured one,
which means it needs a person to keep honouring it.

**`maxPrincipal` at ~60% of the Anvil queue price** is the parity invariant made concrete.
The rule is that borrowing must never beat selling, or defaulting becomes the rational move
and the pool systematically buys Nouns above market. The Anvil is now a real contract with a
real `queuePrice`, so for the first time this number has something to be measured against —
but **it still is not enforced on chain**, because the Anvil price is in ETH and the loan cap
is in $CHIP, and bridging them means trusting a price. Convert at the observed rate, set it,
and **re-check it whenever either side moves.** OPEN_ITEMS item 11.

**Dark recipe paused at deploy** so the Furnace ships with one working recipe and one visibly
switched off, rather than two live paths on day one. Unpausing is a single immediate call.

---

## 6. Deploy sequence, with verification reads

Every step's reasoning is in `DEPLOY.md`. Run the reads.

### Before $CHIP — can be done on day 0

**1. FeeSplitter** — `(MULTISIG, MULTISIG as placeholder pot, OPS_WALLET, 2000, 2000)`
```
owner() == MULTISIG ; opsBps() == 2000 ; potBps() == 8000
send 0.001 ETH, distributeETH(), confirm the 80/20 landing
```

**2. StockRegistry** — `(MULTISIG, USDC, UNI_FACTORY, SLIPSTREAM_FACTORY_B)` where
`SLIPSTREAM_FACTORY_B` is **`0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef`**.

> 🔴 **THIS IS THE ONE ADDRESS THAT CANNOT BE CORRECTED LATER.** There are two Aerodrome CL
> factories and every B20 stock pool is on this one. The older, better-known
> `0x5e7BB1…809A` (factory A) resolves **none** of them, and `slipstreamFactory` is
> **immutable** — a registry deployed against factory A cannot register a single stock as
> `Venue.Slipstream` and has to be redeployed. It does at least fail loudly
> (`PoolNotFoundInFactory`) rather than silently. ASSUMPTIONS A-22.

Register all **thirteen** B20 stocks disabled (addresses and feeds: ASSUMPTIONS A-13/A-18).
Ten register as `Venue.Slipstream` at **tick spacing 10**; COIN, CRCL and INTC have no pool
anywhere and register as `Venue.None`.
```
stockCount() == 13 ; enabledTokens().length == 0
getStock(NVDAc).venue == Slipstream ; getStock(NVDAc).tickSpacing == 10
setEnabled(CRCLc, true)  -> reverts PoolNotSet     # no market yet
liquidityReport()        # ten clearing $25k, the deepest four over $1M
```

**3. Pot** — `(MULTISIG, USDC, UNIV3_FACTORY)`, then `setConversionConfig`, `setRoute(AERO)`
and `setSequencerFeed`. The factory argument makes a Slipstream router unconfigurable
(SEC-POT-001); the sequencer feed is `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` with a 1h
grace (SEC-POT-003, ASSUMPTIONS A-19).
```
pullBudget(1)  from anyone  -> reverts NotRewards  # nobody can pull yet
setRewards(<an EOA>)        -> reverts NotAContract # SEC-POT-006
setRoute(.., <slipstream router>, ..) -> reverts RouterNotUniswapV3   # SEC-POT-001
sequencerUptimeFeed()       -> 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433
```

**6. POLTreasury** — `(MULTISIG, USDC, POSITION_MANAGER, FeeSplitter, UNIV3_FACTORY,
AERO_VOTER)` where `AERO_VOTER` is `0x16613524e02ad97eDfeF371bC883F2F5d6C480A5`.

Each POL asset is registered with its feed and its band:
`setPolAsset(NVDAc, NVDA_USD_FEED, 500, 0)` — 5%, and `maxFeedAge` **0 for equities**, because
the B20 feeds have no off-hours heartbeat (A-14) and a real window would refuse every mint
outside market hours. Use a real window (1 hour) only for 24/7 assets such as WETH.
```
isProtected(USDC) && isProtected(AERO) && isProtected(POSITION_MANAGER) == true
positionFactory() == 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A
setIncomeToken(USDC, true)  -> reverts TokenNotDisjoint      # M-02
setPolAsset(AERO, feed, 500, 0) -> reverts TokenNotDisjoint  # M-02, other direction
stakePosition(id, <not the canonical gauge>) -> reverts GaugeNotCanonical   # H-01
mintPosition(.., token1: <unregistered token>, ..) -> reverts TokenNotPolAsset  # H-02
mintPosition(.., amount0Min: 0, amount1Min: 0) -> reverts SlippageUnbounded # H-02
markAndPoolPrice(NVDAc, <pool>) -> two numbers inside the band
```

### After $CHIP, after price discovery

**4. ChipActivation** — `(MULTISIG, CHIP, ChipBurner, [10000, 12500, 16000, 20000, 33300])`
Then `setFlatRateCollection(CHIPLETS)` **first**, then `queueCosts` **x4** with the §4 table →
**48h** → `executeCosts` **x4**. All four earning collections are priced here: LIL, BASED, DARK
tiered, and CHIPLETS flat at `[5_000e18 x5]`.
```
allTierBps() == [10000,12500,16000,20000,33300]
isFlatRate(CHIPLETS) == true            # BEFORE its executeCosts, or ChipActivation redeploys
isSupportedCollection(BASED_NOUNS) == false BEFORE executeCosts, true after
activate(BASED_NOUNS, id, 0) before executeCosts -> reverts CollectionNotConfigured
chip.balanceOf(chipActivation) == 0   after a test activation
# and the reset, with no keeper in between:
activate a Noun, transfer it, isActive() -> false
```

**5a. ChipClaims** — `(MULTISIG, StockRegistry)`. **The deploy timestamp fixes the claim
window's day of the week, permanently.** Pick it deliberately.
```
setClaimSchedule(604800, 172800) ; setCreditExpiry(2592000)
```

**5b. ChipRounds** — `(MULTISIG, registry, Pot, ChipActivation, ChipClaims, 5_000e18,
ChipBurner)`
```
setRoundParams(86400, 7200, 100e6)            # THREE arguments. There is no maxBudget (§5)
setCollectionBaseBps(LIL, 5000) / (BASED, 10000) / (DARK, 20000) / (CHIPLETS, 1000)
setHoldbackBps(1500) ; setDefaultMaxSlippageBps(200) ; setMaxFeedAge(432000)
setChip(CHIP)                                 # ONE argument - the burn target is immutable
setRouters(0x2626664c2603336E57B271c5C0b26F421741e481,
           0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F)
slipstreamRouter() == 0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F
```

> ### 🔴 ALL FOUR COLLECTIONS NEED A `baseBps`, AND A MISSING ONE IS SILENT
>
> `collectionBaseBps` defaults to **0**, and a collection at zero earns **nothing** — every
> holder in it scores zero weight in every round, for ever, with no revert and no event. It is
> the same failure shape as the custodian wire in §7, and it has four chances to happen instead
> of one.
>
> **CHIPLETS is the one that gets forgotten**, because it is the newest and because it is the
> only collection whose multiplier is not mentioned anywhere else in this file.
>
> ```
> setCollectionBaseBps(LIL_NOUNS,   5000)    # 0.5x
> setCollectionBaseBps(BASED_NOUNS, 10000)   # 1.0x
> setCollectionBaseBps(DARK_NOUNS,  20000)   # 2.0x
> setCollectionBaseBps(CHIPLETS,    1000)    # 0.1x   <- the one that gets missed
> ```
>
> **Run all four reads before you sign off. Every one must be non-zero and exact:**
>
> ```
> cast call $CHIP_ROUNDS "collectionBaseBps(address)(uint32)" $LIL_NOUNS   --rpc-url $BASE_RPC_URL  #  5000
> cast call $CHIP_ROUNDS "collectionBaseBps(address)(uint32)" $BASED_NOUNS --rpc-url $BASE_RPC_URL  # 10000
> cast call $CHIP_ROUNDS "collectionBaseBps(address)(uint32)" $DARK_NOUNS  --rpc-url $BASE_RPC_URL  # 20000
> cast call $CHIP_ROUNDS "collectionBaseBps(address)(uint32)" $CHIPLETS    --rpc-url $BASE_RPC_URL  #  1000
> ```
>
> **And the read that proves it end to end**, because a non-zero setting still does not prove a
> Chiplet scores: activate one, contribute it to an open round, and check the round's weight
> actually moved.
>
> ```
> # totalWeight BEFORE and AFTER contributeWeights(id, CHIPLETS, [tokenId])
> cast call $CHIP_ROUNDS "getRound(uint256)" $ROUND_ID --rpc-url $BASE_RPC_URL
> #   -> totalWeight must INCREASE. If it does not, the collection is at zero.
> ```
>
> Asserted for all four collections by `test_theWholeDeploySequence` in
> `test/fork/DeployRehearsal.t.sol`, which fails if any of them is left at zero.

> ✅ **THE SLIPSTREAM ROUTER MUST BE THE FACTORY-B ONE — AND SINCE `-22` THE CONTRACT
> ENFORCES IT.** `0x698Cb2…A92F` is bound to factory B and is the only router that can reach a
> B20 pool. The better-known `0xBE6D8f…18a5` serves factory A.
>
> `setRouters` now reads the factories off the registry and refuses any router that does not
> match, so **the wrong address reverts at set-time** with `RouterNotOnFactory(router,
> expected, actual)` naming both. Neither router may be zero, and an EOA is refused with
> `NotAContract`.
>
> This used to be the entry with the worst failure mode in this runbook: no validation at all,
> and the symptom of getting it wrong was a round that bought nothing, which reads like a depth
> problem rather than a wiring one. It is now a loud failure in the transaction that causes it.
> Both directions are still proved on a live fork in `test/fork/FactoryBRouter.t.sol`, and the
> guard itself in `test/RouterGuards.t.sol`.

> **⚠️ WIRING CHECK — `claims.setRounds(rounds)`**
> Until this is called, **every round reverts at the first `contributeWeights`**, because the
> ledger rejects writes from an unknown caller. This one fails loudly, which is why it is a
> check and not a trap.
> ```
> cast call $CHIP_CLAIMS "rounds()(address)"  --rpc-url $BASE_RPC_URL   -> ChipRounds
> cast call $CHIP_ROUNDS "claims()(address)"  --rpc-url $BASE_RPC_URL   -> ChipClaims
> cast call $POT         "rewards()(address)" --rpc-url $BASE_RPC_URL   -> ChipRounds
> ```

**7. ClaimRouter** — `(MULTISIG, **ChipClaims**, 1000000)`. Points at the ledger, not the
engine. One leg; the Clutch leg is gone.

**8. Furnace** — `(MULTISIG, CHIP, ChipBurner, CHIPLETS, basedRecipe, darkRecipe)`.

The fuel is **Chiplets**, not Lils — Lils reverted to an ordinary 0.5x family collection and
are never burned (OPEN_ITEMS 20). The Chiplet counts are **25 for a Based Noun, 50 for a
DarkNOUN**, twice the Based count to match the 2.0x base a DarkNOUN earns at. The `chipCost` on
both recipes is a **placeholder at deploy** — it cannot be zero — so pause both immediately and
queue the real prices against the observed §4 price.
```
approve + depositStock(BASED_NOUNS, ids)
setPaused(0, true) ; setPaused(1, true)   # BOTH off at launch, placeholder prices
recipe(0).fuelCost == 25 ; recipe(1).fuelCost == 50
forge(1, ids) -> reverts RecipeIsPaused
# then, once the price is observed:
queueRecipeChange(0, 25, <real>) ; queueRecipeChange(1, 50, <real>)  -> 48h -> execute, unpause
```

**9. NounLoans** — `(MULTISIG, CHIP, FeeSplitter, LOAN_TREASURY, **ChipActivation**, terms)`
Terms: `{length: [7d, 14d, 30d, 90d, 180d], feeBps: [50, 100, 200, 500, 900], bountyBps: 200, lateFeeBps: 100}`.

**Short terms are the product** — fast churn, fast liquidations — so the ladder starts at a
week. The fee rises with duration while the per-day rate falls (7.1 bps/day at 7d down to 5.0
at 180d), which is what makes the long end worth taking. `_validateTerms` enforces strictly
increasing lengths and non-decreasing fees, so the shape cannot be configured backwards.

Grace is **derived**, not configured: `min(7 days, term / 2)`. A 7-day loan gets 3.5 days, a
14-day loan exactly 7, and everything above is capped at the same week it always had.
```
setMaxPrincipal(each collection, ~60% of Anvil queue price in $CHIP)
approve + depositPool(80% of the initial buy)
poolBalance() == chip.balanceOf(nounLoans)
```

**10. Anvil** — `(MULTISIG, FeeSplitter, 2500)`
Then `shelve` per collection, and `queueQueuePrice` → **48h** → `executeQueuePrice`.

The fee splitter is timelocked too since `launch-candidate-11` — `queueFeeSplitter` → 48h →
`executeFeeSplitter`; there is no instant setter. **And every queued change expires 14 days
after it matures** (`CONFIG_GRACE`), so queue and execute inside one operational window.
```
sellEnabled() == false                  # and there is no setter
sellToAnvil(...) -> reverts SellNotOpen
nextOnShelf(BASED_NOUNS)                # the Box's head is readable before anyone buys
prices(BASED_NOUNS) -> (queuePrice, queuePrice + 25%)
shelfQueue(BASED_NOUNS)                 # exactly the order you shelved in
buyNext with the exact price, confirm 100% landed at the FeeSplitter and the Anvil holds 0
unshelve(BASED_NOUNS, shelfRemaining(), ops) -> reverts WouldTakeTheHead  # L-3
```
**Winding a shelf down is two transactions**: `setPaused(collection, true)`, then `unshelve`.
A live shelf will not give up its last Noun.

---

## 6.5 🔴 REQUIRED PRE-LAUNCH: prove the Chiplet burn is a REAL burn

**Not optional, and not a smoke test.** The Furnace and ChipActivation both fall back to a
transfer to `0xdead` when a collection exposes no `burn`. That fallback is deliberate — it
keeps forging and activation working against any ERC-721 — and it is **silent**. A mis-wired or
unexpected Chiplets contract would forge and activate perfectly while never reducing supply,
which is the entire point of the change. Nothing else catches it.

**Check one — the selector is in the deployed bytecode.**

> 🔴 **$CHIP IS AN EIP-1167 MINIMAL PROXY, AND THE OBVIOUS CHECK RETURNS ZERO ON IT.**
> `0x75Af968d…11bA3` is 44 bytes of proxy that delegates to
> `0xdb7b520bb5c3a2c5d4871198081911359f93be87`. A proxy contains **no function selectors at
> all**, so `cast code $CHIP | grep -c 42966c68` returns **0** — and that is not a missing
> burn, it is the wrong contract to grep. **Run every selector check against the
> IMPLEMENTATION.**
>
> ```
> # pull the implementation out of the 1167 proxy (bytes 10..29 of the runtime code):
> CHIP_IMPL=0x$(cast code $CHIP --rpc-url $BASE_RPC_URL | cut -c23-62)
> echo $CHIP_IMPL          # -> 0xdb7b520bb5c3a2c5d4871198081911359f93be87
>
> cast code $CHIP_IMPL --rpc-url $BASE_RPC_URL | grep -c 42966c68   # burn(uint256)      -> 1
> cast code $CHIP_IMPL --rpc-url $BASE_RPC_URL | grep -c 98cd6153   # updateTokenURI     -> 1
> cast code $CHIP_IMPL --rpc-url $BASE_RPC_URL | grep -c f2fde38b   # transferOwnership  -> 1
> ```
>
> **Verified 2026-09-08 against the live token: all three present.** `ChipBurner`'s three
> encoded signatures therefore resolve. State reads (`owner()`, `totalSupply()`,
> `balanceOf`) still go to the PROXY address — only the bytecode greps move.

```
cast code 0xC7c114191aa3b2225F9bb053Bc55b3d6F145Bd33 --rpc-url $BASE_RPC_URL | grep -c 42966c68
# expect >= 1. ALREADY CHECKED 2026-09-07 and it returned 1, alongside:
#   name() = "CHIPLETS", symbol() = "CHIPP", supportsInterface(0x80ac58cd) = true
#   totalSupply() = 0        <- the drop had not minted yet; re-check after it does
```

OpenSea's `ERC721SeaDrop` and `ERC721SeaDropCloneable` both expose
`burn(uint256) { _burn(tokenId, true); }`, so the expected answer is a hit. If it is zero, stop
— the drop was deployed from a contract that cannot be truly burned from.

**Check two — the counters agree after the first real forge.**

```
furnace.totalFuelTrueBurned() == furnace.totalFuelBurned()          # must be EQUAL
```

Equal means every fuel token was destroyed. If `totalFuelTrueBurned` is lower, that many
tokens were dead-held instead and the collection's `totalSupply` did not move. Investigate
before announcing anything about supply.

**Check three — the same for the activation path.**

```
# activate one Chiplet, then read the ActivatedFlat event:
#   sacrificeTrueBurned == true
chiplets.totalSupply()                                             # must have fallen by 1
```

**And the $CHIP side, which is now the same case.** This section used to say $CHIP could never
be truly burned. It can: the token's `burn` is owner-gated rather than absent, and the
`ChipBurner` owns it. Once §6.6 has landed, `chip.totalSupply()` **does** fall.

```
chipActivation.chipBurnedToDead() == chip.balanceOf(0x...dEaD) + chip.balanceOf(<ChipBurner>)
chipActivation.effectiveChipSupply() == chip.totalSupply() - chipActivation.chipBurnedToDead()

# and the end-to-end one, after any app burn:
burner.burnAll() ; chip.totalSupply()          # must have FALLEN by what was burned
```

The site should still display `effectiveChipSupply()` — it counts $CHIP queued at the Burner as
already out of circulation, so the number does not step down at the arbitrary moment a keeper
calls `burnAll()`. **The CoinGecko/CMC filing is no longer required**; see BURN_VISIBILITY.md
for the one case where it is still worth doing.

---

## 6.6 🔴 REQUIRED AT LAUNCH: hand $CHIP ownership to the Burner

**Ordering matters and it is one-way-ish.** The Burner must exist before the token is handed
to it, and the hand-off can only happen after Bankr's launch has put ownership in our hands.

```
1. Deploy ChipBurner(MULTISIG, CHIP)                        # before launch is fine
2. Bankr launches $CHIP                                     # ownership lands with us
3. chip.transferOwnership(<ChipBurner>)                     # THE STEP
4. chip.owner() == <ChipBurner>                             # verify
```

**Verify the token's ABI before step 3, not after.** `ChipBurner` encodes three signatures by
string — `burn(uint256)`, `updateTokenURI(string)`, `transferOwnership(address)`. A mismatch
would not be discovered until the first burn, by which point the token is already owned by a
contract that cannot drive it.

```
cast code <CHIP> --rpc-url $BASE_RPC_URL | grep -c 42966c68     # burn(uint256)
cast sig "updateTokenURI(string)"                                # cross-check against the
cast sig "transferOwnership(address)"                            # verified token source
```

**Then prove it end to end, once, with a small amount:**

```
chip.transfer(<ChipBurner>, 1e18)
burner.burnAll()                       # permissionless, anyone
chip.totalSupply()                     # must have FALLEN by 1e18 - a real burn
burner.totalBurned()                   # == 1e18
burner.burnCount()                     # == 1
```

**`burnAll` is `nonReentrant` since `-22`, and `totalBurned` is bounded by the Burner's own
balance drop as well as by the fall in supply.** Neither changes anything for a well-behaved
token; both exist so that the published figure cannot be inflated by the token it burns. See
`test/ChipBurnerReentrancy.t.sol`.

**What the Burner deliberately cannot do.** It has no `transfer`, no sweep, no rescue and no
generic call: $CHIP that arrives can only ever leave by being destroyed, and the multisig
cannot move it either. `mintInflation`, `updateMintRate` and `lockPool`/`unlockPool` are **not
exposed** — a permissionless burner that can also mint is a contradiction. If any of them is
ever genuinely needed, `transferTokenOwnership` moves the token to a new wrapper, visibly and
deliberately. That escape hatch is why leaving them out is safe.

**Until step 3 lands, `burnAll()` reverts** — the token's `burn` is owner-gated. App burn paths
that send $CHIP to the Burner before then will simply accumulate a balance that gets destroyed
on the first successful call. Nothing is lost; the burn is just deferred.

---

## 7. 🔴 THE ONE THAT FAILS SILENTLY

> **`chipActivation.setCustodian(nounLoans, true)` — DO NOT SIGN OFF WITHOUT THIS RETURNING
> `true`.**
>
> Every other wiring mistake in this runbook reverts. This one does not. Skip it and
> everything looks healthy: loans open, $CHIP is disbursed, collateral is held, rounds run,
> other holders are paid. The only symptom is that **every borrower silently stops earning
> the moment they deposit** — no error, no event, no failed transaction. It is the headline
> feature of NounLoans failing invisibly.
>
> ```
> cast call $CHIP_ACTIVATION "isCustodian(address)(bool)" $NOUN_LOANS --rpc-url $BASE_RPC_URL
> #   -> true      REQUIRED
> ```
>
> **And the end-to-end read, which is the one worth the extra minutes** — `isCustodian` only
> proves the allowlist entry exists, not that `beneficiaryOf` answers the way ChipActivation
> expects:
>
> ```
> # on a fork, with a real Noun:
> #   1. chipActivation.activate(collection, tokenId, tier)
> #   2. nounLoans.borrow(collection, tokenId, term, principal)
> #   3. chipActivation.isActive(collection, tokenId)        -> TRUE
> #   4. chipActivation.effectiveOwner(collection, tokenId)  -> the BORROWER
> ```
>
> If step 3 is `false`, the wire is missing. **The fix is one call, retroactive, and needs no
> action from any borrower** — activations come back the instant the custodian is registered.
> Nothing is lost; it just has to be noticed.
>
> Walked end to end by `test_theCustodianWireIsTheOneMistakeThatFailsSilently`.

Note the ordering trap: NounLoans (9) must exist before this call, but ChipActivation (4)
deploys long before it. It is the **last** wire in the sequence and the easiest to lose.

---

## 8. Day-one operations

**Keeper, daily, all permissionless:**
```
claim_token_fees                        # §2 — silent no-op if forgotten
pot.convert() ; pot.convert(AERO)
rounds.openRound()
rounds.contributeWeights(id, collection, ids[])   # batched, all three collections
rounds.closeAccumulation(id)                      # after the 2h window
rounds.settleStock(id, stock)                     # once per stock
rounds.finalizeRound(id)
```

**Weekly:** `claims.sweepExpired(...)` for any round past `expiresAt`.

**Watch for TWO things, and they have opposite causes:**

1. **A stock skipped with reason `stale feed`** — that is `maxFeedAge` doing its job (the
   budget carried, nothing lost), but a stock skipping repeatedly means a genuinely dead feed,
   not a weekend.
2. 🔴 **A stock where `isEnabled() == true` but `clearsMinLiquidity() == false`.** One
   `liquidityReport()` call returns every stock, its measured depth, its threshold and whether
   it clears, so this is one read per cycle:

   ```
   registry.liquidityReport()    # alert on any row where enabled && !ok
   ```

   **The depth gate is checked once, when a stock is enabled, and never again** — see
   OPEN_ITEMS 28. A pool that drains leaves the stock enabled and buying. Nothing announces it,
   because the per-buy protection (`_minOutFor` against the Chainlink mark) fails *safe*: the
   buy is refused in full and the slice carries. So the symptom is a stock that quietly stops
   filling, not a bad fill. **The response is `setEnabled(token, false)`** — instant, not
   timelocked, and reversible the moment depth returns.

---

## 9. What is still not decided

- **The audit.** Everything in §5 is sized on the assumption it has not happened yet.
- **The Anvil sell side.** Not built. `sellEnabled` is a constant `false` with no setter, so
  it ships after the audit in a deployment that implements it.
- **`maxPrincipal` vs Anvil parity** is operational and unenforced — §5 and OPEN_ITEMS 11.
- **NounLoans has no repayment after maturity plus the loan's grace** — `min(7 days, term/2)`,
  so 3.5 days on a 7-day loan. Deliberate; the site must carry the dates loudly, and the short
  terms make that more urgent, not less. OPEN_ITEMS 10.
- **Compound share redemption** has no path. Phase 2, and it should be answered before
  auto-compound is marketed. OPEN_ITEMS 7.
