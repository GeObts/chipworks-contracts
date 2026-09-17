// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, stdError} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ChipBorrowHelper, MarketParams, IMorphoBlue, IMorphoOracle} from "../../../src/morpho/ChipBorrowHelper.sol";
import {ChipBorrowHelperPreM01} from "./ChipBorrowHelperPreM01.sol";
import {ChipBorrowHelperBankrLiteral} from "./ChipBorrowHelperBankrLiteral.sol";

interface IMorphoAuthM01 {
    function setAuthorization(address, bool) external;
}

/**
 * AUDIT ROUND 1, FINDING M-01 (Bankr): "borrowLimit divides by 1e36 before multiplying, so small
 * collateral falsely reverts TooCloseToLiquidation." Verified here rather than taken on trust,
 * against live Base oracle prices and the live Morpho singleton, with three real bytecodes:
 *
 *   ChipBorrowHelperPreM01       the helper as audited (a0d533d)
 *   ChipBorrowHelperBankrLiteral the same, with Bankr's proposed return line pasted in verbatim
 *   ChipBorrowHelper             the fix that shipped: one division, in 512-bit mulDiv
 *
 * VERDICT: the finding is REAL but tiny (at most 3 base units, 0.000003 USDC, and only at the very
 * edge of the line). The proposed fix is NOT usable: it overflows uint256 above ~$0.15-$0.21 of
 * collateral at live prices, which would revert every real borrow.
 */
abstract contract M01Base is Test {
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant SAFE = 0xe1096B727499a3f70FaD8bc0267F5e69d01373C7;
    address constant IRM = 0x46415998764C29aB2a25CbeA6254146D50D22687;

    ChipBorrowHelperPreM01 pre;
    ChipBorrowHelperBankrLiteral bankr;
    ChipBorrowHelper fixedHelper;
    MarketParams btc;
    MarketParams[] all; // AAPLc, GOOGLc, NVDAc, METAc, cbBTC, WETH - live oracles
    string[] names;
    uint8[] decs;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        _m("AAPLc", 0xb200000000000000000000C2e324d24d7eEcd1fb, 0xEcC5c9bf18CB2CfC94C2f7EFf8BDd5837A60AB0e, 0.625e18, 8);
        _m("GOOGLc", 0xb2000000000000000000002D0BA3164cc74f58B7, 0x24DC11055aa5b2C5692E4B77d7285c4f0fd9Cf99, 0.77e18, 8);
        _m("NVDAc", 0xb20000000000000000000078ee7ce2fE4908108C, 0x4F698C04d01d9CebCDd9494c189aBdD6C5453f84, 0.625e18, 8);
        _m("METAc", 0xb2000000000000000000008bC8786B856E61707C, 0x4752B27dFc1931eb9a5DFEFC7FBC9d0af9020dC7, 0.625e18, 8);
        _m("cbBTC", CBBTC, 0x663BECd10daE6C4A3Dcd89F1d76c1174199639B9, 0.86e18, 8);
        _m("WETH", 0x4200000000000000000000000000000000000006, 0xFEa2D58cEfCb9fcb597723c6bAE66fFE4193aFE4, 0.86e18, 18);
        btc = all[4];

        pre = new ChipBorrowHelperPreM01(MORPHO, SAFE, SAFE);
        bankr = new ChipBorrowHelperBankrLiteral(MORPHO, SAFE, SAFE);
        fixedHelper = new ChipBorrowHelper(MORPHO, USDC, SAFE, SAFE);
        vm.startPrank(SAFE);
        pre.setListed(btc, true);
        bankr.setListed(btc, true);
        fixedHelper.setListed(btc, true);
        vm.stopPrank();
        IMorphoBlue(MORPHO).accrueInterest(btc); // so a borrow in this block accrues nothing more
    }

    function _m(string memory n, address col, address oracle, uint256 lltv, uint8 d) internal {
        all.push(MarketParams({loanToken: USDC, collateralToken: col, oracle: oracle, irm: IRM, lltv: lltv}));
        names.push(n);
        decs.push(d);
    }

    /// @dev The mathematically exact 90% line, floor(c * price * lltv * 0.9 / 1e54), in 512-bit
    ///      arithmetic, written differently from every helper's formula so it is an independent reference.
    function _exact(MarketParams memory p, uint256 c) internal view returns (uint256) {
        return Math.mulDiv(c, IMorphoOracle(p.oracle).price() * p.lltv * 9, 1e55);
    }

    /// @dev Collateral sizes from 1 raw unit to ~1,000 whole tokens on a stretched grid.
    function _size(uint256 i, uint8 d) internal pure returns (uint256) {
        return (i * i * i * 10 ** d) / 8_000_000 + i;
    }

    function _fund(address who, uint256 amount) internal {
        vm.prank(MORPHO);
        IERC20(CBBTC).transfer(who, amount);
    }

    function _toSharesUp(uint256 a, uint256 ta, uint256 ts) internal pure returns (uint256) {
        return Math.mulDiv(a, ts + 1e6, ta + 1, Math.Rounding.Ceil);
    }

    function _toAssetsUp(uint256 s, uint256 ta, uint256 ts) internal pure returns (uint256) {
        return Math.mulDiv(s, ta + 1, ts + 1e6, Math.Rounding.Ceil);
    }

    /// First cbBTC collateral size >= 0.01 BTC where a borrow's resulting Morpho debt lands strictly
    /// above the pre-fix limit and at or below the exact 90% line: a legitimate borrow pre-fix refuses.
    function _findFalseRevertCase() internal view returns (uint256 c, uint256 amount, uint256 preLimit, uint256 exact) {
        (,, uint256 tba, uint256 tbs,,) = IMorphoBlue(MORPHO).market(pre.marketId(btc));
        for (c = 1_000_000; c < 1_010_000; c++) {
            preLimit = pre.borrowLimit(btc, c);
            exact = _exact(btc, c);
            if (exact <= preLimit) continue;
            for (uint256 k; k < 3 && k < exact; k++) {
                amount = exact - k;
                uint256 shares = _toSharesUp(amount, tba, tbs);
                uint256 debt = _toAssetsUp(shares, tba + amount, tbs + shares);
                if (debt > preLimit && debt <= exact) return (c, amount, preLimit, exact);
            }
        }
        revert("no false-revert case in range");
    }

    function _authorize(address user, address helper, uint256 c) internal {
        vm.startPrank(user);
        IMorphoAuthM01(MORPHO).setAuthorization(helper, true);
        IERC20(CBBTC).approve(helper, c);
        vm.stopPrank();
    }
}

