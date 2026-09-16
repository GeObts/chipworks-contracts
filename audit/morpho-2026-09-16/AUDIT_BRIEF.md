# Audit brief: Chipworks on Morpho (borrow helper + USDC vault)

**Chain:** Base mainnet (8453). **Solidity:** 0.8.24, EVM `cancun`, OpenZeppelin 5.1.0, optimizer 200 runs, no `via_ir`.
**Source commit:** `a0d533d` in `chipworks-contracts` (branch `lottery-wrapper`). The packaged files are byte-identical to that commit after CRLF→LF.
**Pastes:** 1 = this brief + `ChipBorrowHelper.sol` (priority) · 2 = helper tests and simulation · 3 = vault bundle · 4 = Morpho reference sources (optional).
**Nothing here is deployed yet.** Your review gates deployment.

You are one of two independent reviewers. Please don't look for or use the other review.
We want two separate readings, not one reading twice.

---

## 0. Before you start: prove you received every file whole

An earlier review was done on a paste that had been cut off. Before any findings, reply with
**this table filled in** for every file you were given:

| file | line count you see | SHA-256 you compute (or "cannot hash") | last non-empty line, verbatim |
|---|---|---|---|

The expected line count and SHA-256 of each file are on its `===== BEGIN FILE` marker line (and in
`SHA256SUMS` / `MANIFEST.md`). Hashes are over the exact bytes: UTF-8, LF line endings, trailing newline
included, i.e. everything strictly between the BEGIN and END marker lines. Each paste ends with an
`===== END OF` line: if you can't see it, the paste was truncated. If a count or a last line does not match, **stop and say which
file**. A review of a truncated file is worse than none.

---

## 1. What this is, in one paragraph

Chipworks is adding lending and borrowing on **Morpho**. It is not building a lending protocol.
There are two pieces:

1. **A USDC vault.** This is a stock **MetaMorpho V1.1** vault deployed by **Morpho's own factory**.
   Chipworks writes no contract for it. The only Chipworks artefact is a **Safe
   transaction bundle** that creates the vault and configures it: owner, a 15% fee, which
   existing markets it may lend into, queue order, and timelock.
2. **`ChipBorrowHelper`**, a small custom contract (278 lines including comments). It lets a user post a
   tokenized stock as collateral and borrow USDC on an **existing Morpho Blue market** in one
   call, and it takes 1% of the amount borrowed. The loan, the collateral and the position all
   live in **Morpho Blue**, under **the user's own address**. The helper is a pass-through. For it
   to borrow for the user, the user must call `Morpho.setAuthorization(helper, true)`.
   **That authorization is the reason this review exists.**

**Scope priority:** `ChipBorrowHelper.sol` first and hardest. The vault bundle second.
Morpho Blue and MetaMorpho are **out of scope**: they are Morpho's audited code. They are
included under `reference/` only so you can check how the helper uses them.

---

## 2. Facts verified on chain (so you don't have to take them on trust)

Each of these was read from Base, and you can check them independently:

