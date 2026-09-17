// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

interface IMorphoBlue {
    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes memory data)
        external;
    function withdrawCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, address receiver)
        external;
    function borrow(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external
        returns (uint256 assetsBorrowed, uint256 sharesBorrowed);
    function repay(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external
        returns (uint256 assetsRepaid, uint256 sharesRepaid);
    function accrueInterest(MarketParams memory marketParams) external;
    function isAuthorized(address authorizer, address authorized) external view returns (bool);
    function position(bytes32 id, address user)
        external
        view
        returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);
    function market(bytes32 id)
        external
        view
        returns (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        );
}

interface IMorphoOracle {
    function price() external view returns (uint256);
}

/**
 * BORROW USDC AGAINST A TOKENIZED STOCK, ON MORPHO, IN ONE CALL - FOR 1%.
 *
 * -- THE POSITION IS THE USER'S, NOT OURS ---------------------------------
 *
 * Every Morpho call here names `onBehalf = msg.sender`. The collateral and the debt
 * sit in the user's OWN Morpho position, exactly as if they had gone to the Morpho
 * app themselves. They can repay, top up or withdraw there directly, with or without
 * this contract, forever. If this contract vanished nothing would be stuck.
 *
 * That is why the user has to call `Morpho.setAuthorization(helper, true)` once:
 * Morpho only lets a third party borrow against a position its owner authorised.
 *
 * -- AN AUTHORISATION IS A LOADED GUN, SO THIS CONTRACT CANNOT AIM IT ------
 *
 * Morpho authorisation is ALL-MARKET: an authorised address may borrow against, and
 * withdraw collateral from, every position the user has. So the one invariant this
 * contract exists to keep is that it only ever acts for the CALLER. There is no
 * function taking a user address, no owner path that touches positions, no upgrade,
 * no arbitrary call. The owner can do exactly two things: choose which markets are
 * offered for NEW borrowing (and only markets lending LOAN_TOKEN), and hand ownership on.
 * The fee, its recipient and the loan token are immutable.
 *
 * -- THE FEE ---------------------------------------------------------------
 *
 * 1% of what is borrowed, taken once, at origination, sent straight to FEE_RECIPIENT.
 * The debt is the full amount: borrow 1,000 and 990 arrives, 1,000 is owed. Repaying
 * and withdrawing through here is free.
 *
 * -- WHY IT REFUSES TO BORROW RIGHT UP TO THE LIMIT ------------------------
 *
 * Morpho will let a position be opened at exactly its LLTV, and liquidate it on the
 * next tick. Stock feeds hold Friday's close all weekend and gap on Monday's open. So
 * a borrow through here - and a collateral withdrawal through here that leaves debt
 * behind - must leave the position at or under MAX_LLTV_USE of the market's LLTV:
 * 90%, which is 56.25% LTV on a 62.5% stock market. A position with no debt is never
 * checked, so closing out never depends on an oracle. A user who wants
 * to go further can do it on Morpho directly; this contract will not be the screen
 * that walked them into a liquidation.
 *
 * -- NOTHING IS HELD BETWEEN TRANSACTIONS ----------------------------------
 *
 * Collateral passes through for the length of one call (Morpho pulls it from
 * msg.sender, so it must be here to be supplied); USDC likewise. Every path ends with
 * this contract holding what it started with.
 */