// ==================================================================================== BEFORE

contract M01PrecisionBeforeTest is M01Base {
    /// How big is the truncation? Swept across 2,000 sizes in each of 6 live markets.
    function test_before_truncationIsReal_atMostThreeBaseUnits() public {
        for (uint256 m; m < all.length; m++) {
            uint256 maxGap;
            uint256 differs;
            for (uint256 i = 1; i <= 2000; i++) {
                uint256 c = _size(i, decs[m]);
                uint256 got = pre.borrowLimit(all[m], c);
                uint256 exact = _exact(all[m], c);
                assertLe(got, exact, "pre-fix limit never exceeds the exact line");
                if (exact - got > maxGap) maxGap = exact - got;
                if (exact > got) differs++;
            }
            assertLe(maxGap, 3, "truncation costs at most 3 base units");
            emit log_named_string("market", names[m]);
            emit log_named_uint("  sizes (of 2000) where pre-fix limit is below exact", differs);
            emit log_named_uint("  largest shortfall, USDC base units (1 = $0.000001)", maxGap);
        }
    }

    /// Reproduce the false revert on live Morpho with the audited bytecode.
    function test_before_M01_reproduced_preFixHelperFalselyReverts() public {
        (uint256 c, uint256 amount, uint256 preLimit, uint256 exact) = _findFalseRevertCase();
        emit log_named_decimal_uint("collateral (cbBTC)", c, 8);
        emit log_named_decimal_uint("pre-fix helper limit (USDC)", preLimit, 6);
        emit log_named_decimal_uint("exact 90% line      (USDC)", exact, 6);
        emit log_named_decimal_uint("borrow attempted    (USDC)", amount, 6);

        address user = makeAddr("m01-user");
        _fund(user, c);
        _authorize(user, address(pre), c);
        vm.prank(user);
        vm.expectPartialRevert(ChipBorrowHelperPreM01.TooCloseToLiquidation.selector);
        pre.supplyCollateralAndBorrow(btc, c, amount);
        emit log("PRE-FIX: reverted TooCloseToLiquidation on a borrow inside the 90% line  -> M-01 REAL");
    }

    /// Bankr's fix, verbatim: multiplies four factors in 256 bits. At live prices that overflows.
    function test_bankrLiteral_borrowLimitOverflows_atOneWholeToken_inEveryMarket() public {
        for (uint256 m; m < all.length; m++) {
            vm.expectRevert(stdError.arithmeticError);
            bankr.borrowLimit(all[m], 10 ** decs[m]);
            uint256 price = IMorphoOracle(all[m].oracle).price();
            uint256 maxC = type(uint256).max / (price * all[m].lltv * 0.9e18);
            emit log_named_string("market", names[m]);
            emit log_named_decimal_uint("  Bankr formula overflows above collateral worth (USDC)", maxC * price / 1e36, 6);
        }
    }

    /// And so a completely ordinary borrow reverts: $100 against 0.01 BTC (~$760).
    function test_bankrLiteral_bricksAnOrdinaryBorrow() public {
        address user = makeAddr("bankr-user");
        _fund(user, 1_000_000);
        _authorize(user, address(bankr), 1_000_000);
        vm.prank(user);
        vm.expectRevert(stdError.arithmeticError);
        bankr.supplyCollateralAndBorrow(btc, 1_000_000, 100e6);
    }
}

