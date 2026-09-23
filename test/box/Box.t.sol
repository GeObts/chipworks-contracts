// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Box} from "../../src/box/Box.sol";
import {PrizeVault} from "../../src/box/PrizeVault.sol";
import {ChipConverter} from "../../src/box/ChipConverter.sol";
import {IBox} from "../../src/interfaces/IBox.sol";
import {IChipConverter} from "../../src/interfaces/IChipConverter.sol";
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
        uint256 toVault,
        uint256 toConverter
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
        uint256 chipPrizeId,
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

    function test_launchTableChipTiersAreDustAndCommonOnly() public view {
        IBox.PrizeTier[] memory tiers = boxes.oddsTable();
        assertTrue(tiers[0].payInChip, "Dust pays CHIP");
        assertTrue(tiers[1].payInChip, "Common pays CHIP");
        for (uint256 i = 2; i < tiers.length; ++i) {
            assertFalse(tiers[i].payInChip, "Uncommon and up pay a stock");
        }
    }

    function test_everyRollMapsToATier() public view {
        uint16[6] memory weights = [uint16(4_500), 3_000, 1_500, 700, 250, 50];
        uint256[6] memory hits;
        for (uint256 roll; roll < 10_000; ++roll) {
            (uint8 tierId,,,,) = boxes.previewDraw(bytes32(roll), SKU1);
            hits[tierId] += 1;
        }
        for (uint256 i; i < 6; ++i) {
            assertEq(hits[i], weights[i], "UI must match this mapping exactly");
        }
    }

    function test_prizeScalesWithSkuPrice() public view {
        bytes32 dust = bytes32(uint256(0));
        (,, uint32 prizeBps, uint256 prize1,) = boxes.previewDraw(dust, SKU1);
        (,, uint32 prizeBps10, uint256 prize10,) = boxes.previewDraw(dust, SKU10);
        (,, uint32 prizeBps25, uint256 prize25,) = boxes.previewDraw(dust, SKU25);
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
        (uint8 a, uint16 w, uint32 bps, uint256 usd, bool inChip) = boxes.previewDraw(rand, skuId);
        (uint8 a2, uint16 w2, uint32 bps2, uint256 usd2, bool inChip2) = boxes.previewDraw(rand, skuId);
        assertEq(a, a2);
        assertEq(w, w2);
        assertEq(bps, bps2);
        assertEq(usd, usd2);
        assertEq(inChip, inChip2);
        assertLt(a, 6);
        assertEq(usd, price * bps / 10_000);
        assertEq(inChip, a < 2, "only Dust/Common pay CHIP");
    }

    /* ------------------------------------------------------------------ */
    /*                      BUY + FEE SPLIT                                 */
    /* ------------------------------------------------------------------ */

    function test_buyWithUsdc_splitsFivePercentToTreasury() public {
        uint256 tre0 = usdc.balanceOf(treasury);
        uint256 vault0 = usdc.balanceOf(address(vault));

        vm.expectEmit(true, true, true, true);
        emit BoxPurchased(alice, alice, 1, SKU1, address(usdc), USD1, 50_000, 950_000, 0);

        uint256 id = _buy1(alice);
        assertEq(id, 1);
        assertEq(boxes.ownerOf(1), alice);
        assertEq(boxes.boxInfo(1).state, boxes.STATE_SEALED());
        assertEq(boxes.sealedSupply(SKU1), 1);

        assertEq(usdc.balanceOf(treasury) - tre0, 50_000);
        assertEq(usdc.balanceOf(address(vault)) - vault0, 950_000);
        assertEq(usdc.balanceOf(address(boxes)), 0, "box holds nothing between calls");
        assertEq(usdc.balanceOf(address(converter)), 0, "USDC buy never touches the converter");
    }

    /// @notice A $CHIP buy sends the WHOLE payment to the converter. The 5/95 split happens
    ///         later, in USDC, when the keeper sells it (H-01 redone).
    function test_buyWithChip_sendsWholePaymentToConverter() public {
        uint256 tre0 = chip.balanceOf(treasury);
        uint256 conv0 = chip.balanceOf(address(converter));

        vm.expectEmit(true, true, true, true);
        emit BoxPurchased(alice, alice, 1, SKU1, address(chip), CHIP1, 0, 0, CHIP1);

        vm.prank(alice);
        uint256 id = boxes.buyWithChip(SKU1, alice);

        assertEq(boxes.ownerOf(id), alice);
        assertEq(chip.balanceOf(address(converter)) - conv0, CHIP1);
        assertEq(chip.balanceOf(treasury) - tre0, 0, "no CHIP fee: the fee is taken in USDC on sale");
        assertEq(chip.balanceOf(address(vault)), 0, "vault never receives CHIP");
        assertEq(chip.balanceOf(address(boxes)), 0);
    }

    function test_buyOneTenTwentyFiveUsdcAndChip() public {
        uint256 treUsdc0 = usdc.balanceOf(treasury);
        uint256 vaultUsdc0 = usdc.balanceOf(address(vault));
        uint256 conv0 = chip.balanceOf(address(converter));

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
        assertEq(usdc.balanceOf(treasury) - treUsdc0, usdcFee);
        assertEq(chip.balanceOf(treasury), 0);
        assertEq(usdc.balanceOf(address(vault)) - vaultUsdc0, usdcPaid - usdcFee);
        assertEq(chip.balanceOf(address(vault)), 0);
        assertEq(chip.balanceOf(address(converter)) - conv0, chipPaid);
        assertEq(usdc.balanceOf(address(boxes)), 0);
        assertEq(chip.balanceOf(address(boxes)), 0);
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
    }

    function test_buyToZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(Box.ZeroAddress.selector);
        boxes.buyWithUsdc(SKU1, address(0));
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

    function test_chipBatchBuy() public {
        vm.prank(alice);
        uint256 first = boxes.buyWithChipBatch(SKU10, bob, 4);
        assertEq(first, 1);
        assertEq(boxes.ownerOf(4), bob);
        assertEq(boxes.sealedSupply(SKU10), 4);
        assertEq(chip.balanceOf(address(converter)), 4 * uint256(CHIP10));
        assertEq(chip.balanceOf(address(vault)), 0);
    }

    function test_batchLimits() public {
        uint256 max = boxes.MAX_BATCH();
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Box.BatchTooLarge.selector, uint256(0)));
        boxes.buyWithUsdcBatch(SKU1, alice, 0);
        vm.expectRevert(abi.encodeWithSelector(Box.BatchTooLarge.selector, max + 1));
        boxes.buyWithUsdcBatch(SKU1, alice, max + 1);
        vm.expectRevert(abi.encodeWithSelector(Box.BatchTooLarge.selector, uint256(0)));
        boxes.buyWithChipBatch(SKU1, alice, 0);
        vm.expectRevert(abi.encodeWithSelector(Box.BatchTooLarge.selector, max + 1));
        boxes.buyWithChipBatch(SKU1, alice, max + 1);
        uint256 first = boxes.buyWithUsdcBatch(SKU1, alice, max);
        vm.stopPrank();
        assertEq(first, 1);
        assertEq(boxes.sealedSupply(SKU1), max);
    }

    function test_buyRevertsWhenPaused() public {
        vm.prank(multisig);
        boxes.setPaused(true);
        vm.startPrank(alice);
        vm.expectRevert(Box.PausedError.selector);
        boxes.buyWithUsdc(SKU1, alice);
        vm.expectRevert(Box.PausedError.selector);
        boxes.buyWithChip(SKU1, alice);
        vm.expectRevert(Box.PausedError.selector);
        boxes.buyWithUsdcBatch(SKU1, alice, 2);
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
        vm.prank(multisig);
        boxes.setSkuPaused(SKU1, true);
        uint128 fee = boxes.quoteOpenFee();
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Box.SkuPausedError.selector, SKU1));
        boxes.buyWithUsdc(SKU1, alice);
        vm.expectRevert(abi.encodeWithSelector(Box.SkuPausedError.selector, SKU1));
        boxes.open{value: fee}(id);
        // Other SKUs are unaffected.
        boxes.buyWithUsdc(SKU10, alice);
        vm.stopPrank();
    }

    function test_pauseIsOwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert();
        boxes.setPaused(true);
        vm.prank(alice);
        vm.expectRevert();
        boxes.setSkuPaused(SKU1, true);
    }

    function test_chipDisabledWhenPriceZero() public {
        (PrizeVault v, ChipConverter c) = _freshVaultAndConverter(address(chip));
        Box bare = new Box(
            multisig, address(usdc), address(chip), treasury, address(v), address(c), address(entropy), 0, CHIP10, CHIP25
        );
        vm.startPrank(multisig);
        v.setBox(address(bare));
        c.setBox(address(bare));
        vm.stopPrank();
        usdc.mint(address(v), 200e6); // covers the $36 SKU1 top prize at 25%

        vm.startPrank(alice);
        usdc.approve(address(bare), type(uint256).max);
        chip.approve(address(bare), type(uint256).max);
        vm.expectRevert(Box.ChipDisabled.selector);
        bare.buyWithChip(SKU1, alice);
        vm.expectRevert(Box.ChipDisabled.selector);
        bare.buyWithChipBatch(SKU1, alice, 1);
        uint256 id = bare.buyWithUsdc(SKU1, alice);
        vm.stopPrank();
        assertEq(id, 1);
    }

    function test_noChipBoxDisablesChipPathAndChipTiers() public {
        (PrizeVault v,) = _freshVaultAndConverter(address(0));
        Box bare = new Box(
            multisig, address(usdc), address(0), treasury, address(v), address(0), address(entropy), CHIP1, CHIP10, CHIP25
        );
        vm.prank(multisig);
        v.setBox(address(bare));
        usdc.mint(address(v), 200e6);

        IBox.PrizeTier[] memory tiers = bare.oddsTable();
        for (uint256 i; i < tiers.length; ++i) {
            assertFalse(tiers[i].payInChip, "no converter, no CHIP tiers");
        }
        assertEq(bare.rtpBps(), 9_100, "same RTP either way");

        vm.startPrank(alice);
        usdc.approve(address(bare), type(uint256).max);
        vm.expectRevert(Box.ChipDisabled.selector);
        bare.buyWithChip(SKU1, alice);
        bare.buyWithUsdc(SKU1, alice);
        vm.stopPrank();
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
        (uint8 tierId,, uint32 prizeBps, uint256 prizeUsd, bool inChip) = boxes.previewDraw(rand, SKU1);
        assertEq(tierId, 2);
        assertEq(prizeUsd, USD1);
        assertEq(prizeBps, 10_000);
        assertFalse(inChip);

        _openAndFulfill(alice, id, rand);

        vm.expectRevert();
        boxes.ownerOf(id);
        assertEq(boxes.sealedSupply(SKU1), 0);
        assertEq(boxes.outstandingLiabilityUsd(), 0);
        // $1 at $100/NVDA; roll 7500 is even so NVDA (index 0) is tried first.
        assertEq(nvda.balanceOf(alice), 1e6);
    }

    function test_chipTierPrizeIsEscrowedOnConverter() public {
        uint256 id = _buy1(alice);
        bytes32 rand = _rollForTier(1); // Common, 0.50x -> $0.50 in CHIP
        (uint8 tierId,,, uint256 prizeUsd, bool inChip) = boxes.previewDraw(rand, SKU1);
        assertEq(tierId, 1);
        assertTrue(inChip);
        assertEq(prizeUsd, 500_000);

        uint256 vault0 = usdc.balanceOf(address(vault));
        uint256 prizeId = converter.nextPrizeId();
        _openAndFulfill(alice, id, rand);

        vm.expectRevert();
        boxes.ownerOf(id);
        assertEq(vault0 - usdc.balanceOf(address(vault)), prizeUsd, "vault paid the USD prize in USDC");
        assertEq(converter.escrowedUsdc(), prizeUsd);
        assertEq(usdc.balanceOf(address(converter)), prizeUsd);
        IChipConverter.ChipPrize memory p = converter.chipPrize(prizeId);
        assertEq(p.winner, alice);
        assertEq(p.usdcAmount, prizeUsd);
        assertFalse(p.settled);
        assertEq(chip.balanceOf(alice), 100 * uint256(CHIP_PER_USD) * 100, "CHIP arrives later, from the converter");
    }

    function test_gifteeOpensNotBuyer() public {
        vm.prank(alice);
        uint256 id = boxes.buyWithUsdc(SKU1, bob);
        uint128 fee = boxes.quoteOpenFee();
        vm.prank(alice);
        vm.expectRevert(Box.NotOwner.selector);
        boxes.open{value: fee}(id);

        uint256 prizeId = converter.nextPrizeId();
        _openAndFulfill(bob, id, _rollForTier(0));
        vm.expectRevert();
        boxes.ownerOf(id);
        assertEq(converter.chipPrize(prizeId).winner, bob, "Dust prize is escrowed for the giftee");
    }

    function test_openEmitsDrawAndPrizeFields() public {
        uint256 id = _buy1(alice);
        bytes32 rand = _rollForTier(3); // 2.00x -> $2; roll 9000 even -> NVDA
        (uint8 tierId,, uint32 prizeBps, uint256 prizeUsd,) = boxes.previewDraw(rand, SKU1);
        uint64 seq = _open(alice, id);

        vm.expectEmit(true, true, true, true);
        emit BoxOpened(alice, id, seq, SKU1, tierId, prizeBps, prizeUsd, address(nvda), 2e6, 0, 0, false, false);
        entropy.fulfill(seq, rand);
    }

    function test_retryOpenAfterTimeout() public {
        uint256 id = _buy1(alice);
        uint64 oldSeq = _open(alice, id);
        uint128 fee = boxes.quoteOpenFee();

        vm.prank(alice);
        vm.expectRevert();
        boxes.retryOpen{value: fee}(id);

        vm.prank(bob);
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

    function test_defaultFeeRecipientIsFeeSplitter() public {
        assertEq(boxes.DEFAULT_FEE_RECIPIENT(), 0xb9b76e1835afE05e5A73065FE01A19B14869F8A3);
        assertEq(boxes.feeRecipient(), boxes.treasury());
        (PrizeVault v, ChipConverter c) = _freshVaultAndConverter(address(chip));
        address dflt = boxes.DEFAULT_FEE_RECIPIENT();
        Box launch = new Box(
            multisig, address(usdc), address(chip), dflt, address(v), address(c), address(entropy), CHIP1, CHIP10, CHIP25
        );
        assertEq(launch.treasury(), dflt);
        assertEq(launch.feeRecipient(), dflt);
    }

    function test_constructorCanOverrideFeeRecipient() public {
        (PrizeVault v, ChipConverter c) = _freshVaultAndConverter(address(chip));
        Box other = new Box(
            multisig, address(usdc), address(chip), alice, address(v), address(c), address(entropy), CHIP1, CHIP10, CHIP25
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

        _buy1(alice);
        assertEq(usdc.balanceOf(nextSafe), 50_000, "fee follows the new recipient");
    }

    function test_treasuryTimelockExpiresAndCancels() public {
        address nextSafe = makeAddr("nextSafe");
        vm.prank(multisig);
        boxes.queueTreasury(nextSafe);
        vm.warp(block.timestamp + 48 hours + 14 days + 1);
        vm.prank(multisig);
        vm.expectRevert();
        boxes.executeTreasury();

        vm.prank(multisig);
        boxes.cancelTreasury();
        vm.prank(multisig);
        vm.expectRevert(Box.NothingQueued.selector);
        boxes.executeTreasury();
        assertEq(boxes.treasury(), treasury);

        vm.prank(alice);
        vm.expectRevert();
        boxes.queueTreasury(alice);
    }

    function test_skuAndOddsChangesAreTimelocked() public {
        IBox.PrizeTier[] memory flat = new IBox.PrizeTier[](1);
        flat[0] = IBox.PrizeTier({weight: 10_000, prizeBps: 9_000, payInChip: false});

        vm.startPrank(multisig);
        boxes.queueSku(SKU1, true, uint96(2 * USD1), CHIP1);
        boxes.queueOdds(flat);
        vm.expectRevert();
        boxes.executeSku();
        vm.expectRevert();
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
        shortW[0] = IBox.PrizeTier({weight: 9_999, prizeBps: 9_000, payInChip: false});
        IBox.PrizeTier[] memory empty = new IBox.PrizeTier[](0);
        IBox.PrizeTier[] memory zeroBps = new IBox.PrizeTier[](1);
        zeroBps[0] = IBox.PrizeTier({weight: 10_000, prizeBps: 0, payInChip: false});

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
