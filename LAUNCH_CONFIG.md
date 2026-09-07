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

---

## 1. The critical path, and what actually blocks it

Three things gate everything else. Read this before booking a launch date.

| Blocker | Duration | What it blocks |
|---|---|---|
| **$CHIP must launch first** | — | 4 contracts take it as a constructor argument |
| **Price discovery: 24–48h observed** | 1–2 days | The entire cost table (§4). ChipActivation cannot deploy before it |
| **48h timelocks** | 2 days each, parallel | Pricing each collection in ChipActivation; NounLoans terms |

**These do not fully overlap.** ChipActivation deploys with a cost table computed from the
observed price, so the timelock cannot start until price discovery finishes. Realistic shape:

```
Day 0     $CHIP launches. Initial buy inside the window (§3).
Day 1–2   Observe. Do NOT compute the table from day-0 volatility.
Day 2     Compute the cost table (§4). Deploy ChipActivation. Queue costs for
          all three collections. Queue NounLoans terms. Queue Anvil prices.
Day 4     Execute all queued config. Deploy the rest. Wire. Verify.
Day 5     First round.
```

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

### Worked example, at a base unit of 50,000

```
ChipActivation.queueCosts(LIL_NOUNS,   [50_000e18, 110_000e18, 225_000e18, 450_000e18, 1_200_000e18])
ChipActivation.queueCosts(BASED_NOUNS, [ same ])
ChipActivation.queueCosts(DARK_NOUNS,  [ same ])
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
| Round minimum | **$100** | `ChipRounds.setRoundParams` — `minPot = 100e6` |
| Round maximum | **$1,000** | `ChipRounds.setRoundParams` — `maxBudget = 1_000e6` |
| POL holdback | **15%** — unchanged | `ChipRounds.setHoldbackBps(1500)` |
| NounLoans `maxPrincipal` | **≈60% of the Anvil queue price**, per collection, denominated in $CHIP | `NounLoans.setMaxPrincipal` |
| NounLoans pool | seeded from the initial buy (§3) | `NounLoans.depositPool` |
| Furnace Based stock | deploy argument | `Furnace.depositStock` |
| Furnace Dark recipe | **deployed but PAUSED** | `Furnace.setPaused(1, true)` |

**The round cap is the important one.** $1,000 is deliberately small: it bounds what a bug
in an unaudited buying path can cost to one round's budget, and confidence in anything
B20-specific is structurally lower than the rest of the repo (OPEN_ITEMS item 5). The first
mainnet round should be smaller still.

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

**2. StockRegistry** — `(MULTISIG, USDC, UNI_FACTORY, SLIPSTREAM_FACTORY)`
Register all **thirteen** B20 stocks disabled (addresses and feeds: ASSUMPTIONS A-13/A-18).
```
stockCount() == 13 ; enabledTokens().length == 0
setEnabled(CRCLc, true)  -> reverts PoolNotSet     # no market yet
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

**4. ChipActivation** — `(MULTISIG, CHIP, [10000, 12500, 16000, 20000, 33300])`
Then `queueCosts` x3 with the §4 table → **48h** → `executeCosts` x3.
```
allTierBps() == [10000,12500,16000,20000,33300]
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

**5b. ChipRounds** — `(MULTISIG, registry, Pot, ChipActivation, ChipClaims, 5_000e18)`
```
setRoundParams(86400, 7200, 100e6, 1_000e6)   # LAUNCH CAPS
setCollectionBaseBps(LIL, 5000) / (BASED, 10000) / (DARK, 20000)
setHoldbackBps(1500) ; setDefaultMaxSlippageBps(200) ; setMaxFeedAge(432000)
setRouters(...) ; setChip(CHIP, 0xdead)
```

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

**8. Furnace** — `(MULTISIG, CHIP, LIL_NOUNS, basedRecipe, darkRecipe)` with the §4 amounts.
```
approve + depositStock(BASED_NOUNS, ids)
setPaused(1, true)                      # Dark recipe OFF at launch
recipe(1).paused == true
forge(1, ids) -> reverts RecipeIsPaused
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

```
cast code <CHIPLETS> --rpc-url $BASE_RPC_URL | grep -c 42966c68     # burn(uint256), expect >= 1
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

**And the $CHIP side, which is the opposite case.** $CHIP **cannot** be truly burned — Bankr's
Doppler token has no `burn` — so `chip.totalSupply()` will NOT move and that is correct. What
must be true instead:

```
chipActivation.chipBurnedToDead() == chip.balanceOf(0x...dEaD)     # by definition
chipActivation.effectiveChipSupply() == chip.totalSupply() - chip.balanceOf(0x...dEaD)
```

The site must display `effectiveChipSupply()`, and `0x000000000000000000000000000000000000dEaD`
must be filed with CoinGecko and CoinMarketCap as an excluded burn address post-launch. See
BURN_VISIBILITY.md. **Neither aggregator infers this**, and the overstatement grows with every
activation and every forge.

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

**Watch for:** a stock skipped with reason `stale feed` — that is `maxFeedAge` doing its job
(the budget carried, nothing lost), but a stock skipping repeatedly means a genuinely dead
feed, not a weekend.

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