// ==================================================================================== AFTER

contract M01PrecisionAfterTest is M01Base {
    /// The exact case that reproduced the bug now borrows, and pays the right amounts.
    function test_after_sameCase_nowBorrows() public {
        (uint256 c, uint256 amount,, uint256 exact) = _findFalseRevertCase();
        assertEq(fixedHelper.borrowLimit(btc, c), exact, "fixed limit is the exact line");

        address user = makeAddr("m01-user");
        _fund(user, c);
        _authorize(user, address(fixedHelper), c);
        uint256 safeBefore = IERC20(USDC).balanceOf(SAFE);
        vm.prank(user);
        uint256 received = fixedHelper.supplyCollateralAndBorrow(btc, c, amount);

        assertEq(received, amount - amount / 100, "user receives 99%");
        assertEq(IERC20(USDC).balanceOf(user), received);
        assertEq(IERC20(USDC).balanceOf(SAFE) - safeBefore, amount / 100, "Safe receives 1%");
        emit log_named_decimal_uint("FIXED: same borrow succeeded (USDC)", amount, 6);
        emit log_named_decimal_uint("       user received      (USDC)", received, 6);
    }

    /// The fixed limit equals the exact line at every size in every market - small AND large.
    function test_after_limitEqualsExact_acrossAllSizes_allMarkets() public view {
        for (uint256 m; m < all.length; m++) {
            for (uint256 i = 1; i <= 2000; i++) {
                uint256 c = _size(i, decs[m]);
                assertEq(fixedHelper.borrowLimit(all[m], c), _exact(all[m], c), "fixed != exact");
            }
            // and far beyond any real position: a billion whole tokens does not overflow
            uint256 huge = 1e9 * 10 ** decs[m];
            assertEq(fixedHelper.borrowLimit(all[m], huge), _exact(all[m], huge), "huge != exact");
        }
    }

    /// Large collateral still works end to end: 10 cbBTC (~$760k), borrow half the line.
    function test_after_largeCollateral_borrowsAndRepays() public {
        uint256 c = 10e8;
        address user = makeAddr("whale");
        _fund(user, c);
        _authorize(user, address(fixedHelper), c);
        uint256 amount = fixedHelper.borrowLimit(btc, c) / 2;
        vm.prank(user);
        uint256 received = fixedHelper.supplyCollateralAndBorrow(btc, c, amount);
        assertEq(received, amount - amount / 100);

        deal(USDC, user, amount * 2);
        vm.startPrank(user);
        IERC20(USDC).approve(address(fixedHelper), type(uint256).max);
        (, uint256 withdrawn) = fixedHelper.repayAndWithdraw(btc, type(uint256).max, type(uint256).max);
        vm.stopPrank();
        assertEq(withdrawn, c, "all 10 cbBTC back");
        emit log_named_decimal_uint("10 cbBTC: borrowed (USDC)", amount, 6);
    }

    /// The line still holds: just over it reverts, just under it passes.
    function test_after_stillRefusesPastTheLine() public {
        uint256 c = 1e8;
        address user = makeAddr("edge");
        _fund(user, c);
        _authorize(user, address(fixedHelper), c);
        uint256 limit = fixedHelper.borrowLimit(btc, c);
        vm.prank(user);
        vm.expectPartialRevert(ChipBorrowHelper.TooCloseToLiquidation.selector);
        fixedHelper.supplyCollateralAndBorrow(btc, c, limit + 1);
    }

    /// The more precise line can never sit above Morpho's own liquidation line (except dust, where
    /// Morpho refuses the borrow itself).
    function testFuzz_after_neverAboveMorphoLiquidationLine(uint256 c) public view {
        c = bound(c, 1_000, 1e14);
        uint256 price = IMorphoOracle(btc.oracle).price();
        uint256 morphoMax = Math.mulDiv(c, price, 1e36) * btc.lltv / 1e18; // Morpho's _isHealthy rounding
        uint256 limit = fixedHelper.borrowLimit(btc, c);
        if (morphoMax >= 20) assertLe(limit, morphoMax, "helper line above Morpho's");
    }
}
