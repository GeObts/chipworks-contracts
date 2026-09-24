# Box security audit — Box, PrizeVault, ChipConverter

Read-only review. No production contract was modified.

| | |
|---|---|
| Repo | `GeObts/chipworks-contracts` |
| Commit | `740fc3760dd3659b0e9f0d7b94a640b4650edd9e` |
| Scope | `src/box/Box.sol`, `src/box/PrizeVault.sol`, `src/box/ChipConverter.sol`, and the `src/interfaces/` files they import |
| Brief followed | `audit/box-2026-09-23/AUDIT_BRIEF.md` (the box brief). The repo-root `AUDIT_BRIEF.md` / `REVIEW_PACKAGE.md` describe the older rounds/claims system and were not used as the attack list. |
| Chain assumptions | Base mainnet USDC (6 decimals), WETH (18), Chainlink ETH/USD, Pyth Entropy v2, Uniswap v4 PoolManager. Not deployed. |
| Gate | **CLEAR-FOR-FUNDED-TESTNET. Not mainnet.** |

---

## A. Receipt

Hashes are SHA-256 of the raw file bytes (UTF-8, LF, trailing newline included). Line count is the number of newline-terminated lines (the last source line in each file). Commit for every row is `740fc3760dd3659b0e9f0d7b94a640b4650edd9e`.

| path | bytes | lines | sha256 | first 80 chars | last 80 chars |
|---|---:|---:|---|---|---|
| `src/box/Box.sol` | 39712 | 890 | `671fbd315d220b6df8b23f4337c8e27c4d23736fda0b27c7f0a7793493997567` | `// SPDX-License-Identifier: MIT\npragma solidity ^0.8.24;\n\nimport {Ownable} from ` | ` expiresAt) revert TimelockExpired(uint64(block.timestamp), expiresAt);\n    }\n}\n` |
| `src/box/PrizeVault.sol` | 32035 | 706 | `acb0b4e2fedc2de6715719e1c8f3b183ccc4e0729e0d5a5f962cbb811b23a067` | `// SPDX-License-Identifier: MIT\npragma solidity ^0.8.24;\n\nimport {Ownable} from ` | ` expiresAt) revert TimelockExpired(uint64(block.timestamp), expiresAt);\n    }\n}\n` |
| `src/box/ChipConverter.sol` | 16599 | 362 | `269b6e04e437183e90ad788d3039e76089dd9b628c5098fd557a5f3f07f45911` | `// SPDX-License-Identifier: MIT\npragma solidity ^0.8.24;\n\nimport {Ownable} from ` | `e(weth, address(this), uint256(uint128(wethDelta)));\n        return "";\n    }\n}\n` |
| `src/interfaces/IBox.sol` | 4164 | 82 | `c92229fbd4aea1b876492bd5042e11e1f0d6ae03662f9b9b062972639fa40b30` | `// SPDX-License-Identifier: MIT\npragma solidity ^0.8.24;\n\n/// @title IBox\n/// @n` | ` tokenId) external payable;\n    function claimOwed(uint256 tokenId) external;\n}\n` |
| `src/interfaces/IPrizeVault.sol` | 1436 | 33 | `99c6b766fabfd31294d80c26588894a4de8220a71f189a6fec5514f616a14638` | `// SPDX-License-Identifier: MIT\npragma solidity ^0.8.24;\n\n/// @title IPrizeVault` | `ess to, uint256 prizeUsd, bytes32 entropy) external returns (Payout memory);\n}\n` |
| `src/interfaces/IChipConverter.sol` | 538 | 12 | `083fdd7ca1e421d823c4c7a91b7b1fc321f84708fc84e1c9c864c4c3facd828f` | `// SPDX-License-Identifier: MIT\npragma solidity ^0.8.24;\n\n/// @title IChipConver` | `l view returns (address);\n    function box() external view returns (address);\n}\n` |
| `src/interfaces/IEntropyV2.sol` | 1889 | 45 | `6a61847358772c396240380de1845e2a7c2b44994df1317b408e576eb25a3e23` | `// SPDX-License-Identifier: MIT\npragma solidity ^0.8.24;\n\n/// @title IEntropyV2\n` | `    external\n        payable\n        returns (uint64 assignedSequenceNumber);\n}\n` |
| `src/interfaces/IUniswapV4.sol` | 3673 | 85 | `f03af6e50dceff1b2028a43ba88d71f14223084927752cb9e1ab87c929bb2849` | `// SPDX-License-Identifier: MIT\npragma solidity ^0.8.24;\n\n/**\n * Minimal Uniswap` | `utSingleParams calldata params) external payable returns (uint256 amountIn);\n}\n` |
| `src/interfaces/IStockRegistry.sol` | 2220 | 47 | `9c2d0a8c6b8b519d3c2378a3895f6aa7275351a86d20e41bab93f71907c4b804` | `// SPDX-License-Identifier: MIT\npragma solidity ^0.8.24;\n\n/// @notice Which AMM ` | `\n    function clearsMinLiquidity(address token) external view returns (bool);\n}\n` |
| `src/interfaces/ISwapRouters.sol` | 1084 | 34 | `a64912c36e4c12fa01ccd7c9d3f26c5fe08e787a264fa72edd9b9732ba535aeb` | `// SPDX-License-Identifier: MIT\npragma solidity ^0.8.24;\n\n/// @notice Uniswap v3` | `utSingleParams calldata params) external payable returns (uint256 amountOut);\n}\n` |
| `src/interfaces/IAggregatorV3.sol` | 671 | 15 | `d5c01ffff91b207babead0500c3406b0aed14faa56224182636c07388ad2f15d` | `// SPDX-License-Identifier: MIT\npragma solidity ^0.8.24;\n\n/// @notice Chainlink ` | `int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);\n}\n` |

