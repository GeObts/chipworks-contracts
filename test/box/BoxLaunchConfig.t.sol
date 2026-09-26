// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BoxTestBase} from "./BoxTestBase.sol";
import {Box} from "../../src/box/Box.sol";
import {IBox} from "../../src/interfaces/IBox.sol";

/// @notice The launch defaults as the owner set them on 2026-09-26: odds "option B" (0.50x floor,
///         91.00% RTP) and five box sizes, the $50 and $100 sizes created paused.
contract BoxLaunchConfigTest is BoxTestBase {
    uint8 internal constant SKU50 = 3;
    uint8 internal constant SKU100 = 4;

    /// @dev The exact launch table. Roll = randomNumber % 10_000 picks the tier by cumulative weight:
    ///      0..3499 0.50x | 3500..8499 0.60x | 8500..9449 1x | 9450..9849 2x | 9850..9949 8x | 9950..9999 36x.
    function test_launchOdds_optionB_is91pct() public view {
        assertEq(boxes.oddsTierCount(), 6);
        IBox.PrizeTier[] memory t = boxes.oddsTable();
        assertEq(t.length, 6);

        uint16[6] memory w = [uint16(3_500), 5_000, 950, 400, 100, 50];
        uint32[6] memory bps = [uint32(5_000), 6_000, 10_000, 20_000, 80_000, 360_000];
        uint256 sum;
        for (uint256 i; i < 6; ++i) {
            assertEq(t[i].weight, w[i], "tier weight");
            assertEq(t[i].prizeBps, bps[i], "tier prizeBps");
            sum += t[i].weight;
        }
        assertEq(sum, 10_000, "weights sum to WEIGHT_DENOM");
        assertEq(boxes.rtpBps(), 9_100, "91.00% RTP");

        // The big sizes' jackpots (36x), which the pool must cover before they can sell.
        assertEq(boxes.maxPrizeUsd(SKU50), 1_800e6, "$50 x 36 = $1,800");
        assertEq(boxes.maxPrizeUsd(SKU100), 3_600e6, "$100 x 36 = $3,600");
    }

    /// @dev $50 and $100 open by the same honest-odds gate as the small sizes: once unpaused they
    ///      sell only when prizeCapUsd (25% of inventory) covers their 36x jackpot, i.e. inventory
    ///      of $7,200 for $50 and $14,400 for $100.
    function test_bigSizes_unlockByTheSameGate() public {
        // Shrink the fixture pool: stocks out of inventory, $4,000 of USDC -> cap $1,000.
        vm.startPrank(multisig);
        vault.setStockEnabled(address(nvda), false);
        vault.setStockEnabled(address(tsla), false);
        vm.stopPrank();
        deal(address(usdc), address(vault), 4_000e6);
        assertEq(vault.inventoryUsd(), 4_000e6);
        assertEq(vault.prizeCapUsd(), 1_000e6);

        // ----- $50 -----
        assertTrue(boxes.sku(SKU50).paused, "$50 launches paused");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Box.SkuPausedError.selector, SKU50));
        boxes.buyWithUsdc(SKU50, alice);

        vm.prank(multisig);
        boxes.setSkuPaused(SKU50, false);
        assertFalse(boxes.sku(SKU50).paused);
        assertFalse(boxes.isSkuCovered(SKU50), "cap $1,000 < $1,800 jackpot");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Box.SkuNotCovered.selector, SKU50, uint256(1_800e6), uint256(1_000e6)));
        boxes.buyWithUsdc(SKU50, alice);

        // One micro-dollar short of $7,200 is still not enough.
        usdc.mint(address(vault), 7_200e6 - 4_000e6 - 1);
        uint256 capShort = vault.prizeCapUsd();
        assertLt(capShort, 1_800e6);
        assertFalse(boxes.isSkuCovered(SKU50));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Box.SkuNotCovered.selector, SKU50, uint256(1_800e6), capShort));
        boxes.buyWithUsdc(SKU50, alice);

        // Inventory $7,200 -> cap exactly $1,800: covered, and the buy goes through.
        usdc.mint(address(vault), 1);
        assertEq(vault.inventoryUsd(), 7_200e6);
        assertEq(vault.prizeCapUsd(), 1_800e6);
        assertTrue(boxes.isSkuCovered(SKU50));
        vm.prank(alice);
        uint256 id50 = boxes.buyWithUsdc(SKU50, alice);
        assertEq(boxes.ownerOf(id50), alice);
        assertEq(boxes.boxInfo(id50).faceUsd, 50e6);
        assertEq(boxes.sealedSupply(SKU50), 1);

        // ----- $100 -----
        assertTrue(boxes.sku(SKU100).paused, "$100 launches paused");
        vm.prank(multisig);
        boxes.setSkuPaused(SKU100, false);
        uint256 cap = vault.prizeCapUsd(); // $7,200 + the $47.50 the $50 box paid in, x 25%
        assertEq(cap, (7_200e6 + 47_500_000) / 4);
        assertFalse(boxes.isSkuCovered(SKU100), "cap under the $3,600 jackpot");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Box.SkuNotCovered.selector, SKU100, uint256(3_600e6), cap));
        boxes.buyWithUsdc(SKU100, alice);

        // Grow the pool to $14,400 -> cap exactly $3,600.
        usdc.mint(address(vault), 14_400e6 - vault.inventoryUsd() - 1);
        assertFalse(boxes.isSkuCovered(SKU100), "one micro-dollar short");
        usdc.mint(address(vault), 1);
        assertEq(vault.inventoryUsd(), 14_400e6);
        assertEq(vault.prizeCapUsd(), 3_600e6);
        assertTrue(boxes.isSkuCovered(SKU100));
        vm.prank(alice);
        uint256 id100 = boxes.buyWithUsdc(SKU100, alice);
        assertEq(boxes.ownerOf(id100), alice);
        assertEq(boxes.boxInfo(id100).faceUsd, 100e6);
        assertEq(boxes.maxLivePrizeUsd(), 3_600e6, "the $100 jackpot is now the live reserve");
    }

    /// @dev Mutation gap (round 5): unpausing a big size must raise the sweep reserve AT ONCE, before
    ///      any box of that size sells. The unlock test above only saw it after a sale (maxSoldPrizeUsd).
    function test_unpausingABigSizeRaisesTheReserveBeforeAnySale() public {
        assertEq(boxes.maxLivePrizeUsd(), 900e6, "launch: the $25 jackpot, big sizes paused");
        assertEq(vault.jackpotReserveUsd(), 3_600e6);

        vm.prank(multisig);
        boxes.setSkuPaused(SKU100, false);
        assertEq(boxes.sealedSupply(SKU100), 0, "nothing sold");
        assertEq(boxes.maxLivePrizeUsd(), 3_600e6, "on sale: the $100 jackpot is reserved");
        assertEq(vault.jackpotReserveUsd(), 14_400e6, "so the sweep keeps a $14,400 pool");

        vm.prank(multisig);
        boxes.setSkuPaused(SKU100, true);
        assertEq(boxes.maxLivePrizeUsd(), 900e6, "paused again, never sold: released");
    }

    /// @dev Mutation gap (round 5): only slots 0..MAX_SKUS-1 exist. A ninth slot would be sellable
    ///      but outside the reserve loop, so it must be refused.
    function test_onlyEightSizeSlots() public {
        uint8 max = boxes.MAX_SKUS();
        vm.startPrank(multisig);
        vm.expectRevert(abi.encodeWithSelector(Box.UnknownSku.selector, max));
        boxes.queueSku(max, true, 5e6, true);
        boxes.queueSku(max - 1, true, 5e6, true); // the last slot is fine
        vm.stopPrank();
    }
}
