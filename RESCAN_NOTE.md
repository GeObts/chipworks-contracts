# RESCAN_NOTE.md — targeted re-review for `launch-candidate-19`

For Bankr. **Two contracts changed since the eleven-contract audit closed at
`launch-candidate-14`.** Everything else is byte-identical; `git diff launch-candidate-14
launch-candidate-19 -- src/` is the authoritative list and it touches three files.

```bash
git checkout launch-candidate-19
git diff launch-candidate-14 launch-candidate-19 -- src/       # everything
git diff launch-candidate-14 launch-candidate-19 -- src/ChipRounds.sol
git diff launch-candidate-18 launch-candidate-19 -- src/       # just the Chiplet change
forge test                                                      # 712 + 51 fork
```

Flattened sources for the changed contracts are in `review/flattened/`.

---

## What changed, and where to look

### 1. `ChipRounds.sol` — depth-aware impact trim, and the round cap removed (`-16`)

**Read this one first.** It is the only change that touches the money path.

- **`maxImpactBps` is new.** Each per-stock buy is sized from
  `StockRegistry.poolLiquidityUsd(stock)` — the same measured depth the registry's enable-gate
  already uses — and spends at most `depth x maxImpactBps / BPS`. Default 25 bps, per-stock
  override, hard ceiling `MAX_IMPACT_CEILING_BPS = 500`. Unreadable depth returns **zero and
  the stock is skipped**, which is fail-closed.
- **`maxRoundBudget` is gone.** A round takes the whole Pot; only `minPotToOpen` remains.
  `setRoundParams` lost its fourth argument.
- **Why together:** the cap was the written mitigation for **EXT-R-L-1** and **SEC-POT-002**
  (*"the round cap does not go above $10,000 until dynamic slippage or private routing is in
  place"*). Removing it alone would have reopened both. The trim is the replacement, and it is
  a different kind of bound: exposure per buy is now a function of the POOL, not of the round.
- **What to attack:** can `_maxSpendFor` be made to over-report depth, since
  `poolLiquidityUsd` is headline TVL across both sides and a concentrated pool's tradeable
  depth near spot is a fraction of it? Can a stock be made to skip permanently? Does the
  remainder always reach the Pot? (It leaves through the existing `finalizeRound` unspent path
  — deliberately **no per-stock earmark**, so no new money-path storage.)

Also in `ChipRounds`, smaller: the split-change fee's burn address was a **settable variable
with no validation of any kind** — a documented burn could have been pointed anywhere, silently
becoming revenue. It is now the `0xdead` constant, delta-verified, and counted in
`totalChipBurned`. `setChip` lost its second argument.

### 2. `ChipActivation.sol` — Chiplets as a fourth earning collection (`-19`)

- **`activateFlat(collection, tokenId, sacrificeId)`** is the new entry point. A flat-rate
  collection has no tiers: activation costs a flat $CHIP amount **and one other token of the
  same collection**, which is destroyed.
- **Two burns, two kinds, both verified.** The sacrificed Chiplet is **truly burned** through
  OpenSea's `ERC721SeaDrop.burn` (ERC721A, `_burn(tokenId, true)`, operator-authorised) and its
  absence is checked afterwards. The $CHIP goes to `0xdead` because Bankr's Doppler token has
  no `burn` at all; it is delta-verified against the dead address's balance.
- **`isFlatRate` is one-way and pre-configuration only.** It cannot be set on a live
  collection, and a flat collection's five cost entries must be **equal**, so no hidden ladder.
- **What to attack:** can `activateFlat` burn a token the caller does not own? (`sacrificeId`
  must be owned outright — a custodian-held token is deliberately not burnable, while
  `tokenId` itself may sit with a custodian.) Can the two burns be separated so an activation
  is recorded against a burn that did not happen? Can a flat collection reach `upgrade`, or a
  tiered one reach `activateFlat`?

### 3. `Furnace.sol` — true burns for fuel (`-17`, `-18`)

Outside the money path and outside the eleven-contract scope, included because it shares the
burn pattern. `forge` calls `chiplets.burn(tokenId)` rather than transferring to `0xdead`, with
a transfer-to-dead **fallback** for any collection that exposes no burn. Both routes verify the
end state. `totalFuelTrueBurned` vs `totalFuelBurned` distinguishes them.

---

## What did NOT change, and why that is worth knowing

**`ChipRounds`' weight calculation was not touched by the Chiplet work.** Weight is
`tierBps x collectionBaseBps / BPS` and was already collection-agnostic, so Chiplets at 0.1x is
`setCollectionBaseBps(chiplets, 1_000)` — a configuration call, exactly like Lil Based Nouns at
5_000. `ChipActivation` reports a flat `FLAT_TIER_BPS = 10_000` and the base supplies the 0.1x.

**Chiplets is not a contract in this repo.** It is deployed through OpenSea's drop flow.
Nothing in `src/` imports it, subclasses it, or assumes anything about it beyond the ERC-721
surface plus `burn(uint256)`. Both contracts hold only its address, supplied at deploy time.

**No prior finding is reopened.** EXT-R-L-1 and SEC-POT-002 were reopened by the cap removal
and are re-closed by the trim — see the TRIAGE entry at the top of the file, which shows both
states. Everything else stands as triaged.

---

## Still open, and not introduced by these changes

- **`StockRegistry` has never had an external review** (OPEN_ITEMS 25a). Largest un-reviewed
  surface; it decides which stock is tradeable and at what depth, which is the input the trim
  above now reads.
- **`ChipClaims` lows `EXT-C-L-1`…`-L-4` were never received** (OPEN_ITEMS 25b) and have never
  been read.