| Claim | Evidence |
|---|---|
| Morpho Blue is `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` | Morpho docs' address page; Blockscout verified name `Morpho` |
| The vault factory is `0xFf62A7c278C62eD665133147129245053Bbf5918` | Listed as "MetaMorpho Factory V1.1" on docs.morpho.org/get-started/resources/addresses; verified as `MetaMorphoV1_1Factory`; `MORPHO()` returns Blue; 390 vaults created from it (Spark, Seamless, Re7 among them) |
| The vault created by the bundle is recognised by that factory | `isMetaMorpho(vault) == true` after simulation (`vault/vault-bundle.out.txt`) |
| All 8 markets already exist; Chipworks creates none | `CreateMarket` events at blocks 15.5M-51.0M, sent by third parties: the stock, cbXRP and USDe markets through a contract verified as `MorphoMarketFactory` (`0x8212…4769`), cbBTC directly and WETH through `0x5a4e…d4d0`. None were sent by the Chipworks Safe |
| The interest rate model is Morpho's governance-enabled `AdaptiveCurveIrm` `0x4641…2687` | `Morpho.isIrmEnabled` = true |
| 7 of 8 oracles are `MorphoChainlinkOracleV2` from Morpho's oracle factory `0x2DC2…bd3d` | `isMorphoChainlinkOracleV2` = true. Stock feeds are Chainlink "Coinbase AAPL/GOOGL/NVDA/META" |
| **The USDe market oracle is the exception** | `0xF4b1…2A47` is an EIP-1167 clone of `MetaOracleDeviationTimelock` (`0x846e…aC3e`), not factory-made. It prices 1.0 today and backs a $365M market |
| Every `IMorphoBlue` selector in the helper exists on the deployed Morpho | Matched against Morpho's verified ABI: `supplyCollateral 0x238d6579`, `withdrawCollateral 0x8720316d`, `borrow 0x50d8cd4b`, `repay 0x20b76e81`, `accrueInterest 0x151c1ade`, `isAuthorized 0x65e4ad9e`, `position 0x93c52062`, `market 0x5c60e39a` |
| The stocks are **B20 tokens** (Base's tokenized-stock standard), implemented as **node precompiles** | They cannot run inside a forge fork (1 byte of code there), which is why the stock leg is proven with `eth_simulateV1` on a real node. B20s carry transfer **policies** (allow/block lists) and pausable functions |

---

## 3. `ChipBorrowHelper`: design and security model

Line numbers refer to `borrow-helper/ChipBorrowHelper.sol`.

### 3.1 The whole state and the whole privilege set

- Immutable: `MORPHO`, `FEE_RECIPIENT` (the Chipworks Safe). Constant: `FEE_BPS = 100`, `MAX_LLTV_USE = 0.9e18`.
- Mutable: only `isListed[marketId]`, set by `setListed` (L143), `onlyOwner` (`Ownable2Step`, owner = Safe).
- **No** upgradeability, no `delegatecall`, no arbitrary call, no token rescue or sweep, no function
  that takes a user address, and no owner path that reaches a position or a balance.

### 3.2 The two user functions

**`supplyCollateralAndBorrow(params, collateralAmount, borrowAssets)`** (L159-192)
1. `id = keccak256(abi.encode(params))`. The market must be listed (L165). `borrowAssets > 0`.
2. Requires `Morpho.isAuthorized(msg.sender, helper)` (L167). This check is for a clear error message; Morpho enforces it anyway.
3. If `collateralAmount > 0`: `transferFrom(msg.sender → helper)`, measures the balance delta and requires it to equal the amount,
   `forceApprove(Morpho, amount)`, then `Morpho.supplyCollateral(params, amount, onBehalf = msg.sender, "")`.
4. `Morpho.borrow(params, borrowAssets, 0, onBehalf = msg.sender, receiver = helper)`, and measures the balance delta.
5. `_requireHeadroom(msg.sender)`: after the borrow, debt ≤ `collateral × price / 1e36 × lltv × 0.9`.
6. `fee = borrowed × 100 / 10_000` (rounds down) goes to `FEE_RECIPIENT`, and `borrowed − fee` goes to `msg.sender`.

**`repayAndWithdraw(params, repayAssets, collateralOut)`** (L205-246). No fee. **No listing check**, by design.
- If `repayAssets > 0`: `accrueInterest`, read the position, and compute `owed = toAssetsUp(borrowShares)`
  exactly as Morpho does.
  - No debt: skip.
  - `repayAssets >= owed` (use `type(uint256).max` for "all"): pull exactly `owed` from `msg.sender` and
    `repay(shares = borrowShares, onBehalf = msg.sender)`, so the position closes with no leftover shares.
  - Otherwise: pull `repayAssets` and `repay(assets = repayAssets, onBehalf = msg.sender)`.
  - The allowance to Morpho is reset to 0.
- If `collateralOut > 0`: withdraw `min(collateralOut, posted)` via
  `withdrawCollateral(onBehalf = msg.sender, receiver = msg.sender)`, then `_requireHeadroom`. That check
  returns early with **no oracle read** when there is no debt (L265).

### 3.3 The invariants we believe hold. Try to break them.

- **I-1 (the load-bearing one):** every Morpho call has `onBehalf == msg.sender`. Every `transferFrom` has
  `from == msg.sender`. Every withdrawal of collateral pays `msg.sender`. The only transfers out of the
  helper go to `msg.sender` or the immutable `FEE_RECIPIENT`.
- **I-2:** the helper holds no tokens and no Morpho position between transactions. The test suite asserts this after every path.
- **I-3:** for any borrow, the user receives `borrowed − floor(borrowed/100)` and the Safe receives `floor(borrowed/100)`.
  The user's Morpho debt is `borrowed` (plus Morpho's round-up on shares).