`IWETH.sol` is not imported by the three contracts and is not in this receipt. Every file above ends with a newline and was read through that newline. Nothing was truncated.

---

## B. Answers

### 1. ChipConverter keeper / sell / unlock / caps / floor

**Q1. Can value leave the fee recipient and the vault, or can a sell move more $CHIP than the caps?**

No, not by the keeper or by any other caller, while `box` is the real `Box` and the PoolManager, v3 router, $CHIP, and WETH are the real Base contracts.

- `sellChip` is `onlyKeeper` and `nonReentrant` (`ChipConverter.sol` 215–218). USDC proceeds are the balance delta, then `FEE_BPS` (constant 500 on `Box`) goes to `IBox(box).treasury()` and the rest to `IBox(box).vault()` (241–251). There is no destination argument.
- The per-call cap is `chipIn > maxChipPerSell` and the daily cap is `chipSoldOnDay[day] + chipIn` with `day = block.timestamp / 1 days` (223–227). Both are charged before the swap and roll back if the swap reverts. A UTC boundary starts a new counter; that is the cap, not a way through it.
- A partial fill spends `chipSpent <= chipIn` (`owed > chipIn` reverts at 354). The daily counter still charges the full `chipIn`. That over-counts, so it cannot be used to sell more than the cap. Re-entering `sellChip` from the v4 hook is blocked by the reentrancy guard, and `unlockCallback` rejects any caller other than `poolManager` (331).
- `rescue` cannot take $CHIP (290). It can take donated USDC or WETH that `sellChip` did not produce. A successful `sellChip` forwards the whole USDC delta (`fee + (usdcOut - fee) == usdcOut`) and consumes the whole WETH delta via exact-input, so box proceeds do not sit on the converter between calls.
- The owner can still move the economic value of unsold $CHIP. See finding F-1. That is an owner action, not a keeper bypass. `queueChipRecovery` (261–277) sends the tokens themselves anywhere after 48 hours; that path is the documented recovery.

**Q2. Who can call `unlockCallback`, and is the settle complete for both currency orders?**

Only `poolManager`. `PoolManager.unlock` callbacks the locker, so a third party calling `unlock` is called back on their own contract, not on the converter.

`chipIsCurrency0` is fixed in the constructor and the pool key must be exactly `$CHIP`/`WETH` in either order (159–165). `zeroForOne` follows that bit (335). The price limits are `TickMath` min+1 and max−1 (52–53, 343), so they are curve-end guards, not a slippage bound. `amountSpecified` is negative (`-int256(chipIn)`), which is exact input. The returned `int256` is split into the two `int128` legs the same way `test/fork/V4SignConvention.t.sol` does against the live pool (347–350). A non-negative $CHIP delta or a non-positive WETH delta reverts.

Settlement is `sync(chip)` → `transfer(owed)` → `settle()` → `take(weth, address(this), wethDelta)` (356–359). The converter syncs after `swap` returns, so a hook `sync` during the swap does not stick. Under-delivery (fee-on-transfer) leaves the v4 delta unsettled and `unlock` reverts. Standard $CHIP is not fee-on-transfer. Hook fees taken from the WETH output reduce `wethDelta` and are then checked by `minUsdcOut` and the floor. If a hook made the $CHIP debt larger than `chipIn`, the function reverts `NothingSwapped` rather than paying it.

**Q3. Can the owner floor be bypassed?**

Not by the keeper, while `minUsdcPerMillionChip != 0`.

