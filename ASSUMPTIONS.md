# ASSUMPTIONS.md

Every guess this codebase makes about a contract **we do not control**. Verify each one
before mainnet. Anything marked **BLOCKER** can cause wrong payouts or lost funds if the
guess is wrong.

Last updated: 2026-09-02 · against spec v0.2. Part 2 verified on a Base mainnet fork.

---

## PART 1 IS NOW HISTORY — read this first

**Chipworks no longer calls Clutch.** `src/activation/ChipActivation.sol` is our own
non-custodial soft-staking vault, behind the same `IActivationSource` interface, and
`ClutchVaultAdapter` is retired in place and not deployed.

**So every assumption in Part 1 — A-1 through A-12 — is moot.** They were guesses about a
contract we do not control; we now control it. Nothing in the deployed system depends on any
of them. They are kept below, unedited, for two reasons:

1. **A-12 became a real design decision.** The tier-0 collision (spec: "a transferred Noun
   reads as tier 0" vs the tier table: "index 0 is the 1.00x base tier") is inherited by our
   own vault, and `ChipActivation` resolves it explicitly — activation status is never
   inferred from tier. The warning in A-12 against "fixing" it the other way still applies,
   now to our code.
2. **A-8 is why our reset is computed rather than stored.** Five of fourteen sampled live
   Robinhood activations are earning for sellers because voiding there is lazy. That
   observation is the reason `ChipActivation` recomputes the effective owner on every read
   instead of keeping a flag someone has to `kick`.

Why the dependency was dropped — no Base deployment, BUSL-1.1 on the V3 generation, and
custody semantics that cannot express "collateral keeps earning" — is in `OPEN_ITEMS.md` §0.

**Parts 2 and 3 are current and unaffected.** They cover Base addresses, B20 behaviour and
our own design decisions, none of which involved Clutch.

---

## Part 0 — SETTLED ON CHAIN, 2026-08-30

**Full report: `CLUTCH_RECON.md`.** Since the Discord is gated, the seven Clutch assumptions
were tested against deployed contracts instead. Summary:

- **No Clutch deployment exists on Base.** All four known factory/router addresses are empty
  there. Chipworks would be the first Clutch market on Base.
- **But five real SoftStakingVaults exist on Robinhood Chain (4663)** and were read directly.
- **A-3 CONFIRMED** (one vault per collection) and **A-11 CONFIRMED**.
- **A-2 RESOLVED, AND THE SPEC WAS RIGHT.** Anvil V3 is real, and V2 really is custodial:
  the V2 generation ships `NFTStakingVault` (deposit-based) while non-custodial soft staking
  appears only in V3. The docs misled me; spec section 2 had it correct all along.
- **A-2 detail:** `AMMFactoryV3` + `SoftStakingVaultV3` are deployed on
  Robinhood Chain. See `CLUTCH_LICENSES.md` §4a.
- **LICENCE BLOCKER: the V3 code is BUSL-1.1**, not open source. Forking it for production
  needs a licence from Clutch unless their Additional Use Grant covers us. The older ApeChain
  v2 code is MIT. See `CLUTCH_LICENSES.md`.
- **A-8 IS NOW IN DOUBT** — V3's natspec says voiding is atomic on transfer, which
  contradicts the finding below. Needs re-verification before anything depends on it.
- ~~**A-8 CONFIRMED, and observed live.**~~ A scan of one Robinhood vault found 14 activations,
  of which **5 are on NFTs that have already been sold** — the seller is still the owner of
  record and the activation is still earning. Without our independent owner check, Chipworks
  would be paying those five sellers today and the actual holders nothing.
- **A-4, A-5, A-6 REFUTED as names.** All three are replaced by one real function:
  `activations(uint256) returns (address ownerOfRecord, uint256 tier, uint256 activatedAt)`.
  The concept behind A-6 is confirmed: the vault does record an owner separately from the
  live NFT owner.
- **A-9 CONFIRMED and then some.** `claim()` reverts `NotOwner()` for any caller who is not
  the owner of record — which means ClaimRouter's Clutch leg cannot work as designed. See
  CLUTCH_RECON §4 for the three options.

Caveat that matters: this is **v2 on Robinhood**, and the Base target is nominally "V3", so
the interface could differ again. Nothing has been changed in the code on the strength of it.

## Part 0b — What the documentation says

I could not fetch a verified SoftStakingVault ABI, for a concrete reason:

**There is no Clutch deployment on Base.** The official contract list at
`https://anvil.clutch.market/docs#contracts` publishes:

| Contract | Address | Network |
|---|---|---|
| AMMFactory | `0x87B62309B6fF4FA184C89919351bEbd3AC11Fc84` | ApeChain (33139) |
| BatchRouter | `0x1577A7E3740846885610B9Be89886008D977AfDc` | ApeChain (33139) |
| AMMFactory | `0x8b186717a20845b514344b17fd5e198aDCab9069` | Robinhood (4663) |
| BatchRouter | `0x02eA25c9B75D98E4D5c90BEe999493095C2Da3F1` | Robinhood (4663) |
| AMMFactory | **TBD** | Ethereum (1) |

No Base (8453) row. No SoftStakingVault address on any chain — soft-staking vaults appear
to be deployed per-market by the factory, so there is no single canonical address to read.
Therefore there was nothing on Basescan to fetch, and every signature below is either
quoted from prose documentation or invented by me.

---

## Part 1 — Clutch Anvil — **HISTORICAL, NO LONGER LOAD-BEARING**

*Everything in this part concerned a dependency that has been removed. Kept for the record
and for A-8 and A-12, which shaped our own vault. See the note at the top of this file.*

### A-1 · Clutch does not currently support Base — **BLOCKER**
Docs list ApeChain and Robinhood Chain only. The spec assumes a Base market.
**Verify:** ask Clutch directly whether Base (8453) deployment is available, on what
timeline, and get the AMMFactory address. Until that exists, the whole Chipworks
architecture has no foundation, and `ChipRewards` cannot be pointed at anything real.
**If wrong:** nothing else matters. This is the first question to ask.

### A-2 · "Anvil V3" is not a public product name — **BLOCKER**
Spec §2 says "Anvil V3 (not V2: V2 is custodial staking)". The public docs describe
**v2** soft staking as explicitly non-custodial — *"NFTs never leave your wallet"* — which
is the opposite of the spec's claim. Docs contain no mention of V3 anywhere.
**Verify:** confirm with Clutch which version number actually provides non-custodial soft
staking on Base, and whether "V3" exists at all or is a private/unreleased build.
**If wrong:** you may be building against a version that does not exist, or dismissing the
version that does what you want.

### A-3 · One vault per collection — **BLOCKER**
The documented signature is `activate(uint256 tokenId, uint8 tier)`. No collection
argument. But Chipworks needs a **multi-collection** market (Based Nouns + DarkNOUNs).
Either (a) the factory deploys one vault per collection, or (b) the real vault keys by
`(collection, tokenId)`, or (c) it namespaces token ids internally.
**Assumed:** (a), one vault per collection.
**Mitigation already in code:** Chipworks contracts consume `IActivationSource`
(`src/interfaces/IActivationSource.sol`), which is keyed by `(collection, tokenId)`. A
small adapter contract maps that onto whatever the real vault turns out to be. If this
assumption is wrong, only the adapter is redeployed, not `ChipRewards`.
**If wrong and unmitigated:** Based Noun #5 and Dark Noun #5 collide and pay each other's rewards.

### A-4 · `isActive(uint256 tokenId) returns (bool)` — invented
No such view is documented. Chipworks needs to know whether a token has a live activation.
**Verify:** get the real view name. Could be `activations(tokenId)` returning a struct,
`stakes(tokenId)`, `isStaked`, or nothing at all.
**If wrong:** contracts revert on every round. Loud failure, not a silent one. Adapter fix.

### A-5 · `tierOf(uint256 tokenId) returns (uint8)` — invented
**Verify:** real name and return type. Might be packed into an activation struct.
**If wrong:** same as A-4 — loud, adapter-fixable.

### A-6 · `ownerOfRecord(uint256 tokenId) returns (address)` — invented — **BLOCKER**
This is the address Clutch recorded when the NFT was activated. Chipworks books rewards to
an address, not to an NFT (spec §1), so this is the address we credit.
**Verify:** does the vault store the activating address at all? It must, in order for
`kick` to detect a transfer — but it may not expose it publicly.
**If it is not exposed:** we fall back to `IERC721.ownerOf(tokenId)` and lose the ability
to distinguish "activated by A, now held by B" from "activated by B". See A-8.

### A-7 · Tier index 0..4 maps to 1.00 / 1.25 / 1.60 / 2.00 / 3.33 — partly documented
The multiplier *values* are documented (docs tier table, and spec §1). The mapping from a
`uint8` index to a multiplier is my assumption about ordering.
**Mitigation in code:** the tier table is adapter configuration in basis points, never a
hardcoded constant. Wrong ordering is a config change, not a redeploy.

### A-8 · A transferred Noun reads as inactive without anyone calling `kick` — **BLOCKER**
Docs say *"anyone can void a transferred NFT's stale activation"* via `kick(tokenId)`.
That wording strongly implies voiding is **lazy**: until somebody calls `kick`, the vault
may still report the token as active with the old owner of record. Spec §4 assumes the
opposite — "our contract simply sees tier 0 after a transfer".
**Consequence if lazy:** a Noun sold on the open market keeps earning for the *seller*
until someone bothers to kick it. Real money to the wrong person.
**Planned mitigation in `ChipRewards`:** do not trust the vault alone. At round time,
also read `IERC721.ownerOf(collection, tokenId)` and require it to equal the vault's owner
of record. If they differ, the Noun scores zero weight this round. This is cheap, it is
entirely under our control, and it makes A-6 and A-8 fail safe.
**Verify:** whether `kick` is required, and whether the vault has an internal check that
makes it automatic.

### A-9 · `claim(tokenId)` pays the owner of record, not `msg.sender`
Matters only for `ClaimRouter`. If Clutch pays `msg.sender`, the router would receive the
$CHIP itself and must forward it; if it pays the owner of record, the router just calls
through and touches nothing.
**Assumed:** pays owner of record (the mock models this).
**If wrong:** `ClaimRouter` strands $CHIP in itself. Must be settled before ClaimRouter ships.

### A-10 · The vault does not enumerate activated tokens — architectural
No documented way to ask "which token ids are currently activated". Assumed there is none.
**Consequence:** `openRound()` cannot iterate all activated Nouns on-chain. The round must
be driven over a caller-supplied list of token ids, with the contract verifying each one
against the vault, so a wrong or padded list cannot inflate anyone's share. This shapes the
whole `ChipRewards` design and I will flag it again when we build it.
**Verify:** if an enumeration view does exist, the design gets simpler and cheaper.

### A-11 · `pendingRewards` returns `(address[], uint256[])`
Quoted from docs. Used by `ClaimRouter` and the dashboard only. Low risk.

### A-12 · Tier 0 is ambiguous
Spec §4 says "not activated = 0", but the docs tier table says tier 0 is the *base* tier
worth 1.00x. These collide.
**Resolution in code:** activation status comes from `isActive` only. Tier is never used to
infer whether a Noun is activated. Do not "fix" this later by treating tier 0 as inactive —
that would silently zero out every base-tier Noun.

---

## Part 2 — Third-party Base addresses (VERIFIED on fork, block 50,567,828, 2026-08-28)

All of the following is checked against Base mainnet, not assumed. The checks live in
`test/fork/BaseAddresses.t.sol` and run on every `forge test`, so if mainnet changes,
a test goes red.

| Thing | Address | Status |
|---|---|---|
| USDC (Base) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | VERIFIED, 6 dp |
| Slipstream NonfungiblePositionManager | `0x827922686190790b37229fd06084350E74485b72` | VERIFIED, symbol `AERO-CL-POS` |
| Slipstream (Aerodrome CL) factory | `0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A` | VERIFIED via NPM.factory() |
| Uniswap v3 factory (Base) | `0x33128a8fC17869897dcE68Ed026d694621f6FDfD` | VERIFIED |
| NVDAc | `0xb20000000000000000000078ee7ce2fE4908108C` | VERIFIED "NVIDIA Corporation", 8 dp, supply 13,069 sh |
| GOOGLc | `0xb2000000000000000000002D0BA3164cc74f58B7` | VERIFIED "Alphabet Inc.", 8 dp, supply 5,647 sh |
| AAPLc | `0xb200000000000000000000C2e324d24d7eEcd1fb` | VERIFIED "Apple Inc.", 8 dp, supply 5,468 sh |
| METAc | `0xb2000000000000000000008bC8786B856E61707C` | VERIFIED "Meta Platforms Inc.", 8 dp, supply 2,475 sh |
| Chainlink B20 equity feeds on Base | **addresses not yet obtained** | feeds CONFIRMED to exist; see A-13 |

Note the stock tokens are **8 decimals**, not 18. Every USD calculation must scale for it.

### A-13 · Chainlink Base equity feeds — **RESOLVED, addresses verified on chain**
All nine feeds exist on Base, are listed in Chainlink's own directory as "Coinbase
<TICKER>", use the standard V3 aggregator interface, report 8 decimals, and returned live
sane prices when queried. Verified in `test/fork/ChainlinkFeeds.t.sol`, which re-checks
them on every fork run.

**The mapping below is now asserted, not just logged.** Each feed must report
`description() == "Coinbase <TICKER>"` for the ticker it is filed under, and no two rows may
share an address. That is the only check here a **transposed row** can fail — every address
in this table is a real, live, correctly-shaped feed returning a sane price, so liveness and
decimals assertions would pass happily while a round bought NVDA at AAPL's mark. Confirmed
against the live node on 2026-09-03: all nine descriptions match.

| Ticker | Feed proxy |
|---|---|
| NVDA | `0x04689a41629776563E6822F76f2e57D148d28513` |
| GOOGL | `0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2` |
| AAPL | `0x787f13dEa48Db0897CbCDD985de77809D837F988` |
| META | `0x6526aE6797A76123638b863AeE4dD27Ba4E4b27D` |
| TSLA | `0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4` |
| AMZN | `0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295` |
| MSFT | `0xeB10A6c9aa7E537aEd766C08c35Dae35B321b18c` |
| COIN | `0x408e44f504A7371a345F03a73dDC96A4b48e8aa7` |
| MSTR | `0xB3cE282CD188b35DA0E38D8Bc7d58e33173D202a` |
| CRCL | `0x0231cF2635D1E17bB5c2462cc7504Ba1fBd61f33` |
| INTC | `0xAB657C39bac0D5886250D70849e2E3E008F2EECB` |
| SNDK | `0x388b0dC46C0Fb05A74BeE0994fa5b02c6Fcca2eA` |
| SPCX | `0x6A634B235903C4ad6376892180d6fF8612e3Fa68` |

**CORRECTION, 2026-09-03: there are THIRTEEN feeds, not nine.** An earlier version of this
file listed only the nine launch tickers and `A-18` went further and recorded the other four
as having "none published". That was inferred from this table's own incompleteness rather
than checked. `B20_DOCS.md` — now filed in this repo — lists all thirteen, and all four
extra feeds verify live on Base: correct descriptions, 8 decimals, sane prices (CRCL
$102.71, INTC $91.22, SNDK $1,559.99, SPCX $152.17 at the time of checking). All thirteen
are asserted in `test/fork/ChainlinkFeeds.t.sol`.

**THE FEEDS ARE TOTAL-RETURN, WHICH IS WHY OUR PRICING NEEDS NO MULTIPLIER MATHS.**
This is the single most load-bearing fact in the file and it is now sourced rather than
inferred. `B20_DOCS.md`:

> `Token Price = Underlying Equity Market Price × Multiplier`
> … **Normal (`paused = false`):** the feed publishes underlying price × multiplier.

So the feed reports the price of **one token**, not one share. `StockRegistry.priceUsd` uses
the answer directly as the token price, and that is correct: there is no multiplier to fetch,
no registry to read, and no adjustment to get wrong. Had the feed reported the *share* price
instead, every purchase and every USD figure would have been wrong by the multiplier the
moment any stock did a split — a silent, unbounded mispricing. Worth stating plainly because
the correct code and the broken code look identical.

A corollary: because the feed is total-return, a corporate action produces **no price
discontinuity** — the underlying price and the multiplier move in opposite directions and
cancel. A 10:1 split drops the underlying ~10x and raises the multiplier ~10x.

**And balances do not rebase.** From the same source: cash dividends are reflected via a
multiplier update *"rather than distributed as cash to the B20 holder. This allows B20 holder
balances to automatically reflect corporate actions **without changing their balance of the
B20 token**."* `balanceOf` returns raw units and is untouched by corporate actions;
`scaledBalanceOf` is the multiplier-adjusted view. One B20 token is still NOT permanently one
share — that part stands — but the token count a holder owns does not move under them.

### A-19 · Base L2 sequencer uptime feed — **verified on chain 2026-09-04**
`0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`. `description()` returns
"L2 Sequencer Uptime Status Feed"; `latestRoundData()` reports `answer == 0` (up) with a
`startedAt` of 1782491507.

**Why it matters here.** On an L2 a Chainlink price feed keeps returning its last answer while
the sequencer is down — so a feed can be *fresh* and *wrong at the same time*, which is
precisely the input `ConversionRoutes` prices conversions against. `answer == 0` means up;
anything else means down. A grace period after it returns stops us trading on the first, thin
blocks. Raised by external review as SEC-POT-003 and wired in LAUNCH_CONFIG at 1 hour.

Reproduce:
```bash
cast call 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433 "description()(string)" -r $BASE_RPC_URL
```

### A-14 · Equity feeds have NO heartbeat outside market hours — **design input**
Straight from Chainlink's docs: *"When underlying equity markets are closed (weekends,
holidays, thin overnight windows), the feed holds the last close even though the contract
remains callable via latestRoundData(). These feeds do not have heartbeats during off-hours."*