- **I-4:** a borrow, or a collateral withdrawal that leaves debt, never leaves the position above 90% of the market's LLTV,
  measured the same way Morpho's `_isHealthy` does (`reference/morpho-blue__Morpho.sol` L527-539).
- **I-5:** delisting a market never prevents repaying or withdrawing from it.
- **I-6:** the owner cannot move, lock or redirect any user's funds or position.

---

## 4. ATTACK THESE HARDEST

### Q1: Can the helper ever act for anyone other than the caller?
A user who has run `setAuthorization(helper, true)` has handed the helper **all-market** power over
their Morpho account. Morpho lets an authorized address borrow against **any** of the user's positions, withdraw
**any** of their collateral, and withdraw their supply, all to any receiver (`reference/morpho-blue__Morpho.sol`
L212, L247, L331, L467). So:
- Is there **any** input to either function, **from any caller including the owner**, that makes the helper
  call Morpho with an `onBehalf` or receiver that is not `msg.sender`?
- Can a stranger borrow against an authorized user's position? Can they withdraw an authorized user's collateral, or
  make the helper call `withdraw` (the supply-side function, which the helper never calls)?
- Can a caller make the helper act inside a *different* market than the one `params` describes? Consider how
  `id = keccak256(abi.encode(params))` (calldata struct) compares with Morpho's `MarketParamsLib.id`
  (assembly `keccak256` over 5 words of memory). Is there any encoding where they diverge?
- Reentrancy: can a collateral token (listed by the owner) or a Morpho path call back into the helper
  mid-call so that the `msg.sender` context is wrong? Both mutators are `nonReentrant`. Morpho callbacks are not
  triggered because `data` is always empty. Check that claim.

### Q2: Can it steal or misroute funds?
- The fee split (L180-189): both amounts are measured by balance delta. Can a donation to the helper, a
  pre-existing balance, or a loan token that is also a collateral token distort `borrowed`, `fee`
  or `received`? Can the user be paid less than `borrowed − fee`? Can the Safe be paid more?
- Collateral accounting (L171-176): can more be pulled than supplied, or supplied for someone else?
- Allowances: can a leftover allowance from the helper to Morpho be spent by anyone? (Collateral is approved for the exact amount;
  the loan token is reset to 0.) Users will approve the helper for USDC and stock, often for unlimited amounts.
  Can **anyone** make the helper spend a user's approval other than that user?
- Repay-all (L222-226): is `owed` guaranteed to equal what Morpho pulls for `repay(shares = borrowShares)`
  in the same transaction? Could it pull more from the user than it repays?

### Q3: Is the broad Morpho authorization safe to ask users for?
- Given I-1, what is the worst a **malicious owner** (compromised Safe) can do? We believe it can only list
  a market for *new* borrowing, which could be a market with a hostile oracle. That hurts only users who then choose to
  borrow in that specific market. Is that right, or can listing affect existing positions?
- The authorization **stays in place** after the user is done unless they revoke it. With no upgrade path, is a lingering
  authorization to this bytecode harmless? Is there anything the helper can be made to do later that it can't do now?
- Is there any interaction with `Morpho.setAuthorizationWithSig` or nonces that the helper exposes?

### Q4: The 90% guard (L184, L241, L255-270)
- Does `borrowLimit` round the same way as Morpho's `maxBorrow`, or conservatively? Note that the helper divides in a
  different order (`a*p/1e36*lltv/1e18*0.9e18/1e18` vs `mulDivDown(a,p,1e36).wMulDown(lltv)`).
