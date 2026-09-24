// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BoxTestBase} from "./BoxTestBase.sol";
import {IBox} from "../../src/interfaces/IBox.sol";
import {PrizeVault} from "../../src/box/PrizeVault.sol";

/// @notice Audit round 1 (Bankr + Grok on 740fc37): each finding reproduced as a test of the SAFE
///         property before anything is changed. A test that fails on the audited code confirms the
///         finding; one that passes refutes it. See audit/box-2026-09-23/TRIAGE-ROUND1.md.
contract BoxAuditRound1Test is BoxTestBase {
    /* ---------------- F-2: Pyth sequence numbers are per provider ---------------- */

    /// @dev Grok F-2. Two opens from two providers can both be sequence 1. The first provider's
    ///      reveal must pay the box IT was requested for, and must not settle the other box.
    function test_F2_aRevealPaysOnlyTheBoxItWasRequestedFor() public {
        uint256 a = _buy1(alice);
        uint64 seqA = _open(alice, a); // provider: the mock itself

        address p2 = makeAddr("provider-2");
        entropy.setDefaultProvider(p2); // Pyth changes its default provider
        uint256 b = _buy1(bob);
        uint64 seqB = _open(bob, b);
        assertEq(seqA, seqB, "both requests are sequence 1, from different providers");

        uint256 aliceN0 = nvda.balanceOf(alice);
        uint256 bobN0 = nvda.balanceOf(bob);
        entropy.fulfillFrom(address(entropy), seqA, _rollForTier(2)); // A's reveal: Uncommon, $1
        assertEq(nvda.balanceOf(alice) - aliceN0, 1e6, "A's reveal pays A");
        assertEq(nvda.balanceOf(bob), bobN0, "and does not touch B");
        assertEq(boxes.boxInfo(b).state, boxes.STATE_OPENING(), "B still waits for ITS reveal");

        entropy.fulfillFrom(p2, seqB, _rollForTier(2));
        assertEq(nvda.balanceOf(bob) - bobN0, 1e6, "B's own reveal pays B");
    }

    /* ---------------- H-1 (strengthened): a fixed $CHIP price ---------------- */

    /// @dev Grok H-1, and the sharper form of it. The audited design took a fixed $CHIP price per
    ///      box (48h to change) and sold it later: when $CHIP halved, a "$10" box put $4.75 into the
    ///      pool against $9.10 of liability. FIXED by swapping at buy: the buyer pays whatever $CHIP
    ///      buys the exact price, so the pool gets 95% of face however far $CHIP falls.
    function test_H1_aChipBoxFundsThePoolAtItsFace_evenWhenChipFalls() public {
        pm.setRate(address(chip), address(weth), 125, 1e10); // $CHIP halves
        pm.setRate(address(weth), address(chip), 1e10, 125);
        (, uint256 cost) = _chipQuote(USD10);
        assertEq(cost, 2 * CHIP10, "the buyer now pays twice the $CHIP");
        uint256 vault0 = usdc.balanceOf(address(vault));
        _buyChip(alice, SKU10);
        uint256 funded = usdc.balanceOf(address(vault)) - vault0;
        assertGe(funded, 9_500_000, "a $10 box must fund the pool with $9.50");
    }

    /* ---------------- H-2: owner $CHIP recovery against live liability ---------------- */

    /// @dev Grok H-2. The audited converter held box $CHIP until a keeper sold it, and the owner
    ///      could recover it after 48h while the boxes it paid for were outstanding. FIXED by
    ///      construction: the converter now holds nothing between calls, so there is no $CHIP to
    ///      recover, and the recovery path is gone.
    function test_H2_chipRecoveryCannotStrandBoxesItPaidFor() public {
        _buyChip(alice, SKU10);
        (uint256 c, uint256 w, uint256 u) = converter.sweepZero();
        assertEq(c + w + u, 0, "nothing on the converter for anyone to take");
        assertGt(boxes.outstandingLiabilityUsd(), 0);
        assertEq(usdc.balanceOf(address(vault)), 10_000e6 + 9_500_000, "and the box is already paid for");
    }

    /* ---------------- H-3: withdrawing a stale-marked stock ---------------- */

    /// @dev Grok H-3. A stale-marked stock is not counted in inventory, before or after the
    ///      withdraw, so taking it cannot take the pool below the floors the pool is held to.
    ///      Safe property: after the withdraw, USDC >= 110% of liability, inventory >= the
    ///      jackpot reserve, and every SKU is still covered.
    function test_H3_withdrawingAStaleStockLeavesEveryFloorIntact() public {
        for (uint256 i; i < 10; ++i) {
            vm.prank(alice);
            boxes.buyWithUsdc(SKU25, alice);
        }
        uint256 allNvda = nvda.balanceOf(address(vault)); // read first: prank binds to the next call
        vm.prank(multisig);
        vault.queueSurplusWithdraw(address(nvda), multisig, allNvda);
        vm.warp(block.timestamp + 48 hours);
        registry.setPrice(address(tsla), TSLA_PRICE); // TSLA fresh, NVDA stale (6 days)
        registry.setStalePrice(address(nvda), NVDA_PRICE, block.timestamp - 6 days);

        vm.prank(multisig);
        vault.executeSurplusWithdraw();

        uint256 liability = boxes.outstandingLiabilityUsd();
        assertGe(usdc.balanceOf(address(vault)), liability * 11_000 / 10_000, "USDC >= 110% of liability");
        assertGe(vault.inventoryUsd(), vault.jackpotReserveUsd(), "inventory >= jackpot reserve");
        assertTrue(boxes.isSkuCovered(SKU25), "the $25 SKU is still covered");
    }

    /* ---------------- M-2: raising maxPrizeBps lowers the reserve ---------------- */

    /// @dev Grok M-2. True arithmetically, and by design: the reserve is the pool size at which
    ///      the largest prize is payable under the CURRENT cap. Safe property at either cap: a pool
    ///      swept down to exactly the reserve can still pay the largest live prize in full.
    function test_M2_aPoolAtTheReserveStillPaysTheJackpot_atAnyCap() public {
        uint256 top = boxes.maxLivePrizeUsd();
        assertGe(vault.jackpotReserveUsd() * vault.maxPrizeBps() / 10_000, top, "25% cap");
        vm.startPrank(multisig);
        vault.queueMaxPrizeBps(5_000);
        vm.warp(block.timestamp + 48 hours);
        vault.executeMaxPrizeBps();
        vm.stopPrank();
        assertEq(vault.jackpotReserveUsd(), 1_800e6, "the reserve halves when the cap doubles");
        assertGe(vault.jackpotReserveUsd() * vault.maxPrizeBps() / 10_000, top, "50% cap");
    }

    /* ---------------- L-2: the self-call guard names itself ---------------- */

    function test_L2_extTransferIsSelfOnly() public {
        vm.expectRevert(PrizeVault.OnlySelf.selector);
        vault.extTransfer(address(usdc), alice, 1);
    }
}
