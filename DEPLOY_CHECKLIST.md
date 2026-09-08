# DEPLOY_CHECKLIST.md — the live run sheet

**Tag: `launch-candidate-22` (`79d14ca`).** HEAD is past it by docs-only commits, so the
Solidity at HEAD is byte-identical to the reviewed package. **No contract changed to produce
this checklist** — every fix below is documentation or a test assertion, so the tag stands.

Rehearsed end to end on a Base mainnet fork by `test/fork/DeployRehearsal.t.sol`. Every
verification read below was executed there and passed. Re-run it the morning of:

```
forge test --match-contract DeployRehearsalTest -vv
```

> **How to read the markers.**
> 🔴 = **IRREVERSIBLE.** Getting it wrong means redeploying this contract, and sometimes
> others. Read the whole step out loud before signing.
> ⚠️ = fails silently or is easy to skip. Nothing will tell you.
> ✅ = fails loudly. The chain will stop you.

---

## 0. WHAT I NEED FROM YOU BEFORE STEP 1

### 0.1 Addresses — ✅ ALL CONFIRMED ON CHAIN

| Name | Address | Verified |
|---|---|---|
| `MULTISIG` | `0xe1096B727499a3f70FaD8bc0267F5e69d01373C7` | Safe v1.4.1, **2-of-3** |
| `DEPLOY_WALLET` | `0x9FD4A40f7bE01CB69b7286cEC43D3d5936980Ad4` | nonce 0, fresh. **Also a Safe signer** — rotate out post-launch if you want the stronger property |
| `OPS_WALLET` | `0x35325dD7e972780C3aDef20E9675a4264a8a57fb` | EOA |
| `LOAN_TREASURY` | `0xe1096B727499a3f70FaD8bc0267F5e69d01373C7` | = the Safe |
| `KEEPER` | `0x6571E3412553Fada40C3D96e61E7Cfd20A0695B9` | EOA, **not** a Safe owner ✓ |

**Funding:** deploy wallet → **0.05 ETH** · keeper → **0.02 ETH**

### 0.2 Collection addresses

| Name | Status |
|---|---|
| `BASED_NOUNS` | ❗ **STILL TBD.** Needed by steps 4, 5b, 8, 9, 10 |
| `DARK_NOUNS` | ❗ **STILL TBD.** Same |
| `LIL_NOUNS` | ✅ `0xe3c5Ef27B80481518a2363406e354a9361415556` |
| `CHIPLETS` | ✅ `0xC7c114191aa3b2225F9bb053Bc55b3d6F145Bd33` |

### 0.3 External gates

| Gate | State | Blocks |
|---|---|---|
| Bankr launch of $CHIP done? | ❗ **No** | 0, 4, 5b, 8, 9 and every $CHIP number |
| `$CHIP` address known? | ❗ **No** | same |
| 24–48h of price observed? | ❗ **No** | the cost table (§4), so step 4 |
| **Is $CHIP `Ownable` or `Ownable2Step`?** | ✅ **RESOLVED — single-step OpenZeppelin `Ownable`, confirmed by Bankr.** `transferOwnership(ChipBurner)` completes in one transaction. No `acceptOwnership` needed, no ChipBurner change, no re-tag | step 6.6 — now clear |
| Chiplets drop minted? | ❗ **No. `totalSupply()` is 0 on chain** | the first forge, and the §6.5 fuel-burn proof |
| Chiplets seeded into the Furnace? | Cannot be — nothing minted | step 8's real use |

> **The Chiplets gate, stated plainly.** The Furnace deploys, stocks its *output* Nouns and
> pauses fine with zero Chiplets in existence — the rehearsal does exactly that. What you
> cannot do until the drop mints is **prove the fuel burn is a real burn** (LAUNCH_CONFIG
> §6.5 checks two and three). That proof is the only thing standing between "supply is
> falling" and "supply looks like it is falling". **Announce nothing about Chiplet supply
> until `totalFuelTrueBurned() == totalFuelBurned()` after a real forge.**

### 0.4 The numbers

**ETH — paste as wei.** Set from the observed ETH price at deploy, NOT from $CHIP.

| Value | USD | Wei | When |
|---|---|---|---|
| **Anvil queue price**, Based | $27 | recompute at deploy | **PHASE 1, today** |
| **Round-one seed** → sent to `$POT` | $150 | recompute at deploy | pause F |

```
cast call 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70   "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url $BASE_RPC_URL
# wei = round(USD / ethUsd * 1e18)
```

**$CHIP — paste as wei.** `P` = observed price. `wei = (USD / P) x 1e18`.

