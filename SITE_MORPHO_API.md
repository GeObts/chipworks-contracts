# SITE_MORPHO_API.md: Lend and Borrow on Morpho, exactly as the contracts expose them

Two pages. Both are **non-custodial and powered by Morpho**. Chipworks holds nobody's money:

- **Lend:** supply USDC to the *Chipworks USDC* vault. That is a standard MetaMorpho V1.1 vault
  from Morpho's factory; Chipworks only curates it. Variable yield, with 15% of the interest to Chipworks.
- **Borrow:** post a tokenized stock and borrow USDC on an existing Morpho Blue market through
  `ChipBorrowHelper`, which takes 1% of what is borrowed. The position lives in Morpho under the
  user's own address.

> **DEPLOYMENT STATUS (2026-09-16): NOTHING IS LIVE.** Both are waiting on two independent
> audits (`audit/morpho-2026-09-16/`). Build behind address checks: render each page only when its
> address is set. **Never ship Borrow before the helper address exists on chain.**

Viem is assumed. Every write must `await waitForTransactionReceipt` and check
`receipt.status === 'success'` before any success copy. A revert surfaces as a failure with the tx
hash. (This rule exists because the GET CHIPPED dialog once reported success over a revert.)

---

## Addresses (Base, 8453)

| | address | status |
|---|---|---|
| Morpho (Blue) | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` | live, Morpho's |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | live |
| Chipworks USDC vault (`cwUSDC`) | `0x6B0EF5dd1cED6E26c384E4CcAf72f9dC0A1093d6` | **not deployed.** This is the CREATE2 address `safecalls-morpho-vault.json` will produce. Check `getCode` before use |
| ChipBorrowHelper | **TBD** | not deployed; address known only after deploy |

### The four borrow markets (and the vault's stock markets)

A market is identified by its `MarketParams`. `id = keccak256(abi.encode(params))`. Loan token is
USDC and the IRM is `0x46415998764C29aB2a25CbeA6254146D50D22687` for all four.

| stock | collateralToken | oracle | lltv (1e18) | id |
|---|---|---|---|---|
| AAPL | `0xb200000000000000000000C2e324d24d7eEcd1fb` | `0xEcC5c9bf18CB2CfC94C2f7EFf8BDd5837A60AB0e` | `625000000000000000` | `0xae1a30486234bf7e7ac166c7c03d9bc5f2cd8a39be2c48e73c665ac7148c3c28` |
| GOOGL | `0xb2000000000000000000002D0BA3164cc74f58B7` | `0x24DC11055aa5b2C5692E4B77d7285c4f0fd9Cf99` | `770000000000000000` | `0xa3913d896b7e9c0e0a84f1be27d376cf2065616101cb7c44674af8a154e684cc` |
| NVDA | `0xb20000000000000000000078ee7ce2fE4908108C` | `0x4F698C04d01d9CebCDd9494c189aBdD6C5453f84` | `625000000000000000` | `0xb4b42dd66cef25614b94510a910d54b2c148e7621d22b4271566724beda63d13` |
| META | `0xb2000000000000000000008bC8786B856E61707C` | `0x4752B27dFc1931eb9a5DFEFC7FBC9d0af9020dC7` | `625000000000000000` | `0x44b343b5087c0bd34207cb5c199f12030777bf6b8c0a128438246f1212f37ca5` |

**Hardcode these. Never discover markets, and never sort or pick by APY.** Base has markets pinned at 100%
utilisation quoting ~297,000% APY that a lender cannot withdraw from. There are two NVDA markets; the 77% one
is near-empty and deliberately excluded. `helper.isListed(id)` is the live check that a market is
offered.

ABI with custom errors: `tools/claim-day/borrow-helper.abi.json`. **Include the error entries**, or
reverts decode as unreadable hex.

---

## LEND: the vault

```solidity
// ERC-4626. Shares are 18 decimals, assets are USDC (6).
function deposit(uint256 assets, address receiver) returns (uint256 shares);
function redeem(uint256 shares, address receiver, address owner) returns (uint256 assets);
function withdraw(uint256 assets, address receiver, address owner) returns (uint256 shares);
function balanceOf(address) view returns (uint256 shares);
function convertToAssets(uint256 shares) view returns (uint256 assets);
function maxWithdraw(address owner) view returns (uint256 assets);   // can be < balance
function maxRedeem(address owner) view returns (uint256 shares);
function maxDeposit(address) view returns (uint256);                   // 0 when every cap is full
function totalAssets() view returns (uint256);
function fee() view returns (uint96);                                  // 0.15e18
```

**Supply:** `USDC.approve(vault, amount)`, then `vault.deposit(amount, user)`. If
`amount > maxDeposit(user)`, cap it and say why ("the vault is full").

**Withdraw all:** `vault.redeem(vault.maxRedeem(user), user, user)`. Use redeem-by-shares for "max",
never `withdraw(balanceInAssets)`: interest accrues between read and send, so a stale amount reverts or leaves dust.
**Withdraw some:** `vault.withdraw(assets, user, user)`.

**Show the user:**
- Position: `convertToAssets(balanceOf(user))` USDC.
- **Available to withdraw now:** `maxWithdraw(user)`. Money lent out to borrowers comes back as they
  repay. If this is below the position, say so plainly rather than hiding it.
- **Rate: variable, never promised.** Compute it; do not hardcode "5%". For each of the 8 markets, read
  `Morpho.market(id)` and `IIrm(irm).borrowRateView(params, market)`, which is a per-second rate:
  `borrowAPY = e^(rate × 31,536,000) − 1`, `util = totalBorrowAssets / totalSupplyAssets`,
  `supplyAPY = borrowAPY × util × (1 − market.fee/1e18)`.
  The vault's gross APY is the average of those weighted by the vault's supply in each market
  (`Morpho.position(id, vault).supplyShares` → assets via `totalSupplyAssets/totalSupplyShares`).
  **Net to the depositor = gross × 0.85.** Label it "current, variable". The 8-market list and IRM are in
  `tools/claim-day/vault-bundle.cjs`.

**Copy that must appear:**
- "Powered by Morpho. Your USDC goes into a Morpho vault, not to Chipworks. You can withdraw any time
  liquidity allows."
- "Fee: 15% of the interest earned, never of your deposit." Example: earn $100 of interest,
  receive $85.
- Risk line: lent USDC is borrowed against crypto and tokenized stocks. If a borrower's collateral
  falls too fast, losses can reach lenders. Withdrawals can wait for borrowers to repay.

---

## BORROW: `ChipBorrowHelper`

```solidity
function supplyCollateralAndBorrow(MarketParams params, uint256 collateralAmount, uint256 borrowAssets)
    returns (uint256 received);                    // received = borrowAssets - floor(borrowAssets/100)
