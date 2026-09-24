# Box audit, round 1: triage

Round 1 reviewed commit `740fc37` (package source `c98ee57`). **Bankr** returned no findings on
Q1–Q15. **Grok** returned 3 High, 4 Medium, 4 Low, and 2 more (F-1, F-2) from a deeper pass.

**Every finding was reproduced as a test of the SAFE property before anything changed**
(`test/box/BoxAuditRound1.t.sol`): a test that failed on the audited code confirmed the finding,
one that passed refuted it. Fixes were then made and the same tests re-run green.

## Receipts

Both reviewers' SHA-256s matched the package for every file. Bankr's line counts are uniformly +1
(a counting convention: the trailing newline); Grok's match exactly.

## Dispositions

| ID | Sev (theirs) | Verdict | What happened |
|---|---|---|---|
| **H-1** | High | **Confirmed, and worse than reported.** Fixed. | Beyond the deferred funding Grok described, a SKU's `$CHIP` price was a fixed number with a 48h timelock. With `$CHIP` halved, a "$10" box funded the pool **$4.75** against $9.10 of liability, an arbitrage open to anyone. **Fix: swap `$CHIP` to the exact USDC price inside the buy** (`buyWithChip(sku, to, wethNeeded, maxChipIn, deadline)`, the deployed ChipLottery's exact-output route). The same test now shows the buyer paying twice the `$CHIP` and the pool getting its full $9.50. |
| **H-2** | High | **Confirmed.** Fixed by construction. | The owner's 48h `$CHIP` recovery could take unsold box `$CHIP` while its boxes were outstanding. The converter now holds nothing between calls, and the recovery path is removed. |
| **H-3** | High | **Refuted.** | A stale-marked stock is excluded from inventory both before and after an owner withdrawal, so withdrawing it cannot take the pool below any floor. Test: after the withdrawal, USDC ≥ 110% of liability, inventory ≥ the jackpot reserve, every SKU still covered. |
| **M-1** | Medium | **Accepted as design.** | `restock` swaps USDC for stock at the Chainlink mark (≤2% slippage), so pool value is preserved, and it keeps the `minUsdcBps` USDC share. The 110%-in-USDC floor governs value **leaving** the pool (sweep, withdraw), not reallocation inside it. More stock means more ways to pay, not fewer. |
| **M-2** | Medium | **Refuted as a defect.** | True that raising `maxPrizeBps` lowers the reserve, by design: the reserve is the pool size at which the largest prize is payable under the current cap. Test: a pool at exactly the reserve pays the top prize in full at 25% and at 50%. Raising the cap is 48h-timelocked. |
| **M-3** | Medium | **Closed by the H-1 fix.** | There is no keeper `$CHIP` sale any more. |
| **M-4** | Medium | **Accepted.** | Prize stocks come only from the curated StockRegistry (Coinbase B20s, not fee-on-transfer). Adding recipient balance checks inside the gas-bounded callback costs gas for a token class the registry cannot list. |
| **L-1** | Low | **Moot.** | The converter now holds nothing between calls, so `rescue` reaching USDC/WETH reaches only strays (the ChipLottery reasoning). |
| **L-2** | Low | **Accepted; fixed.** | The vault's self-call guard now reverts `OnlySelf`, not `OnlyBox`. |
| **L-3** | Low | **Accepted as-is.** | A contract that rejects ETH can send the exact fee (`quoteOpenFee()`); there is then no refund. |
| **L-4** | Low | **Accepted as-is.** | `sealedSupply` counts sealed, opening and owed boxes: the conservative count the retire guard needs. Documented. |
| **F-1** | Medium | **Closed by the H-1 fix.** | Immediate owner `setPriceFloor` / `setLimits` / `setKeeper` on the converter no longer exist. |
| **F-2** | Medium | **Confirmed.** Fixed. | Pyth numbers requests **per provider**, but the Box keyed them by sequence alone. After a default-provider change, a reveal paid the wrong box (test: box A's reveal paid box B, and A was stranded). Requests are now keyed by `(provider, sequence)` and `_fulfill` checks the provider. |

## On the reviews themselves

- **Bankr's Q7 reasoning is wrong, though the conclusion holds.** It says "no external calls exist
  in the callback execution path". There are: registry price reads, B20 balance reads and the prize
  transfer. They are bounded by the 16-stock cap and measured on the live node (~466k–573k gas
  against a 1,000,000 limit).
- **Grok's H-1 understated the problem.** It framed the risk as delayed funding and keeper
  discretion. The fixed-`$CHIP`-price arbitrage, open to any buyer, is the real exposure, and it is
  what the fix targets.