**Consequence:** the naive staleness check (reject if `updatedAt` is older than N seconds)
would reject every round opened on a weekend. But accepting a stale mark blindly means the
min-out bound is computed off a Friday close while the pool has drifted all weekend.

**Decision needed from you.** My recommendation: rounds may open any time, but a stock whose
feed is stale beyond a configurable threshold is SKIPPED and its budget carried to the next
round — reusing the same "skip and carry" path the spec already defines for excess price
impact. Rounds still happen daily; weekend rounds simply buy less.

### A-15 · The B20 tokens are node-native, not EVM contracts — **major, verified**
Each stock token has exactly ONE byte of code (`0xef`, not executable EVM) and all storage
slots read zero, yet `name()`, `symbol()`, `decimals()`, `totalSupply()` and `balanceOf()`
all answer correctly over live RPC. Confirmed identically on Alchemy and on the public Base
RPC, so this is chain behaviour, not a provider quirk. The execution client special-cases
these addresses.

**Consequence 1 — testing.** A forked EVM executes the fetched bytecode and hits an invalid
opcode. Any fork test that touches a stock token reverts. Chipworks fork tests must install
a stand-in with `vm.etch` (`test/mocks/EtchableERC20.sol`, demonstrated in the fork suite).
Practical effect: we can test *our* logic against real pools, but we cannot test the real
token's behaviour locally. Confidence in anything stock-touching is lower than normal.