function repayAndWithdraw(MarketParams params, uint256 repayAssets, uint256 collateralOut)
    returns (uint256 repaid, uint256 withdrawn);   // type(uint256).max = "all" for either
function borrowLimit(MarketParams params, uint256 collateral) view returns (uint256);  // max TOTAL debt via helper
function isListed(bytes32 id) view returns (bool);
function marketId(MarketParams params) pure returns (bytes32);

// Morpho
function isAuthorized(address authorizer, address authorized) view returns (bool);
function setAuthorization(address authorized, bool newIsAuthorized);   // reverts "already set" if unchanged
function position(bytes32 id, address user) view returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);
function market(bytes32 id) view returns (uint128 totalSupplyAssets, uint128 totalSupplyShares,
    uint128 totalBorrowAssets, uint128 totalBorrowShares, uint128 lastUpdate, uint128 fee);
```

### The fee. Show it exactly like this.

```
Borrow         1,000.00 USDC
Chipworks fee     10.00 USDC  (1%, once, at borrow)
You receive      990.00 USDC
You owe        1,000.00 USDC  + interest at X.XX% (variable)
```

`fee = borrowAssets / 100n` (bigint, rounds down) and `receive = borrowAssets - fee`. **Compute it the same
way the contract does** so the number shown is the number that arrives. Repaying and withdrawing
are free.

### Opening a loan: three signatures on first use, one after

1. **Authorize, once:** if `!Morpho.isAuthorized(user, helper)`, send `Morpho.setAuthorization(helper, true)`.
   Check first, because Morpho reverts `already set` on a repeat.
   Explain it before the signature: *"This lets the Chipworks borrow helper open and manage loans on your
   Morpho account when you use it. It can only act when you send the transaction, and only for you.
   You can revoke it any time."* Morpho authorization is account-wide, so it must not be buried.
2. **Approve the stock:** `stock.approve(helper, collateralAmount)`. Approve the exact amount, not unlimited.
3. `helper.supplyCollateralAndBorrow(params, collateralAmount, borrowAssets)`. Pass `collateralAmount = 0` to borrow
   more against collateral already posted.

**Borrow ceiling. Enforce it in the form before the wallet ever opens:**
```
postedCollateral = position.collateral + collateralAmount
maxDebt          = helper.borrowLimit(params, postedCollateral)      // 90% of the market's LLTV
currentDebt      = borrowShares × (totalBorrowAssets + 1) / (totalBorrowShares + 1e6), rounded UP
freeLiquidity    = totalSupplyAssets − totalBorrowAssets
maxBorrow        = min(maxDebt − currentDebt − small buffer, freeLiquidity)
```
Keep a buffer of a few basis points under `maxDebt`, because interest accrues between the read and the
transaction. **Show `freeLiquidity` openly.** On 2026-09-16 it was only $487 (META) to $2,206 (AAPL), and it is
the real limit on borrowing, not the collateral.

### Show on an open position

- Collateral: `position.collateral` (raw units; format with the B20's decimals).
- Debt: `currentDebt` as above. For live interest, accrue forward with `borrowRateView`.
- Collateral value: `collateral × oracle.price() / 1e36` in USDC units (6 decimals).
- **LTV** = debt / collateral value. **Liquidation at LLTV** (62.5%, or 77% for GOOGL). **The helper line is 90% of that.**
- **Distance to liquidation:** the price can fall by `1 − LTV/LLTV` before liquidation.
- Borrow rate: `borrowAPY` as in the Lend section.
- **Weekend warning:** stock prices hold Friday's close over the weekend and can jump at Monday's
  open, and liquidations follow them. Say it.

### Repay and get the stock back

- **Repay all:** `USDC.approve(helper, owed × 1.001)`, then `helper.repayAndWithdraw(params, MAX_UINT256, 0)`.
  The helper pulls **exactly** what is owed at execution; the approval buffer only covers interest
  accruing in between. The user needs that much USDC. They received 99%, so repaying everything costs
  more than they got. Say so up front.
- **Repay some:** `approve(helper, amount)`, then `repayAndWithdraw(params, amount, 0)`.
- **Withdraw stock:** `repayAndWithdraw(params, 0, amount)`. With debt still open this is held to the same 90% line.
- **Close out in one transaction:** `approve(helper, owed × 1.001)`, then `repayAndWithdraw(params, MAX, MAX)`.
- **After a full close, offer the revoke:** `Morpho.setAuthorization(helper, false)`.
- These work even if a market is delisted. **Never grey out repay** based on `isListed`.

### Errors to translate

| revert | say |
|---|---|
| `NotAuthorized()` | "Authorize the borrow helper on Morpho first." |
| `MarketNotListed(id)` | "This market isn't open for new loans. You can still repay and withdraw." |
| `TooCloseToLiquidation(debt, limit)` | "That would put the loan too close to liquidation. Borrow less, or add collateral." |
| `NothingToDo()` | form bug: nothing was requested |
| `CollateralAccountingMismatch` | "The stock transfer didn't arrive in full." (a B20 policy or pause issue) |
| Morpho `"insufficient liquidity"` | "Not enough USDC in this market right now." |
| Morpho `"insufficient collateral"` | position unhealthy; should be unreachable through the helper |
| Morpho `"already set"` | the authorization was already on; re-read and continue |
| B20 transfer revert | the stock's compliance policy or a pause blocked the transfer |

---

## Testing locally

B20 stocks are node precompiles and **do not execute in an anvil/forge fork.** A balance read burns
all the gas and reverts. Borrow flows must be exercised against a real node: `eth_simulateV1`, as
`tools/claim-day/borrow-helper-sim.cjs` does, or `eth_call` with block overrides. The Lend page is
plain USDC and works on a fork.