`px = usdcOut * 1e24 / chipSpent` (244) is USDC (6 dp) per 1,000,000 whole $CHIP. Division rounds down, so `px >= floor` implies the true ratio is at least the floor. Overflow reverts on 0.8. The check uses measured `chipSpent` and measured `usdcOut`, so a partial fill is judged on the fill, not on the keeper's `minUsdcOut`. `minUsdcOut` cannot undercut the floor. The keeper cannot shrink `chipSpent` below what the pool received unless $CHIP or the hook returns $CHIP after `take`/`settle`; the real token and PoolManager do not.

The owner bypasses it by setting the floor to 0. See F-1.

**Q4. Is the ETH/USD leg bound correct?**

Yes for the intended tokens. `_wethToUsdc` (300–305) rejects `answer <= 0`, `updatedAt == 0`, and `block.timestamp > updatedAt + maxEthFeedAge`. With WETH at 18 decimals and USDC at 6, fair USDC out is `wethIn * answer / 10^(12 + feedDecimals)`. For an 8-decimal feed that is `/ 1e20`. Check: 1 WETH at $3000 (`answer = 3000e8`) yields `3e9` = 3000 USDC. `minOut` is that amount times `(10_000 - ethSlippageBps) / 10_000`, and `ethSlippageBps` cannot exceed 300 (200–204).

The constructor stores feed decimals and rejects 0 or `> 18` (149–151). It does not read USDC decimals; the `12` in the divisor hardcodes 6-decimal USDC. That matches `Box` face prices and Base USDC. A non-6-decimal quote token would make `minOut` wrong. Do not deploy against any other quote.

Not checked, and not treated as a finding against a live Chainlink ETH/USD feed: `answeredInRound`, a future `updatedAt`, and the Base sequencer uptime feed. `setEthLeg` can raise `maxEthFeedAge` immediately (any non-zero value). That widens the bound to a stale ETH price. Combined with the 3% slippage it is a keeper/owner parameter, not an unprivileged bypass. The $CHIP/WETH leg remains the unbounded one, down to the floor.

### 2. Pyth callback — gas, choice, re-roll

**Q5. Can anyone make the callback exceed its measured gas or revert?**

No unprivileged caller can, against Chainlink feeds and B20 stocks, with at most 16 listed stocks.

The callback does not call the opener. The ETH refund is in `open` / `retryOpen`, not in `_fulfill`. `settle` is inside `try/catch` (760–765). A reverting or out-of-gas `settle` is swallowed and the prize becomes owed; the inner payment rolls back with the failed call, so a caught failure does not also pay. `_snapshot` prices each listed stock once. Disabled stocks skip `priceUsd` (489). `MAX_STOCKS` is 16 (PrizeVault 61, 524). `queueOdds` allows at most 8 tiers. The measured slope in `audit/box-2026-09-23/gas/box-callback-sim.out.txt` is about 36k gas per listed stock, about 573k at 13 and about 680k at 16. `MIN_CALLBACK_GAS` is 900_000 (Box 88, 535–537).

Pyth's `roundTo10kGas` rounds the request **up** to a multiple of 10,000 and never down, so a limit of 900_000 stays 900_000 and any in-range non-multiple gets more gas, not less. The first `revealWithCallback` is gas-capped. If it fails with enough gas supplied, status becomes `CALLBACK_FAILED` and the permissionless retry calls `_entropyCallback` with the same number and no cap. A heavy-but-finite feed can fail the first attempt and still complete on the retry. A feed or token that consumes the whole block gas could stick opens; that feed is chosen by the StockRegistry owner, not by the opener, and `priceUsd` for the real registry is one `latestRoundData`.

The 63/64 rule does not create a false owed payment: if `settle` runs out of gas, its transfers revert, and if the outer callback then runs out of gas the whole Pyth call reverts and the box stays `OPENING`.

**Q6. Can an opener choose the outcome or re-roll?**

No, on one provider.

`open` calls `requestV2(provider, gasLimit)` (728). Entropy fills the user contribution with its own `random()` (`keccak256(block.timestamp, block.prevrandao, msg.sender, seed)`). The provider's value comes from a precommitted hash chain. The opener does not learn that value until after `open` is mined (Fortuna HTTP or the callback). They cannot revert `open` after seeing it. `retryOpen` (377–389) requires `STATE_OPENING`, the stored opener, 30 days, and `getRequestV2(storedProvider, sequence)` still equal to that sequence with `callbackStatus == 1` (`CALLBACK_NOT_STARTED`).

Checked against Pyth `Entropy.sol` (`getRequestV2` → `findRequest`, and `clearRequest`):