**Consequence 2 — deployment.** `forge script` simulation runs in the same forked EVM, so
any broadcast touching a stock token will fail simulation and needs `--skip-simulation`, or
must be executed from the multisig UI. To be reflected in DEPLOY.md when we get there.

**Consequence 3 — RESOLVED by Base docs.** Base documents B20 as "an extension of the
ERC-20 token standard" implemented as "native precompiles, not separately deployed
contracts", which is exactly what the measurements show. On the question that mattered:
*"holding and trading on the secondary market is permissionless"*, policies apply mainly to
mint/redeem flows with Authorized Participants, and **smart contracts can hold B20 tokens
unless specifically policy-blocked**. So ChipRewards and POLTreasury may custody stock.

Two residual risks that come with the standard, both worth disclosing to holders:
- **Policy blocklist.** Onchain policies can block specific addresses (e.g. sanctioned
  ones) and a blocked transfer reverts. If a Chipworks contract were ever blocked, claims
  in that stock would revert until it is unblocked. Low probability, total impact.
- **Pause.** B20 includes pause mechanisms and scheduled multiplier updates. A paused stock
  would break buys and claims for that stock while paused. The per-stock disable switch in
  StockRegistry is the mitigation: the multisig can switch a paused stock off and let the
  rest of the round proceed.