| Number | Formula | At a 50,000 base |
|---|---|---|
| ❗ **`CHIP_BASE_UNIT`** | nearest round number to **$5 / P**, then **x1.5–2 (bias HIGH, §1b)** | 50,000 |
| Tier ladder | base x `1.0 / 2.2 / 4.5 / 9.0 / 24.0` | 50k/110k/225k/450k/1.2M |
| Chiplets flat, five **equal** | 10% of base | 5,000 |
| `SPLIT_FEE_CHIP` | 10% of base | 5,000 |
| `FURNACE_BASED_CHIP_COST` | 0.5x base — **placeholder, paused** | 25,000 |
| `FURNACE_DARK_CHIP_COST` | 1.2x base — **placeholder, paused** | 60,000 |
| Loan pool seed | **$700** / P | — |
| `maxPrincipal` **Based** | **$16** / P — 60% of the **$27 Anvil price**, not the $30 floor | — |
| `maxPrincipal` **Dark** | **$95** / P — 60% of the $160 floor | — |
| `maxPrincipal` **Lil** | **$7** / P — 60% of the $12 floor | — |
| Games reserve — held, not deposited | $150 / P | — |

**The initial buy: $850 of $CHIP, and $150 kept as ETH.** Not $1,000. $CHIP has no Chainlink
feed, so no Pot route for it can ever exist and it can never become round budget. The
round-one seed must be ETH.

**Counts:** 150 Based Nouns → Anvil **100** · Furnace **40** · keep **10**.

> The Chiplets flat cost and the split-change fee are **the same number at a 50,000 base and
> not the same thing.** One is what a Chiplet costs to activate; the other is what changing a
> split costs. They move together only because both are 10% of the base unit.

### 0.5 The fee-recipient flip

`transfer_fee_recipient` → FeeSplitter is a **post-launch Bankr step**, done only after step 1
is deployed and `distributeETH()` has been proved to land 80/20. Do not set it at launch.

### 0.6 ❗ External copy you must fix before posting

Not a deploy input, but it gates the announcement. **There is no round cap any more** (see F1).
Three places still imply one:

1. **LAUNCH_CONFIG §0's disclosure line** — the line itself is still accurate; what is stale is
   any reading of it that implies a per-round ceiling.
2. **The site's launch-caps copy**, wherever it names a dollar figure per round.
3. **The launch thread / article copy**, same.

**Honest replacement:** *"each buy is limited to a fraction of the pool's measured depth, and
the first rounds are funded small."* The second half is an operational promise, not a contract
guarantee — keep the wording that way.

---

## 1. THE FOUR DEFECTS THE REHEARSAL FOUND — ALL RESOLVED

Kept as a record so the reasoning is not lost. **Nothing here is an outstanding action except
§0.6's copy fix.**

| # | Defect | Resolution |
|---|---|---|
| **F1** | LAUNCH_CONFIG called `setRoundParams` with **four** arguments. The real signature takes three; `maxBudget` was removed with the depth-aware impact trim. The 4-arg call would have reverted on the day, and §5's "$1,000 round maximum" was never settable | ✅ Fixed in LAUNCH_CONFIG §5, §6 5b and DEPLOY.md. **Remaining action: the external copy in §0.6** |
| **F2** | The Chiplets flat activation cost had no documented value anywhere, and it sits behind a 48h timelock | ✅ Now **10% of the base unit = 5,000 $CHIP**, written into LAUNCH_CONFIG §4 item 6 and the worked example |
| **F3** | `setCollectionBaseBps(CHIPLETS, 1000)` was missing from §6 5b. A collection at the default 0 earns nothing, silently, for ever | ✅ Now a can't-skip 🔴 block in §6 5b with four verification reads, plus a fails-loud assertion in the rehearsal (proved by negative control) |
| **F4** | `ChipBurner` has no `acceptOwnership()`, so an `Ownable2Step` token would have bricked the hand-off | ✅ **Not a defect.** Bankr confirmed $CHIP is single-step OpenZeppelin `Ownable`. Step 6.6 works in one transaction as written |

### F1 in full — what replaced the cap

`setRoundParams(uint64 duration, uint64 window, uint128 minPot)`. `maxBudget` is gone
(OPEN_ITEMS 26, `test/UncappedRounds.t.sol`). What bounds exposure instead is `maxImpactBps`,
which sizes every buy from measured pool depth — so exposure is a function of the **pool**, not
the round. **The constructor already sets `defaultMaxImpactBps = 25`** (0.25%, ceiling 500), so
the protection is on by default and needs no deploy step.

---

## 1b. THE T+48h SCHEDULE — start every clock as early as it can start

**Only two things in this deploy are timelocked with no first-set exemption**, and everything
else is immediate. Verified in the code, not inferred:

