# OPEN_ITEMS.md

What the full-system fork test surfaced, plus everything still unresolved. Ordered by how
much it matters. The **Clutch seam** is item 0 and is marked throughout.

Updated 2026-08-28 after the weekly-claim-window change. Generated from `test/fork/FullSystem.t.sol`, which runs the whole machine —
fees in → convert → round → claims → expiry sweep → POL mint → POL income back out — on a
Base mainnet fork.

---

## 0. THE CLUTCH SEAM — the one thing the test cannot verify

**Status: blocked on Clutch. Everything below it is our code; this is not.**

The full-system test is real end to end *except* the Clutch soft-staking vault, which is a
mock. It has to be: Clutch publishes no Base deployment at all (ApeChain 33139 and Robinhood
4663 only), so there is nothing on Base to point at.

Everything that depends on the vault is therefore unproven against reality:

| Assumption | What we guessed | Blast radius if wrong |
|---|---|---|
| A-1 | Clutch will deploy on Base | Total. No foundation. |
| A-2 | "Anvil V3" exists and does non-custodial soft staking | Wrong product. |
| A-3 | One vault per collection | Based #5 and Dark #5 collide |
| A-4 | `isActive(tokenId)` | Every round reverts. Loud. |
| A-5 | `tierOf(tokenId)` | Every round reverts. Loud. |
| A-6 | `ownerOfRecord(tokenId)` | Rewards booked to the wrong address |
| A-8 | Voiding may be lazy, so we re-check the live NFT owner ourselves | Already mitigated |
| A-9 | `claim` pays the owner of record, not the caller | Already mitigated |

**Two of these are already neutralised, whatever the answer turns out to be.**
- A-8: `ClutchVaultAdapter` independently checks `IERC721.ownerOf` against the vault's owner
  of record, so a sold Noun stops earning immediately whether or not anyone calls `kick`.
- A-9: `ClaimRouter` sweeps its own balance to the owner after claiming, so it works whether
  Clutch pays the owner of record or the caller.

**The rest are concentrated in one small contract.** `ClutchVaultAdapter` is the only thing
that talks to Clutch. If the real ABI differs we redeploy that one contract and repoint
ChipRewards and ClaimRouter at it — no migration of anyone's credits, no redeploy of
anything holding money.

**Action:** the four questions for Clutch are drafted and sitting with you. One answer
closes A-2 through A-6 and A-9 at a stroke.

---

## 1. POL income stranded as AERO — **CLOSED**

Was: the loop closed on paper but `convert()` only knew ETH and WETH, so recycled AERO
reached the Pot and no round could spend a cent of it.

Now: conversion is a **per-token route table** — Chainlink feed, router, fee tier, slippage
bound, per-call cap and staleness limit, one row per asset. `convert(token)` is
permissionless for every registered token. AERO's route is registered against the live
AERO/USD feed (`0x4EC5970fC728C5f65ba413992CD5fF6FD70fcfF0`) and the Uniswap AERO/USDC pool.

Proven in `test/fork/FullSystem.t.sol`: 1,000 AERO of POL income → splitter → 700 to the Pot
→ converted → **funds the next round**. The test previously ended with 800 stranded AERO and
1 wei of spendable budget.

Residual note: the AERO/USDC pool on Uniswap holds ~$66k, thinner than the WETH pools.
The per-call cap and the Chainlink bound are what keep that safe; size the cap accordingly.

## 2. Nothing routed USDC to POL — **CLOSED**

Was: POL received the stock holdback but had no quote token to pair it with, except by
accident when an unclaimed credit expired into it.

Now, two mechanisms:
- **`FeeSplitter.polShareBps`** — an optional third leg, default 0, hard-capped at 2000 and
  requiring a treasury to be set before a non-zero share can be configured. Same flush
  semantics, same permissionless calls, dust still to the Pot.
- **POLTreasury shares the Pot's converter.** The splitter leg arrives in whatever asset was
  flowing (ETH from the locker, AERO from gauges), so POL realises it into the quote token
  itself using the same Chainlink-bounded, capped route table.

Without the second half the leg would have delivered ETH that POL cannot pair — the same
class of bug as item 1. Proven in the full-system fork test: POL self-funded $732 of pairable
USDC from its own ETH slice, with no expired credit and no manual transfer.

The conversion machinery lives in `src/base/ConversionRoutes.sol` and there is exactly one
copy of it, shared by `Pot` and `POLTreasury`. Duplicating a Chainlink-bounded swap would
have doubled the audit surface and guaranteed drift.

## 3. AERO accrual is not exercised, only its routing

The test injects AERO rather than earning it, because emissions accrue over epochs. Our
routing of it is proven; Aerodrome's accrual is not our code. What is genuinely unverified
is the **gauge address per pool** — there is no registry for it, the manager passes it per
call. Low risk, but a wrong gauge address is a manager mistake with no on-chain guard.
Consider verifying the gauge against the Aerodrome voter contract the way StockRegistry
verifies pools against the factory.

## 4. A round stuck in `Buying` has no escape hatch