- Overflow: `collateral * price` with an 18-decimal collateral and a high price. Can realistic values revert the check?
  Could a revert here lock a user out of repaying? (Repaying never calls it. Withdrawing with debt does.)
- Can the guard be bypassed **through the helper**, for example by borrowing with `collateralAmount = 0` after
  withdrawing, or through ordering inside `repayAndWithdraw`? (Bypassing it **directly on Morpho** is expected and
  fine: it is a UX guard, not a protocol rule.)
- B20 stock feeds hold the last close over weekends and freeze during corporate actions. Does anything in the helper
  become unsafe, rather than merely unavailable, when a feed is stale or frozen?

### Q5: Denial of service and user lock-in
- Can anyone stop a user from repaying, or from withdrawing their collateral after full repayment? Consider
  delisting, a paused or policy-blocked B20, a reverting oracle, and USDC blacklisting of the helper or the Safe.
- `FEE_RECIPIENT` is immutable. If USDC blacklisted the Safe, borrowing would revert. Confirm that repaying and
  withdrawing are unaffected.

---

## 5. The vault deploy bundle

Files: `vault/safecalls-morpho-vault.json` (Safe Transaction Builder format, 22 calls, all from the Safe
`0xe1096B727499a3f70FaD8bc0267F5e69d01373C7`), `vault/vault-bundle.cjs` (the generator and simulation),
`vault/vault-bundle.out.txt` (the decoded calls and simulated result), and `vault/MorphoVaultRehearsal.t.sol` (forge fork tests).
The vault is Morpho's code. **What you are reviewing is our configuration of it.**

**Please decode the calldata in the JSON yourself** rather than trusting the labels in `vault-bundle.out.txt`.

| # | call | intent |
|---|---|---|
| 1 | `factory.createMetaMorpho(Safe, 0, USDC, "Chipworks USDC", "cwUSDC", bytes32("chipworks-usdc-1"))` | CREATE2 → `0x6B0EF5dd1cED6E26c384E4CcAf72f9dC0A1093d6` |
| 2-3 | `setFeeRecipient(Safe)`, `setFee(0.15e18)` | 15% of interest to the Safe |
| 4-19 | `submitCap` + `acceptCap` ×8 | AAPLc 62.5%, GOOGLc 77%, NVDAc 62.5%, METAc 62.5% at 2,000 USDC each; cbBTC 86%, USDe 91.5%, WETH 86%, cbXRP 62.5% at 5,000,000 each |
| 20 | `setSupplyQueue([AAPL, GOOGL, NVDA, META, cbBTC, USDe, WETH, cbXRP])` | deposits fill the thin stock markets first, up to their caps |
| 21 | `updateWithdrawQueue([4,5,6,7,0,1,2,3])` | withdrawals come from the deep markets first, so they don't drain stock-market liquidity |
| 22 | `submitTimelock(86400)` | 1 day. Raising the timelock applies immediately |

**Questions for the vault:**
- **V1. Timelock 0 at creation.** It exists so that caps can be accepted in the same transaction. Since calls 1-22 run in one Safe
  `MultiSend`, is there any block in which the vault exists with timelock 0? Is there any
  reason not to create it directly with a 1-day timelock and accept caps a day later?
- **V2. CREATE2 pre-emption.** Anyone can call `createMetaMorpho` with identical arguments first. We believe that only makes our
  bundle revert, because the pre-created vault is owned by the Safe, unconfigured and empty. Is there a way to turn a
  pre-created vault into harm, for example deposits arriving before configuration, or a share-inflation setup?
- **V3. Roles.** There is no curator, allocator or guardian; the Safe as owner holds all of those roles. With no guardian, nothing can veto a
  pending owner action. Is a 1-day timelock without a guardian adequate for a public vault?
- **V4. Queue indexes.** `updateWithdrawQueue` takes indexes into the *current* queue, which `_setCap` builds in acceptance
  order. Confirm that `[4,5,6,7,0,1,2,3]` yields cbBTC, USDe, WETH, cbXRP, AAPL, GOOGL, NVDA, META. (The simulation reads it back by
  id. Our own forge rehearsal got this wrong once, because it accepts caps in a different order.)