### A-17 · Never wrap a B20 call in a plain try/catch — **design rule, learned the hard way**
A call to a B20 precompile inside a forked EVM fails with `OpcodeNotFound`, which consumes
**every wei of gas forwarded to the subcall**. With an ordinary `try/catch` this silently
burns the entire block gas budget: the first `addStock` succeeded and the second ran out of
gas in the same transaction. Caught by `test_registersAllNineStocksAllDisabled`.

**Rule for every contract from here on:** any optional call to a stock token must be a
gas-capped `staticcall`, never a bare `try/catch`. `StockRegistry._checkedDecimals` uses
`DECIMALS_PROBE_GAS = 50_000` and is the reference implementation. This only bites in
simulation, never on real Base — which is exactly what makes it dangerous, because it would
have shown up first in a deploy dry run.

### A-18 · All thirteen B20 stocks — **ALL THIRTEEN NOW VERIFIED**
Base publishes thirteen tokenized stocks. **All thirteen** are now verified live on chain:
8 decimals, the symbol below, and the one-byte `0xef` precompile shape. Only four have a
Uniswap v3 pool against USDC today.

| Ticker | Address | Decimals | USDC pool? | Feed | Launch state |
|---|---|---|---|---|---|
| NVDAc | `0xb20000000000000000000078ee7ce2fE4908108C` | 8 ✓ | yes, 0.3% | A-13 | register, enable if depth clears |
| GOOGLc | `0xb2000000000000000000002D0BA3164cc74f58B7` | 8 ✓ | yes, 1% | A-13 | register, enable if depth clears |
| AAPLc | `0xb200000000000000000000C2e324d24d7eEcd1fb` | 8 ✓ | yes, 0.3% | A-13 | register, enable if depth clears |
| METAc | `0xb2000000000000000000008bC8786B856E61707C` | 8 ✓ | yes, 0.3% | A-13 | register, enable if depth clears |
| TSLAc | `0xb2000000000000000000001e800a7f5189430cD0` | 8 ✓ | none yet | A-13 | register **disabled** |
| AMZNc | `0xb200000000000000000000d9192b6B456483C2E8` | 8 ✓ | none yet | A-13 | register **disabled** |
| MSFTc | `0xB200000000000000000000Ab99cFa739E253872B` | 8 ✓ | none yet | A-13 | register **disabled** |
| COINc | `0xb200000000000000000000c85a31389D71F3ecfb` | 8 ✓ | none yet | A-13 | register **disabled** |
| MSTRc | `0xb2000000000000000000004884b426556b92883d` | 8 ✓ | none yet | A-13 | register **disabled** |
| CRCLc | `0xB20000000000000000000019f6E7C675b73C2e4D` | 8 ✓ | none yet | A-13 ✓ | register **disabled** |
| INTCc | `0xB2000000000000000000004AFF16039bA04bdFBc` | 8 ✓ | none yet | A-13 ✓ | register **disabled** |
| SNDKc | `0xb200000000000000000000397293Cb8cda9a10c5` | 8 ✓ | none yet | A-13 ✓ | register **disabled** |
| SPCXc | `0xb2000000000000000000007b9fcbd005511aCBd5` | 8 ✓ | none yet | A-13 ✓ | register **disabled** |