`cancelRound` covers a round opened and never closed. But a round that closed accumulation
and then has a stock nobody settles stays in `Buying` forever, and `finalizeRound` requires
every stock settled — so claims for that round never open.

In practice `settleStock` is permissionless and cannot revert for a frozen stock (it skips),
so anyone can push it along. The one genuine wedge is C-10: if USDC itself policy-blocked
ChipRewards, `settleStock` could not approve or transfer and the round would hang.

**Judged acceptable** (USDC blocking a public contract would be an ecosystem-wide event) but
it is the single place where "isolated failure" does not hold, and it is worth a `cancelBuying`
that returns the remaining budget and marks the round finalized with whatever was acquired.

## 5. B20 behaviour is covered by mocks, not by the real token

The full-system test substitutes WETH for a B20 stock, because B20 tokens are native
precompiles a forked EVM cannot execute (A-15). That gives a real swap, real feed, real
pool — but it does not exercise B20's own policy blocklist, pause, or dividend multiplier.

Those are covered by `ChipRewardsHostile`, `FeeSplitterHostile` and `POLTreasury` hostile
suites using `BlacklistToken` / `PausableToken` / `LyingToken`, which model documented B20
behaviour. **Confidence in anything B20-specific is therefore lower than everything else in
this repo**, and no amount of local testing fixes that. First mainnet round should be small.

## 6. Chainlink equity feeds go stale outside market hours — by design

A-14. The feeds hold the last close and have no heartbeat when equity markets are closed.
StockRegistry deliberately does not judge staleness; ChipRewards currently does not either.

**Decision still open:** should a round skip a stock whose feed is older than N seconds and
carry its budget? I recommend yes, with N configurable and generous (say 36h) so ordinary
weekends pass but a genuinely dead feed does not silently price a purchase.

## 8. NEW: the claim window shortens the effective time to claim

Credits expire 30 days after a round finalizes, but can only be taken during a 48-hour
window every 7 days. So a holder does not get 30 days of claiming — they get **four 48-hour
windows**, roughly 8 days of actual opportunity.

The contract guarantees at least three windows for any accepted configuration
(`creditExpiry >= 3 * windowLength`, enforced on every setter, frozen per round at finalize,
asserted by fuzz and by a stateful invariant that retunes the schedule mid-run). But three or
four chances is a much narrower promise than "30 days", and the gap is a UX problem:

- The site must show the next window prominently and a per-round countdown to expiry.
- `claim` reverts with `ClaimsClosed(now, nextOpenAt)` so the UI can render the exact return
  time. `ClaimRouter.claimWindowStatus()` exposes the same for greying out the button.
- A holder who misses every window forfeits outright: expiry writes no ledger entry, so
  there is no consolation POL share.

**Worth considering before launch:** `claimFor` is permissionless and always pays the owner,
so a keeper could claim on behalf of everyone during the last window of each round at its own
gas cost. That converts a forfeit risk into an operational cost. Not built.

**Also unresolved:** the three-window rule bounds the COUNT of windows, not their spacing.
With 7-day windows and a 30-day expiry the last window can land only hours before expiry.

## 7. Smaller things

- **Deploy simulation.** Any `forge script` touching a B20 token fails simulation; use
  `--skip-simulation` or execute from the multisig UI. Already in DEPLOY.md.
- **Conversion fee tier.** Defaulted to Uniswap 0.05% ($3.14M USDC). The 0.3% tier holds
  more raw TVL ($64.2M) but costs 25bps more. One multisig call to change; a wrong choice
  fails safe because the Chainlink bound rejects rather than executes badly.
- **`recoverExcess` on a live round.** Cannot touch committed budget or booked credits, but
  the multisig can still take genuinely stray tokens. Documented in C-9.
- **Compound ledger is mirrored.** ChipRewards' `polCreditUsd` is authoritative; POLTreasury's
  `compoundShares` is a best-effort mirror that can never block a claim. If they ever diverge,
  trust ChipRewards.
- **No redemption path for compound shares.** The ledger records who compounded; the spec
  does not define how they get value back out. Phase 2 question, worth answering before you
  market auto-compound. Note expiry does NOT feed this ledger — an expired credit is a
  forfeit, not a compound, and the two are deliberately distinguishable.
- **Sweep gas scales with holders.** The expiry sweep walks a per-(round, stock) holder list
  to emit per-holder amounts. It is batched with a cursor and idempotent, but a popular round
  needs several calls. The token movement alone would have been O(1); the iteration exists
  only so the site can show who lost what.

---

## Verified, so no longer open

- Chainlink B20 equity feeds — all nine live on Base, addresses in ASSUMPTIONS A-13
- Slipstream position manager ABI — probed against deployed bytecode, real position minted
- Uniswap SwapRouter02, ETH/USD feed, WETH/USDC pools, USDC, AERO — all checked on fork
- B20 token addresses and decimals — all nine verified, 8 decimals
- Contracts may hold B20 — confirmed by Base docs, secondary trading is permissionless
- AERO/USD feed and AERO/USDC pool — verified on fork, route registered