- **V5. Market risk the caps accept.** Stock collateral in thin markets ($0.5k-$2.2k free liquidity today) at 90% utilisation. GOOGL at a
  77% LLTV on an equity that can gap overnight. The non-factory USDe oracle. Stock feeds freezing during corporate actions. Could bad debt in a
  stock market reach depositors beyond that market's 2,000 cap? Are the caps and LLTVs defensible?
- **V6. Share inflation / first depositor.** MetaMorpho V1.1 uses a decimals offset. Is a seed deposit still advisable for a
  6-decimal USDC vault?

---

## 6. Known and accepted. Challenge these if you disagree.

- **K-1.** There is no rescue function. Tokens sent directly to the helper are stuck forever. This is deliberate: there is no owner path to balances.
- **K-2.** The owner can list a market with a hostile oracle. Only users who borrow in that market through the helper are exposed.
- **K-3.** The fee rounds down. Borrows under 100 base units (0.0001 USDC) pay no fee.
- **K-4.** The 90% guard applies only through the helper. A user can go to 100% of LLTV directly on Morpho.
- **K-5.** A partial repay (`repayAssets < owed`) is not guarded, because repaying only improves health.
- **K-6.** Supplying collateral without borrowing is not offered (`borrowAssets == 0` reverts). Users can do that on Morpho directly.
- **K-7.** The helper checks `isAuthorized` for borrowing but not for withdrawing collateral. Morpho enforces both.
- **K-8.** `TooCloseToLiquidation(borrowed, limit)`: the first argument is the total debt, not the amount just borrowed.
- **K-9.** The helper briefly holds the user's stock and USDC within a call. Whether B20 transfer policies allow the helper
  to hold stock was checked with real holders of all four stocks under `eth_simulateV1` (`borrow-helper-sim.out.txt`).

---

## 7. What has already been run

- `ChipBorrowHelper.t.sol`: **11 forge tests on a live Base fork** against the real Morpho and the real cbBTC/USDC market
  (cbBTC stands in for stocks, because B20s cannot execute in forge). They cover the 99/1 split; repay-all closing to exactly zero shares with no exit fee;
  partial repay then top-up; refusal without authorization; refusal on unlisted markets with exit still open; the 90% line on
  borrowing and on withdrawing; debt-free withdrawal with the oracle mocked to revert; owner-only listing; and a stranger unable to touch
  an authorized user's position.
- `borrow-helper-sim.cjs`: **`eth_simulateV1` on a real Base node** with a real holder of each of AAPLc, GOOGLc, NVDAc and METAc.
  Each one posts through the helper, borrows, the Safe receives exactly 1%, and after 7 days the holder repays all and withdraws all:
  position `[0,0,0]`, every unit of stock returned, helper empty. `problems: []`.
- `MorphoVaultRehearsal.t.sol`: **8 forge fork tests**. Ownership and fee; caps; a deposit reaching the stock markets; a partial withdrawal
  leaving stock liquidity untouched; a full year's cycle with the Safe redeeming its fee to USDC (14.99% of gross interest); and the
  timelock raise followed by caps waiting.
- `vault-bundle.cjs`: the exact 22-call bundle **simulated from the Safe** on a real node. Every setting is read back. Then a 50,000 deposit,
  a 10,000 withdrawal that leaves stock supply untouched, a full exit 30 days later, and the Safe's fee redeemed (15.00%). `problems: []`.
- The repo's 819 non-fork tests passed at `d0193e5`. Since then only `ChipBorrowHelper`, which none of them import, has changed.

Tests passing isn't evidence of safety. They only check the properties we thought to write down, and the most
useful findings are usually the properties we didn't think of.

---

## 8. How to report

For each finding: **severity** (Critical / High / Medium / Low / Info), **file and line**, **the concrete
sequence of calls** that demonstrates it (who calls what, with what arguments, and what state results), and a **suggested fix**.
If you believe an invariant in §3.3 is false, say which one. If you examined Q1-Q5 or V1-V6 and found
nothing, **say so explicitly for each**. "No finding on Q1" is a result we need, and silence is not.