| | Blocked at first set? | Why |
|---|---|---|
| Activation cost table | 🔒 **YES, 48h** | `collectionConfigured = true` is written in exactly one place — inside `executeCosts`, behind `TimelockNotElapsed`. No constructor path. |
| Anvil queue price | 🔒 **YES, 48h** | `queuePrice[c]` is written in exactly one place — inside `executeQueuePrice`. Starts at 0, and 0 means `NotForSale`. |
| `setCustodian` | ✅ immediate | plain setter |
| Everything else | ✅ immediate | round params, all four `baseBps`, routers, `setChip`, `setEnabled`, `setMaxPrincipal`, `depositPool`, `depositStock`, `shelve`, `setPaused`, Pot routes, `setPot`, `ChipClaims.setRounds` |

**Those two cascade.** `borrow` reverts `NotChipped`, and `settleStock` reverts `NoWeight`, so
lending and rounds follow chipping rather than having clocks of their own.

### The two moves that halve the timeline

**1. The Anvil is deployed in PHASE 1 and its price is queued the same day.** Its constructor
is `(multisig, feeSplitter, premiumBps)` — no $CHIP — and its price is in ETH. So its 48-hour
clock runs *through* the token launch and the observation window instead of starting after
them. Deploying it in phase 4 would have started the same clock two days later for nothing.
Shelving is separate and not timelocked: shelve whenever the Nouns are in hand.

**2. `queueCosts` runs the MOMENT $CHIP launches, not two days later.** `ChipActivation.chipToken`
is `immutable`, so the contract genuinely cannot exist before the token — **$CHIP launch + 48h
is a hard floor and nothing beats it.** But nothing forces you to wait for price observation
before *queueing*. Queue at T+0 and the clock runs during the observation window.

**Result: chipping, lending, rounds and the Anvil all live at T+48h, not T+96h.**

### 🔴 SET THE BASE UNIT DELIBERATELY HIGH — ~1.5–2x your best guess

Queueing at T+0 means pricing activation from an *expected* rather than observed price. **The
risk is asymmetric, and that is the whole reason to bias high:**

- **Too high** → activation looks expensive, few people chip, you lower it in a later 48h
  window. **Recoverable.**
- **Too low** → people chip at a discount and **activation burns $CHIP irreversibly.** There is
  no refund and no un-burn. **Not recoverable.**

One number carries all of it — the tier ladder, the Chiplet flat and the split fee are all
ratios of the base unit.

### 🔴🔴 THE T+48h DECISION POINT — LOOK AT THE PRICE BEFORE YOU SIGN

**A queued table is not a commitment. `cancelCosts(address)` exists. The value of queueing
early is entirely in the CHOICE you make at the 48-hour mark — and that value is zero if you
execute on autopilot.**

At T+48h, before signing anything, read the observed price and decide:

```
                    ┌─────────────────────────────────────────┐
                    │  READ THE OBSERVED $CHIP PRICE NOW      │
                    └────────────────┬────────────────────────┘
                                     │
              ┌──────────────────────┴──────────────────────┐
              │                                             │
    queued table is within tolerance          queued table is materially off
              │                                             │
      executeCosts x4                        cancelCosts x4, re-queue correct
      -> CHIPPING LIVE at T+48h              -> CHIPPING LIVE at T+96h
                                             (exactly where the old plan had you)
```

**You are never worse off for having queued early.** The downside branch lands on the original
timeline; the upside branch saves two days. The only way to lose is to execute without looking.

> **Write the decision down before you sign.** Observed price, the base unit you queued, the
> ratio between them, and execute-or-cancel. If you cannot state the ratio out loud, you have
> not done the check.

## 2. THE SEQUENCE

```
export BASE_RPC_URL=...      # already in .env
export MULTISIG=0x... ; export OPS_WALLET=0x... ; export LOAN_TREASURY=0x...
export CHIP=0x...            # after Bankr launch
```

Verified-on-chain constants that need no decision:

```
USDC            0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
WETH            0x4200000000000000000000000000000000000006
AERO            0x940181a94A35A4569E4529A3CDfB74e38FD98631
UNIV3_FACTORY   0x33128a8fC17869897dcE68Ed026d694621f6FDfD
UNIV3_ROUTER    0x2626664c2603336E57B271c5C0b26F421741e481   factory() verified
SLIP_FACTORY_B  0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef
SLIP_ROUTER_B   0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F   factory() verified == B
SLIP_NPM        0x827922686190790b37229fd06084350E74485b72
AERO_VOTER      0x16613524e02ad97eDfeF371bC883F2F5d6C480A5
SEQUENCER_FEED  0xBCF85224fc0756B9Fa45aA7892530B47e10b6433
ETH_USD_FEED    0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70
AERO_USD_FEED   0x4EC5970fC728C5f65ba413992CD5fF6FD70fcfF0
```

---

### DAY 0 — before $CHIP exists

> **PHASE 1 NOW DEPLOYS FIVE CONTRACTS, NOT FOUR.** The Anvil joins it so its 48-hour price
> timelock starts today — §1b. Run `SafeCallsPhase1` the same day and queue the price.

#### ☐ Step 1 — FeeSplitter