contract ChipBorrowHelper is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IMorphoBlue public immutable MORPHO;
    /// @notice The only loan token any listed market may use (USDC). Immutable, so a fee-on-transfer
    ///         or otherwise non-standard loan token can never be listed (audit round 1, Grok M-01/M-02).
    address public immutable LOAN_TOKEN;
    /// @notice Where the 1% goes. Immutable: nobody can redirect it after deployment.
    address public immutable FEE_RECIPIENT;

    uint256 public constant FEE_BPS = 100; // 1%
    uint256 public constant MAX_LLTV_USE = 0.9e18; // borrow to at most 90% of the market's LLTV

    uint256 internal constant WAD = 1e18;
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    /// @notice Markets offered for new borrowing. Repaying and withdrawing ignore this,
    ///         so delisting a market can never trap anyone in it.
    mapping(bytes32 id => bool) public isListed;

    event MarketListed(bytes32 indexed id, MarketParams params, bool listed);
    event Borrowed(
        address indexed user,
        bytes32 indexed id,
        uint256 collateralAdded,
        uint256 borrowed,
        uint256 fee,
        uint256 received
    );
    event Repaid(address indexed user, bytes32 indexed id, uint256 repaid, uint256 collateralWithdrawn);

    error MarketNotListed(bytes32 id);
    error NotAuthorized();
    error NothingToDo();
    error TooCloseToLiquidation(uint256 borrowed, uint256 limit);
    error CollateralAccountingMismatch(uint256 expected, uint256 received);
    error ZeroAddress();
    error WrongLoanToken(address loanToken);
    error LltvTooHigh(uint256 lltv);
    error LoanAccountingMismatch(uint256 expected, uint256 received);

    constructor(address morpho, address loanToken, address feeRecipient, address initialOwner) Ownable(initialOwner) {
        if (morpho == address(0) || loanToken == address(0) || feeRecipient == address(0)) revert ZeroAddress();
        MORPHO = IMorphoBlue(morpho);
        LOAN_TOKEN = loanToken;
        FEE_RECIPIENT = feeRecipient;
    }

    // ---------------------------------------------------------------- owner

    function setListed(MarketParams calldata params, bool listed) external onlyOwner {
        if (params.loanToken != LOAN_TOKEN) revert WrongLoanToken(params.loanToken);
        // Morpho's own rule (enableLltv requires lltv < WAD), so no listing can overflow
        // lltv * MAX_LLTV_USE in borrowLimit. (Audit round 2, Grok.)
        if (params.lltv >= WAD) revert LltvTooHigh(params.lltv);
        bytes32 id = marketId(params);
        isListed[id] = listed;
        emit MarketListed(id, params, listed);
    }

    // ---------------------------------------------------------------- borrow

    /**
     * Post `collateralAmount` of the market's collateral (0 to borrow against what is
     * already posted) and borrow `borrowAssets` of the loan token. The caller receives
     * borrowAssets minus the 1% fee and owes borrowAssets.
     *
     * Needs: Morpho.setAuthorization(this, true), and an approval of the collateral
     * token to this contract when collateralAmount > 0.
     */
    function supplyCollateralAndBorrow(MarketParams calldata params, uint256 collateralAmount, uint256 borrowAssets)
        external
        nonReentrant
        returns (uint256 received)
    {
        bytes32 id = marketId(params);
        if (!isListed[id]) revert MarketNotListed(id);
        if (borrowAssets == 0) revert NothingToDo();
        if (!MORPHO.isAuthorized(msg.sender, address(this))) revert NotAuthorized();

        if (collateralAmount > 0) {
            IERC20 collateral = IERC20(params.collateralToken);
            uint256 before = collateral.balanceOf(address(this));
            collateral.safeTransferFrom(msg.sender, address(this), collateralAmount);
            uint256 got = collateral.balanceOf(address(this)) - before;
            if (got != collateralAmount) revert CollateralAccountingMismatch(collateralAmount, got);
            collateral.forceApprove(address(MORPHO), collateralAmount);
            MORPHO.supplyCollateral(params, collateralAmount, msg.sender, "");
        }

        IERC20 loan = IERC20(params.loanToken);
        uint256 loanBefore = loan.balanceOf(address(this));
        MORPHO.borrow(params, borrowAssets, 0, msg.sender, address(this));
        uint256 borrowed = loan.balanceOf(address(this)) - loanBefore;
        // Morpho booked borrowAssets of debt; anything less arriving would charge the user for money
        // they never received. Unreachable with USDC, enforced anyway (audit round 1, Grok M-01).
        if (borrowed != borrowAssets) revert LoanAccountingMismatch(borrowAssets, borrowed);

        _requireHeadroom(params, id, msg.sender);

        uint256 fee = borrowed * FEE_BPS / 10_000;
        received = borrowed - fee;
        if (fee > 0) loan.safeTransfer(FEE_RECIPIENT, fee);
        loan.safeTransfer(msg.sender, received);

        emit Borrowed(msg.sender, id, collateralAmount, borrowed, fee, received);
    }

    // ---------------------------------------------------------------- repay

    /**
     * Repay `repayAssets` of the caller's debt (type(uint256).max repays ALL of it,
     * to the last share, pulling exactly what that costs), then return
     * `collateralOut` of collateral to the caller (type(uint256).max returns all of it).
     * No fee. Works on delisted markets.
     *
     * Needs: an approval of the loan token to this contract when repaying, and
     * Morpho.setAuthorization(this, true) when withdrawing collateral.
     */
    function repayAndWithdraw(MarketParams calldata params, uint256 repayAssets, uint256 collateralOut)
        external
        nonReentrant
        returns (uint256 repaid, uint256 withdrawn)
    {
        if (repayAssets == 0 && collateralOut == 0) revert NothingToDo();
        bytes32 id = marketId(params);

        if (repayAssets > 0) {
            MORPHO.accrueInterest(params);
            (, uint256 borrowShares,) = MORPHO.position(id, msg.sender);
            (,, uint256 totalBorrowAssets, uint256 totalBorrowShares,,) = MORPHO.market(id);
            uint256 owed = _toAssetsUp(borrowShares, totalBorrowAssets, totalBorrowShares);

            IERC20 loan = IERC20(params.loanToken);
            if (borrowShares == 0) {
                // Nothing owed: "repay all, then withdraw" on a clean position is just a withdraw.
            } else if (repayAssets >= owed) {
                // By shares, so the position closes exactly: repaying by assets leaves dust.
                loan.safeTransferFrom(msg.sender, address(this), owed);
                loan.forceApprove(address(MORPHO), owed);
                (repaid,) = MORPHO.repay(params, 0, borrowShares, msg.sender, "");
            } else {
                loan.safeTransferFrom(msg.sender, address(this), repayAssets);
                loan.forceApprove(address(MORPHO), repayAssets);
                (repaid,) = MORPHO.repay(params, repayAssets, 0, msg.sender, "");
            }
            loan.forceApprove(address(MORPHO), 0);
        }

        if (collateralOut > 0) {
            if (!MORPHO.isAuthorized(msg.sender, address(this))) revert NotAuthorized();
            (,, uint256 collateral) = MORPHO.position(id, msg.sender);
            withdrawn = collateralOut > collateral ? collateral : collateralOut;
            if (withdrawn > 0) {
                MORPHO.withdrawCollateral(params, withdrawn, msg.sender, msg.sender);
                // Same line as borrowing: taking collateral out may not leave a debt past 90% of LLTV.
                _requireHeadroom(params, id, msg.sender);
            }
        }

        emit Repaid(msg.sender, id, repaid, withdrawn);
    }

    // ---------------------------------------------------------------- views

    function marketId(MarketParams calldata params) public pure returns (bytes32) {
        return keccak256(abi.encode(params));
    }

    /// @notice The most a position may owe after borrowing through here, in loan-token base units:
    ///         floor(collateral * price * (lltv * MAX_LLTV_USE / WAD) / (ORACLE_PRICE_SCALE * WAD)).
    ///         That is collateral valued at the oracle price (price is scaled by 1e36), times the
    ///         market's LLTV (1e18-scaled), times 90% (1e18-scaled), rounded down once at the end.
    ///         The inner lltv * MAX_LLTV_USE / WAD is exact for every LLTV Morpho has enabled (all are
    ///         multiples of 10 wei); an LLTV that were not would round the limit down, never up.
    /// @dev    AUDIT ROUND 1, Bankr M-01. The original divided three times, losing up to 3 base units
    ///         (0.000003 USDC), which made a borrow within a unit of the line falsely revert. The fix
    ///         as proposed - multiply all four factors, then divide - overflows uint256 once collateral
    ///         is worth ~$0.15-$0.21 at live prices, bricking every real borrow. So: one division, in
    ///         OpenZeppelin's 512-bit mulDiv. Listed LLTVs are < WAD (setListed), so the inner factor is
    ///         < 0.9e18 and price * it fits 256 bits for any price below ~1.2e59 (live max ~7.6e38).
    function borrowLimit(MarketParams calldata params, uint256 collateral) public view returns (uint256) {
        uint256 price = IMorphoOracle(params.oracle).price();
        return Math.mulDiv(collateral, price * (params.lltv * MAX_LLTV_USE / WAD), ORACLE_PRICE_SCALE * WAD);
    }

    // ---------------------------------------------------------------- internal

    function _requireHeadroom(MarketParams calldata params, bytes32 id, address user) internal view {
        (, uint256 borrowShares, uint256 collateral) = MORPHO.position(id, user);
        // No debt, nothing to protect - and no oracle read, so a debt-free exit never depends on a feed.
        if (borrowShares == 0) return;
        (,, uint256 totalBorrowAssets, uint256 totalBorrowShares,,) = MORPHO.market(id);
        uint256 debt = _toAssetsUp(borrowShares, totalBorrowAssets, totalBorrowShares);
        uint256 limit = borrowLimit(params, collateral);
        if (debt > limit) revert TooCloseToLiquidation(debt, limit);
    }

    /// @dev Morpho's SharesMathLib.toAssetsUp, so "owed" here equals what Morpho charges.
    function _toAssetsUp(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        uint256 num = shares * (totalAssets + VIRTUAL_ASSETS);
        uint256 den = totalShares + VIRTUAL_SHARES;
        return (num + den - 1) / den;
    }
}
