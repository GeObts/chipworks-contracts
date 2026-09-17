# ChipWorks Box

**UNAUDITED. Not deployed. A new product family — not Anvil, not rounds.**

Sealed, giftable ERC-721 boxes on Base. Buy with USDC and/or `$CHIP`. Open for a random Coinbase B20 stock prize, sized by a published on-chain odds table. Pyth Entropy v2 supplies the draw. The Next.js `/box` page must read that table from chain and match it exactly.

This document is the feature brief. Contracts live in `src/box/` and `src/interfaces/IBox.sol`.

---

## What this is not

Anvil's `{buyNext}` is a FIFO shelf of **known** Nouns. Box is a gacha. The two share no storage, no inheritance, and no call path. Do not bolt Box onto Anvil, and do not reuse Anvil events or prices here.

Gifted-stock style vaults (the `0xaBB8…214B` pattern class: sealed NFT, inventory pool, **owner can withdraw the prizes**) were used as negative space only. Prize assets leave this vault through `{settle}` or a 48-hour surplus withdraw that still leaves enough **USDC** to cover outstanding Box EV plus a 10% buffer. Stock mark-to-market is **not** counted toward that floor (feeds are owner-settable). There is no instant privileged drain of USDC, registered B20, or `$CHIP` working capital.

**UNAUDITED.** Highs H-01–H-05 from the Box review are closed in this revision; do not treat that as a completed audit.

---

## Contracts

| Contract | Role |
|---|---|
| `Box` | ERC-721. Buy, gift, open, odds table, fee split, Entropy request/callback. |
| `PrizeVault` | USDC + B20 inventory. Caps a single prize vs holdings. Never pays more than it holds. Honest empty-stock handling. |

Deploy order: `PrizeVault` → `Box(vault)` → `PrizeVault.setBox(box)` once. Same shape as `ChipClaims.setRounds`.

Constructor args filled at deploy, not in bytecode:

- `$CHIP` token — **deploy default is the live Base token** `0x75Af968d2e58749FDA1b42C58186B76f5E511bA3` (`Box.DEFAULT_CHIP`). Pass `address(0)` only to disable `{buyWithChip}`. USDC and `$CHIP` are both live payment assets.
- 5% fee recipient (`treasury` / `feeRecipient`) — **default is Goyabean's Safe** `0xe1096B727499a3f70FaD8bc0267F5e69d01373C7` (`Box.DEFAULT_FEE_RECIPIENT`). Constructor still takes the address so a deploy can override; a live change is 48h-timelocked with a 14-day grace window.

`PrizeVault` takes the same `$CHIP` address. `{Box}` construction reverts unless `vault.chip == Box.chip` (and matching USDC). `{buy*}` revert unless `vault.box == this`. `{rescue}`, `{addStock}` and surplus withdraw all refuse CHIP — it is payment working capital, never prize inventory (H-01). `{settle}` will not pay CHIP. The live Base CHIP address is protected even if the constructor was passed `address(0)`.

