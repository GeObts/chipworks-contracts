// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// BANKR'S M-01 FIX APPLIED VERBATIM - the only change is borrowLimit's return line.
// Test-only. Byte-for-byte the ChipBorrowHelper contract body at commit a0d533d, except where noted.

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MarketParams, IMorphoBlue, IMorphoOracle} from "../../../src/morpho/ChipBorrowHelper.sol";

contract ChipBorrowHelperBankrLiteral is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IMorphoBlue public immutable MORPHO;
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

    constructor(address morpho, address feeRecipient, address initialOwner) Ownable(initialOwner) {
        if (morpho == address(0) || feeRecipient == address(0)) revert ZeroAddress();
        MORPHO = IMorphoBlue(morpho);
        FEE_RECIPIENT = feeRecipient;
    }

    // ---------------------------------------------------------------- owner

    function setListed(MarketParams calldata params, bool listed) external onlyOwner {
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

    /// @notice The most a position may owe after borrowing through here.
    function borrowLimit(MarketParams calldata params, uint256 collateral) public view returns (uint256) {
        uint256 price = IMorphoOracle(params.oracle).price();
        return (collateral * price * params.lltv * MAX_LLTV_USE) / (ORACLE_PRICE_SCALE * WAD * WAD); // Bankr M-01 fix, verbatim
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