- A revealed success is cleared. `clearRequest` zeros `sequenceNumber` on the hot slot (or deletes the overflow slot). The next read does not match, returns an empty struct, and `sequenceNumber != b.sequence` reverts `RevealAlreadyPublic`. A cleared request cannot look `NOT_STARTED`.
- `CALLBACK_FAILED` (3) keeps the sequence and fails the status check. `revealWithCallback` re-runs the same number. `retryOpen` cannot replace it.
- `retryOpen` reads `_providerOf[tokenId]`, not the current default provider. Changing Pyth's default provider does not make the old request look unrevealed.
- Sequence numbers on one provider only increase. They are not reused. Deleting `_tokenIdOfSequence[oldSequence]` before the new request makes a late callback for the old sequence an `OrphanCallback` (746–749), which does not draw again.

The opener also cannot grind inside the callback: the box is non-transferable in `OPENING` and `OWED` (875–882), and the prize is computed from the mint snapshot (`faceUsd`, `oddsVersion`) at 757–758.

What does **not** hold is written up as F-2: the token-id map is keyed only by `sequence`, and `_fulfill` never checks `provider`. A default-provider change can alias two live requests. Separately, because Box does not pass a user secret, Pyth's "either party honest" property does not apply to the buyer. A provider who frontruns `open` can grind which hash-chain step the box gets. That is Pyth's own documented provider trust, not an opener re-roll. Accepted; stated so it is not mistaken for a user-secret design.

**Q7. Is the gas cap enforced everywhere it needs to be?**

Yes on the contracts in scope. `addStock` reverts at `MAX_STOCKS` (524). `setCallbackGasLimit` reverts outside `[900_000, 2_000_000]` (535–537). In-flight requests keep the gas limit Pyth stored at `requestV2`; a later `setCallbackGasLimit` does not shrink them. No other callback loop is unbounded. The gas of `registry.priceUsd` and of the prize token's `transfer` is bounded only by those external contracts.

### 3. Owed path

**Q8. Can an owed prize be paid twice, to the wrong address, or at the wrong size? Can a box be both owed and paid?**

No.

`claimOwed` requires `STATE_OWED`, calls `settle(opener, owedUsd, …)`, and reverts with `StillUnpayable` if `paid` is false, before any Box state change (395–400). On success it subtracts `owedUsd` once and `_retire` deletes the record and burns the NFT (401–402, 785–793). A second claim sees state 0 and reverts `NotOwed`. The callback and the claim are mutually exclusive: `_fulfill` either sets `STATE_OWED` and returns, or `_retire`s (770–782). The sequence key is deleted before that branch (767), so a second callback is an orphan.

The payee is `b.opener`, set to `msg.sender` of `open` / `retryOpen` (731) and never updated. `retryOpen` requires that same opener (381). Opening and owed boxes cannot be transferred (875–882). A gift pays the holder who opens, not the buyer.

`owedUsd` is the snapshot draw (`faceUsd * tier.prizeBps / 10_000`) and is not rewritten. `claimOwed` passes that stored number into `settle`. USDC fallback pays `_usdToUsdc(prizeUsd)`, which is exact for 6-decimal USDC. A stock payout sizes the token amount from the **current** registry mark (`PrizeVault.sol` 652) so that the mark value equals `owedUsd`, rounding down by less than one token unit (F-3, dust). The caller of `claimOwed` does not choose the stock: the rotation seed is `keccak256(tokenId, sequence)`.

A zero `prizeUsd` would mark `paid` without a transfer (`PrizeVault.sol` 274–277). The odds queue rejects `prizeBps == 0` and a live SKU rejects `usdcPrice == 0`, so a sold box does not draw zero.

**Q9. Is `outstandingLiabilityUsd` exact on every path? Can it underflow or drift?**

It is exact. No path double-counts or drops a box.

| path | change |
|---|---|
| `_buy` | `+= face * rtp(snapshotOdds) / 10_000` (696) |
| callback, paid | `-= mintEvUsd` (768), then burn |
| callback, owed or `settle` reverted | `-= mintEvUsd`, then `+= prizeUsd` (768–776) |
| `claimOwed` success | `-= owedUsd` (401) |
| `retryOpen`, orphan callback, failed `open` | no change |

Buy of two $1 boxes books `2 * 910_000`. Owing the first at the 0.20× prize (`200_000`) leaves `910_000 + 200_000`. Claiming it leaves the other box's `910_000`. A paid open removes only that box's EV, not the prize (the prize left the vault). Underflow would revert the callback; it needs a prior corruption that these paths do not create. `nextId` does not reuse token ids.

CHIP buys book the same USD EV before the converter has sold. That is a timing gap between liability and vault cash, not an accounting drift. The $CHIP sits in the converter until `sellChip`.

