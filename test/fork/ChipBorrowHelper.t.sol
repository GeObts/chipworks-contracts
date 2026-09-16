// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ChipBorrowHelper, MarketParams, IMorphoBlue} from "../../src/morpho/ChipBorrowHelper.sol";

interface IMorphoAuth {
    function setAuthorization(address authorized, bool newIsAuthorized) external;
}

/**
 * THE BORROW HELPER, AGAINST THE LIVE MORPHO SINGLETON.
 *
 * The stock markets cannot be exercised here: B20 stocks are node precompiles that
 * do not execute in a forge fork (test/fork/B20Probe.t.sol). The helper is
 * collateral-agnostic, so every rule is proven on the live cbBTC/USDC market, and
 * the B20 leg - including whether a stock's transfer policy lets the helper hold it
 * for one call - is proven separately under eth_simulateV1 by
 * tools/claim-day/borrow-helper-sim.cjs.
 */
contract ChipBorrowHelperForkTest is Test {
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant SAFE = 0xe1096B727499a3f70FaD8bc0267F5e69d01373C7;
    address constant IRM = 0x46415998764C29aB2a25CbeA6254146D50D22687;

    ChipBorrowHelper helper;
    MarketParams p;
    bytes32 id;

    address user = makeAddr("user");
    address stranger = makeAddr("stranger");

    uint256 constant COLLATERAL = 1e8; // 1 cbBTC

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        p = MarketParams({
            loanToken: USDC,
            collateralToken: CBBTC,
            oracle: 0x663BECd10daE6C4A3Dcd89F1d76c1174199639B9,
            irm: IRM,
            lltv: 0.86e18
        });
        helper = new ChipBorrowHelper(MORPHO, SAFE, SAFE);
        id = helper.marketId(p);
        vm.prank(SAFE);
        helper.setListed(p, true);

        _fundCollateral(user, COLLATERAL);
    }

    function _fundCollateral(address who, uint256 amount) internal {
        // Morpho holds every cbBTC borrower's collateral: the deepest honest source there is.
        vm.prank(MORPHO);
        IERC20(CBBTC).transfer(who, amount);
    }

    function _authorizeAndApprove(address who) internal {
        vm.startPrank(who);
        IMorphoAuth(MORPHO).setAuthorization(address(helper), true);
        IERC20(CBBTC).approve(address(helper), type(uint256).max);
        IERC20(USDC).approve(address(helper), type(uint256).max);
        vm.stopPrank();
    }

    function _assertHelperEmpty() internal view {
        assertEq(IERC20(USDC).balanceOf(address(helper)), 0, "helper kept USDC");
        assertEq(IERC20(CBBTC).balanceOf(address(helper)), 0, "helper kept collateral");
        (uint256 s, uint128 b, uint128 c) = IMorphoBlue(MORPHO).position(id, address(helper));
        assertEq(s + b + c, 0, "helper has a Morpho position of its own");
    }

    // ---- the headline path -----------------------------------------------

    function test_borrow_positionIsTheUsers_safeGetsOnePercent() public {
        _authorizeAndApprove(user);
        uint256 amount = helper.borrowLimit(p, COLLATERAL) / 2;
        uint256 safeBefore = IERC20(USDC).balanceOf(SAFE);

        vm.prank(user);
        uint256 received = helper.supplyCollateralAndBorrow(p, COLLATERAL, amount);

        uint256 fee = amount / 100;
        assertEq(received, amount - fee, "user gets 99%");
        assertEq(IERC20(USDC).balanceOf(user), amount - fee, "USDC reached the user");
        assertEq(IERC20(USDC).balanceOf(SAFE) - safeBefore, fee, "1% reached the Safe");

        (, uint128 borrowShares, uint128 collateral) = IMorphoBlue(MORPHO).position(id, user);
        assertEq(collateral, COLLATERAL, "collateral sits in the USER's Morpho position");
        assertGt(borrowShares, 0, "debt sits in the USER's Morpho position");
        _assertHelperEmpty();

        emit log_named_decimal_uint("borrowed (USDC)", amount, 6);
        emit log_named_decimal_uint("to user (USDC)", received, 6);
        emit log_named_decimal_uint("to Safe (USDC)", fee, 6);
    }

    function test_repayAll_andWithdrawAll_closesThePositionExactly_noFee() public {
        _authorizeAndApprove(user);
        uint256 amount = helper.borrowLimit(p, COLLATERAL) / 2;
        vm.prank(user);
        helper.supplyCollateralAndBorrow(p, COLLATERAL, amount);

        skip(30 days);
        deal(USDC, user, amount * 2); // the 99% they got is short of principal + interest
        uint256 safeBefore = IERC20(USDC).balanceOf(SAFE);
        uint256 usdcBefore = IERC20(USDC).balanceOf(user);

        vm.prank(user);
        (uint256 repaid, uint256 withdrawn) = helper.repayAndWithdraw(p, type(uint256).max, type(uint256).max);

        (uint256 s, uint128 b, uint128 c) = IMorphoBlue(MORPHO).position(id, user);
        assertEq(s + b + c, 0, "position fully closed, not a share of dust left");
        assertEq(withdrawn, COLLATERAL, "all collateral back");
        assertEq(IERC20(CBBTC).balanceOf(user), COLLATERAL, "collateral reached the user");
        assertGt(repaid, amount, "30 days of interest was paid");
        assertEq(usdcBefore - IERC20(USDC).balanceOf(user), repaid, "pulled exactly what was owed");
        assertEq(IERC20(USDC).balanceOf(SAFE), safeBefore, "no fee on the way out");
        assertEq(IERC20(USDC).allowance(address(helper), MORPHO), 0, "no allowance left behind");
        _assertHelperEmpty();
        emit log_named_decimal_uint("repaid after 30 days (USDC)", repaid, 6);
    }

    function test_partialRepay_thenBorrowAgainstPostedCollateral() public {
        _authorizeAndApprove(user);
        uint256 limit = helper.borrowLimit(p, COLLATERAL);
        vm.prank(user);
        helper.supplyCollateralAndBorrow(p, COLLATERAL, limit / 4);

        vm.prank(user);
        helper.repayAndWithdraw(p, limit / 8, 0);

        // Top up the loan with no new collateral.
        vm.prank(user);
        helper.supplyCollateralAndBorrow(p, 0, limit / 4);
        (, uint128 b, uint128 c) = IMorphoBlue(MORPHO).position(id, user);
        assertGt(b, 0);
        assertEq(c, COLLATERAL);
        _assertHelperEmpty();
    }

    // ---- the refusals -----------------------------------------------------

    function test_refusesWithoutMorphoAuthorization() public {
        vm.startPrank(user);
        IERC20(CBBTC).approve(address(helper), type(uint256).max);
        vm.expectRevert(ChipBorrowHelper.NotAuthorized.selector);
        helper.supplyCollateralAndBorrow(p, COLLATERAL, 1_000e6);
        vm.stopPrank();
    }

    function test_refusesAnUnlistedMarket_butStillLetsYouLeaveIt() public {
        _authorizeAndApprove(user);
        uint256 amount = helper.borrowLimit(p, COLLATERAL) / 2;
        vm.prank(user);
        helper.supplyCollateralAndBorrow(p, COLLATERAL, amount);

        vm.prank(SAFE);
        helper.setListed(p, false);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ChipBorrowHelper.MarketNotListed.selector, id));
        helper.supplyCollateralAndBorrow(p, 0, 1e6);

        deal(USDC, user, amount * 2);
        vm.prank(user);
        helper.repayAndWithdraw(p, type(uint256).max, type(uint256).max);
        (uint256 s, uint128 b, uint128 c) = IMorphoBlue(MORPHO).position(id, user);
        assertEq(s + b + c, 0, "a delisted market must never trap a borrower");
    }

    function test_refusesToBorrowPastNinetyPercentOfLltv() public {
        _authorizeAndApprove(user);
        uint256 limit = helper.borrowLimit(p, COLLATERAL);

        vm.prank(user);
        vm.expectRevert(); // TooCloseToLiquidation(debt, limit)
        helper.supplyCollateralAndBorrow(p, COLLATERAL, limit + 2);

        // Just under the line is fine. (-2 absorbs Morpho's round-up on borrow shares.)
        vm.prank(user);
        helper.supplyCollateralAndBorrow(p, COLLATERAL, limit - 2);
    }

    function test_onlyTheOwnerListsMarkets() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        helper.setListed(p, true);
    }

    /**
     * THE ONE THAT MATTERS. The user has authorised the helper on Morpho, which is an
     * all-market grant. A stranger calling the helper must not be able to reach that
     * position in any way: every call acts for msg.sender and nobody else.
     */
    function test_aStrangerCannotTouchAnAuthorisedUsersPosition() public {
        _authorizeAndApprove(user);
        uint256 amount = helper.borrowLimit(p, COLLATERAL) / 2;
        vm.prank(user);
        helper.supplyCollateralAndBorrow(p, COLLATERAL, amount);
        (, uint128 b0, uint128 c0) = IMorphoBlue(MORPHO).position(id, user);

        // Borrow: acts on the stranger's own (unauthorised, empty) position.
        vm.prank(stranger);
        vm.expectRevert(ChipBorrowHelper.NotAuthorized.selector);
        helper.supplyCollateralAndBorrow(p, 0, 1_000e6);

        // Even authorised, the stranger's own position has nothing to borrow against.
        vm.startPrank(stranger);
        IMorphoAuth(MORPHO).setAuthorization(address(helper), true);
        vm.expectRevert();
        helper.supplyCollateralAndBorrow(p, 0, 1_000e6);

        // Withdraw-all: withdraws the stranger's zero, not the user's cbBTC.
        (, uint256 w) = helper.repayAndWithdraw(p, 0, type(uint256).max);
        vm.stopPrank();
        assertEq(w, 0);

        (, uint128 b1, uint128 c1) = IMorphoBlue(MORPHO).position(id, user);
        assertEq(c1, c0, "user's collateral untouched");
        assertGe(b1, b0, "user's debt untouched");
        assertEq(IERC20(CBBTC).balanceOf(stranger), 0);
        _assertHelperEmpty();
    }

    function test_feeAndRecipientAreFixed() public view {
        assertEq(helper.FEE_BPS(), 100);
        assertEq(helper.FEE_RECIPIENT(), SAFE);
        assertEq(helper.owner(), SAFE);
    }
}