**Deploy:** `FeeSplitter(MULTISIG, MULTISIG, OPS_WALLET, 2000, 2000)`
*(second argument is the multisig standing in as the Pot; corrected in 5b)*

**Produces:** `FEE_SPLITTER` → needed by 6, 9, 10, and the Bankr fee-recipient flip

```
cast call $FEE_SPLITTER "owner()(address)" --rpc-url $BASE_RPC_URL   # == MULTISIG
cast call $FEE_SPLITTER "opsBps()(uint32)" --rpc-url $BASE_RPC_URL   # == 2000
cast call $FEE_SPLITTER "potBps()(uint32)" --rpc-url $BASE_RPC_URL   # == 8000
# send 0.001 ETH, distributeETH(): 0.0002 to ops, 0.0008 to the placeholder
```

---

#### ☐ Step 2 — StockRegistry

> 🔴 **`SLIP_FACTORY_B` IS THE ONE ADDRESS THAT CANNOT BE CORRECTED LATER.**
> `slipstreamFactory` is **immutable**. Every B20 pool is on factory **B**
> (`0xf8f2eB…061Ef`). A registry built on factory A (`0x5e7BB1…809A`) resolves **none** of them
> and must be redeployed. It fails loudly (`PoolNotFoundInFactory`) — but only at `addStock`.

**Deploy:** `StockRegistry(MULTISIG, USDC, UNIV3_FACTORY, SLIP_FACTORY_B)`

**Produces:** `STOCK_REGISTRY` → needed by 5a, 5b (5b reads the factories back off it to
validate the routers)

**Then:** `addStock` x13, **all disabled**. Ten as `Venue.Slipstream`, tick spacing 10, fee 0,
`tokenDecimals = 8`, `minLiquidityUsd = 25_000e18`. COIN, CRCL, INTC have no pool and register
as `Venue.None` with their feed set. **Source the thirteen from
`test/fork/B20RegistryConfig.t.sol`, which re-derives every pool from the live factory — not
from a pasted list.**

> `addStock` probes `decimals()`, which local simulation cannot execute against a B20
> precompile. Use `--skip-simulation` or run from the Safe UI.

```
cast call $STOCK_REGISTRY "slipstreamFactory()(address)" --rpc-url $BASE_RPC_URL  # FACTORY B
cast call $STOCK_REGISTRY "stockCount()(uint256)"        --rpc-url $BASE_RPC_URL  # == 13
cast call $STOCK_REGISTRY "enabledTokens()(address[])"   --rpc-url $BASE_RPC_URL  # == []
```
✅ `setEnabled(CRCLc, true)` reverts `PoolNotSet`.

**Enabling is a separate later step:** run `script/CheckDepth.s.sol` against real Base (it reads
through raw RPC, because a forked EVM reports B20 depth as $0), then `setEnabled` each stock
that clears.

---

#### ☐ Step 3 — Pot