**Q10. Can someone force the owed path and gain?**

They cannot increase the prize or re-roll it.

`sweepSurplus` cannot push a single max prize under the cap. `jackpotReserveUsd` is `ceil(maxLivePrizeUsd * 10_000 / maxPrizeBps)` (413). After a sweep, inventory is still at least that reserve, and `prizeCap = floor(inventory * maxPrizeBps / 10_000)` is still at least the max prize (the ceil/floor pair lands on the prize, and `settle` uses `prizeUsd > cap`). At the default `minUsdcBps` of 50%, the USDC left after a sweep is at least about twice the max prize, so the USDC fallback can pay it even if stocks are split.

A keeper `restock` can spend up to 5% worse than the mark and can nudge a pool that is sitting on the reserve just under the cap. The resulting owed prize is the same USD amount. The searcher's gain is the restock slippage, which they can take with no reveal in the mempool. Seeing the Fortuna number and forcing owed does not pay them more.

Moving the Chainlink mark, donating, or sweeping does not change `owedUsd`. Donations cannot be pulled back out by the donor (`rescue` refuses USDC and listed stocks).

### 4. Solvency — restock, sweep, owner

**Q11. Can the keeper drain the vault through `restock`?**

No, beyond the configured slippage.

`restock` is `onlyKeeper` and `nonReentrant` (343). The recipient is `address(this)` on both routers (369, 384). Output is the stock balance delta and must be at least `minOut` (394–395). `minOut` is the registry mark less `restockSlippageBps` (max 500). Approvals are set to the pull amount and cleared to 0 on both branches (363–376, 378–390). A revert rolls the approval back with the transaction. Per-call and per-day caps are charged in USDC before the swap (347–351). After the swap, USDC must be at least `minUsdcBps` of `inventoryUsd()` (397–400).

The keeper does not choose the router. Venue, fee, and tick spacing come from `registry.getStock`. A compromised StockRegistry owner can retarget those fields; that is outside these three contracts. With an honest registry record, the keeper's extraction is MEV up to the slippage, capped per call and per UTC day, and the stock stays in the vault.

`minUsdcBps` may be 0 (`setRestockParams` only caps it at 9000). The owner can allow the keeper to convert all USDC into stock. That is F-4's setup, not a silent router bug.

**Q12. Can sweep or the owner withdraw take the pool below what sold boxes are owed or could win?**

`sweepSurplus` cannot, at the default USDC share.

`sweepableUsdc` (417–449) fails closed to 0 if `box` is unset or if liability or `jackpotReserveUsd` reverts. It pays only `IBox(box).treasury()` (453–458). The amount is the minimum of:

1. USDC above `ceil(liability * 11_000 / 10_000)`,
2. inventory above the jackpot reserve,
3. the USDC-share solution `x <= (usdc * 10_000 - minUsdcBps * inv) / (10_000 - minUsdcBps)`.

All three divisions round the swept amount down. `maxLivePrizeUsd` is `max(maxSoldPrizeUsd, top prize of every SKU that exists and is not paused)` (470–478). `maxSoldPrizeUsd` is raised at buy to that box's snapshot max and never lowered (670–673), so pausing a SKU, cutting its price, or lowering a later odds table does not shrink the reserve under boxes already sold. Owed prizes are inside `outstandingLiabilityUsd` at their exact size, so the 110% USDC floor covers them in USDC, not only in aggregate inventory.

`executeSurplusWithdraw` checks those two floors after the transfer and reverts the whole call if either fails (589–597). It does **not** apply `minUsdcBps`, and neither path checks that a single asset can cover the max prize. See F-4. The owner cannot pull the reserve itself. They can, after 48 hours, shape what is left so `settle` cannot pay it until new USDC arrives.

A stale-high mark inflates `inventoryUsd` and can let sweep send real USDC. Stale marks are skipped once `maxFeedAge` passes, which fails safe. Widening `maxFeedAge` is immediate. See F-5.

**Q13. Can inventory be inflated to pass the sell gate and then deflated?**

Not by an unprivileged attacker. `deposit` is one-way. `rescue` cannot take USDC or a listed stock. Marks come from `registry.priceUsd` (Chainlink), and `_freshPrice` rejects a zero, a revert, or a stale update (632–638). A flash-loan donation cannot be withdrawn in the same transaction, so it cannot be used to pass `isSkuCovered` and then disappear. A later honest Chainlink move can shrink inventory; that is the oracle, and the prize then waits as owed at the original size.

**Q14. Can $CHIP get stuck, or be paid as a prize?**

