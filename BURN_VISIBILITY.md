# BURN_VISIBILITY.md — what actually gets destroyed, and what only looks it

Two things Chipworks destroys — a collection it does not own, and a token it now does — and
they are destroyed by different mechanisms. This file is the reference for the site, for the
explorers, and for anyone reasoning about circulating supply.

**Both are real burns as of the ChipBurner.** The $CHIP half of this file used to say otherwise;
the section below keeps that reasoning rather than overwriting it, because the way it was wrong
is the useful part.

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

## $CHIP — a REAL burn, through the ChipBurner

**This section used to say the opposite, and the reasoning it used to carry is worth keeping.**
It said $CHIP burns could never be real because Bankr's Doppler token exposes no `burn`, so
every burn was a transfer to `0xdead`: unreachable, but still inside `totalSupply`. The premise
was half right. The token has no *public* `burn` — it has an **owner-gated** one, and ownership
lands with us at launch. A contract we own can call it.

That contract is **`ChipBurner`** (`src/ChipBurner.sol`), and it is the token's owner. Every app
burn path sends $CHIP there; `burnAll()` destroys the balance and **`totalSupply` falls**.

```
app burn path ──transferFrom──> ChipBurner ──burn()──> gone, totalSupply falls
```

### The two addresses, which are NOT interchangeable

This is the one thing to get right when reading the contracts:

| | Goes to | Why |
|---|---|---|
| **$CHIP** | `chipBurnTarget` — the `ChipBurner` | It owns the token and can genuinely destroy it |
| **NFTs** | `BURN_ADDRESS` — `0x…dEaD` | Only when the collection exposes no `burn` of its own |

**An NFT sent to the Burner would be stranded forever.** It has no ERC-721 surface at all — no
`onERC721Received`, no rescue, and no owner able to move it. So `BURN_ADDRESS` stays `0xdead` on
all three contracts and `chipBurnTarget` is a **separate immutable field**. A single "burn
address" for both would have been the obvious simplification and it would have quietly destroyed
NFTs in a way nobody could undo. `test/BurnRouting.t.sol` is what keeps them apart.

**`chipBurnTarget` is immutable, on purpose.** It was briefly a settable address on `ChipRounds`
with no validation at all, which meant a documented burn could have been pointed anywhere and
quietly become revenue. It is now set once, at deploy, with a zero-check, and there is no setter
on any of the three contracts — asserted by `test_theBurnTargetCannotBeChanged`.

### Every burn path, and its counter

| Path | Contract | Counter |
|---|---|---|
| Activate a Noun | `ChipActivation` | `totalChipBurned` |
| Activate a flat-rate token (Chiplets) | `ChipActivation` | `totalChipBurned` |
| Upgrade a tier | `ChipActivation` | `totalChipBurned` |
| Forge, $CHIP portion | `Furnace` | `totalChipBurned` |
| Change a split | `ChipRounds` | `totalChipBurned` |

All five are **delta-verified**: the contract measures the burn target's balance before and
after and reverts `ChipBurnShortfall` if less arrived than was owed, so a token that taxes or
lies about transfers cannot buy anything under-paid.

All five moved to the Burner **together**, in one change. Routing one path through it and
leaving the others at `0xdead` would have split the accounting and made `chipBurnedToDead()`
silently incomplete — worse than the honest limitation it replaced.

> The `ChipRounds` split-change fee had **neither a counter nor a delta check** until burn
> visibility was wired up, and its burn address was a settable variable with no validation of
> any kind. It now takes the same immutable target as everywhere else, and the lever is gone
> rather than validated.

### Burning is permissionless, and verified by supply

`burnAll()` may be called by **anyone**. It destroys the Burner's whole balance, there is no
argument to get wrong, and no way to direct the outcome.

It reads `totalSupply` **before and after** and reverts unless it actually fell. That is what
makes `ChipBurner.totalBurned` a number the site can publish: it counts what left existence, not
what was asked to leave. A token that silently no-ops its own burn cannot quietly turn the
Burner into the `0xdead` address with extra steps.

**$CHIP that arrives at the Burner is already gone**, whether or not anyone has called
`burnAll()` yet. There is no `transfer`, no sweep, no rescue and no generic `call` — the only
instruction the contract can give about its own balance is "destroy it". Not even the multisig
can move it.

### The number to display

```solidity
ChipActivation.effectiveChipSupply()   // totalSupply() - everything burned
ChipActivation.chipBurnedToDead()      // balanceOf(0xdEaD) + balanceOf(chipBurnTarget)
```

**These stay correct across the burn**, which is the subtle part. $CHIP queued at the Burner but
not yet destroyed is counted as already out of circulation — it can only ever be destroyed — and
once `burnAll()` runs it leaves `totalSupply` as well, so the figure does not jump or
double-count. Pinned by `test_effectiveSupplyIsRightBeforeAndAfterTheBurn`.

**`chipBurnedToDead` still adds the dead address's BALANCE**, and that is deliberate. Summing
the five counters above would miss a sixth contract added later, and would miss anyone who
burned $CHIP by sending it to `0xdead` themselves. It also still counts the historical
`0xdead` holdings, which is why both terms are in the sum and why the name is unchanged.

### The aggregator filing is no longer required

**This used to be a mandatory post-launch step** — file `0xdead` with CoinGecko and CMC as an
excluded burn address, or both would overstate circulating supply forever. With real burns,
`totalSupply` falls on its own and every aggregator picks it up with no filing at all.

It is worth doing anyway **only** if $CHIP was burned to `0xdead` before the ownership hand-off
landed — see LAUNCH_CONFIG §6.6, where `burnAll()` reverts until `chip.owner()` is the Burner.
Anything sent to the app's burn paths in that window accumulates at the Burner and is destroyed
on the first successful call, so the window costs nothing; only $CHIP sent directly to `0xdead`
by a holder stays counted. Check `chipBurnedToDead()` against
`chip.balanceOf(chipBurnTarget)` after launch: if the difference is zero, there is nothing to
file.

The site should show effective supply, not `totalSupply`, and should say which it is showing.