**CORRECTION, 2026-09-03.** This table previously said the last four had "none published"
for a feed. **Wrong** — all four feeds exist and are live; the addresses are in A-13 and in
`B20_DOCS.md`. The error came from reading A-13's own nine-row table as complete instead of
checking the source, which is exactly the failure mode the feed-description assertion in
`test/fork/ChainlinkFeeds.t.sol` was added to catch one row at a time.

**What actually keeps the last four disabled is the missing POOL, not a missing feed.**
`setEnabled(token, true)` requires a feed, a verified pool AND measured depth clearing
`minLiquidityUsd`, so a stock with no USDC pool reverts `PoolNotSet` however it is
registered. Register all thirteen with their feeds; the four without markets stay disabled
until a pool exists, and turning one on later is `setVenue` + `setEnabled` rather than a
fresh `addStock` against an address nobody has reviewed under time pressure.

**How this was verified, and why not in a fork.** Decimals and symbols were read by direct
RPC against a live Base node on 2026-09-03, outside the EVM. A fork **cannot** do it: these
are node-native precompiles (A-15), so `decimals()` reverts under a forked EVM after
consuming all forwarded gas. `test/fork/ChainlinkFeeds.t.sol` asserts the code shape (which
a fork *can* read) and asserts that calling one fails, so the limitation itself is pinned;
this table carries the RPC result.

Reproduce:
```bash
cast call 0xB20000000000000000000019f6E7C675b73C2e4D "decimals()(uint8)" -r $BASE_RPC_URL
cast call 0xB20000000000000000000019f6E7C675b73C2e4D "symbol()(string)"  -r $BASE_RPC_URL
```

### A-16 · The liquidity is NOT on Aerodrome Slipstream — **BLOCKER, verified**
Spec section 5 step 4 buys on Aerodrome Slipstream, and section 6 mints Slipstream LP.
Measured on Base at block 50,567,828:

**Aerodrome Slipstream: no pool exists for any launch stock**, against USDC or WETH, at
tick spacings 1 / 50 / 100 / 200 / 2000. The factory itself works (WETH/USDC resolves), so
this is genuine absence, not a bad call.

**Aerodrome v2: effectively nothing.** NVDA/USDC holds $72. AAPL/USDC holds $0.002.
GOOGL and META have no v2 pool at all.

**Uniswap v3 is where the liquidity is.** Best pool per stock, by USDC held:

| Stock | Best pool | Fee | USDC in pool | Stock in pool |
|---|---|---|---|---|
| GOOGL | `0x1f52F46BaC657564c31122b12b43A459E09273C8` | 1% | $37,119 | 145.68 sh |
| NVDA | `0x60661b315553EB81872deEA9a66d567Cf0CCd33B` | 0.3% | $7,440 | 16.06 sh |
| AAPL | `0x97F35d1E92795327614BE000cd18cba1Be2c1931` | 0.3% | $3,179 | 3.69 sh |
| META | `0x583919ec1975a1238C50e1940911894ee6912476` | 0.3% | $1,573 | 3.68 sh |

Those are raw token balances. Because Uniswap v3 is concentrated, the depth actually
tradeable near spot is a FRACTION of those numbers, so real slippage is worse than the
table implies.

**Consequence for the round mechanism.** A $10k round split four ways is $2,500 per stock.
META's entire pool holds under 4 shares; AAPL's holds under 4. A $2,500 market buy would
consume most of the pool and blow through any sane `maxImpactBps`. Even the $250 minimum
round puts $62.50 into a $1,573 pool — several percent of impact on the two thinnest names.
At today's depth the "skip and carry" rule would likely skip AAPL and META nearly every
round, and the pot would simply accumulate.

**Important context:** Coinbase launched B20 on Base on 2026-08-24, four days before this
was measured. Thin depth is what a four-day-old market looks like, not necessarily what it
will look like at Chipworks launch. Re-measure before go-live. The `minLiquidityUsd` gate in
StockRegistry is exactly the right defence, and the spec already anticipated this.

**Decision needed from you.** Three options, not mutually exclusive:
1. Buy on Uniswap v3 (where the liquidity is) and LP into Aerodrome Slipstream (where AERO
   emissions are). Coherent, and POL becomes the first Slipstream LP. Needs two venue
   integrations.
2. Route buys through an aggregator (0x / 1inch), which the spec already allows, and stop
   caring which venue wins. Adds an off-chain quote dependency to the keeper.
3. Launch with GOOGL and NVDA only, holding AAPL/META in the reserved list behind
   `minLiquidityUsd` until depth arrives. Fewest moving parts.

My recommendation: 3 for launch, 1 for the venue, revisit 2 later.

## Part 3 — Things I chose, that you can overrule

### C-1 · FeeSplitter is pull, not push
ETH sits in the splitter until someone calls `distributeETH()`. It is not forwarded the
instant it arrives. Reason: fee sources forward wildly different gas amounts and a
push-on-receive design breaks with LP lockers that use the 2300-gas `transfer`.
**Cost:** the Pot balance lags until the keeper calls distribute.

### C-2 · The ops share has an immutable ceiling
`opsBps` is changeable by the multisig, but only up to `maxOpsBps`, which is fixed at
deploy. Deploy with both at 2000 and the multisig can only ever *lower* the ops share.
**Decision needed:** set `maxOpsBps` to 2000 (ops share can never rise above 20%) or
higher (keeps flexibility, costs credibility).

### C-3 · Rounding dust always goes to the Pot
Sub-wei / sub-unit remainders favour holders. Deliberate and tested.