It cannot be paid as a prize. `addStock` rejects `chip` and `DEFAULT_CHIP` (`PrizeVault.sol` 522, 624–628). `deposit` rejects anything unregistered. `_canPayStock` skips `_isChip` even if a token were listed (644–646). `_buy` sends a $CHIP payment entirely to the converter (685–690) and reverts if the converter's `box()` is not this Box.

$CHIP in the converter is stuck until `sellChip` or `executeChipRecovery`. That is intentional. $CHIP sent directly to the vault is stray and `rescue` can return it (607–613). $CHIP does not remain on `Box` after a buy.

**Q15. Can the owner take user funds or break a sold box's promise with an immediate action?**

Yes for unsold $CHIP in the converter. See F-1. That is the immediate path. It does not depend on the 48-hour recovery.

No for the vault's USDC or listed stocks: `rescue` reverts on those (611). Treasury, SKU price and existence, the odds table, raising or lowering `maxPrizeBps`, surplus withdraw, and $CHIP recovery are all 48-hour queues with a 14-day grace.

Immediate liveness levers, as the brief accepts: `setPaused`, `setSkuPaused`, `setStockEnabled(false)`. Pause blocks buy, open, and `retryOpen`. It does not block the Entropy callback or `claimOwed`. Disabling every stock pushes prizes onto the USDC fallback; if USDC cannot cover, they become owed at full size.

Also immediate, and not just liveness: `setMaxFeedAge` upward (F-5), `setRestockParams` (slippage to 5%, `minUsdcBps` to 0, caps to any size), `setKeeper` on both contracts, `setLimits`, `setPriceFloor(0)`, `setEthLeg`. None of these transfer vault principal to an arbitrary address in the same call. `setPriceFloor(0)` plus a sandwiched `sellChip` does transfer the converter's $CHIP value to the pool counterparty in the same transaction.

There is no on-chain ceiling on `prizeBps` or RTP. After the 48-hour odds timelock, a table that pays the cap on every open can drain the vault down to the sell gate. Existing boxes keep their snapshot and become owed if the pool is emptied. That is governance, not an immediate action. It is listed under accepted design.

---

## C. Findings

### F-1 — Medium — owner can drop the $CHIP floor and dump in one transaction

**Where:** `src/box/ChipConverter.sol` 184–198 (`setKeeper`, `setLimits`, `setPriceFloor`), used by `sellChip` 215–238 and `_checkFloorAndPay` 241–246. Contrast `queueChipRecovery` 261–266, which waits 48 hours.

**What goes wrong.** The header says a keeper sale is bounded by caps and by `minUsdcPerMillionChip`, and that $CHIP leaves only via `sellChip` or the 48-hour recovery. The owner can remove both bounds immediately, point `keeper` at themselves, and sell.

**Call sequence.**

1. Owner `setPriceFloor(0)`.
2. Owner `setLimits(type(uint256).max, type(uint256).max)`.
3. Owner `setKeeper(searcher)`.
4. Searcher sandwiches the $CHIP/WETH pool and calls `sellChip(chip.balanceOf(converter), 1, deadline)`.
5. The v4 leg has no price limit except the end of the curve. `minUsdcOut` is 1. The floor is off. USDC out can be dust. Dust is split 5/95 to the current treasury and the vault. The $CHIP is bought by the searcher.

**Why it matters.** Box buyers already paid that $CHIP for a USD-denominated prize. Liability was booked at the USDC face EV. This sale does not fund it. A compromised owner key does not need to wait out `queueChipRecovery`.

**Fix.** Use the same 48-hour queue for any action that weakens the bound: decreasing `minUsdcPerMillionChip` (including to 0), increasing either cap, or raising `maxEthFeedAge` / `ethSlippageBps`. Keep `setKeeper` immediate only if the floor and caps cannot be weakened in the same block. Alternatively set a non-zero floor once and do not allow it to decrease.

**Not this bug.** A keeper who is not the owner cannot pass a non-zero floor, cannot raise caps, and cannot send USDC anywhere but the live treasury and vault.

### F-2 — Medium (low likelihood) — in-flight opens are keyed only by sequence number

**Where:** `src/box/Box.sol` 126 (`_tokenIdOfSequence`), 728–734 (`_requestEntropy` writes it), 745–754 (`_fulfill` reads it and does not compare `provider` to `_providerOf[tokenId]`).

**What goes wrong.** Pyth sequence numbers are per provider. They start over when a new provider is registered, and they are not unique across providers. Box stores one `uint64 → tokenId` map and ignores the provider argument on the callback. `retryOpen` itself queries the right provider, so the status gate in Q6 is fine. The fulfillment map is not.

**Call sequence.**

