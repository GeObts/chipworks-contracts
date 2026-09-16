# ChipWorks Box

**UNAUDITED. Not deployed. A new product family — not Anvil, not rounds.**

Sealed, giftable ERC-721 boxes on Base. Buy with USDC and/or `$CHIP`. Open for a random Coinbase B20 stock prize, sized by a published on-chain odds table. Pyth Entropy v2 supplies the draw. The Next.js `/box` page must read that table from chain and match it exactly.

This document is the feature brief. Contracts live in `src/box/` and `src/interfaces/IBox.sol`.

---

## What this is not

Anvil's `{buyNext}` is a FIFO shelf of **known** Nouns. Box is a gacha. The two share no storage, no inheritance, and no call path. Do not bolt Box onto Anvil, and do not reuse Anvil events or prices here.

Gifted-stock style vaults (the `0xaBB8…214B` pattern class: sealed NFT, inventory pool, **owner can withdraw the prizes**) were used as negative space only. Prize assets leave this vault through `{settle}` or a 48-hour surplus withdraw that still leaves enough USD-equivalent inventory to cover outstanding Box EV plus a 10% buffer. There is no instant privileged drain.

---

## Contracts

| Contract | Role |
|---|---|
| `Box` | ERC-721. Buy, gift, open, odds table, fee split, Entropy request/callback. |
| `PrizeVault` | USDC + B20 inventory. Caps a single prize vs holdings. Never pays more than it holds. Honest empty-stock handling. |

Deploy order: `PrizeVault` → `Box(vault)` → `PrizeVault.setBox(box)` once. Same shape as `ChipClaims.setRounds`.

Constructor TODOs, filled at deploy, not in bytecode:

- `$CHIP` token — pass the live address, or `address(0)` to disable `{buyWithChip}` until a new deployment.
- Treasury / Safe — 5% recipient. A placeholder is fine in tests; retarget is 48h-timelocked with a 14-day grace window (same as Anvil).

USDC on Base is `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (6 dp). Pyth Entropy v2 on Base is `0x6E7D74FA7d5c90FEF9F0512987605a6d546181Bb`.

---

## Odds table (launch, 91.00% RTP)

Weights sum to `10_000`. Prize is `sku.usdcPrice * prizeBps / 10_000`, so the same table serves $1, $5, and later $10 / $25.

| Tier | Weight | Prob | Prize (× face) | $1 box | $5 box | EV contribution |
|---|---|---|---|---|---|---|
| Dust | 4,500 | 45.00% | 0.20× | $0.20 | $1.00 | 9.00¢ |
| Common | 3,000 | 30.00% | 0.50× | $0.50 | $2.50 | 15.00¢ |
| Uncommon | 1,500 | 15.00% | 1.00× | $1.00 | $5.00 | 15.00¢ |
| Rare | 700 | 7.00% | 2.00× | $2.00 | $10.00 | 14.00¢ |
| Epic | 250 | 2.50% | 8.00× | $8.00 | $40.00 | 20.00¢ |
| Jackpot | 50 | 0.50% | 36.00× | $36.00 | $180.00 | 18.00¢ |
| **Total** | **10,000** | **100%** | | | | **$0.9100 (91.00%)** |

`Box.rtpBps()` returns `9100`. Changing the table is timelocked. $10 / $25 SKUs are ids `2` and `3`, `exists = false` until `{queueSku}`.

### Draw rule the UI must copy

```text
roll     = uint256(randomNumber) % 10_000
tier     = first oddsTable[i] whose cumulative weight > roll
prizeUsd = sku.usdcPrice * tier.prizeBps / 10_000
```

Call `previewDraw(randomNumber, skuId)` rather than reimplementing it. `test_everyRollMapsToATier` locks the 10,000-entry histogram to the weights above.

---

## Fee flow

Every buy, same transaction, same token (USDC or `$CHIP`):

```text
user ──100%──► Box ──5%──► treasury (Safe)
                   └──95%──► PrizeVault
