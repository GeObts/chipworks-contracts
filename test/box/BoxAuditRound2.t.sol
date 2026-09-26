// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BoxTestBase} from "./BoxTestBase.sol";
import {Box} from "../../src/box/Box.sol";

/// @notice Audit round 2 (Grok on fdb77c4). See audit/box-2026-09-24/TRIAGE-ROUND2.md.
contract BoxAuditRound2Test is BoxTestBase {
    /* ---------------- BOX-L1: an immediate $CHIP-only kill switch ---------------- */

    /// @dev Grok BOX-L1. Before the fix, the only ways to stop $CHIP sales were the 48h SKU queue or
    ///      a pause that also stopped USDC. `setChipPaused` stops $CHIP alone, in the same block.
    function test_BOXL1_chipPauseStopsChipBuysAtOnce_usdcStillSells() public {
        _buyChip(alice, SKU10); // sells before

        vm.prank(multisig);
        boxes.setChipPaused(true);
        assertTrue(boxes.chipPaused());

        (uint256 wethNeeded, uint256 chipCost) = _chipQuote(USD10);
        uint256 max = chipCost * 101 / 100;
        vm.prank(alice);
        vm.expectRevert(Box.ChipDisabled.selector);
        boxes.buyWithChip(SKU10, alice, wethNeeded, max, block.timestamp + 600);

        (uint256 wethBatch, uint256 chipBatch) = _chipQuote(USD10 * 2);
        uint256 maxBatch = chipBatch * 101 / 100;
        vm.prank(alice);
        vm.expectRevert(Box.ChipDisabled.selector);
        boxes.buyWithChipBatch(SKU10, alice, 2, wethBatch, maxBatch, block.timestamp + 600);

        uint256 id = _buy1(bob);
        assertEq(boxes.ownerOf(id), bob, "USDC sales are untouched");

        vm.prank(multisig);
        boxes.setChipPaused(false);
        _buyChip(alice, SKU10); // and back on, also at once
    }

    function test_BOXL1_onlyTheOwnerCanPauseChip() public {
        vm.prank(alice);
        vm.expectRevert();
        boxes.setChipPaused(true);
        assertFalse(boxes.chipPaused());
    }

    /* ---------------- LOT-L1 counterpart: stray $CHIP on the converter ---------------- */

    /// @dev Grok LOT-L1 is on the live ChipLottery (`chipSpent = maxChipIn - chipLeft` underflows
    ///      when someone sends the wrapper more $CHIP than a buy spends). The converter measures the
    ///      spend instead, so a stray balance larger than a whole buy must not stop the next buy;
    ///      the stray goes to that buyer as change, which is the documented BOX-I1 behaviour.
    function test_LOTL1_strayChipOnTheConverterDoesNotBlockABuy() public {
        (, uint256 chipCost) = _chipQuote(USD10);
        uint256 stray = chipCost * 3;
        chip.mint(address(converter), stray);

        uint256 alice0 = chip.balanceOf(alice);
        _buyChip(alice, SKU10);
        assertEq(chip.balanceOf(address(converter)), 0, "the converter holds nothing after a buy");
        assertEq(chip.balanceOf(alice) + chipCost, alice0 + stray, "alice paid the cost; the stray came back as change");
    }
}
