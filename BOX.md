# ChipWorks Box

**UNAUDITED. Not deployed. Needs a Bankr + Grok audit and the owner's written OK before mainnet.**

Sealed, giftable ERC-721 gacha boxes on Base. Buy with USDC or `$CHIP` ($1 / $10 / $25). Open with
Pyth Entropy v2 for a **Coinbase B20 stock** prize sized by a published on-chain odds table (USDC
if no stock can cover it). 91% RTP. Prizes are never paid in `$CHIP`: `$CHIP` is a payment option
only. The pool funds itself from sales.

This is the **rebuild** of the first draft (PRs #8/#9). What changed and why is in
[What the rebuild changed](#what-the-rebuild-changed). Contracts: `src/box/`, interfaces in
`src/interfaces/IBox.sol`, `IPrizeVault.sol`, `IChipConverter.sol`.

---

## Contracts

| Contract | Role |
|---|---|
| `Box` | ERC-721. Buy, gift, open, odds table, fee split, Entropy request/callback, owed prizes. |
| `PrizeVault` | The prize pool: USDC + B20 stocks. Pays draws all-or-nothing. Keeper restock. House-take sweep. |
| `ChipConverter` | Receives every `$CHIP` payment whole and, on the keeper's call, sells it for pool USDC. |

Deploy: `PrizeVault` → `ChipConverter` → `Box(vault, converter)` → the Safe calls
`vault.setBox(box)` and `converter.setBox(box)` once each, lists stocks, sets keepers and limits, seeds
the vault. `script/box/DeployBox.s.sol` refuses to run without `BOX_MAINNET_WRITTEN_OK=true` and
has no default `$CHIP` price (the price moves; pass `BOX_CHIP_PER_USD`).

## Money flow

```text
USDC buy  ── 5% ──► fee recipient (FeeSplitter: 80% Pot / 20% ops)
          └─ 95% ─► PrizeVault

$CHIP buy ─ 100% ─► ChipConverter ──keeper sellChip──► USDC ── 5% ──► fee recipient
                                                           └─ 95% ─► PrizeVault

open ──► Pyth Entropy ──► callback ──► PrizeVault.settle (all or nothing)
            paid      ─► a B20 stock from the vault (USDC if no stock can cover it)
            unpayable ─► box becomes OWED at exactly the drawn prize ── claimOwed later

keeper restock: vault USDC ──► B20 stock ──► vault   (Chainlink-bounded, capped)
sweepSurplus:   vault USDC above every floor ──► fee recipient   (permissionless)
```

**House take is 9% of face**: the 5% fee, plus ~4% of expected value that stays in the vault and
leaves through `sweepSurplus` once the floors are met. All of it reaches the fee recipient as
**USDC**, never `$CHIP`. The live Pot's round currency is USDC and it has no `$CHIP` conversion
route (it converts WETH and AERO only), so `$CHIP` sent to FeeSplitter would be stranded in the Pot.

## Odds table (launch, 91.00% RTP)

Weights sum to `10_000`. Prize = `sku.usdcPrice * prizeBps / 10_000`. Every tier pays a stock.

| Tier | Weight | Prob | Prize | $1 | $10 | $25 |
|---|---|---|---|---|---|---|
| Dust | 4,500 | 45% | 0.20× | $0.20 | $2 | $5 |
| Common | 3,000 | 30% | 0.50× | $0.50 | $5 | $12.50 |
| Uncommon | 1,500 | 15% | 1.00× | $1 | $10 | $25 |
| Rare | 700 | 7% | 2.00× | $2 | $20 | $50 |
| Epic | 250 | 2.5% | 8.00× | $8 | $80 | $200 |
| Jackpot | 50 | 0.5% | 36.00× | $36 | $360 | $900 |

A prize is paid in one registered stock at its StockRegistry mark: the walk starts at
`uint256(randomNumber) % stockCount` and takes the first enabled, fresh-priced stock the vault
holds enough of. If none can cover it, USDC.

Draw rule the UI must copy (or call `previewDraw`):

```text
roll = uint256(randomNumber) % 10_000
tier = first tier whose cumulative weight > roll
```

## Honest odds: never paid short

- **Sell gate.** `buy*` reverts `SkuNotCovered` while `vault.prizeCapUsd() < maxPrizeUsd(sku)`.
  The cap is 25% of inventory, so a SKU sells only when the pool holds 4× its jackpot:
  **$144** for $1, **$1,440** for $10, **$3,600** for $25. Launch with $1 only; the others unlock
  by themselves as volume grows. `isSkuCovered(sku)` is the UI's read.
- **All-or-nothing settle.** If a drawn prize still cannot be paid at callback time (the pool
  shrank between buy and open), NOTHING moves and the box becomes **OWED** (`state 3`) at exactly
  the drawn size, counted in full in `outstandingLiabilityUsd`. Anyone may `claimOwed(tokenId)`
  later; it pays the opener in full. It is never paid short and never re-rolled. Owed and opening
  boxes cannot be transferred.
- **Single-prize cap.** One prize can never exceed 25% of the pool (`maxPrizeBps`, ceiling 50%,
  raise timelocked). Back-to-back jackpots take at most 25%, then 25% of the rest: the pool
  cannot be drained by early luck.

## Keeper powers (and their bounds)

The keeper can move value only by swapping, never to itself.

| Call | Where output goes | Bounded by |
|---|---|---|
| `PrizeVault.restock(stock, usdcIn)` | the vault | Chainlink mark from the StockRegistry less `restockSlippageBps` (≤5%); stale mark refused; per-call + per-day caps; USDC must stay ≥ `minUsdcBps` of inventory (≤90%) |
| `ChipConverter.sellChip(chipIn, minUsdcOut)` | 5% fee recipient / 95% vault | **keeper `minUsdcOut`** + owner price floor; per-call + per-day caps; ETH leg Chainlink-bounded |

### ⚠ AUDIT FOCUS: `$CHIP` has no on-chain price

`$CHIP` trades only on a Uniswap v4 pool behind a Doppler hook with no oracle, no cumulatives and
no Chainlink feed. The `$CHIP` → WETH leg of `sellChip` is therefore bounded by a
**keeper-supplied minimum**, not an oracle. A compromised keeper key could sell box `$CHIP` too
cheap. The loss is bounded by the caps and the optional owner price floor
(`minUsdcPerMillionChip`); nothing lets the keeper withdraw, and output goes only to the fee
recipient and the vault. This is the Box's primary trust assumption.

## House take → fee recipient

`PrizeVault.sweepSurplus()` is permissionless and pays only `box.treasury()`. It sends USDC that
clears **all three** floors:

1. USDC ≥ 110% of `outstandingLiabilityUsd` (EV of every unopened box + every owed prize);
2. inventory ≥ `jackpotReserveUsd()` (the pool the largest live jackpot needs; a paused SKU still
   counts while its boxes are out);
3. USDC ≥ `minUsdcBps` of what remains (the USDC fallback and restock draw on it).

A reverting liability or reserve read sweeps nothing. The owner's 48h `queueSurplusWithdraw` (for
winding down) checks the same floors.

## `$CHIP` is never inventory (H-01, redone)

The first draft sent 95% of every `$CHIP` payment to the vault and then refused `$CHIP` on every
exit, so it sat there forever and `$CHIP` boxes were paid for by USDC buyers. Now:

- the vault never takes `$CHIP` in and never pays it out: `addStock`, `deposit` and `settle`
  refuse it; a stray transfer is an ordinary stray and `rescue` can return it;
- box `$CHIP` sits on the converter only until `sellChip`; if the pool route ever breaks, the owner
  can recover it after a 48h timelock (`queueChipRecovery`). `rescue` never takes `$CHIP`.

## Entropy (Pyth v2)

`quoteOpenFee()` then `open{value}(tokenId)`: the exact fee is forwarded, excess refunded (M-08).
The fee is paid in ETH and sits **outside** the 91% RTP. The callback never reverts: it pays, or
marks the box owed, or ignores an orphan sequence. Nothing swaps inside the callback.

**Callback gas, measured on the live node with real B20s** (`tools/box/box-callback-sim.cjs`,
`eth_simulateV1`, 10 stocks listed): **~466k** whether the walk pays the first stock or skips all
nine others, against a **1,000,000** `callbackGasLimit` (~35k more per extra stock, so ~680k at the
16-stock maximum). The first build measured 529k over a 500k limit, which would have left a box
stuck and re-rolled by `retryOpen`; the fix prices each stock once per payout (`_snapshot`) and
raised the limit. Pyth charges 0.000020 ETH at 1M against 0.000015 at 500k. The cost is the pool
valuation (~35k/stock), not the B20 transfer (a B20 `balanceOf` is 2.6k). A buy costs ~640k gas
for the same reason (the sell gate values the pool). `retryOpen` re-requests only if no callback
arrived within `REVEAL_TIMEOUT` (3 days).

Mint terms are snapshotted per box (face, odds version, EV: H-05). A SKU cannot be retired while
boxes are out (H-03). Payment and opens revert until the vault and converter are wired (H-04).

## What the rebuild changed

| Draft | Rebuild |
|---|---|
| 95% of `$CHIP` payments stranded in the vault | 100% to `ChipConverter`, sold for USDC 5/95 |
| Manual restock (owner 48h withdraw, buy off-chain, deposit) | Keeper `restock`, oracle-bounded, into the vault |
| Owner-set price feeds per stock | StockRegistry Chainlink marks (same as ChipRounds) |
| Prize over the cap paid short (`shortfall`) | Sell gate + all-or-nothing settle + owed prizes |
| Settle revert → `SettleFailed`, retry re-rolls | Settle failure → owed at the drawn size, no re-roll |
| 5% fee to the Safe; 4% margin stuck unless owner withdraws | FeeSplitter; permissionless `sweepSurplus` above three floors |

## Tests

```bash
forge test --match-path 'test/box/*'                       # unit: no RPC
forge test --match-contract BoxForkTest -vv                # Base fork: needs BASE_RPC_URL
```

`test/box/BoxRebuild.t.sol` covers the rebuild's properties; `Box.t.sol`, `BoxVault.t.sol` and
`BoxAuditPoC.t.sol` carry the draft's audit PoCs forward. `test/fork/BoxFork.t.sol` is the proof on
live Base: the StockRegistry, the factory-B Slipstream router, the `$CHIP` v4 pool, the WETH/USDC
pool, Chainlink ETH/USD, a real Entropy request, and FeeSplitter → Pot. B20 stocks are node-native
precompiles that cannot run in a fork, so NVDA is etched with a runnable ERC-20 carrying the pool's
real balance, so the fork cannot measure real B20 gas. `tools/box/box-callback-sim.cjs` does:
it deploys all three contracts in an `eth_simulateV1` block on the live node, restocks real NVDA,
buys, opens through real Entropy and delivers both reveals. Re-run it after any change to
`settle`, and whenever stocks are added: `node tools/box/box-callback-sim.cjs`.