### C-4 · `setPot` exists
The multisig can repoint the splitter at a new Pot. Needed because Pot may be redeployed,
but it is also the strongest privilege in the contract.
**Decision needed:** keep it, or lock the Pot address forever at deploy?

### C-5 · The Pot converts its own ETH — RESOLVED
`Pot.convert()` is permissionless and swaps accumulated ETH (and WETH) into USDC through
Uniswap v3, with the minimum output bounded by the Chainlink ETH/USD feed. Route, fee tier,
slippage bound, per-call cap and feed-staleness limit are all configuration.

Un-converted ETH still does NOT count toward the $250 gate: `available()` reports round
currency only, so a round can never open against money that has not been realised.

**The per-call cap earns its place.** Verified on a Base fork against the live pool: 2 ETH
converted to 4,882 USDC against a 4,838 Chainlink floor, while an uncapped 500 ETH in one
shot breached the bound and was refused outright. Without the cap a fat pot would either
fail to convert or bleed value walking the pool.

**Dust floor.** Amounts small enough that the Chainlink-derived minimum rounds to zero are
refused with `AmountTooSmall` rather than swapped without price protection. Found by fuzz.

`sweepEth` survives as the escape hatch if the route itself breaks.

### C-6 · The hoodie boost is REMOVED — **no longer a design decision, a deleted feature**
**Removed before launch, 2026-09-04.** The 1.10x boost for holders of an external NFT
collection was carried over from the pre-Clutch v0.1 spec. That collection is not part of
this project and is not deployed on Base, so the term was configuration pointing at nothing.
It also carried a live sybil, found by external review: the boost read ownership at
contribution time while the `counted` guard tracked Nouns rather than boost tokens, so one
NFT passed between addresses inside the 2-hour accumulation window could boost unlimited
Nouns. Removed at the source rather than fixed — see TRIAGE.md EXT-R-M-2.

**A Noun's weight is now `tier x collectionBase`, and nothing else.** No term in the weight
formula depends on any property of the owner, which is a simpler and stronger statement than
the boost was ever worth.

*The original note is kept below for the record.*

~~Spec section 4 has `poke(id)` to refresh a cached boost. This reads the hoodie balance live~~
at contribution time instead: always correct, no stale-cache bug class, no keeper
dependency, and one fewer function. Cost is one gas-capped `balanceOf` per Noun per round.
**Residual risk either way:** a borrowed or briefly-held hoodie boosts that round. Caching
does not fix that; only a snapshot at activation time would, and that has its own problems.
Flagging rather than solving.

### C-7 · No masterchef accumulator, per-round weight shares instead
Explained at the top of `ChipRewards.sol`. Short version: an accumulator cannot express
per-round 90-day expiry, and we have to iterate Nouns anyway because the vault cannot
enumerate them. Per-round shares give exact expiry and exact sweeps with no second pass.

### C-8 · A live round's budget is committed and cannot be rescued
`recoverExcess` cannot touch either booked credits or the unspent budget of a round in
flight (`committedQuote`). **This was a real bug found by the solvency invariant**, not a
design intention: before the fix, the multisig could pull an open round's budget and a
later settlement would still credit holders for money that had already gone, leaving the
contract insolvent. `cancelRound` exists so a round that is opened and then abandoned
returns its budget to the Pot rather than stranding it.

### C-9 · Rescue powers, stated plainly
The multisig can recover any token strictly above `totalOwed` plus `committedQuote`. It can
never take a booked credit, an expired-but-unswept credit, or a live round's budget. Proven
by `ChipRewardsRecover.t.sol` and by the stateful solvency invariant.

### C-10 · One residual wedge: a blocked quote token
If USDC itself ever policy-blocked ChipRewards, a round stuck in `Buying` could not settle
or finalize, because approving and transferring the quote token would revert. Every stock
path degrades gracefully; the quote token is the single asset with no fallback. Judged
acceptable (USDC blocking a public contract would be an ecosystem-wide event), but it is
the one place where "isolated failure" does not hold.

### C-11 · Round accounting books what MOVED, not what was intended
`settleStock` records the measured balance deltas of both the quote token spent and the
stock received, never the amounts requested or a router return value.

**This came from a bug the lying-token test found.** Previously a swap that consumed the
input but delivered less than the Chainlink floor was recorded as a "skip", as though the
money were untouched. It was not: the USDC had gone. The round then believed it still held
a budget it did not have, and `finalizeRound` reverted trying to return it — leaving the
round permanently unfinishable and every holder in it unable to claim.

Now: a swap that reverts atomically is a genuine skip and the slice carries. A swap that
executes is booked at its real cost and real proceeds, and under-delivery is surfaced with
a `StockUnderdelivered` event rather than hidden. A real Uniswap router enforces
`amountOutMinimum` itself, so this path should never trigger in production — which is
precisely why it needed a test.

### C-12 · The POL holdback fails open, in holders' favour
`holdbackBps` (0-25%, ceiling immutable at 2500) is taken from each purchase and sent to
POLTreasury. The transfer is measured by balance delta and cannot revert the round: if the
treasury is policy-blocked, paused, or the token lies, the holdback simply does not happen
and holders are credited MORE. There is no path where a failed holdback leaves the contract
crediting stock it does not hold.

### C-13 · POLTreasury's rescue works by exclusion, not by arithmetic
ChipRewards protects a computed sum of user credits. POLTreasury holds protocol assets, so
"balance minus owed" would protect nothing. Instead its rescue can never move the quote
token, a registered POL asset, a registered income token, or a position NFT — only tokens
it does not recognise. POL assets leave only via `forwardIncome` to the splitter or a
manager action on a position. There is no path from POL assets to a wallet.

### C-14 · The Bankr optimizer is a manager, not an owner
`manager` may mint, re-range, stake and unstake positions. It may NOT change the fee
splitter, the asset lists, the rewards address, or its own role, and it cannot mint a
position to its own wallet — `mintPosition` overrides the recipient to the treasury.
Collecting fees, claiming gauge rewards and forwarding income are all permissionless, so
income keeps flowing to holders even if the optimizer goes quiet or is revoked.