1. Provider A has a still-`CALLBACK_NOT_STARTED` request at sequence `N` (a stuck open). Its Fortuna reveal may already be public.
2. Pyth changes the default provider to B. B's counter is independent and will eventually issue sequence `N`.
3. A new `open` on B receives sequence `N` and overwrites `_tokenIdOfSequence[N]`.
4. Anyone submits A's `revealWithCallback` first. `_fulfill` loads the new token id, sees `STATE_OPENING` and the same sequence, and pays or owes that box using A's number.
5. The callback returns success, so Pyth clears A's request. The new box's own later callback finds a zero token id and orphans.
6. If step 4 instead runs the new box's callback first, the old box is the one left `OPENING` with its map slot gone. `retryOpen` on a cleared request hits `RevealAlreadyPublic` and the NFT stays locked. `outstandingLiabilityUsd` keeps that box's EV forever.

Recent in-flight boxes use high sequence numbers and do not collide with a new provider's first requests. The collision is with old stuck requests whose sequence the new provider reissues. It does not happen if the default provider never changes.

**Fix.** Key the map by provider and sequence, and in `_fulfill` require `provider == _providerOf[tokenId]` before drawing. Keep the orphan path for a genuine late callback after `retryOpen`.

**Test gap.** `test/mocks/MockEntropyV2.sol` uses one provider and one global counter, so `test/box/**` cannot see this.

### F-3 — Informational — stock prizes round down by less than one token unit

**Where:** `src/box/PrizeVault.sol` 652 (`Math.mulDiv` toward zero).

The USDC fallback pays the exact USD amount. A stock payout pays the greatest token amount whose mark value does not exceed `prizeUsd`. For 8-decimal B20 that is sub-cent. Not a double-pay and not a way to enlarge an owed prize. No change required unless "never paid short" is meant to be exact in wei rather than exact in USD at the mark, rounding down.

### F-4 — Low — owner withdraw can leave the jackpot unpayable without taking the reserve

**Where:** `src/box/PrizeVault.sol` `executeSurplusWithdraw` 580–598. The missing check is the one `sweepableUsdc` applies at 441–448. `setRestockParams` 228–236 can set `minUsdcBps` to 0 immediately, which also drops that constraint out of the permissionless sweep.

**What goes wrong.** Both floors are aggregate. At `maxPrizeBps = 2500`, the reserve is 4× the max prize. The owner can, after 48 hours, withdraw USDC down to `ceil(1.1 * liability)` and withdraw each stock so that no single balance covers the max prize, while `inventoryUsd()` still equals the reserve. `settle` then returns `paid == false`. The prize becomes owed at full size. The assets are still in the vault; they are not in a shape `settle` can pay. `deposit` or a later USDC sale unblocks `claimOwed`. With the default 50% USDC share, `sweepSurplus` alone cannot do this: it leaves enough USDC to pay the max prize about twice.

**Call sequence.** Owner `setRestockParams` is optional. `queueSurplusWithdraw` of USDC down to the liability floor, wait 48 hours, `executeSurplusWithdraw`. Repeat per stock, leaving each under the max prize and the sum at the reserve. Open the box (or wait for the callback). `settle` caps or finds no bucket. The box is `STATE_OWED` until someone adds USDC.

**Fix.** After any withdraw or sweep, require that USDC or some one enabled stock can cover `maxLivePrizeUsd`, and apply `minUsdcBps` inside `executeSurplusWithdraw`. Reject `minUsdcBps == 0` if the USDC fallback is part of the promise.

### F-5 — Low — `setMaxFeedAge` can be raised immediately

**Where:** `src/box/PrizeVault.sol` 240–244. The consumer is `_freshPrice` 632–638, which feeds `inventoryUsd`, the sell gate, `settle`, and `restock`.

Decreasing the window fails safe (stale stocks drop out). Increasing it re-includes a frozen high mark. `sweepSurplus` will then send real USDC to the treasury against an inventory figure the feed no longer supports. The owner cannot set the price; they can choose to keep trusting a dead one. The default of 5 days matches the weekend last-close policy and is fine.

**Fix.** Timelock increases of `maxFeedAge`. Allow decreases down to `MIN_FEED_AGE` immediately.

---

### Accepted by design

These were checked and are not filed as defects. Disagreeing with one is a product choice, not a missed bug in the paths above.

