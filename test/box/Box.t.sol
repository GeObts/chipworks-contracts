// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Box} from "../../src/box/Box.sol";
import {IBox} from "../../src/interfaces/IBox.sol";
import {IPrizeVault} from "../../src/interfaces/IPrizeVault.sol";
import {BoxTestBase} from "./BoxTestBase.sol";

contract BoxTest is BoxTestBase {
    event BoxPurchased(
        address indexed buyer,
        address indexed to,
        uint256 indexed tokenId,
        uint8 skuId,
        address paymentToken,
        uint256 price,
        uint256 fee,
        uint256 toVault
    );
    event BoxOpened(
        address indexed opener,
        uint256 indexed tokenId,
        uint64 indexed sequence,
        uint8 skuId,
        uint8 tierId,
        uint32 prizeBps,
        uint256 prizeUsd,
        address stock,
        uint256 stockAmount,
        uint256 usdcAmount,
        uint256 paidUsd,
        bool capped,
        bool shortfall,
        bool emptyStockFallback
    );

    /* ------------------------------------------------------------------ */
    /*                         ODDS / RTP                                   */
    /* ------------------------------------------------------------------ */

    function test_rtpIs9100Bps() public view {
        assertEq(boxes.rtpBps(), 9_100, "launch table is 91.00% RTP");
        assertEq(boxes.expectedValueUsd(SKU1), 910_000);
        assertEq(boxes.expectedValueUsd(SKU10), 9_100_000);
        assertEq(boxes.expectedValueUsd(SKU25), 22_750_000);
    }

    function test_oddsWeightsSumToDenom() public view {
        IBox.PrizeTier[] memory tiers = boxes.oddsTable();
        assertEq(tiers.length, 6);
        uint256 w;
        uint256 ev;
        for (uint256 i; i < tiers.length; ++i) {
            w += tiers[i].weight;
            ev += uint256(tiers[i].weight) * tiers[i].prizeBps;
        }
        assertEq(w, boxes.WEIGHT_DENOM());
        assertEq(ev / boxes.WEIGHT_DENOM(), 9_100);
    }

    function test_everyRollMapsToATier() public view {
        uint16[6] memory weights = [uint16(4_500), 3_000, 1_500, 700, 250, 50];
        uint256[6] memory hits;
        for (uint256 roll; roll < 10_000; ++roll) {
            (uint8 tierId,,,) = boxes.previewDraw(bytes32(roll), SKU1);
            hits[tierId] += 1;
        }
        for (uint256 i; i < 6; ++i) {
            assertEq(hits[i], weights[i], "UI must match this mapping exactly");
        }
    }

    function test_prizeScalesWithSkuPrice() public view {
        bytes32 dust = bytes32(uint256(0));
        (,, uint32 prizeBps, uint256 prize1) = boxes.previewDraw(dust, SKU1);
        (,, uint32 prizeBps10, uint256 prize10) = boxes.previewDraw(dust, SKU10);
        (,, uint32 prizeBps25, uint256 prize25) = boxes.previewDraw(dust, SKU25);
        assertEq(prizeBps, prizeBps10);
        assertEq(prizeBps, prizeBps25);
        assertEq(prize1, USD1 * prizeBps / 10_000);
        assertEq(prize10, USD10 * prizeBps / 10_000);
        assertEq(prize25, USD25 * prizeBps / 10_000);
        assertEq(prize10, prize1 * 10);
        assertEq(prize25, prize1 * 25);
    }

    function testFuzz_previewDrawIsDeterministic(bytes32 rand, uint8 skuPick) public view {
        uint8 skuId = skuPick % 3;
        uint256 price = _skuUsd(skuId);
        (uint8 a, uint16 w, uint32 bps, uint256 usd) = boxes.previewDraw(rand, skuId);
        (uint8 a2, uint16 w2, uint32 bps2, uint256 usd2) = boxes.previewDraw(rand, skuId);
        assertEq(a, a2);
        assertEq(w, w2);
        assertEq(bps, bps2);
        assertEq(usd, usd2);
        assertLt(a, 6);
        assertEq(usd, price * bps / 10_000);
    }

    /* ------------------------------------------------------------------ */
    /*                      BUY + FEE SPLIT                                 */
    /* ------------------------------------------------------------------ */

    function test_buyWithUsdc_splitsFivePercentToTreasury() public {
        uint256 tre0 = usdc.balanceOf(treasury);
        uint256 vault0 = usdc.balanceOf(address(vault));

        vm.expectEmit(true, true, true, true);
        emit BoxPurchased(alice, alice, 1, SKU1, address(usdc), USD1, 50_000, 950_000);

        uint256 id = _buy1(alice);
        assertEq(id, 1);
        assertEq(boxes.ownerOf(1), alice);
        assertEq(boxes.boxInfo(1).state, boxes.STATE_SEALED());
        assertEq(boxes.sealedSupply(SKU1), 1);

        assertEq(usdc.balanceOf(treasury) - tre0, 50_000);
        assertEq(usdc.balanceOf(address(vault)) - vault0, 950_000);
        assertEq(usdc.balanceOf(address(boxes)), 0, "box holds nothing between calls");
    }

    function test_buyWithChip_splitsFivePercentToTreasury() public {
        uint256 tre0 = chip.balanceOf(treasury);
        uint256 vault0 = chip.balanceOf(address(vault));

        vm.prank(alice);
        uint256 id = boxes.buyWithChip(SKU1, alice);

        assertEq(boxes.ownerOf(id), alice);
        uint256 fee = uint256(CHIP1) * 500 / 10_000;
        assertEq(chip.balanceOf(treasury) - tre0, fee);
        assertEq(chip.balanceOf(address(vault)) - vault0, uint256(CHIP1) - fee);
        assertEq(chip.balanceOf(address(boxes)), 0);
    }

    function test_buyOneTenTwentyFiveUsdcAndChip() public {
        uint256 treUsdc0 = usdc.balanceOf(treasury);
        uint256 treChip0 = chip.balanceOf(treasury);
        uint256 vaultUsdc0 = usdc.balanceOf(address(vault));
        uint256 vaultChip0 = chip.balanceOf(address(vault));

        uint8[3] memory skus = [SKU1, SKU10, SKU25];
        for (uint256 i; i < skus.length; ++i) {
            uint8 skuId = skus[i];
            vm.prank(alice);
            uint256 usdcId = boxes.buyWithUsdc(skuId, alice);
            vm.prank(alice);
            uint256 chipId = boxes.buyWithChip(skuId, alice);
            assertEq(boxes.boxInfo(usdcId).skuId, skuId);
            assertEq(boxes.boxInfo(chipId).skuId, skuId);
            assertEq(boxes.boxInfo(usdcId).faceUsd, _skuUsd(skuId));
            assertEq(boxes.boxInfo(chipId).faceUsd, _skuUsd(skuId));
            assertEq(boxes.sku(skuId).usdcPrice, _skuUsd(skuId));
            assertEq(boxes.sku(skuId).chipPrice, _skuChip(skuId));
        }

        uint256 usdcPaid = USD1 + USD10 + USD25;
        uint256 chipPaid = uint256(CHIP1) + uint256(CHIP10) + uint256(CHIP25);
        uint256 usdcFee = usdcPaid * 500 / 10_000;
        uint256 chipFee = chipPaid * 500 / 10_000;
        assertEq(usdc.balanceOf(treasury) - treUsdc0, usdcFee);
        assertEq(chip.balanceOf(treasury) - treChip0, chipFee);
        assertEq(usdc.balanceOf(address(vault)) - vaultUsdc0, usdcPaid - usdcFee);
        assertEq(chip.balanceOf(address(vault)) - vaultChip0, chipPaid - chipFee);
        assertEq(usdc.balanceOf(address(boxes)), 0);
        assertEq(chip.balanceOf(address(boxes)), 0);
        assertEq(boxes.sealedSupply(SKU1), 2);
        assertEq(boxes.sealedSupply(SKU10), 2);
        assertEq(boxes.sealedSupply(SKU25), 2);
    }

    function test_buyAsGift_mintsToRecipient() public {
        vm.prank(alice);
        uint256 id = boxes.buyWithUsdc(SKU1, bob);
        assertEq(boxes.ownerOf(id), bob);
        assertEq(boxes.boxInfo(id).state, boxes.STATE_SEALED());
    }

    function test_sealedBoxIsTransferable() public {
        uint256 id = _buy1(alice);
        vm.prank(alice);
        boxes.transferFrom(alice, bob, id);
        assertEq(boxes.ownerOf(id), bob);
    }

    function test_batchBuy() public {
        vm.prank(alice);
        uint256 first = boxes.buyWithUsdcBatch(SKU1, bob, 3);
        assertEq(first, 1);
        assertEq(boxes.ownerOf(1), bob);
        assertEq(boxes.ownerOf(3), bob);
        assertEq(boxes.sealedSupply(SKU1), 3);
        assertEq(usdc.balanceOf(treasury), 150_000);
    }

    function test_buyRevertsWhenPaused() public {
        vm.prank(multisig);
        boxes.setPaused(true);
        vm.prank(alice);
        vm.expectRevert(Box.PausedError.selector);
        boxes.buyWithUsdc(SKU1, alice);
    }

    function test_chipDisabledWhenPriceZero() public {
        Box bare = _newBox(address(vault), address(chip), 0, CHIP10, CHIP25);
        vm.prank(alice);
        usdc.approve(address(bare), type(uint256).max);
        vm.prank(alice);
        chip.approve(address(bare), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(Box.ChipDisabled.selector);
        bare.buyWithChip(SKU1, alice);
        vm.prank(alice);
        uint256 id = bare.buyWithUsdc(SKU1, alice);
        assertEq(id, 1);
    }

    /* ------------------------------------------------------------------ */
    /*                     ENTROPY OPEN / CALLBACK                          */
    /* ------------------------------------------------------------------ */

    function test_openPaysEntropyFeeAndRefundsExcess() public {
        uint256 id = _buy1(alice);
        uint128 fee = boxes.quoteOpenFee();
        uint256 eth0 = alice.balance;

        vm.prank(alice);
        boxes.open{value: uint256(fee) + 0.05 ether}(id);

        assertEq(alice.balance, eth0 - fee, "excess ETH refunded; fee passed through");
        assertEq(address(entropy).balance, fee);
        assertEq(boxes.boxInfo(id).state, boxes.STATE_OPENING());
        assertEq(boxes.boxInfo(id).opener, alice);
    }

    function test_openRevertsIfUnderpaidFee() public {
        uint256 id = _buy1(alice);
        uint128 fee = boxes.quoteOpenFee();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Box.Underpaid.selector, 1, uint256(fee)));
        boxes.open{value: 1}(id);
    }

    function test_openingBoxCannotBeTransferred() public {
        uint256 id = _buy1(alice);
        uint128 fee = boxes.quoteOpenFee();
        vm.prank(alice);
        boxes.open{value: fee}(id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Box.BoxLocked.selector, id));
        boxes.transferFrom(alice, bob, id);
    }

    function test_callbackFromNonEntropyReverts() public {
        uint256 id = _buy1(alice);
        uint128 fee = boxes.quoteOpenFee();
        vm.prank(alice);
        boxes.open{value: fee}(id);
        vm.expectRevert(Box.OnlyEntropy.selector);
        boxes._entropyCallback(1, address(this), bytes32(uint256(1)));
        vm.expectRevert(Box.OnlyEntropy.selector);
        boxes.entropyCallback(1, address(this), bytes32(uint256(1)));
    }

    function test_fulfillBurnsAndPaysMatchingPreview() public {
        uint256 id = _buy1(alice);
        bytes32 rand = _rollForTier(2); // 1.00× → $1
        (uint8 tierId,, uint32 prizeBps, uint256 prizeUsd) = boxes.previewDraw(rand, SKU1);
        assertEq(tierId, 2);
        assertEq(prizeUsd, USD1);

        uint256 nvda0 = nvda.balanceOf(alice);
        _openAndFulfill(alice, id, rand);

        vm.expectRevert();
        boxes.ownerOf(id);

        assertEq(boxes.sealedSupply(SKU1), 0);
        assertGt(nvda.balanceOf(alice) + tsla.balanceOf(alice) + usdc.balanceOf(alice), nvda0);
        // paidUsd should match the $1 draw (vault is solvent).
        assertEq(prizeBps, 10_000);
    }

    function test_gifteeOpensNotBuyer() public {
        vm.prank(alice);
        uint256 id = boxes.buyWithUsdc(SKU1, bob);
        uint128 fee = boxes.quoteOpenFee();
        vm.prank(alice);
        vm.expectRevert(Box.NotOwner.selector);
        boxes.open{value: fee}(id);

        bytes32 rand = _rollForTier(0);
        _openAndFulfill(bob, id, rand);
        vm.expectRevert();
        boxes.ownerOf(id);
    }

    function test_openEmitsDrawAndPrizeFields() public {
        uint256 id = _buy1(alice);
        bytes32 rand = _rollForTier(3);
        (uint8 tierId,, uint32 prizeBps, uint256 prizeUsd) = boxes.previewDraw(rand, SKU1);
        uint128 fee = boxes.quoteOpenFee();
        vm.prank(alice);
        boxes.open{value: fee}(id);
        uint64 seq = boxes.boxInfo(id).sequence;

        vm.expectEmit(true, true, true, false);
        emit BoxOpened(alice, id, seq, SKU1, tierId, prizeBps, prizeUsd, address(0), 0, 0, 0, false, false, false);
        entropy.fulfill(seq, rand);
    }

    function test_retryOpenAfterTimeout() public {
        uint256 id = _buy1(alice);
        uint128 fee = boxes.quoteOpenFee();
        vm.prank(alice);
        boxes.open{value: fee}(id);
        uint64 oldSeq = boxes.boxInfo(id).sequence;

        vm.prank(alice);
        vm.expectRevert();
        boxes.retryOpen{value: fee}(id);

        vm.warp(block.timestamp + 3 days);
        vm.prank(alice);
        boxes.retryOpen{value: fee}(id);
        uint64 newSeq = boxes.boxInfo(id).sequence;
        assertTrue(newSeq != oldSeq);
        assertEq(boxes.tokenIdOfSequence(oldSeq), 0);

        entropy.fulfill(oldSeq, bytes32(uint256(1)));
        assertEq(boxes.ownerOf(id), alice, "orphan callback does not burn");

        entropy.fulfill(newSeq, bytes32(uint256(1)));
        vm.expectRevert();
        boxes.ownerOf(id);
    }

    /* ------------------------------------------------------------------ */
    /*                         TREASURY TIMELOCK                            */
    /* ------------------------------------------------------------------ */

    function test_defaultFeeRecipientIsGoyabeanSafe() public view {
        assertEq(boxes.DEFAULT_FEE_RECIPIENT(), 0xe1096B727499a3f70FaD8bc0267F5e69d01373C7);
        assertEq(boxes.treasury(), boxes.DEFAULT_FEE_RECIPIENT());
        assertEq(boxes.feeRecipient(), boxes.treasury());
    }

    function test_constructorCanOverrideFeeRecipient() public {
        Box other = new Box(
            multisig, address(usdc), address(chip), alice, address(vault), address(entropy), CHIP1, CHIP10, CHIP25
        );
        assertEq(other.feeRecipient(), alice);
        assertTrue(other.feeRecipient() != other.DEFAULT_FEE_RECIPIENT());
    }

    function test_treasuryChangeIsTimelocked() public {
        address nextSafe = makeAddr("nextSafe");
        vm.prank(multisig);
        boxes.queueTreasury(nextSafe);
        vm.prank(multisig);
        vm.expectRevert();
        boxes.executeTreasury();

        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        boxes.executeTreasury();
        assertEq(boxes.treasury(), nextSafe);
        assertEq(boxes.feeRecipient(), nextSafe);
    }

    function test_launchSkusAreOneTenTwentyFive() public view {
        assertEq(boxes.MAX_SKUS(), 3);
        assertTrue(boxes.sku(SKU1).exists);
        assertTrue(boxes.sku(SKU10).exists);
        assertTrue(boxes.sku(SKU25).exists);
        assertEq(boxes.sku(SKU1).usdcPrice, USD1);
        assertEq(boxes.sku(SKU10).usdcPrice, USD10);
        assertEq(boxes.sku(SKU25).usdcPrice, USD25);
        assertEq(boxes.sku(SKU1).chipPrice, CHIP1);
        assertEq(boxes.sku(SKU10).chipPrice, CHIP10);
        assertEq(boxes.sku(SKU25).chipPrice, CHIP25);
        assertFalse(boxes.sku(3).exists, "$5 slot removed; id 3 is unused");
        assertEq(boxes.DEFAULT_CHIP(), 0x75Af968d2e58749FDA1b42C58186B76f5E511bA3);
        assertEq(boxes.DEFAULT_USDC(), 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    }

    function test_buyUnknownSkuReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Box.UnknownSku.selector, uint8(3)));
        boxes.buyWithUsdc(3, alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Box.UnknownSku.selector, uint8(3)));
        boxes.buyWithChip(3, alice);
    }
}