### C-15 · Routing is never worse than claiming directly
`ClaimRouter` guarantees three things, each with a test named after it: every leg is an
independent bounded call whose failure is recorded rather than propagated; the router never
becomes the claimant and never keeps a balance; and gas is capped per leg so one hostile
entry cannot starve the legs after it. Two tests assert the routed outcome is byte-identical
to claiming each side directly, including when a leg is broken. A failed leg leaves the
credit fully claimable.

### C-16 · `claimFor` is permissionless on purpose
Anyone may trigger anyone's Chipworks claim, but the proceeds always go to the owner, never
the caller. This is what lets the router bundle a claim without becoming the claimant, and
it lets the site auto-claim before a holder sells into the anvil. A stranger calling it can
only help: it delivers the owner's own credit and protects them from the 90-day expiry.

### C-17 · The full-system fork test substitutes WETH for a B20 stock
B20 tokens are precompiles a forked EVM cannot execute, so a fork test cannot both use the
real token and trade it in its real pool. WETH has a real Chainlink feed and a deep real
pool, so the buy, credit, claim, sweep and POL paths all run against live infrastructure.
What it does not exercise is B20's own blocklist, pause and multiplier — those are covered
by the hostile-token suites. See OPEN_ITEMS.md item 5.

### C-18 · Claims are gated to weekly windows; expiry is 30 days
Claims unlock on a `windowLength` cadence (default 7 days) anchored at deploy and stay open
`windowOpenDuration` (default 48h). Credits accrue and stay visible between windows via
`claimable`; only the taking is gated. Outside a window `claim` reverts with
`ClaimsClosed(now, nextOpenAt)`, so a caller is told exactly when to come back.

Three properties make this safe rather than merely restrictive:
- **`windowAnchor` is immutable.** If governance could move it, it could slide every future
  window forward and block claims indefinitely without changing a single duration.
- **Every config must leave at least 3 full windows before expiry.** Enforced on both setters
  as `creditExpiry >= 3 * windowLength`. Openings sit on a fixed cadence, so any interval of
  length E contains at least `floor(E / W)` of them; the check therefore makes the guarantee
  hold for any finalize moment, not only favourable ones.
- **Each round freezes its own schedule at finalize** (`expiresAt`, `windowLengthAt`,
  `openDurationAt`). Retuning affects future rounds only and can never narrow or shorten a
  round that already exists.

Cost of the design, recorded honestly: a holder gets three or four chances rather than 30
open days. See OPEN_ITEMS item 8.

### C-20 · Only standard ERC-20s are routed as fee assets — documented, not enforced
The FeeSplitter moves whatever token it is handed. Restricting that to an allowlist was
considered after external review (TRIAGE SEC-FEE-002) and **deliberately not done**: an
allowlist adds a governance surface, and a way to freeze a fee stream by forgetting to add a
token, to defend against a class the reentrancy guards already cover.

What protects the splitter instead: every downstream entry point a token hook could re-enter
is `nonReentrant`, the splitter holds no cross-leg accounting state a re-entrant call could
read inconsistently, and the Pot is paid last from the measured remaining balance so a token
that takes a cut in transit cannot revert its own split.

**The operational rule stands even though it is not enforced:** route WETH, USDC, AERO and
$CHIP. A rebasing or callback-heavy token should not be pointed at this contract without
reading it first.

### C-19 · An expired credit is forfeited, not compounded
The 30-day sweep moves everything unclaimed to POLTreasury and writes **no ledger entry** for
the holder. There never was compound-share crediting on this path — the ledger is only
touched by the voluntary `setAutoCompound` route — and tests now pin that, including for a
holder who has auto-compound switched on. Blurring the two would let a forfeit look like a
deposit.

The sweep is permissionless, per (round, stock), batched over a holder list with a cursor,
and emits one `CreditExpired` per holder so the site can show exactly what each person lost.
Per-holder shares are floored, so the final batch settles the rounding dust and the contract
never keeps a remainder it no longer owes.

---

### A-20 · The Aerodrome Voter is the only authority on gauges — **verified on chain 2026-09-04**

`0x16613524e02ad97eDfeF371bC883F2F5d6C480A5`, 33,827 bytes of code on Base.

**Why this is an assumption worth writing down rather than a detail.** `POLTreasury.stakePosition`
grants an ERC-721 approval to a gauge and then calls into it. Whether that is a staking
operation or a theft depends entirely on whether the address is really a gauge, and there is
nothing about a gauge address that says so — anyone can deploy a contract with a
`deposit(uint256)`. The Voter's `gauges(pool)` mapping is the only on-chain statement that a
given gauge belongs to a given pool. **We are trusting Aerodrome's Voter to answer that
honestly**, which is a much smaller and much more inspectable trust than trusting whoever
holds the manager key.

Probed live:

```
voter.gauges(0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59)  # WETH/USDC, tickSpacing 100
  -> 0xF33a96b5932D9E9B9A0eDA447AbD8C9d48d2e0c8
voter.isAlive(0xF33a96b5932D9E9B9A0eDA447AbD8C9d48d2e0c8) -> true
```

The pool address itself comes from the Slipstream factory
`0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A`, which POLTreasury reads out of
`positionManager.factory()` at construction rather than accepting as an argument.

**`isAlive` is deliberately NOT checked.** A killed gauge earns nothing, so checking it is
tempting, but it is an economics question and not a custody one: a killed gauge is still the
canonical gauge and `withdraw` still returns the position. Adding the call would put an extra
Voter interface dependency in the staking path, where a change would break staking rather
than merely cost yield. It belongs on the keeper side — see OPEN_ITEMS 21.

**What breaks if this is wrong.** If Aerodrome migrated to a new Voter, `stakePosition` would
start refusing the new canonical gauges and POL would stop earning AERO until the treasury
was redeployed. It would not become unsafe — the failure is a refusal, not an acceptance —
but the Voter is an immutable constructor argument, so a migration is a redeploy. Recorded
here so nobody discovers it as a surprise.