| Item | Why it stands |
|---|---|
| Keeper sells $CHIP down to the floor | $CHIP has no oracle. With a non-zero floor the keeper cannot go under it (Q3). Caps hold (Q1). F-1 is only the owner turning the floor off. |
| Floor of 0 disables the check | Intentional. Unsafe if left at 0. F-1 is the missing timelock on going back to 0. |
| Daily cap charges `chipIn`, not `chipSpent` | Conservative. Partial fills cannot exceed the cap. |
| 48-hour $CHIP recovery to any `to` | The documented broken-route path. It is not immediate. F-1 is the immediate substitute. |
| Curve-end sqrt price limit on the v4 leg | The keeper minimum and the owner floor are the slippage bounds. The limits only stop v4 from reverting on a zero/max limit. |
| ETH leg slippage up to 3% under Chainlink | Bounded. Independent of the $CHIP leg. |
| Callback failure becomes owed, same number | `try/catch` around `settle`. Pyth `CALLBACK_FAILED` retries the same reveal. `retryOpen` refuses that status even after 30 days. |
| Opener can `retryOpen` after 30 days if the provider never revealed | New randomness only in that case. The keeper is expected to submit `revealWithCallback` long before. |
| Provider frontrun of `open` | Box uses Entropy's `random()` and does not pass a user secret. Pyth documents that a frontrunning provider can grind. The opener cannot. |
| Owed prizes wait | Full size, no re-roll, no short pay. A fragmented or shrunken pool delays them. |
| `maxSoldPrizeUsd` only rises | After the last jackpot box opens, sweep stays conservative. |
| One box's max prize is 25% of inventory, not the sum of all boxes | Several jackpots become owed rather than overpaying. The 110% liability floor is EV until draw, then the exact owed amount. |
| Restock MEV within `restockSlippageBps` (≤ 5%) and the USDC/day caps | Output stays in the vault. |
| B20 marks hold the last close over weekends | `maxFeedAge` defaults to 5 days. Older than the window is skipped everywhere. F-5 is only an immediate widening past that. |
| Donations are irreversible | They cannot be flashed in and out to pass the sell gate. |
| Pause and disabling stocks | Liveness. They do not rewrite `owedUsd` or a mint snapshot. |
| Odds / SKU / treasury / `maxPrizeBps` / surplus withdraw | 48 hours, 14-day grace. No RTP ceiling: a reckless table can later drain new sales. Pause is the immediate stop. |
| `executeSurplusWithdraw` may ignore the USDC share | Documented as the two floors (liability and reserve). F-4 is the payability gap that leaves, not a withdrawal of the reserve. |
| Gas-heavy buys | The sell gate re-prices the pool. Accepted on Base. |
| Box runtime size | Out of scope for this logic review. No production edit was made, so the ~1.6 KB headroom is unchanged. |

---

## D. Gate

**CLEAR-FOR-FUNDED-TESTNET. Not mainnet.**

Nothing in this commit lets a buyer, a gift recipient, or the keeper (with a non-zero floor and finite caps) pull value out of the fee recipient and the vault, pay an owed prize twice, or re-roll a revealed box. Sweep at the default 50% USDC share cannot push a single max prize under the cap. That is enough to fund a testnet if all of the following are true:

- the owner is a Safe, not a hot key sitting on the converter (F-1);
- `minUsdcPerMillionChip` is set non-zero and both $CHIP caps are set before the first $CHIP buy;
- `minUsdcBps` stays at 5000;
- `maxFeedAge` is not raised;
- the Pyth default provider is not changed while any box is `OPENING` (F-2).

Do not ship this commit to mainnet. F-1 makes the 48-hour $CHIP recovery the slower of two owner exits, and F-2 can permanently lock a paid NFT if the provider key changes. Both are small code changes. Re-review those diffs before a mainnet candidate. This review does not bless mainnet.

---

## E. Tests

```
forge 1.8.3
solc 0.8.24 (foundry.toml: cancun, optimizer 200, no via_ir)
forge test --match-path 'test/box/**'
```

| suite | result |
|---|---|
| `test/box/BoxRebuild.t.sol` | 23 passed |
| `test/box/BoxAuditPoC.t.sol` | 18 passed, 1 skipped |
| `test/box/BoxVault.t.sol` | 28 passed |
| `test/box/Box.t.sol` | 39 passed (includes `testFuzz_previewDrawIsDeterministic`, 512 runs) |
| **total** | **108 passed, 0 failed, 1 skipped** |

The skip is `test_M08_OpenForwardsExactEntropyFee_RefundsExcess_BaseFork`, which needs `BASE_RPC_URL`. No fork test and no `box-callback-sim` re-run were executed in this review. The gas numbers cited in Q5 are the committed simulation output, not a new measurement.

The passing suite covers the 5/95 split, the keeper floor and caps, stale ETH, timelocked recovery, owed-then-claim, `retryOpen` refusing `CALLBACK_FAILED`, the 30-day wait, restock bounds, and sweep versus liability and `maxSoldPrizeUsd`. It does not cover F-1 (owner zeros the floor and sells) or F-2 (two providers, one sequence number).
