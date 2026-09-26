// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Box} from "../../src/box/Box.sol";
import {PrizeVault} from "../../src/box/PrizeVault.sol";
import {ChipConverter} from "../../src/box/ChipConverter.sol";
import {IBox} from "../../src/interfaces/IBox.sol";
import {BoxTestBase} from "./BoxTestBase.sol";
import {MockSwapRouter} from "../mocks/MockSwapRouter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

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
    event PaidInChip(address indexed buyer, uint256 chipSpent, uint256 usdc);
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
        bool fallbackStock,
        bool usdcFallback
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
        assertEq(boxes.oddsTierCount(), 6);
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

    function test_maxPrizeAndCoverage() public view {
        assertEq(boxes.maxPrizeUsd(SKU1), 36e6);
        assertEq(boxes.maxPrizeUsd(SKU10), 360e6);
        assertEq(boxes.maxPrizeUsd(SKU25), 900e6);
        assertEq(boxes.maxLivePrizeUsd(), 900e6);
        assertEq(vault.prizeCapUsd(), 7_500e6, "25% of the $30k fixture");
        assertTrue(boxes.isSkuCovered(SKU1));
        assertTrue(boxes.isSkuCovered(SKU10));
        assertTrue(boxes.isSkuCovered(SKU25));
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
        _assertConverterEmpty();
    }

    /// @notice Was `test_buyWithChip_sendsWholePaymentToConverter`. Swap-at-buy: the buyer's CHIP
    ///         is swapped to the exact USDC face inside the buy, then split 5/95 like a USDC buy.
    function test_buyWithChip_swapsAtBuyAndSplitsLikeUsdc() public {
        (uint256 wethNeeded, uint256 cost) = _chipQuote(USD1);
        assertEq(cost, CHIP1, "20,000 CHIP = $1 at the mock rates");
        uint256 tre0 = usdc.balanceOf(treasury);
        uint256 vault0 = usdc.balanceOf(address(vault));
        uint256 chip0 = chip.balanceOf(alice);
        uint256 usdc0 = usdc.balanceOf(alice);

        vm.expectEmit(true, true, true, true);
        emit PaidInChip(alice, cost, USD1);
        vm.expectEmit(true, true, true, true);
        emit BoxPurchased(alice, alice, 1, SKU1, address(chip), USD1, 50_000, 950_000);
        vm.prank(alice);
        uint256 id = boxes.buyWithChip(SKU1, alice, wethNeeded, cost * 101 / 100, block.timestamp);

        assertEq(boxes.ownerOf(id), alice);
        assertEq(boxes.boxInfo(id).faceUsd, USD1);
        assertEq(chip0 - chip.balanceOf(alice), cost, "spent exactly the swap cost; the 1% slack refunded");
        assertEq(usdc.balanceOf(alice), usdc0, "no USDC taken from the buyer");
        assertEq(usdc.balanceOf(treasury) - tre0, 50_000, "5% fee in USDC, at once");
        assertEq(usdc.balanceOf(address(vault)) - vault0, 950_000, "95% of face in the vault, at once");
        assertEq(chip.balanceOf(address(vault)), 0, "vault never receives CHIP");
        assertEq(chip.balanceOf(treasury), 0);
        assertEq(chip.balanceOf(address(boxes)), 0);
        assertEq(usdc.balanceOf(address(boxes)), 0);
        _assertConverterEmpty();
    }

    function test_chipBuyRefundsUnspentChipAndWeth() public {
        (uint256 wethNeeded, uint256 cost) = _chipQuote(USD10);
        uint256 chip0 = chip.balanceOf(alice);

        // Generous max: every unspent CHIP comes back.
        vm.prank(alice);
        boxes.buyWithChip(SKU10, alice, wethNeeded, cost * 3, block.timestamp);
        assertEq(chip0 - chip.balanceOf(alice), cost);
        _assertConverterEmpty();

        // Over-quoted WETH: the extra WETH (and the CHIP it cost) is the buyer's, not the house's.
        uint256 chip1 = chip.balanceOf(alice);
        vm.prank(alice);
        boxes.buyWithChip(SKU10, alice, wethNeeded * 2, cost * 3, block.timestamp);
        assertEq(chip1 - chip.balanceOf(alice), cost * 2, "bought 2x the WETH the USDC leg needed");
        assertEq(weth.balanceOf(alice), wethNeeded, "the unused WETH is refunded to the buyer");
        _assertConverterEmpty();
        assertEq(usdc.balanceOf(address(boxes)), 0);
    }

    function test_chipBuyRevertsWhenMaxChipInTooLow() public {
        (uint256 wethNeeded, uint256 cost) = _chipQuote(USD1);
        uint256 chip0 = chip.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ChipConverter.ChipCostAboveMax.selector, cost, cost - 1));
        boxes.buyWithChip(SKU1, alice, wethNeeded, cost - 1, block.timestamp);
        assertEq(chip.balanceOf(alice), chip0);
        assertEq(boxes.nextId(), 1);

        // Exactly the cost is enough.
        vm.prank(alice);
        boxes.buyWithChip(SKU1, alice, wethNeeded, cost, block.timestamp);
        assertEq(chip0 - chip.balanceOf(alice), cost);
    }

    function test_chipBuyRevertsWhenWethQuoteTooLow() public {
        (uint256 wethNeeded, uint256 cost) = _chipQuote(USD1);
        // The WETH -> USDC exact-output leg needs `wethNeeded`; one wei less trips the router's
        // amountInMaximum.
        vm.prank(alice);
        vm.expectRevert(MockSwapRouter.TooMuchRequested.selector);
        boxes.buyWithChip(SKU1, alice, wethNeeded - 1, cost * 2, block.timestamp);
        assertEq(boxes.nextId(), 1);
        _assertConverterEmpty();
    }

    function test_chipBuyRevertsAfterDeadline() public {
        (uint256 wethNeeded, uint256 cost) = _chipQuote(USD1);
        (uint256 w4, uint256 c4) = _chipQuote(4 * USD1);
        uint256 dl = block.timestamp - 1;
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Box.DeadlinePassed.selector, block.timestamp, dl));
        boxes.buyWithChip(SKU1, alice, wethNeeded, cost * 2, dl);
        vm.expectRevert(abi.encodeWithSelector(Box.DeadlinePassed.selector, block.timestamp, dl));
        boxes.buyWithChipBatch(SKU1, alice, 4, w4, c4 * 2, dl);
        // The deadline itself is still valid.
        boxes.buyWithChip(SKU1, alice, wethNeeded, cost * 2, block.timestamp);
        vm.stopPrank();
    }

    function test_buyOneTenTwentyFiveUsdcAndChip() public {
        uint256 treUsdc0 = usdc.balanceOf(treasury);
        uint256 vaultUsdc0 = usdc.balanceOf(address(vault));
        uint256 aliceChip0 = chip.balanceOf(alice);

        uint8[3] memory skus = [SKU1, SKU10, SKU25];
        uint256 chipCost;
        for (uint256 i; i < skus.length; ++i) {
            uint8 skuId = skus[i];
            vm.prank(alice);
            uint256 usdcId = boxes.buyWithUsdc(skuId, alice);
            (, uint256 c) = _chipQuote(_skuUsd(skuId));
            chipCost += c;
            uint256 chipId = _buyChip(alice, skuId);
            assertEq(boxes.boxInfo(usdcId).skuId, skuId);
            assertEq(boxes.boxInfo(chipId).skuId, skuId);
            assertEq(boxes.boxInfo(usdcId).faceUsd, _skuUsd(skuId));
            assertEq(boxes.boxInfo(chipId).faceUsd, _skuUsd(skuId));
            assertEq(boxes.sku(skuId).usdcPrice, _skuUsd(skuId));
            assertTrue(boxes.sku(skuId).chipEnabled);
        }

        uint256 usdcPaid = USD1 + USD10 + USD25;
        uint256 usdcFee = usdcPaid * 500 / 10_000;
        // Both paths land identically: 2x the face, split 5/95.
        assertEq(usdc.balanceOf(treasury) - treUsdc0, 2 * usdcFee);
        assertEq(usdc.balanceOf(address(vault)) - vaultUsdc0, 2 * (usdcPaid - usdcFee));
        assertEq(aliceChip0 - chip.balanceOf(alice), chipCost);
        assertEq(chipCost, uint256(CHIP1) + CHIP10 + CHIP25);
        assertEq(chip.balanceOf(treasury), 0);
        assertEq(chip.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(boxes)), 0);
        assertEq(chip.balanceOf(address(boxes)), 0);
        _assertConverterEmpty();
        assertEq(boxes.sealedSupply(SKU1), 2);
        assertEq(boxes.sealedSupply(SKU10), 2);
        assertEq(boxes.sealedSupply(SKU25), 2);
        assertEq(boxes.outstandingLiabilityUsd(), 2 * (910_000 + 9_100_000 + 22_750_000));
    }

    function test_buyAsGift_mintsToRecipient() public {
        vm.prank(alice);
        uint256 id = boxes.buyWithUsdc(SKU1, bob);
        assertEq(boxes.ownerOf(id), bob);
        assertEq(boxes.boxInfo(id).state, boxes.STATE_SEALED());

        (uint256 w, uint256 c) = _chipQuote(USD1);
        uint256 bobChip0 = chip.balanceOf(bob);
        uint256 aliceChip0 = chip.balanceOf(alice);
        vm.prank(alice);
        uint256 id2 = boxes.buyWithChip(SKU1, bob, w, c * 2, block.timestamp);
        assertEq(boxes.ownerOf(id2), bob);
        assertEq(chip.balanceOf(bob), bobChip0, "the giftee pays nothing");
        assertEq(aliceChip0 - chip.balanceOf(alice), c, "the payer is charged and refunded");
    }

    function test_buyToZeroReverts() public {
        (uint256 w, uint256 c) = _chipQuote(USD1);
        vm.startPrank(alice);
        vm.expectRevert(Box.ZeroAddress.selector);
        boxes.buyWithUsdc(SKU1, address(0));
        vm.expectRevert(Box.ZeroAddress.selector);
        boxes.buyWithChip(SKU1, address(0), w, c * 2, block.timestamp);
        vm.stopPrank();
    }

    function test_sealedBoxIsTransferable() public {
        uint256 id = _buy1(alice);
        vm.prank(alice);
        boxes.transferFrom(alice, bob, id);
        assertEq(boxes.ownerOf(id), bob);
    }

    function test_batchBuy() public {
        uint256 alice0 = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 first = boxes.buyWithUsdcBatch(SKU1, bob, 3);
        assertEq(first, 1);
        assertEq(boxes.ownerOf(1), bob);
        assertEq(boxes.ownerOf(3), bob);
        assertEq(boxes.sealedSupply(SKU1), 3);
        assertEq(usdc.balanceOf(treasury), 150_000);
        assertEq(alice0 - usdc.balanceOf(alice), 3 * USD1);
        assertEq(usdc.balanceOf(address(boxes)), 0);
    }

    /// @notice One swap of n x the price, then n boxes split 5/95 each.
    function test_chipBatchBuy() public {
        (uint256 w, uint256 cost) = _chipQuote(4 * USD10);
        uint256 alice0 = chip.balanceOf(alice);
        uint256 tre0 = usdc.balanceOf(treasury);
        uint256 vault0 = usdc.balanceOf(address(vault));

        vm.expectEmit(true, true, true, true);
        emit PaidInChip(alice, cost, 4 * USD10);
        vm.prank(alice);
        uint256 first = boxes.buyWithChipBatch(SKU10, bob, 4, w, cost * 101 / 100, block.timestamp);

        assertEq(first, 1);
        assertEq(boxes.ownerOf(4), bob);
        assertEq(boxes.sealedSupply(SKU10), 4);
        assertEq(alice0 - chip.balanceOf(alice), cost);
        assertEq(cost, 4 * uint256(CHIP10));
        assertEq(usdc.balanceOf(treasury) - tre0, 4 * 500_000);
        assertEq(usdc.balanceOf(address(vault)) - vault0, 4 * 9_500_000);
        assertEq(chip.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(boxes)), 0);
        _assertConverterEmpty();
    }

    function test_chipBatchRevertsWhenMaxChipInTooLow() public {
        (uint256 w, uint256 cost) = _chipQuote(3 * USD1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ChipConverter.ChipCostAboveMax.selector, cost, cost - 1));
        boxes.buyWithChipBatch(SKU1, alice, 3, w, cost - 1, block.timestamp);
        assertEq(boxes.nextId(), 1);
    }

    function test_batchLimits() public {
        uint256 max = boxes.MAX_BATCH();
        (uint256 w, uint256 c) = _chipQuote(USD1);
        (uint256 wm, uint256 cm) = _chipQuote(max * USD1);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Box.BatchTooLarge.selector, uint256(0)));
        boxes.buyWithUsdcBatch(SKU1, alice, 0);
        vm.expectRevert(abi.encodeWithSelector(Box.BatchTooLarge.selector, max + 1));
        boxes.buyWithUsdcBatch(SKU1, alice, max + 1);
        vm.expectRevert(abi.encodeWithSelector(Box.BatchTooLarge.selector, uint256(0)));
        boxes.buyWithChipBatch(SKU1, alice, 0, w, c, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(Box.BatchTooLarge.selector, max + 1));
        boxes.buyWithChipBatch(SKU1, alice, max + 1, w * (max + 1), c * (max + 1), block.timestamp);
        uint256 first = boxes.buyWithUsdcBatch(SKU1, alice, max);
        uint256 firstChip = boxes.buyWithChipBatch(SKU1, alice, max, wm, cm, block.timestamp);
        vm.stopPrank();
        assertEq(first, 1);
        assertEq(firstChip, max + 1);
        assertEq(boxes.sealedSupply(SKU1), 2 * max);
    }

    function test_buyRevertsWhenPaused() public {
        (uint256 w, uint256 c) = _chipQuote(USD1);
        vm.prank(multisig);
        boxes.setPaused(true);
        vm.startPrank(alice);
        vm.expectRevert(Box.PausedError.selector);
        boxes.buyWithUsdc(SKU1, alice);
        vm.expectRevert(Box.PausedError.selector);
        boxes.buyWithChip(SKU1, alice, w, c * 2, block.timestamp);
        vm.expectRevert(Box.PausedError.selector);
        boxes.buyWithUsdcBatch(SKU1, alice, 2);
        vm.expectRevert(Box.PausedError.selector);
        boxes.buyWithChipBatch(SKU1, alice, 2, w * 2, c * 4, block.timestamp);
        vm.stopPrank();
    }

    function test_openRevertsWhenPaused() public {
        uint256 id = _buy1(alice);
        vm.prank(multisig);
        boxes.setPaused(true);
        uint128 fee = boxes.quoteOpenFee();
        vm.prank(alice);
        vm.expectRevert(Box.PausedError.selector);
        boxes.open{value: fee}(id);
    }

    function test_skuPauseBlocksBuyAndOpen() public {
        uint256 id = _buy1(alice);
        (uint256 w, uint256 c) = _chipQuote(USD1);
        vm.prank(multisig);
        boxes.setSkuPaused(SKU1, true);
        uint128 fee = boxes.quoteOpenFee();
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Box.SkuPausedError.selector, SKU1));
        boxes.buyWithUsdc(SKU1, alice);
        vm.expectRevert(abi.encodeWithSelector(Box.SkuPausedError.selector, SKU1));
        boxes.buyWithChip(SKU1, alice, w, c * 2, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(Box.SkuPausedError.selector, SKU1));
        boxes.open{value: fee}(id);
        // Other SKUs are unaffected.
        boxes.buyWithUsdc(SKU10, alice);
        vm.stopPrank();
    }

    function test_pauseIsOwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        boxes.setPaused(true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        boxes.setSkuPaused(SKU1, true);
    }

    /// @notice Was `test_chipDisabledWhenPriceZero`: CHIP is now a per-SKU switch (timelocked).
    function test_chipDisabledPerSku() public {
        vm.prank(multisig);
        boxes.queueSku(SKU1, true, uint96(USD1), false);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        boxes.executeSku();
        assertFalse(boxes.sku(SKU1).chipEnabled);

        (uint256 w, uint256 c) = _chipQuote(USD1);
        vm.startPrank(alice);
        vm.expectRevert(Box.ChipDisabled.selector);
        boxes.buyWithChip(SKU1, alice, w, c * 2, block.timestamp);
        vm.expectRevert(Box.ChipDisabled.selector);
        boxes.buyWithChipBatch(SKU1, alice, 1, w, c * 2, block.timestamp);
        uint256 id = boxes.buyWithUsdc(SKU1, alice);
        vm.stopPrank();
        assertEq(id, 1);
        // Other SKUs still take CHIP.
        _buyChip(alice, SKU10);
    }

    function test_noChipBoxDisablesChipPath() public {
        (PrizeVault v,) = _freshVaultAndConverter(address(0));
        Box bare = new Box(multisig, address(usdc), address(0), treasury, address(v), address(0), address(entropy));
        vm.prank(multisig);
        v.setBox(address(bare));
        usdc.mint(address(v), 200e6);

        assertEq(bare.rtpBps(), 9_100, "same table with or without a CHIP path");
        assertFalse(bare.sku(SKU1).chipEnabled);
        assertFalse(bare.sku(SKU10).chipEnabled);
        assertFalse(bare.sku(SKU25).chipEnabled);

        // A no-converter Box cannot switch CHIP on.
        vm.prank(multisig);
        vm.expectRevert(Box.BadConfig.selector);
        bare.queueSku(SKU1, true, uint96(USD1), true);

        vm.startPrank(alice);
        usdc.approve(address(bare), type(uint256).max);
        vm.expectRevert(Box.ChipDisabled.selector);
        bare.buyWithChip(SKU1, alice, 1, 1, block.timestamp);
        vm.expectRevert(Box.ChipDisabled.selector);
        bare.buyWithChipBatch(SKU1, alice, 1, 1, 1, block.timestamp);
        bare.buyWithUsdc(SKU1, alice);
        vm.stopPrank();
    }

    /* ------------------------------------------------------------------ */
    /*                           CONVERTER                                  */
    /* ------------------------------------------------------------------ */

    function test_converterSwapIsBoxOnly() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ChipConverter.NotBox.selector, alice));
        converter.swapToUsdc(USD1, 1, 1, alice);
    }

    function test_converterRescueIsOwnerOnlyAndAnyToken() public {
        chip.mint(address(converter), 5 ether);
        usdc.mint(address(converter), 7e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        converter.rescue(address(chip), alice, 5 ether);

        vm.startPrank(multisig);
        converter.rescue(address(chip), multisig, 5 ether);
        converter.rescue(address(usdc), multisig, 7e6);
        vm.stopPrank();
        assertEq(chip.balanceOf(multisig), 5 ether);
        assertEq(usdc.balanceOf(multisig), 7e6);
        _assertConverterEmpty();
    }

    function _assertConverterEmpty() internal view {
        (uint256 c, uint256 w, uint256 u) = converter.sweepZero();
        assertEq(c, 0, "converter holds no CHIP");
        assertEq(w, 0, "converter holds no WETH");
        assertEq(u, 0, "converter holds no USDC");
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
        assertEq(address(boxes).balance, 0);
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

    function test_openTwiceReverts() public {
        uint256 id = _buy1(alice);
        _open(alice, id);
        uint128 fee = boxes.quoteOpenFee();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Box.NotSealed.selector, id));
        boxes.open{value: fee}(id);
    }

    function test_openingBoxCannotBeTransferred() public {
        uint256 id = _buy1(alice);
        _open(alice, id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Box.BoxLocked.selector, id));
        boxes.transferFrom(alice, bob, id);
    }

    function test_callbackFromNonEntropyReverts() public {
        uint256 id = _buy1(alice);
        _open(alice, id);
        vm.expectRevert(Box.OnlyEntropy.selector);
        boxes._entropyCallback(1, address(this), bytes32(uint256(1)));
        vm.expectRevert(Box.OnlyEntropy.selector);
        boxes.entropyCallback(1, address(this), bytes32(uint256(1)));
    }

    function test_fulfillBurnsAndPaysMatchingPreview() public {
        uint256 id = _buy1(alice);
        bytes32 rand = _rollForTier(2); // 1.00x -> $1, a stock tier
        (uint8 tierId,, uint32 prizeBps, uint256 prizeUsd) = boxes.previewDraw(rand, SKU1);
        assertEq(tierId, 2);
        assertEq(prizeUsd, USD1);
        assertEq(prizeBps, 10_000);

        _openAndFulfill(alice, id, rand);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        boxes.ownerOf(id);
        assertEq(boxes.sealedSupply(SKU1), 0);
        assertEq(boxes.outstandingLiabilityUsd(), 0);
        // $1 at $100/NVDA; roll 7500 is even so NVDA (index 0) is tried first.
        assertEq(nvda.balanceOf(alice), 1e6);
    }

    /// @notice Was `test_chipTierPrizeIsEscrowedOnConverter`. Dust and Common now pay a stock
    ///         like every other tier: exact USD value, no $CHIP, nothing parked on the converter.
    function test_dustAndCommonTiersPayStockNotChip() public {
        uint256 aliceChip0 = chip.balanceOf(alice);

        // Common, 0.50x -> $0.50. Roll 4500 is even -> NVDA first. $0.50 at $100 = 0.005 NVDA.
        uint256 id = _buy1(alice);
        bytes32 rand = _rollForTier(1);
        (uint8 tierId,,, uint256 prizeUsd) = boxes.previewDraw(rand, SKU1);
        assertEq(tierId, 1);
        assertEq(prizeUsd, 500_000);
        uint64 seq = _open(alice, id);
        vm.expectEmit(true, true, true, true);
        emit BoxOpened(alice, id, seq, SKU1, 1, 5_000, 500_000, address(nvda), 5e5, 0, false, false);
        entropy.fulfill(seq, rand);
        assertEq(nvda.balanceOf(alice), 5e5);

        // Dust, 0.20x -> $0.20. Roll 0 -> NVDA first. $0.20 at $100 = 0.002 NVDA.
        uint256 id2 = _buy1(alice);
        _openAndFulfill(alice, id2, _rollForTier(0));
        assertEq(nvda.balanceOf(alice), 5e5 + 2e5);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        boxes.ownerOf(id);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id2));
        boxes.ownerOf(id2);
        assertEq(chip.balanceOf(alice), aliceChip0, "no prize is ever paid in CHIP");
        assertEq(usdc.balanceOf(address(converter)), 0, "nothing escrowed on the converter");
        assertEq(chip.balanceOf(address(converter)), 0);
        assertEq(boxes.outstandingLiabilityUsd(), 0);
    }

    function test_gifteeOpensNotBuyer() public {
        vm.prank(alice);
        uint256 id = boxes.buyWithUsdc(SKU1, bob);
        uint128 fee = boxes.quoteOpenFee();
        vm.prank(alice);
        vm.expectRevert(Box.NotOwner.selector);
        boxes.open{value: fee}(id);

        _openAndFulfill(bob, id, _rollForTier(0));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        boxes.ownerOf(id);
        assertEq(nvda.balanceOf(bob), 2e5, "Dust ($0.20) paid to the giftee in NVDA");
        assertEq(nvda.balanceOf(alice), 0);
    }

    function test_openEmitsDrawAndPrizeFields() public {
        uint256 id = _buy1(alice);
        bytes32 rand = _rollForTier(3); // 2.00x -> $2; roll 9000 even -> NVDA
        (uint8 tierId,, uint32 prizeBps, uint256 prizeUsd) = boxes.previewDraw(rand, SKU1);
        uint64 seq = _open(alice, id);

        vm.expectEmit(true, true, true, true);
        emit BoxOpened(alice, id, seq, SKU1, tierId, prizeBps, prizeUsd, address(nvda), 2e6, 0, false, false);
        entropy.fulfill(seq, rand);
    }

    function test_retryOpenAfterTimeout() public {
        uint256 id = _buy1(alice);
        uint64 oldSeq = _open(alice, id);
        uint128 fee = boxes.quoteOpenFee();
        uint64 readyAt = boxes.boxInfo(id).openingStartedAt + boxes.REVEAL_TIMEOUT();

        // The opener, too early.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Box.RevealNotTimedOut.selector, uint64(block.timestamp), readyAt));
        boxes.retryOpen{value: fee}(id);

        // Not the opener.
        vm.prank(bob);
        vm.expectRevert(Box.NotOwner.selector);
        boxes.retryOpen{value: fee}(id);

        vm.warp(block.timestamp + boxes.REVEAL_TIMEOUT());
        vm.prank(alice);
        boxes.retryOpen{value: fee}(id);
        uint64 newSeq = boxes.boxInfo(id).sequence;
        assertTrue(newSeq != oldSeq);
        assertEq(boxes.tokenIdOfRequest(address(entropy), oldSeq), 0);

        entropy.fulfill(oldSeq, bytes32(uint256(1)));
        assertEq(boxes.ownerOf(id), alice, "orphan callback does not burn");

        entropy.fulfill(newSeq, bytes32(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        boxes.ownerOf(id);
    }

    /* ------------------------------------------------------------------ */
    /*                         TREASURY TIMELOCK                            */
    /* ------------------------------------------------------------------ */

    function test_defaultFeeRecipientIsFeeSplitter() public {
        assertEq(boxes.DEFAULT_FEE_RECIPIENT(), 0xb9b76e1835afE05e5A73065FE01A19B14869F8A3);
        assertEq(boxes.feeRecipient(), boxes.treasury());
        (PrizeVault v, ChipConverter c) = _freshVaultAndConverter(address(chip));
        address dflt = boxes.DEFAULT_FEE_RECIPIENT();
        Box launch = new Box(
            multisig, address(usdc), address(chip), dflt, address(v), address(c), address(entropy)
        );
        assertEq(launch.treasury(), dflt);
        assertEq(launch.feeRecipient(), dflt);
    }

    function test_constructorCanOverrideFeeRecipient() public {
        (PrizeVault v, ChipConverter c) = _freshVaultAndConverter(address(chip));
        Box other = new Box(
            multisig, address(usdc), address(chip), alice, address(v), address(c), address(entropy)
        );
        assertEq(other.feeRecipient(), alice);
        assertTrue(other.feeRecipient() != other.DEFAULT_FEE_RECIPIENT());
    }

    function test_treasuryChangeIsTimelocked() public {
        address nextSafe = makeAddr("nextSafe");
        uint64 t0 = uint64(block.timestamp);
        vm.prank(multisig);
        boxes.queueTreasury(nextSafe);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(Box.TimelockNotElapsed.selector, t0, t0 + 48 hours));
        boxes.executeTreasury();

        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        boxes.executeTreasury();
        assertEq(boxes.treasury(), nextSafe);
        assertEq(boxes.feeRecipient(), nextSafe);

        _buy1(alice);
        assertEq(usdc.balanceOf(nextSafe), 50_000, "fee follows the new recipient");
    }

    function test_treasuryTimelockExpiresAndCancels() public {
        address nextSafe = makeAddr("nextSafe");
        uint64 expiresAt = uint64(block.timestamp) + 48 hours + 14 days;
        vm.prank(multisig);
        boxes.queueTreasury(nextSafe);
        vm.warp(expiresAt + 1);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(Box.TimelockExpired.selector, expiresAt + 1, expiresAt));
        boxes.executeTreasury();

        vm.prank(multisig);
        boxes.cancelTreasury();
        vm.prank(multisig);
        vm.expectRevert(Box.NothingQueued.selector);
        boxes.executeTreasury();
        assertEq(boxes.treasury(), treasury);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        boxes.queueTreasury(alice);
    }

    function test_skuAndOddsChangesAreTimelocked() public {
        IBox.PrizeTier[] memory flat = new IBox.PrizeTier[](1);
        flat[0] = IBox.PrizeTier({weight: 10_000, prizeBps: 9_000});

        vm.startPrank(multisig);
        boxes.queueSku(SKU1, true, uint96(2 * USD1), true);
        boxes.queueOdds(flat);
        uint64 nowTs = uint64(block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(Box.TimelockNotElapsed.selector, nowTs, nowTs + 48 hours));
        boxes.executeSku();
        vm.expectRevert(abi.encodeWithSelector(Box.TimelockNotElapsed.selector, nowTs, nowTs + 48 hours));
        boxes.executeOdds();
        vm.stopPrank();

        vm.warp(block.timestamp + 48 hours);
        vm.startPrank(multisig);
        boxes.executeSku();
        boxes.executeOdds();
        vm.stopPrank();
        assertEq(boxes.sku(SKU1).usdcPrice, 2 * USD1);
        assertEq(boxes.rtpBps(), 9_000);
        assertEq(boxes.oddsVersion(), 1);
    }

    function test_queueOddsRejectsBadTables() public {
        IBox.PrizeTier[] memory shortW = new IBox.PrizeTier[](1);
        shortW[0] = IBox.PrizeTier({weight: 9_999, prizeBps: 9_000});
        IBox.PrizeTier[] memory empty = new IBox.PrizeTier[](0);
        IBox.PrizeTier[] memory zeroBps = new IBox.PrizeTier[](1);
        zeroBps[0] = IBox.PrizeTier({weight: 10_000, prizeBps: 0});

        vm.startPrank(multisig);
        vm.expectRevert(Box.BadConfig.selector);
        boxes.queueOdds(shortW);
        vm.expectRevert(Box.BadConfig.selector);
        boxes.queueOdds(empty);
        vm.expectRevert(Box.BadConfig.selector);
        boxes.queueOdds(zeroBps);
        vm.stopPrank();
    }

    function test_launchSkusAreOneTenTwentyFive() public view {
        assertEq(boxes.MAX_SKUS(), 3);
        assertTrue(boxes.sku(SKU1).exists);
        assertTrue(boxes.sku(SKU10).exists);
        assertTrue(boxes.sku(SKU25).exists);
        assertEq(boxes.sku(SKU1).usdcPrice, USD1);
        assertEq(boxes.sku(SKU10).usdcPrice, USD10);
        assertEq(boxes.sku(SKU25).usdcPrice, USD25);
        assertTrue(boxes.sku(SKU1).chipEnabled);
        assertTrue(boxes.sku(SKU10).chipEnabled);
        assertTrue(boxes.sku(SKU25).chipEnabled);
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
        boxes.buyWithChip(3, alice, 1, 1, block.timestamp);
    }

}