Covered by `test_realAerodromeAnswersThePoolAndGaugeChecks` and
`test_realVoterRefusesANonCanonicalGauge` in `test/fork/PolTreasuryFork.t.sol`.

---

### A-21 · ETH can be forced into the Anvil and cannot be got out — **accepted, by design**

External review batch 7, I-1.

`Anvil` has no `receive()` and no `fallback()`, so an ordinary `send` or `transfer` to it
reverts. Two things get past that, and no contract on any EVM chain can refuse either:

- `selfdestruct(anvilAddress)` from a contract holding a balance;
- being named as a block's `coinbase` (fee recipient).

ETH that arrives either way is **permanently stuck**. The Anvil forwards 100% of every sale to
the FeeSplitter inside the same transaction and deliberately has no ETH withdraw path, so
there is nothing to sweep it with.

**We are choosing that, and the reasoning is the point.** The fix would be an owner-callable
ETH withdraw on the contract that handles every Anvil sale. That is a standing way to take
sale proceeds out of the protocol, permanently, in exchange for being able to recover money
somebody chose to destroy by sending it somewhere with no way in. A contract that cannot pay
its owner out in ETH is a stronger property than a recoverable donation, and the amounts
involved are whatever a griefer is willing to burn.

**What it is NOT.** It cannot affect a sale: `_settle` forwards exactly `price` and refunds
exactly `msg.value - price`, both from figures it computed, never from `address(this).balance`.
A stuck balance changes no arithmetic anywhere in the contract, and
`test_everyWeiIsForwardedAndNothingIsHeld` asserts the normal path holds nothing.

The same is true of every other contract in the repo that forwards rather than holds. It is
recorded once, here.

---

### A-22 · No B20 stock has an Aerodrome Slipstream pool — **swept on chain 2026-09-06**

**This one contradicts a briefing, so it is written with the method attached.**

The stock-registry expansion was specified as adding TSLA, AMZN, MSFT, MSTR, SNDK and SPCX
"all with live Aerodrome Slipstream pools". They do not have any. Neither do the four already
registered, and neither do the three being added disabled.

Swept with `test/fork/B20PoolDiscovery.t.sol` against latest Base, for **all thirteen** B20
tickers:

| Venue | Probed | Found |
|---|---|---|
| Aerodrome Slipstream (CL) `0x5e7BB1…809A` | vs USDC **and** vs WETH, tick spacings 1, 2, 5, 10, 25, 50, 100, 200, 500, 2000 | **nothing, for any ticker** |
| Aerodrome basic AMM `0x420DD3…40Da` | vs USDC (v and s) and vs WETH | AAPL and NVDA only, both **vAMM**, ~$4.9k and ~$4.2k |
| Uniswap v3 `0x33128a…FDfD` | vs USDC, fees 100/500/2500/3000/10000 | every pool with real depth |

**The control matters.** The same `getPool` call on the same Slipstream factory resolves
WETH/USDC at tick spacing 100 in the same test run, so a zero is "there is no pool", not "we
are calling it wrong". `test_noB20StockHasASlipstreamPool` asserts both halves and will start
failing the day a Slipstream pool appears — which is the point of writing it as an assertion
rather than a note.

**Where the belief probably came from.** AAPL and NVDA really do have Aerodrome pools, and a
router or aggregator UI would happily route a stock buy through Aerodrome for them. But they
are **basic vAMM pools, not concentrated-liquidity ones**, and they are the two smallest
venues either token trades on. `Venue.Slipstream` verifies against the CL factory and
correctly refuses them; `Venue.UniswapV3` is where the depth is.

**Consequence for the registry.** Every B20 stock is registered as `Venue.UniswapV3`, with the
deepest USDC pool for that ticker. `test_slipstreamVenueCannotBeFakedForAB20` proves the
registry cannot be told otherwise: passing `Venue.Slipstream` with a ticker's real Uniswap
pool reverts `PoolNotFoundInFactory`, because the CL factory has never heard of it.

**This does not close the Slipstream path.** `ChipRounds` encodes both venue shapes and
`StockRegistry` verifies both factories, so the day a B20 Slipstream pool appears with real
depth it is a `setVenue` call and nothing else. See A-16, which said the same thing about the
conversion side and is still correct.

## A-23 — Executable-depth gate and its limits (issue #5)

The registry certifies one configured quote-to-stock buy probe using the venue's
canonical QuoterV2, bounded by a Chainlink output-value deviation. No token balance
contributes to enablement. `poolTvlUsd` is the renamed historical balance metric and
remains diagnostic. The result is the validated input USD notional, not total pool
capacity, available liquidity across all prices, or permission to extrapolate a larger buy.

Canonical quoters are non-view and expensive. Each measurement uses one bounded CALL;
their inner pool swap reverts, leaving balances and positions unchanged. Off-chain
reports must use eth_call, not EVM STATICCALL. A 1M-gas quote cap can conservatively reject
markets that cross many ticks. A failed quote, bad state, numeric overflow, or unavailable
feed produces zero and fails the gate, even at a zero threshold.

The new depth policy requires a fresh feed timestamp (minimum age window 72h; recommended
120h for equity closures); priceUsd itself retains A-14's raw mark/timestamp semantics.
The quote token is still valued at par. Quoter factory identity is a configuration check,
not proof of canonical bytecode: the multisig must select the reviewed deployed quoter.

Donations alone cannot add positions or improve executable quotes for ordinary tokens.
Spot state can still change through swaps, flash liquidity, position changes, issuer
policies, and market moves. This is not a TWAP or anti-MEV guarantee. An enablement-time
probe cannot guarantee liquidity at settlement. The present ChipRounds has no
_maxSpendFor/maxImpactBps path; its budget cap, Chainlink minimum output, balance-delta
accounting and skip/carry-forward semantics remain the independent controls. Historical
references suggesting a production per-stock impact check should be read with this correction.
