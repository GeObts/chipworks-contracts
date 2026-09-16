// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Box} from "../../src/box/Box.sol";
import {PrizeVault} from "../../src/box/PrizeVault.sol";
import {BoxTestBase} from "./BoxTestBase.sol";
import {BlacklistToken} from "../mocks/HostileTokens.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract BoxVaultTest is BoxTestBase {
    function test_emptyStockFallsBackToNextStock() public {
        vm.prank(multisig);
        vault.setStockEnabled(address(nvda), false);

        uint256 tsla0 = tsla.balanceOf(alice);
        uint256 id = _buy1(alice);
        _openAndFulfill(alice, id, bytes32(uint256(0)));
        assertGt(tsla.balanceOf(alice), tsla0, "paid the remaining enabled stock");
        assertEq(nvda.balanceOf(alice), 0);
    }

    function test_allStocksEmptyFallsBackToUsdc() public {
        vm.startPrank(multisig);
        vault.setStockEnabled(address(nvda), false);
        vault.setStockEnabled(address(tsla), false);
        vm.stopPrank();

        uint256 id = _buy1(alice);
        uint256 usdc0 = usdc.balanceOf(alice);
        _openAndFulfill(alice, id, _rollForTier(2));
        assertEq(usdc.balanceOf(alice) - usdc0, 1_000_000, "honest USDC fallback");
        assertEq(nvda.balanceOf(alice), 0);
    }

    function test_chipBuyAgainstEmptyB20AndUsdcIsHonestShortfall() public {
        (Box thinBox, PrizeVault thinVault) = _newPair();
        vm.prank(multisig);
        thinVault.setBox(address(thinBox));

        vm.startPrank(alice);
        chip.approve(address(thinBox), type(uint256).max);
        uint256 id = thinBox.buyWithChip(SKU1, alice);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(thinVault)), 0);
        assertGt(chip.balanceOf(address(thinVault)), 0);
        assertEq(thinVault.inventoryUsd(), 0, "CHIP is working capital, not priced inventory");

        uint128 fee = thinBox.quoteOpenFee();
        vm.prank(alice);
        thinBox.open{value: fee}(id);
        uint64 seq = thinBox.boxInfo(id).sequence;
        entropy.fulfill(seq, _rollForTier(2));

        vm.expectRevert();
        thinBox.ownerOf(id);
        assertEq(thinBox.sealedSupply(SKU1), 0);
        assertEq(nvda.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(alice), 1_000 * 1e6, "no USDC prize paid; buyer still has their USDC");
    }

    function test_prizeCapLimitsJackpotOnThinInventory() public {
        (Box thinBox, PrizeVault thinVault) = _newPair();
        vm.prank(multisig);
        thinVault.setBox(address(thinBox));
        usdc.mint(address(thinVault), 40 * 1e6);

        vm.startPrank(alice);
        usdc.approve(address(thinBox), type(uint256).max);
        uint256 id = thinBox.buyWithUsdc(SKU1, alice);
        vm.stopPrank();

        uint256 cap = thinVault.prizeCapUsd();
        assertEq(cap, thinVault.inventoryUsd() * 2_500 / 10_000);
        assertLt(cap, 36 * 1e6);

        uint128 fee = thinBox.quoteOpenFee();
        vm.prank(alice);
        thinBox.open{value: fee}(id);
        uint64 seq = thinBox.boxInfo(id).sequence;
        uint256 alice0 = usdc.balanceOf(alice);
        entropy.fulfill(seq, bytes32(uint256(9_950)));
        uint256 paid = usdc.balanceOf(alice) - alice0;
        assertEq(paid, cap, "capped jackpot paid in USDC");
    }

    function test_thinStockIsSkipped() public {
        MockERC20 dustTok = new MockERC20("Dust", "DSTX", 8);
        MockAggregatorV3 dustFeed = new MockAggregatorV3(8, int256(100e8), "D");
        vm.prank(multisig);
        vault.addStock(address(dustTok), address(dustFeed), 8);
        dustTok.mint(address(this), 1);
        dustTok.approve(address(vault), 1);
        vault.deposit(address(dustTok), 1);

        uint256 tsla0 = tsla.balanceOf(alice);
        uint256 nvda0 = nvda.balanceOf(alice);
        uint256 id = _buy1(alice);
        _openAndFulfill(alice, id, bytes32(uint256(2)));
        assertTrue(tsla.balanceOf(alice) > tsla0 || nvda.balanceOf(alice) > nvda0);
        assertEq(dustTok.balanceOf(alice), 0);
    }

    function test_blacklistedStockIsSkippedAndOpenStillSettles() public {
        BlacklistToken blocked = new BlacklistToken("Blocked", "BLKX", 8);
        MockAggregatorV3 feed = new MockAggregatorV3(8, int256(100e8), "B");
        vm.prank(multisig);
        vault.addStock(address(blocked), address(feed), 8);
        blocked.mint(address(this), 100e8);
        blocked.approve(address(vault), 100e8);
        vault.deposit(address(blocked), 100e8);
        blocked.setBlacklisted(alice, true);

        uint256 id = _buy1(alice);
        _openAndFulfill(alice, id, bytes32(uint256(2)));
        assertEq(blocked.balanceOf(alice), 0);
        assertTrue(nvda.balanceOf(alice) > 0 || tsla.balanceOf(alice) > 0 || usdc.balanceOf(alice) > 0);
    }

    function test_cannotRescuePrizeAssets() public {
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.ProtectedAsset.selector, address(usdc)));
        vault.rescue(address(usdc), alice, 1);

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.ProtectedAsset.selector, address(nvda)));
        vault.rescue(address(nvda), alice, 1);
    }

    function test_rescueStrayToken() public {
        MockERC20 stray = new MockERC20("Stray", "STRX", 18);
        stray.mint(address(vault), 1 ether);
        vm.prank(multisig);
        vault.rescue(address(stray), alice, 1 ether);
        assertEq(stray.balanceOf(alice), 1 ether);
    }

    function test_surplusWithdrawRespectsOutstandingEv() public {
        (Box thinBox, PrizeVault thinVault) = _newPair();
        vm.prank(multisig);
        thinVault.setBox(address(thinBox));
        usdc.mint(address(thinVault), 100 * 1e6);

        vm.startPrank(alice);
        usdc.approve(address(thinBox), type(uint256).max);
        thinBox.buyWithUsdc(SKU1, alice);
        vm.stopPrank();

        uint256 liability = thinBox.outstandingLiabilityUsd();
        assertEq(liability, 910_000);
        uint256 required = liability * 11_000 / 10_000;
        uint256 usdcBal = usdc.balanceOf(address(thinVault));

        vm.prank(multisig);
        thinVault.queueSurplusWithdraw(address(usdc), multisig, usdcBal);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.InsufficientSurplus.selector, 0, required));
        thinVault.executeSurplusWithdraw();
    }

    function test_surplusWithdrawOfDustSucceeds() public {
        _buy1(alice);
        vm.prank(multisig);
        vault.queueSurplusWithdraw(address(usdc), multisig, 1);
        vm.warp(block.timestamp + 48 hours);
        uint256 m0 = usdc.balanceOf(multisig);
        vm.prank(multisig);
        vault.executeSurplusWithdraw();
        assertEq(usdc.balanceOf(multisig) - m0, 1);
    }

    function test_setBoxOnce() public {
        vm.prank(multisig);
        vm.expectRevert(PrizeVault.AlreadyWired.selector);
        vault.setBox(address(boxes));
    }

    function test_onlyBoxCanSettle() public {
        vm.expectRevert(PrizeVault.OnlyBox.selector);
        vault.settle(alice, 1_000_000, bytes32(uint256(1)));
    }

    function test_quoteTokenAmountMatchesPayoutMath() public view {
        assertEq(vault.quoteTokenAmount(address(nvda), 1_000_000), 1e6);
    }

    function test_deadFeedSkipsStock() public {
        nvdaFeed.setRevertOnRead(true);
        uint256 tsla0 = tsla.balanceOf(alice);
        uint256 id = _buy1(alice);
        _openAndFulfill(alice, id, bytes32(uint256(0)));
        assertEq(nvda.balanceOf(alice), 0);
        assertTrue(tsla.balanceOf(alice) > tsla0 || usdc.balanceOf(alice) > 0);
    }

    function test_dollarPrizePaysOneCentOfHundredDollarStock() public {
        uint256 id = _buy1(alice);
        _openAndFulfill(alice, id, _rollForTier(2));
        // $1 at $100/NVDA, entropy 7500 % 2 == 0 → NVDA first.
        assertEq(nvda.balanceOf(alice), 1e6);
    }

    function _newPair() internal returns (Box thinBox, PrizeVault thinVault) {
        thinVault = new PrizeVault(multisig, address(usdc), 2_500);
        thinBox = new Box(
            multisig, address(usdc), address(chip), treasury, address(thinVault), address(entropy), CHIP1, CHIP5
        );
    }
}
