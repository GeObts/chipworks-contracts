# BURN_VISIBILITY.md — what actually gets destroyed, and what only looks it

Two contracts Chipworks burns into, neither of which it owns, and they behave differently.
This file is the reference for the site, for the explorers, and for whoever files the burn
address with the aggregators.

---

## Chiplets — a REAL burn

**Chiplets is not a contract in this repo.** It is deployed through OpenSea's drop flow —
`ERC721SeaDrop`, which is `ERC721A` underneath — and our contracts only ever hold its ADDRESS,
supplied at deploy time. Nothing in `src/` imports it, subclasses it, or assumes anything about
it beyond the ERC-721 surface plus `burn(uint256)`.

The Furnace calls `chiplets.burn(tokenId)`, which emits `Transfer(owner, address(0), tokenId)`
and **decrements `totalSupply`**. OpenSea, Basescan and every indexer read that event and shrink
the collection.

**Operator burn is confirmed against OpenSea's source, not assumed:**

```solidity
// ERC721SeaDrop.sol — and ERC721SeaDropCloneable.sol, the variant their drop UI deploys
function burn(uint256 tokenId) external { _burn(tokenId, true); }

// ERC721A._burn, with approvalCheck == true
if (!_isSenderApprovedOrOwner(...))
    if (!isApprovedForAll(from, _msgSenderERC721A())) revert TransferCallerNotOwnerNorApproved;
```

That last branch — `isApprovedForAll` — is the one the Furnace uses. ERC721A's `totalSupply()`
is `_currentIndex - _burnCounter - _startTokenId()`, so a burn genuinely reduces it, and
`ownerOf` on a burned id reverts, which is how the Furnace verifies the burn took.

**The forge flow is approve-then-burn, and the site must implement step one.**

```
1. chiplets.setApprovalForAll(furnaceAddress, true)   // once per wallet, standard marketplace approval
2. furnace.forge(recipeId, sortedFuelIds)             // ids MUST be strictly ascending
```

Without step one the forge reverts. There is no privileged path: **the Furnace holds no burn
role and none can be granted to it.** `ERC721Burnable.burn` authorises its caller exactly the
way `transferFrom` does — owner, approved-for-token, or operator — so the Furnace can only
reach what a user has approved, in the ordinary way.

**The approval is broad; what the Furnace does with it is narrow.** As with any marketplace,
`setApprovalForAll` covers every Chiplet the user owns. The guarantee is in the contract:
`forge` consumes only the ids the caller passed, and only after checking the caller owns every
one of them. There is no admin function that moves fuel at all. Pinned by
`test_theFurnaceOnlyBurnsTheTokensTheCallerNamed` and
`test_theFurnaceCannotBurnAnotherHoldersTokens`.

**A collection without `burn` falls back to `0xdead`.** If the fuel is ever pointed at a
collection we do not control that exposes no burn — a Noun, say — the call fails, nothing has
happened, and the token is transferred to the dead address instead. **Those show as dead-held,
not supply-reduced.** `Furnace.totalFuelTrueBurned` versus `Furnace.totalFuelBurned` is how you
tell the two apart on chain.

---

## $CHIP — NOT a real burn, and that is Bankr's limitation

**Bankr's Doppler token exposes no `burn`.** Confirmed in their documentation. So every $CHIP
burn in this protocol is a transfer to:

```
0x000000000000000000000000000000000000dEaD
```

the canonical address Basescan labels as a burn address. **`totalSupply()` does not fall.** The
tokens are unreachable — nobody holds that key — but they are still counted by anything reading
`totalSupply` naively.

**This is not a Chipworks bug and it is not fixable from our side.** It is a property of a
contract we do not own.

### Every burn path, and its counter

| Path | Contract | Counter |
|---|---|---|
| Activate a Noun | `ChipActivation` | `totalChipBurned` |
| Upgrade a tier | `ChipActivation` | `totalChipBurned` |
| Forge, $CHIP portion | `Furnace` | `totalChipBurned` |
| Change a split | `ChipRounds` | `totalChipBurned` |

All four are **delta-verified**: the contract measures the dead address's balance before and
after and reverts `ChipBurnShortfall` if less arrived than was owed, so a token that taxes or
lies about transfers cannot buy anything under-paid.

> The `ChipRounds` split-change fee had **neither a counter nor a delta check** until this
> work, and its burn address was a settable variable with no validation of any kind — a
> documented burn could have been pointed anywhere. It is now the same constant as everywhere
> else, and the lever is gone rather than validated.

### The number to display

```solidity
ChipActivation.effectiveChipSupply()   // totalSupply() - chip.balanceOf(0xdEaD)
ChipActivation.chipBurnedToDead()      // chip.balanceOf(0xdEaD)
```

**`effectiveChipSupply` subtracts the dead address's BALANCE, not our own counters**, and that
is deliberate. Summing the four counters above would miss a fifth contract added later, and
would miss anyone who burned $CHIP by sending it to `0xdead` themselves. The balance misses
nothing.

### Required post-launch, and it will not happen by itself

**File `0x000000000000000000000000000000000000dEaD` with CoinGecko and CoinMarketCap as an
excluded burn address for $CHIP.** Until that lands, both will overstate circulating supply by
exactly `chipBurnedToDead()`, and the overstatement grows with every activation and every
forge. Neither aggregator infers this.

The site should show effective supply, not `totalSupply`, and should say which it is showing.