**Deploy:** `Pot(MULTISIG, USDC, UNIV3_FACTORY)`
*(DEPLOY.md's summary table omits the third argument; the constructor takes it)*

**Produces:** `POT` → needed by 5b constructor and `FeeSplitter.setPot`

```
setConversionConfig(WETH, ETH_USD_FEED, UNIV3_ROUTER, 500, 100, 5e18, 0, 3600)
setRoute(AERO, AERO_USD_FEED, UNIV3_ROUTER, 500, 300, 50000e18, 0, 86400)
setSequencerFeed(0xBCF85224fc0756B9Fa45aA7892530B47e10b6433, 3600)
```
```
cast call $POT "sequencerUptimeFeed()(address)" --rpc-url $BASE_RPC_URL  # == 0xBCF852...
```
✅ `pullBudget(1)` reverts (rewards unset) · `setRewards(<EOA>)` reverts `NotAContract` ·
`setRoute(.., <Slipstream router>, ..)` reverts `RouterNotUniswapV3`.

> **Test the EOA case with an address you have proved has no code.** `makeAddr("alice")` — the
> obvious choice — carries 23 bytes of code on live Base, so the naive spelling of this check
> passes for the wrong reason.

---

#### ☐ Step 6 — POLTreasury *(day-0 deployable; holds nothing until 5b points at it)*

**Deploy:** `POLTreasury(MULTISIG, USDC, SLIP_NPM, FEE_SPLITTER, UNIV3_FACTORY, AERO_VOTER)`

**Produces:** `POL_TREASURY` → needed by 5b, 5a, and the FeeSplitter POL leg

**Then:** `setWeth(WETH)`, `setManager(KEEPER)`, one `setPolAsset` per asset.
**`maxFeedAge` must be `0` for every equity** — the B20 feeds have no off-hours heartbeat and a
real window would refuse every mint outside market hours. Use 3600 only for 24/7 assets.

```
cast call $POL_TREASURY "positionFactory()(address)" --rpc-url $BASE_RPC_URL
#  -> 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A   FACTORY A, and this is CORRECT.
#     POL runs on factory A, stock buying on factory B, and the two books never touch.
#     Bankr confirmed the isolation at the -22 re-scan.
```
✅ `setIncomeToken(USDC, true)` reverts `TokenNotDisjoint` · `stakePosition(id, <wrong gauge>)`
reverts `GaugeNotCanonical` · `mintPosition(.., 0, 0)` reverts `SlippageUnbounded`.

---

### DAY 0 (cont.) — $CHIP launches

#### ☐ Step 0 — ChipBurner

> 🔴 **THIS ADDRESS BECOMES `immutable` ON THREE CONTRACTS** — ChipActivation (4), ChipRounds
> (5b), Furnace (8). Wrong here means all four redeploy. Deploy it before any of them.

**Deploy:** `ChipBurner(MULTISIG, CHIP)` → **Produces:** `CHIP_BURNER`

```
cast call $CHIP_BURNER "owner()(address)"     --rpc-url $BASE_RPC_URL  # == MULTISIG
cast call $CHIP_BURNER "chipToken()(address)" --rpc-url $BASE_RPC_URL  # == CHIP
```

---

#### ☐ Step 6.6 — 🔴 HAND $CHIP OWNERSHIP TO THE BURNER

> ✅ **CONFIRMED SAFE.** Bankr confirmed $CHIP is **single-step OpenZeppelin `Ownable`**, so
> `transferOwnership` completes in **one transaction** and the Burner becomes owner
> immediately. There is no pending-owner step and nothing to accept.
>
> 🔴 It is still the **one-way step**: after it the multisig can no longer `burn`,
> `updateTokenURI` or move $CHIP ownership directly — only through the Burner's two
> pass-throughs. The Burner can never move a single $CHIP anywhere except out of existence.

**ABI check first (LAUNCH_CONFIG §6.6), against the deployed token:**
```
cast code $CHIP --rpc-url $BASE_RPC_URL | grep -c 42966c68     # burn(uint256), expect >= 1
```

**The step:**
```
chip.transferOwnership($CHIP_BURNER)
```

**Verify — do not proceed without this:**
```
cast call $CHIP "owner()(address)" --rpc-url $BASE_RPC_URL   # == $CHIP_BURNER   REQUIRED
```

**Then prove it end to end, once, with 1 token:**
```
chip.transfer($CHIP_BURNER, 1e18)
burner.burnAll()                                    # permissionless, anyone
cast call $CHIP "totalSupply()(uint256)"            # must have FALLEN by exactly 1e18
cast call $CHIP_BURNER "totalBurned()(uint256)"     # == 1e18
cast call $CHIP_BURNER "burnCount()(uint256)"       # == 1
```

---

### DAY 2 — after 24–48h of observed price

#### ☐ Step 4 — ChipActivation

**Deploy:** `ChipActivation(MULTISIG, CHIP, CHIP_BURNER, [10000, 12500, 16000, 20000, 33300])`

**Produces:** `CHIP_ACTIVATION` → needed by 5b, 9, and the 🔴 custodian wire at the very end

> 🔴 **`setFlatRateCollection(CHIPLETS)` MUST RUN BEFORE THE FIRST `executeCosts` ON CHIPLETS.**
> It is refused on a live collection and is one-way by design. Wrong order and ChipActivation
> redeploys — which drags 5b and 9 with it.

**Order, exactly:**
```
1.  setFlatRateCollection(CHIPLETS)                                  <- FIRST
2.  queueCosts(LIL_NOUNS,   [50_000e18, 110_000e18, 225_000e18, 450_000e18, 1_200_000e18])
    queueCosts(BASED_NOUNS, [ same ])
    queueCosts(DARK_NOUNS,  [ same ])
    queueCosts(CHIPLETS,    [5_000e18, 5_000e18, 5_000e18, 5_000e18, 5_000e18])   <- five EQUAL
3.  ---- WAIT 48 HOURS ----
4.  executeCosts(LIL_NOUNS) / (BASED_NOUNS) / (DARK_NOUNS) / (CHIPLETS)
```
*(scale every figure with the base unit if it is not 50,000)*

```
cast call $CHIP_ACTIVATION "chipBurnTarget()(address)" --rpc-url $BASE_RPC_URL  # == CHIP_BURNER
cast call $CHIP_ACTIVATION "isFlatRate(address)(bool)" $CHIPLETS                # == true
cast call $CHIP_ACTIVATION "isSupportedCollection(address)(bool)" $BASED_NOUNS  # false→true
cast call $CHIP_ACTIVATION "costOf(address,uint8)(uint256)" $CHIPLETS 0         # == 5000e18
```
✅ `activate(...)` before `executeCosts` reverts `CollectionNotConfigured` ·
`queueCosts(CHIPLETS, <a ladder>)` reverts — a flat collection refuses tiers.

---

### DAY 4 — the rest, wired

#### ☐ Step 5a — ChipClaims

> 🔴 **THE DEPLOY TIMESTAMP FIXES THE CLAIM WINDOW'S DAY OF THE WEEK, PERMANENTLY.** There is
> no setter for the anchor. Pick the moment deliberately.

**Deploy:** `ChipClaims(MULTISIG, STOCK_REGISTRY)` → **Produces:** `CHIP_CLAIMS`
**Then:** `setClaimSchedule(604800, 172800)`, `setCreditExpiry(2592000)`

---

#### ☐ Step 5b — ChipRounds

**Deploy:**
```
ChipRounds(MULTISIG, STOCK_REGISTRY, POT, CHIP_ACTIVATION, CHIP_CLAIMS, 5_000e18, CHIP_BURNER)
```

**Then the config:**
```
setRoundParams(86400, 7200, 100e6)              # THREE arguments. No maxBudget (F1)
setHoldbackBps(1500)
setDefaultMaxSlippageBps(200)
setMaxFeedAge(432000)
setChip(CHIP)                                   # ONE argument; burn target is immutable
setPolTreasury(POL_TREASURY)
setRouters(0x2626664c2603336E57B271c5C0b26F421741e481,
           0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F)
```

> ### 🔴 ALL FOUR COLLECTIONS NEED A `baseBps`, AND A MISSING ONE IS SILENT
>
> `collectionBaseBps` defaults to **0**, and a collection at zero earns **nothing** — every
> holder in it scores zero weight in every round, for ever, with no revert and no event. Same
> failure shape as the custodian wire, with four chances to happen instead of one. **CHIPLETS
> is the one that gets forgotten.**
>
> ```
> setCollectionBaseBps(LIL_NOUNS,   5000)    # 0.5x
> setCollectionBaseBps(BASED_NOUNS, 10000)   # 1.0x
> setCollectionBaseBps(DARK_NOUNS,  20000)   # 2.0x
> setCollectionBaseBps(CHIPLETS,    1000)    # 0.1x   <- the one that gets missed
> ```
>
> **All four reads, before sign-off. Every one non-zero and exact:**
> ```
> cast call $CHIP_ROUNDS "collectionBaseBps(address)(uint32)" $LIL_NOUNS   --rpc-url $BASE_RPC_URL  #  5000
> cast call $CHIP_ROUNDS "collectionBaseBps(address)(uint32)" $BASED_NOUNS --rpc-url $BASE_RPC_URL  # 10000
> cast call $CHIP_ROUNDS "collectionBaseBps(address)(uint32)" $DARK_NOUNS  --rpc-url $BASE_RPC_URL  # 20000
> cast call $CHIP_ROUNDS "collectionBaseBps(address)(uint32)" $CHIPLETS    --rpc-url $BASE_RPC_URL  #  1000
> ```
>
> **And the end-to-end read**, because a non-zero setting still does not prove a Chiplet
> scores — activate one, contribute it to an open round, and check the weight actually moved:
> ```
> # totalWeight BEFORE and AFTER contributeWeights(id, CHIPLETS, [tokenId])
> cast call $CHIP_ROUNDS "getRound(uint256)" $ROUND_ID --rpc-url $BASE_RPC_URL
> #   -> totalWeight must INCREASE. If it does not, the collection is at zero.
> ```
>
> Asserted for all four by `_assertEveryCollectionEarns()` in the rehearsal, which fails with
> `baseBps IS ZERO -- this collection earns nothing: <NAME>`. Verified by negative control:
> removing the CHIPLETS line makes the suite fail.

**The cross-wiring, all five directions:**
```
ChipClaims.setRounds(CHIP_ROUNDS)               # one-shot, immediate, while unset
ChipClaims.setPolTreasury(POL_TREASURY)         # one-shot, immediate, while unset
Pot.setRewards(CHIP_ROUNDS)
FeeSplitter.setPot(POT)                         # replaces the day-0 placeholder
POLTreasury.setRewards(CHIP_CLAIMS)             # the LEDGER, not the engine
```
```
cast call $CHIP_ROUNDS  "slipstreamRouter()(address)" --rpc-url $BASE_RPC_URL  # == 0x698Cb2...
cast call $CHIP_CLAIMS  "rounds()(address)"           --rpc-url $BASE_RPC_URL  # == CHIP_ROUNDS
cast call $CHIP_ROUNDS  "claims()(address)"           --rpc-url $BASE_RPC_URL  # == CHIP_CLAIMS
cast call $POT          "rewards()(address)"          --rpc-url $BASE_RPC_URL  # == CHIP_ROUNDS
cast call $FEE_SPLITTER "pot()(address)"              --rpc-url $BASE_RPC_URL  # == POT
```
✅ `setRouters(uni, 0xBE6D8f…18a5)` — the factory-A router — reverts `RouterNotOnFactory`.
✅ Before `claims.setRounds`, `contributeWeights` reverts. That one fails loudly.

---

#### ☐ Step 7 — ClaimRouter

**Deploy:** `ClaimRouter(MULTISIG, CHIP_CLAIMS, 1000000)`
*(points at the **ledger**, not the engine — easy to get backwards, and it does not fail loudly)*
```
cast call $CLAIM_ROUTER "rewards()(address)" --rpc-url $BASE_RPC_URL   # == CHIP_CLAIMS
```

---

#### ☐ Step 8 — Furnace

**Deploy:**
```
Furnace(MULTISIG, CHIP, CHIP_BURNER, CHIPLETS,
        Recipe{exists:true, paused:false, outputCollection:BASED_NOUNS, fuelCost:25, chipCost:<placeholder>},
        Recipe{exists:true, paused:false, outputCollection:DARK_NOUNS,  fuelCost:50, chipCost:<placeholder>})
```

> 🔴 `fuelCollection` and `chipBurnTarget` are both **immutable**. `chipCost` cannot be zero,
> so both start as placeholders — **pause both immediately**, then queue the real prices
> (25,000 / 60,000 at a 50,000 base).

```
approve + depositStock(BASED_NOUNS, ids)
setPaused(0, true) ; setPaused(1, true)          # BOTH off at launch
# once the price is observed:
queueRecipeChange(0, 25, 25_000e18) ; queueRecipeChange(1, 50, 60_000e18)  -> 48h -> execute
# then unpause recipe 0 only. Dark stays paused (LAUNCH_CONFIG §5).
```
```
cast call $FURNACE "fuelCollection()(address)" --rpc-url $BASE_RPC_URL   # == CHIPLETS
cast call $FURNACE "recipe(uint8)" 0 ; cast call $FURNACE "recipe(uint8)" 1   # fuelCost 25 / 50
```
✅ `forge(1, ids)` reverts `RecipeIsPaused`.
⚠️ **The real burn proof waits on the Chiplets drop.** After the first real forge:
`totalFuelTrueBurned() == totalFuelBurned()`, and `chiplets.totalSupply()` must fall.

---

#### ☐ Step 9 — NounLoans

**Deploy:**
```
NounLoans(MULTISIG, CHIP, FEE_SPLITTER, LOAN_TREASURY, CHIP_ACTIVATION,
          Terms{ length: [7d, 14d, 30d, 90d, 180d],
                 feeBps: [50, 100, 200, 500, 900],
                 bountyBps: 200, lateFeeBps: 100 })
```
**Then:** `setMaxPrincipal` per collection (~60% of the Anvil queue price in $CHIP), then
`approve` + `depositPool(<80% of the initial buy>)`.
```
cast call $NOUN_LOANS "poolBalance()(uint256)" --rpc-url $BASE_RPC_URL
#   must equal chip.balanceOf($NOUN_LOANS)
```
✅ `borrow` reverts `CollectionNotLendable` at `maxPrincipal == 0`, and `PoolTooSmall` on an
empty pool. Collateral is pulled after both checks, so no Noun is locked against a loan the
pool cannot fund.

---

#### ☐ Step 🔴 THE SILENT WIRE — `setCustodian`

> 🔴 **`chipActivation.setCustodian($NOUN_LOANS, true)` — DO NOT SIGN OFF WITHOUT THE READ
> BELOW RETURNING `true`.**
>
> Every other mistake in this sheet reverts. This one does not. Skip it and everything looks
> healthy — loans open, $CHIP is disbursed, collateral is held, rounds run, other holders are
> paid — and **every borrower silently stops earning the moment they deposit.** No error, no
> event, nothing in a log.
>
> It is the **last** wire in the sequence and the easiest to lose, because NounLoans (9) must
> exist first while ChipActivation (4) was deployed two days earlier.

```
cast call $CHIP_ACTIVATION "isCustodian(address)(bool)" $NOUN_LOANS --rpc-url $BASE_RPC_URL
#   -> true       REQUIRED
```

**And the end-to-end read** — `isCustodian` only proves the allowlist entry exists, not that
`beneficiaryOf` answers the way ChipActivation expects. With one real Noun:
```
1. chipActivation.activate(collection, tokenId, 0)
2. nounLoans.borrow(collection, tokenId, 0, principal)
3. cast call $CHIP_ACTIVATION "isActive(address,uint256)(bool)" $COLLECTION $ID   -> TRUE
4. cast call $CHIP_ACTIVATION "effectiveOwner(address,uint256)(address)" ...      -> the BORROWER
```
*The rehearsal walks exactly this and both reads pass. If step 3 is `false`, the fix is one
call, retroactive, and needs nothing from any borrower — but nothing will tell you.*

---

#### ☐ Step 10 — Anvil *(DEPLOYED IN PHASE 1 — see §1b)*

> The Anvil is no longer deployed here. It goes out with phase 1 so its 48-hour price
> timelock starts on day zero. What remains at this point is shelving, which is **not**
> timelocked, and `executeQueuePrice`, which matures 48h after the phase-1 queue.

**Then, per collection:** `shelve(collection, ids)`, `queueQueuePrice(collection, price)` →
**48h** → `executeQueuePrice(collection)`.

> ⚠️ **Every queued Anvil change expires 14 days after it matures** (`CONFIG_GRACE`). Queue and
> execute inside one operational window or it lapses. The fee splitter is timelocked too —
> `queueFeeSplitter` → 48h → `executeFeeSplitter`. There is no instant setter.

```
cast call $ANVIL "sellEnabled()(bool)"          --rpc-url $BASE_RPC_URL  # == false, no setter
cast call $ANVIL "prices(address)" $BASED_NOUNS --rpc-url $BASE_RPC_URL  # (queuePrice, +25%)
cast call $ANVIL "nextOnShelf(address)" $BASED_NOUNS                     # (true, headTokenId)
```
✅ `unshelve(collection, shelfRemaining(), ops)` reverts `WouldTakeTheHead` — winding a shelf
down is two transactions: `setPaused(collection, true)` first.

---

## 3. FIRST ROUND

Only after `script/CheckDepth.s.sol` has run against real Base and `setEnabled` has been called
for each stock that clears.

```
pot.convert()
rounds.openRound()
rounds.contributeWeights(id, collection, ids[])    # batched, all FOUR collections
rounds.closeAccumulation(id)                       # after the 2h window
rounds.settleStock(id, stock)                      # once per stock
rounds.finalizeRound(id)
```

**Holders must call `setSplit` before the round settles, and `setSplit` requires the stock to
already be enabled** — so enabling has to precede any holder picking that stock. Without a
split a holder's slice routes to USDC, and `settleStock(<that stock>)` correctly reverts
`NoWeight`.

**Fund the first rounds small.** With no ceiling in the contract this is an operational control
rather than a configured one — it needs a person to keep honouring it (F1).

---

## 4. GAS — WHAT THE DEPLOY WALLET NEEDS

Measured by the rehearsal, plus the per-transaction intrinsic and calldata gas a `gasleft()`
delta does not capture.

| | gas |
|---|---|
| 12 contract deployments | **32,993,707** |
| ~30 config / wiring transactions | **5,933,491** |
| **Total** | **≈ 38.9M** |

Largest deploys: **ChipRounds 5.20M**, **POLTreasury 5.15M**, NounLoans 3.71M, ChipClaims 3.33M.

Base gas price at rehearsal time was **0.006 gwei**.

| L2 gas price | L2 execution cost |
|---|---|
| 0.006 gwei (current) | ~0.00023 ETH |
| 0.05 gwei | ~0.0019 ETH |
| 0.1 gwei | ~0.0039 ETH |

Add the **L1 data fee** — roughly **0.0004 ETH** for ~154 KB of init code at the current blob
base fee. It is the larger half of the bill and moves with L1, not with Base.

> **Fund the deploy wallet with 0.05 ETH.** ~50x the measured all-in cost; absorbs an L1
> blob-fee spike, a failed transaction and a redeploy or two. **Separate from the 0.25–0.5 ETH
> initial buy**, which comes from the same wallet but is not gas.

---

## 5. CODE SIZE

Runtime bytecode against the EIP-170 limit of 24,576 bytes:

| Contract | runtime | headroom |
|---|---|---|
| **POLTreasury** | **23,032** | **1,544** ← the tightest |
| ChipRounds | 22,582 | 1,994 |
| NounLoans | 15,566 | 9,010 |
| ChipClaims | 14,678 | 9,898 |

The `-22` re-scan cited ChipRounds' headroom, which is fine — but **POLTreasury is the contract
closest to the ceiling** and was not mentioned. Any change to it should run
`test/CodeSize.t.sol` first; that suite budgets to 24,000, not 24,576.

---

## 6. STILL OPEN AT DEPLOY TIME

- **OPEN_ITEMS 29** — the buy path already reads manipulable pool depth (`settleStock` →
  `_maxSpendFor` → `poolLiquidityUsd`), and the `-22` §4 reasoning assumed it did not. Griefing
  and liveness, not theft, so not a deploy blocker — but §4 is not settled until Bankr answers
  knowing the trim exists.
- **PR #4** is neither blessed nor rejected by the §4 ruling: Bankr was asked about a
  *continuous* gate inside `settleStock`/`_buy`; PR #4 re-checks at *administrative* time in
  `setMinLiquidityUsd`, the zone they endorsed keeping. Optional tidy-up, closes nothing.
- **OPEN_ITEMS 25** — `StockRegistry` has never had an external review, and the `ChipClaims`
  lows/informationals were never received.
- **The audit.** Every launch cap is sized on the assumption it has not happened.