```

`FEE_BPS = 500`. Rounding dust (`price - fee`) stays with the vault, not the treasury. Box holds no ERC-20 between calls.

`$CHIP` in the vault is **working capital** to acquire B20 off-cycle. It is not priced into `{inventoryUsd}` and is not a prize asset. A CHIP-funded vault with no B20/USDC will pay a shortfall (see below) rather than pretend.

---

## Entropy (Pyth v2)

1. UI calls `quoteOpenFee()` → `entropy.getFeeV2(callbackGasLimit)`.
2. Owner of a **sealed** box calls `open{value: fee}(tokenId)`. Excess ETH is refunded; Entropy does not refund.
3. Box stores the sequence, locks the NFT (not transferable, still owned).
4. Entropy later calls `_entropyCallback(sequence, provider, randomNumber)` — ABI-compatible with `IEntropyConsumer`.
5. Callback **must not revert**. A failing vault settle is recorded as shortfall; the box is still burned.
6. If the callback never arrives, the opener may `retryOpen` after `REVEAL_TIMEOUT` (3 days), paying a new fee. A late original callback is ignored (`OrphanCallback`).

Default `callbackGasLimit` is 500,000 (stock loop + transfers). Owner can retune it; that only changes the fee, not RTP.

---

## Vault rules

- Never transfer more of a token than `balanceOf(this)`.
- Single prize capped at `maxPrizeBps` of live USD inventory (launch 2,500 = 25%; ceiling 50%). Lowering the cap is immediate; raising it is timelocked.
- Stock pick: `uint256(entropy) % n`, then walk the list. Empty, thin, disabled, dead-feed, or reverting-transfer stocks are skipped (`StockSkipped`) and the next one is tried.
- If no B20 can fill the (capped) prize, pay USDC.
- If USDC cannot fill it either, pay what is there and set `shortfall`. The open still completes.
- B20 tokens are identified **by address**, never by ticker. Feeds may hold last close over the weekend; a bad feed skips that stock instead of bricking the callback.

Surplus withdraw of USDC / registered B20: 48h queue, then leftover `{inventoryUsd}` must still cover `{Box.outstandingLiabilityUsd} * 110%`. Stray tokens (not USDC, not a registered prize stock) can be rescued immediately.

---

## Events (Basescan)

- `BoxPurchased(buyer, to, tokenId, skuId, paymentToken, price, fee, toVault)`
- `BoxOpeningRequested(opener, tokenId, sequence, skuId, entropyFee)`
- `BoxOpened(opener, tokenId, sequence, skuId, tierId, prizeBps, prizeUsd, stock, stockAmount, usdcAmount, paidUsd, capped, shortfall, emptyStockFallback)`
- `PrizePaid` / `StockSkipped` on the vault

---

## Frontend surface

`IBox` is the `/box` page ABI. Minimum calls:

- `buyWithUsdc(skuId, to)` / `buyWithChip(skuId, to)` (and the batch variants)
- `quoteOpenFee()` then `open{value}(tokenId)`
- `oddsTable()`, `rtpBps()`, `sku(id)`, `previewDraw`, `boxInfo`, `sealedSupply`
- `PrizeVault.inventoryUsd()`, `prizeCapUsd()`, `quoteTokenAmount(token, prizeUsd)`

Metadata: `setBaseURI` + `tokenURI = baseURI + tokenId`. Index `Transfer` events for a wallet's boxes; the collection is not enumerable.

---

## How to test locally

```bash
forge test --match-path 'test/box/*' -vv
forge test --match-contract BoxTest --match-contract BoxVaultTest
forge test --match-contract CodeSizeTest --match-test test_everyDeployableContractIsWithinBudget
```

No RPC required. The suite covers odds math (including the 10,000-roll histogram), 5/95 fee split on both USDC and CHIP, Entropy fee pass-through and callback mock, gift/lock, vault cap, empty/thin/blacklisted stock, USDC fallback, CHIP-buy shortfall, and surplus-withdraw accounting.

Do not mainnet-deploy from this PR.