USDC on Base is `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (`Box.DEFAULT_USDC`, 6 dp). Pyth Entropy v2 on Base is `0x6E7D74FA7d5c90FEF9F0512987605a6d546181Bb`.

Launch SKUs (all `exists = true`): **$1** (id 0), **$10** (id 1), **$25** (id 2). There is no $5 SKU.

---

## Odds table (launch, 91.00% RTP)

Weights sum to `10_000`. Prize is `sku.usdcPrice * prizeBps / 10_000`, so the same table serves $1, $10, and $25.

| Tier | Weight | Prob | Prize (× face) | $1 box | $10 box | $25 box | EV contribution ($1) |
|---|---|---|---|---|---|---|---|
| Dust | 4,500 | 45.00% | 0.20× | $0.20 | $2.00 | $5.00 | 9.00¢ |
| Common | 3,000 | 30.00% | 0.50× | $0.50 | $5.00 | $12.50 | 15.00¢ |
| Uncommon | 1,500 | 15.00% | 1.00× | $1.00 | $10.00 | $25.00 | 15.00¢ |
| Rare | 700 | 7.00% | 2.00× | $2.00 | $20.00 | $50.00 | 14.00¢ |
| Epic | 250 | 2.50% | 8.00× | $8.00 | $80.00 | $200.00 | 20.00¢ |
| Jackpot | 50 | 0.50% | 36.00× | $36.00 | $360.00 | $900.00 | 18.00¢ |
| **Total** | **10,000** | **100%** | | | | | **$0.9100 (91.00%)** |

`Box.rtpBps()` returns `9100`. Changing the table is timelocked. SKU ids: `$1=0`, `$10=1`, `$25=2`.

### Draw rule the UI must copy

```text
roll     = uint256(randomNumber) % 10_000
tier     = first oddsTable[i] whose cumulative weight > roll
prizeUsd = sku.usdcPrice * tier.prizeBps / 10_000
```

Call `previewDraw(randomNumber, skuId)` rather than reimplementing it. `test_everyRollMapsToATier` locks the 10,000-entry histogram to the weights above. A sealed box pays the **mint** face and odds version, not a later `{executeSku}` / `{executeOdds}` (H-05).

---

## Audit Highs (this revision)

| ID | Issue | Fix |
|---|---|---|
| H-04 | `open` with `vault.box` unset → Entropy callback `settle` reverts → silent burn | `open`/`retryOpen` revert unless `vault.box()==this`. Failed settle emits `SettleFailed`, does not burn. |
| H-03 | `outstandingLiabilityUsd` revert (retired SKU) zeroed the surplus floor | Surplus fail-closes on a failed liability call. `executeSku` cannot set `exists=false` while `sealedSupply>0`. Liability is the mint-EV running total. |
| H-02 | Fake/owner-set stock feed inflated `inventoryUsd`, surplus drained USDC | Surplus leftover floor is **USDC only**. |
| H-01 | `rescue(CHIP)` / `addStock(CHIP)` / surplus / settle / unwired-buy drained working capital | **CLOSED.** `Box` constructor requires `vault.chip == Box.chip` (and matching USDC). `{buy*}` revert unless `vault.box == this`, so CHIP cannot land in an unwired vault. `{rescue}`, `{addStock}`, surplus withdraw, and `{settle}` all refuse CHIP (constructor chip, `{Box.chip}` after wire, and `{DEFAULT_CHIP}`). |
| H-05 | Live SKU/odds rewrote sealed tickets (`$1` paid `$25`-tier) | Each box snapshots `faceUsd`, `oddsVersion`, `mintEvUsd` at mint. Launch table stays 6-tier. |
| M-08 | Entropy fee | `{open}` forwards `getFeeV2` exactly and refunds excess (unit test + optional Base fork). |

---

## Fee flow

Every buy, same transaction, same token (USDC or `$CHIP`):

```text
user ──100%──► Box ──5%──► feeRecipient / treasury (Goyabean's Safe by default)
                   └──95%──► PrizeVault
```

Default recipient: `0xe1096B727499a3f70FaD8bc0267F5e69d01373C7` (`Box.DEFAULT_FEE_RECIPIENT`). `FEE_BPS = 500`. Rounding dust (`price - fee`) stays with the vault, not the treasury. Box holds no ERC-20 between calls. Override at construct with a different `treasury_`, or later via `{queueTreasury}` / `{executeTreasury}`.

`$CHIP` in the vault is **working capital** to acquire B20 off-cycle. It is not priced into `{inventoryUsd}` and is not a prize asset. `{rescue(CHIP)}`, `{addStock(CHIP)}`, and surplus withdraw of CHIP all revert (H-01). A CHIP-funded vault with no B20/USDC will pay a shortfall (see below) rather than pretend.

---

## Entropy (Pyth v2)

1. UI calls `quoteOpenFee()` → `entropy.getFeeV2(callbackGasLimit)`.
2. Owner of a **sealed** box calls `open{value: fee}(tokenId)`. Excess ETH is refunded; Entropy does not refund. `{buy*}` / `{open}` / `{retryOpen}` revert unless `PrizeVault.box() == address(Box)` (H-04 / H-01: payment cannot hit an unwired vault).
3. Box stores the sequence, locks the NFT (not transferable, still owned).
4. Entropy later calls `entropyCallback(sequence, provider, randomNumber)` — the Pyth v2 consumer selector (`_entropyCallback` is an alias).
5. Callback **must not revert**. A failing vault settle emits `{SettleFailed}` and **does not burn** the NFT (ownerOf unchanged). An honest shortfall (empty inventory) is still a successful settle call and burns as before.
6. If the callback never arrives — or settle failed — the opener may `retryOpen` after `REVEAL_TIMEOUT` (3 days), paying a new fee. A late original callback is ignored (`OrphanCallback`) unless the box is still `OPENING` on that sequence (failed settle leaves it opening so a late retry of the same callback can still pay).

Default `callbackGasLimit` is 500,000 (stock loop + transfers). Owner can retune it; that only changes the fee, not RTP.

---

## Vault rules

- Never transfer more of a token than `balanceOf(this)`.
- Single prize capped at `maxPrizeBps` of live USD inventory (launch 2,500 = 25%; ceiling 50%). Lowering the cap is immediate; raising it is timelocked.
- Stock pick: `uint256(entropy) % n`, then walk the list. Empty, thin, disabled, dead-feed, or reverting-transfer stocks are skipped (`StockSkipped`) and the next one is tried.
- If no B20 can fill the (capped) prize, pay USDC. Never pay `$CHIP`.
- If USDC cannot fill it either, pay what is there and set `shortfall`. The open still completes.
- B20 tokens are identified **by address**, never by ticker. Feeds may hold last close over the weekend; a bad feed skips that stock instead of bricking the callback.
- `{open}` uses the **mint snapshot** of face USDC and odds version (H-05). `{executeSku}` / `{executeOdds}` cannot rewrite a sealed ticket. `{executeSku}` cannot set `exists = false` while `sealedSupply[id] > 0` (H-03).

Surplus withdraw of USDC / registered B20: 48h queue, then leftover **USDC** (not stock MTM) must still cover `{Box.outstandingLiabilityUsd} * 110%`. A reverting liability query fails closed (H-03). `$CHIP` is working capital: `{rescue(CHIP)}`, `{addStock(CHIP)}`, and surplus withdraw of CHIP revert (H-01). Stray tokens (not USDC, not CHIP, not a registered prize stock) can be rescued immediately.

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
- `feeRecipient()` / `treasury()` — 5% recipient; default Goyabean's Safe
- `PrizeVault.inventoryUsd()`, `prizeCapUsd()`, `quoteTokenAmount(token, prizeUsd)`

Metadata: `setBaseURI` + `tokenURI = baseURI + tokenId`. Index `Transfer` events for a wallet's boxes; the collection is not enumerable.

---

## How to test locally

```bash
forge test --match-path 'test/box/*' -vv
```

No RPC required. The suite covers odds math (including the 10,000-roll histogram), 5/95 fee split on both USDC and CHIP for **$1 / $10 / $25**, Entropy fee pass-through and callback mock, gift/lock, vault cap, empty/thin/blacklisted stock, USDC fallback, CHIP-buy shortfall, surplus-withdraw accounting, and PoCs for H-01–H-05 / M-08 (`test/box/BoxAuditPoC.t.sol`) including addStock/surplus CHIP drains.

An optional Base-fork assertion for M-08 (`test_M08_OpenForwardsExactEntropyFee_RefundsExcess_BaseFork`) runs only when `BASE_RPC_URL` is set; it never broadcasts.

Dry-run the isolated Box deploy script (does **not** touch Anvil / rounds; does not broadcast unless you pass `--broadcast`):

```bash
MULTISIG=0x... forge script script/box/DeployBox.s.sol:DeployBox --rpc-url $BASE_RPC_URL -vvv
```

`BOX_TREASURY` overrides the 5% recipient; otherwise it is `Box.DEFAULT_FEE_RECIPIENT`. After a real broadcast the Safe must call `PrizeVault.setBox(box)` once.

Do not mainnet-deploy from this PR.
