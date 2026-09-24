// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BoxTestBase} from "./BoxTestBase.sol";
import {Box} from "../../src/box/Box.sol";
import {PrizeVault} from "../../src/box/PrizeVault.sol";
import {ChipConverter} from "../../src/box/ChipConverter.sol";
import {IBox} from "../../src/interfaces/IBox.sol";
import {Venue} from "../../src/interfaces/IStockRegistry.sol";

/// @notice The rebuild's own properties: CHIP never parked, stocks-only prizes, never-short
///         payouts, the sell gate, keeper restock and the house-take sweep. Every expected
///         amount follows from the base's round prices (NVDA $100, TSLA $200, ETH $2,000,
///         20,000 CHIP = $1).
contract BoxRebuildTest is BoxTestBase {
    uint8 internal constant DUST = 0;
    uint8 internal constant COMMON = 1;
    uint8 internal constant UNCOMMON = 2;
    uint8 internal constant JACKPOT = 5;

    function _deadline() internal view returns (uint256) {
        return block.timestamp + 600;
    }

    /* ------------------------------------------------------------------ */
    /*                  1. $CHIP payments: never parked                     */
    /* ------------------------------------------------------------------ */

    function test_chipBuy_sendsWholePaymentToConverter() public {
        uint256 vaultUsdc0 = usdc.balanceOf(address(vault));
        vm.prank(alice);
        boxes.buyWithChip(SKU10, alice);

        assertEq(chip.balanceOf(address(converter)), CHIP10, "whole payment to converter");
        assertEq(chip.balanceOf(address(vault)), 0, "vault never holds CHIP");
        assertEq(chip.balanceOf(treasury), 0, "fee recipient never gets CHIP");
        assertEq(chip.balanceOf(address(boxes)), 0, "box holds nothing");
        assertEq(usdc.balanceOf(address(vault)), vaultUsdc0, "no USDC until the keeper sells");
        assertEq(boxes.outstandingLiabilityUsd(), 9_100_000, "liability is booked at mint");
    }

    function test_sellChip_splitsUsdcFiveNinetyFive() public {
        vm.prank(alice);
        boxes.buyWithChip(SKU10, alice);
        uint256 vaultUsdc0 = usdc.balanceOf(address(vault));

        // 200,000 CHIP -> 0.005 ETH -> $10.
        vm.prank(keeper);
        uint256 out = converter.sellChip(CHIP10, 10e6, _deadline());

        assertEq(out, 10e6, "200k CHIP sells for $10");
        assertEq(usdc.balanceOf(treasury), 500_000, "5% to the fee recipient");
        assertEq(usdc.balanceOf(address(vault)) - vaultUsdc0, 9_500_000, "95% to the vault");
        assertEq(chip.balanceOf(address(converter)), 0, "nothing left behind");
        assertEq(usdc.balanceOf(address(converter)), 0, "no USDC left behind");
    }

    function test_sellChip_boundsTheKeeper() public {
        vm.prank(alice);
        boxes.buyWithChip(SKU10, alice);

        vm.expectRevert(abi.encodeWithSelector(ChipConverter.NotKeeper.selector, alice));
        vm.prank(alice);
        converter.sellChip(CHIP10, 0, _deadline());

        // The keeper's own floor.
        vm.expectRevert(abi.encodeWithSelector(ChipConverter.BelowMinOut.selector, 10e6, 10e6 + 1));
        vm.prank(keeper);
        converter.sellChip(CHIP10, 10e6 + 1, _deadline());

        // The owner's floor: $10 per 200k CHIP is $50 per million. A floor of $60 refuses it,
        // whatever minimum the keeper passes.
        vm.prank(multisig);
        converter.setPriceFloor(60e6);
        vm.expectRevert(abi.encodeWithSelector(ChipConverter.BelowPriceFloor.selector, 50e6, 60e6));
        vm.prank(keeper);
        converter.sellChip(CHIP10, 0, _deadline());

        // Per-call and per-day caps.
        vm.startPrank(multisig);
        converter.setPriceFloor(0);
        converter.setLimits(CHIP10 - 1, type(uint256).max);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(ChipConverter.OverCap.selector, CHIP10, CHIP10 - 1));
        vm.prank(keeper);
        converter.sellChip(CHIP10, 0, _deadline());

        vm.prank(multisig);
        converter.setLimits(CHIP10, CHIP10 / 2);
        vm.expectRevert(abi.encodeWithSelector(ChipConverter.OverDailyCap.selector, CHIP10, CHIP10 / 2));
        vm.prank(keeper);
        converter.sellChip(CHIP10, 0, _deadline());
    }

    function test_sellChip_refusesAStaleEthMark() public {
        vm.prank(alice);
        boxes.buyWithChip(SKU10, alice);
        vm.warp(block.timestamp + 2 hours); // the mock feed was stamped at setUp
        vm.expectRevert(ChipConverter.BadEthPrice.selector);
        vm.prank(keeper);
        converter.sellChip(CHIP10, 0, _deadline());
    }

    function test_chipRecovery_isTimelocked_andRescueNeverTakesChip() public {
        vm.prank(alice);
        boxes.buyWithChip(SKU10, alice);

        vm.startPrank(multisig);
        vm.expectRevert(abi.encodeWithSelector(ChipConverter.ProtectedAsset.selector, address(chip)));
        converter.rescue(address(chip), multisig, 1);

        converter.queueChipRecovery(multisig);
        vm.expectRevert();
        converter.executeChipRecovery();
        vm.warp(block.timestamp + 48 hours);
        converter.executeChipRecovery();
        vm.stopPrank();
        assertEq(chip.balanceOf(multisig), CHIP10, "route-broken recovery returns all of it");
    }

    /* ------------------------------------------------------------------ */
    /*                  2. Prizes are stocks, never $CHIP                    */
    /* ------------------------------------------------------------------ */

    /// @dev Every tier, Dust to Jackpot, pays a stock at the registry mark. The rolls used here
    ///      are all even, so the stock walk starts at NVDA ($100): the raw 8-dp NVDA paid equals
    ///      the 6-dp USD prize exactly.
    function test_everyTier_paysAStock_neverChip() public {
        uint256[6] memory prize = [uint256(2e6), 5e6, 10e6, 20e6, 80e6, 360e6];
        uint256 convChip0 = chip.balanceOf(address(converter));
        for (uint8 t; t < 6; ++t) {
            uint256 id = _buyUsdc(alice, SKU10);
            uint256 n0 = nvda.balanceOf(alice);
            uint256 c0 = chip.balanceOf(alice);
            _openAndFulfill(alice, id, _rollForTier(t));
            assertEq(nvda.balanceOf(alice) - n0, prize[t], "the exact prize, in NVDA");
            assertEq(chip.balanceOf(alice), c0, "never paid in CHIP");
        }
        assertEq(chip.balanceOf(address(converter)), convChip0, "the converter is not involved");
        assertEq(boxes.outstandingLiabilityUsd(), 0);
    }

    function test_stockTier_paysAStock() public {
        uint256 id = _buyUsdc(alice, SKU10);
        uint256 n0 = nvda.balanceOf(alice);
        uint256 t0 = tsla.balanceOf(alice);
        _openAndFulfill(alice, id, _rollForTier(UNCOMMON)); // $10
        uint256 gotN = nvda.balanceOf(alice) - n0;
        uint256 gotT = tsla.balanceOf(alice) - t0;
        assertTrue(gotN == 0.1e8 || gotT == 0.05e8, "$10 of NVDA ($100) or TSLA ($200)");
    }

    function test_noStockCanCover_paysTheUsdcFallback() public {
        vm.startPrank(multisig);
        vault.setStockEnabled(address(nvda), false);
        vault.setStockEnabled(address(tsla), false);
        vm.stopPrank();
        // With the stocks out of inventory the pool is $10,000 of USDC: the $10 SKU is covered.
        uint256 id = _buyUsdc(alice, SKU10);
        uint256 u0 = usdc.balanceOf(alice);
        _openAndFulfill(alice, id, _rollForTier(DUST)); // $2
        assertEq(usdc.balanceOf(alice) - u0, 2e6, "the full $2, in USDC");
    }

    /* ------------------------------------------------------------------ */
    /*               3. Honest odds: gate and owed prizes                   */
    /* ------------------------------------------------------------------ */

    function test_sellGate_opensSkusAsThePoolGrows() public {
        (Box b2, PrizeVault v2,) = _freshSystem(144e6); // cap $36: exactly the $1 jackpot
        assertTrue(b2.isSkuCovered(SKU1));
        assertFalse(b2.isSkuCovered(SKU10));
        assertFalse(b2.isSkuCovered(SKU25));

        _approveBox(alice, b2);
        vm.prank(alice);
        b2.buyWithUsdc(SKU1, alice);
        vm.expectRevert(abi.encodeWithSelector(Box.SkuNotCovered.selector, SKU10, 360e6, v2.prizeCapUsd()));
        vm.prank(alice);
        b2.buyWithUsdc(SKU10, alice);

        usdc.mint(address(v2), 1_440e6); // volume arrives
        assertTrue(b2.isSkuCovered(SKU10), "the $10 box unlocks by itself");
        vm.prank(alice);
        b2.buyWithUsdc(SKU10, alice);
    }

    function test_owed_thenClaimedInFullOnceThePoolCan() public {
        // $100 USDC + $100 NVDA: cap $50 covers the $36 jackpot of a $1 box.
        (Box b2, PrizeVault v2,) = _freshSystem(100e6);
        nvda.mint(address(v2), 1e8);
        _approveBox(alice, b2);
        vm.prank(alice);
        uint256 id = b2.buyWithUsdc(SKU1, alice);

        // Before the reveal, the NVDA mark goes stale: inventory ~$100.95, cap ~$25.
        registry.setStalePrice(address(nvda), NVDA_PRICE, block.timestamp - 6 days);
        uint64 seq = _openOn(b2, alice, id);
        entropy.fulfill(seq, _rollForTierOn(b2, JACKPOT));

        IBox.BoxView memory info = b2.boxInfo(id);
        assertEq(info.state, 3, "owed, not paid short and not re-rolled");
        assertEq(info.owedUsd, 36e6);
        assertEq(b2.outstandingLiabilityUsd(), 36e6, "liability is now the exact prize");
        assertEq(b2.ownerOf(id), alice, "not burned");

        vm.expectRevert(abi.encodeWithSelector(Box.StillUnpayable.selector, id, 36e6));
        b2.claimOwed(id);

        // Owed boxes stay with the opener.
        vm.expectRevert(abi.encodeWithSelector(Box.BoxLocked.selector, id));
        vm.prank(alice);
        b2.transferFrom(alice, bob, id);

        registry.setPrice(address(nvda), NVDA_PRICE); // mark fresh again: cap ~$50
        uint256 before = usdc.balanceOf(alice) + nvda.balanceOf(alice) * 1e6 / 1e8 * 100;
        vm.prank(bob); // anyone may push it; it pays the opener
        b2.claimOwed(id);
        uint256 afterBal = usdc.balanceOf(alice) + nvda.balanceOf(alice) * 1e6 / 1e8 * 100;
        assertEq(afterBal - before, 36e6, "the full $36, to the opener");
        assertEq(b2.outstandingLiabilityUsd(), 0);
    }

    /// @dev The re-roll hole: a callback that FAILED has had its random number published by
    ///      Pyth. retryOpen must refuse it however long the holder waits; the only way forward
    ///      is Pyth's revealWithCallback, which re-runs the callback with the SAME number.
    function test_retryOpen_refusesARevealThatFailed_evenAfterTheTimeout() public {
        uint256 id = _buy1(alice);
        uint64 seq = _open(alice, id);
        entropy.setStatus(seq, 3); // CALLBACK_FAILED: the number is public
        vm.warp(block.timestamp + boxes.REVEAL_TIMEOUT());
        uint128 fee = boxes.quoteOpenFee();
        vm.expectRevert(abi.encodeWithSelector(Box.RevealAlreadyPublic.selector, id, uint8(3)));
        vm.prank(alice);
        boxes.retryOpen{value: fee}(id);

        // Recovery is the same number, delivered again: the box pays that draw, not a new one.
        entropy.setStatus(seq, 1);
        registry.setPrice(address(nvda), NVDA_PRICE); // 30 days on, the marks need a fresh stamp
        registry.setPrice(address(tsla), TSLA_PRICE);
        uint256 n0 = nvda.balanceOf(alice);
        entropy.fulfill(seq, _rollForTier(2)); // Uncommon, $1
        assertEq(nvda.balanceOf(alice) - n0, 1e6, "the original draw is what pays");
    }

    /// @dev The gas bound: at most 16 stocks can ever be listed, and the callback gas can never be
    ///      set below what 16 need (measured ~683k with real B20s; the floor is 900k).
    function test_stockListAndCallbackGasAreBothBounded() public {
        uint256 cap = vault.MAX_STOCKS();
        assertEq(cap, 16);
        vm.startPrank(multisig);
        for (uint256 i = vault.stockCount(); i < cap; ++i) {
            MockERC20_ t = new MockERC20_();
            registry.setStock(address(t), Venue.Slipstream, 0, 10, 8, true);
            vault.addStock(address(t));
        }
        MockERC20_ extra = new MockERC20_();
        registry.setStock(address(extra), Venue.Slipstream, 0, 10, 8, true);
        vm.expectRevert(PrizeVault.TooManyStocks.selector);
        vault.addStock(address(extra));

        // Disabling does not free a slot: every stock ever listed is still walked.
        vault.setStockEnabled(address(nvda), false);
        vm.expectRevert(PrizeVault.TooManyStocks.selector);
        vault.addStock(address(extra));

        uint32 floor = boxes.MIN_CALLBACK_GAS();
        assertEq(floor, 900_000);
        vm.expectRevert(Box.BadConfig.selector);
        boxes.setCallbackGasLimit(floor - 1);
        boxes.setCallbackGasLimit(floor);
        vm.stopPrank();
        assertEq(boxes.callbackGasLimit(), 900_000);
    }

    function test_retryOpen_waitsThirtyDays() public {
        uint256 id = _buy1(alice);
        _open(alice, id);
        assertEq(boxes.REVEAL_TIMEOUT(), 30 days);
        vm.warp(block.timestamp + 30 days - 1);
        uint128 fee = boxes.quoteOpenFee();
        vm.expectRevert();
        vm.prank(alice);
        boxes.retryOpen{value: fee}(id);
    }

    /* ------------------------------------------------------------------ */
    /*                     4. Keeper restock                                */
    /* ------------------------------------------------------------------ */

    function test_restock_buysIntoTheVault_withinBounds() public {
        vm.prank(multisig);
        vault.setRestockParams(5_000e6, 20_000e6, 200, 2_000);
        uint256 n0 = nvda.balanceOf(address(vault));
        uint256 u0 = usdc.balanceOf(address(vault));

        vm.prank(keeper);
        uint256 got = vault.restock(address(nvda), 1_000e6);

        assertEq(got, 10e8, "$1,000 of NVDA at $100");
        assertEq(nvda.balanceOf(address(vault)) - n0, 10e8, "lands in the vault");
        assertEq(u0 - usdc.balanceOf(address(vault)), 1_000e6);
        assertEq(nvda.balanceOf(keeper), 0, "the keeper holds nothing");
    }

    function test_restock_refusals() public {
        vm.prank(multisig);
        vault.setRestockParams(1_000e6, 1_500e6, 200, 2_000);

        vm.expectRevert(abi.encodeWithSelector(PrizeVault.NotKeeper.selector, alice));
        vm.prank(alice);
        vault.restock(address(nvda), 100e6);

        vm.expectRevert(abi.encodeWithSelector(PrizeVault.OverCap.selector, 1_001e6, 1_000e6));
        vm.prank(keeper);
        vault.restock(address(nvda), 1_001e6);

        vm.prank(keeper);
        vault.restock(address(nvda), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.OverDailyCap.selector, 2_000e6, 1_500e6));
        vm.prank(keeper);
        vault.restock(address(nvda), 1_000e6);

        vm.warp(block.timestamp + 1 days);
        registry.setPrice(address(tsla), TSLA_PRICE);
        registry.setStalePrice(address(nvda), NVDA_PRICE, block.timestamp - 6 days);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.StockNotBuyable.selector, address(nvda), bytes32("no-fresh-price")));
        vm.prank(keeper);
        vault.restock(address(nvda), 100e6);

        // A router that fills 3% under the mark is refused by the 2% bound.
        router.setRate(address(usdc), address(tsla), 97, 200);
        vm.expectRevert();
        vm.prank(keeper);
        vault.restock(address(tsla), 100e6);
    }

    function test_restock_keepsTheUsdcShare() public {
        // Base: $10k USDC of $30k. With a 30% share, spending $1,001 leaves $8,999 < $9,000.
        vm.prank(multisig);
        vault.setRestockParams(5_000e6, 20_000e6, 200, 3_000);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.UsdcShareTooLow.selector, 8_999e6, 9_000e6));
        vm.prank(keeper);
        vault.restock(address(nvda), 1_001e6);
        vm.prank(keeper);
        vault.restock(address(nvda), 1_000e6);
    }

    /* ------------------------------------------------------------------ */
    /*                 5. House take -> fee recipient                       */
    /* ------------------------------------------------------------------ */

    function test_sweep_paysOnlyTheFeeRecipient_aboveAllFloors() public {
        // Base USDC share is 33% of $30k and the kept share 50%: nothing is spare.
        vm.expectRevert(PrizeVault.NothingToSweep.selector);
        vault.sweepSurplus();

        usdc.mint(address(vault), 50_000e6); // $60k USDC of $80k
        // Share floor binds: 60k - x >= 0.5 * (80k - x)  =>  x <= 40k.
        assertEq(vault.sweepableUsdc(), 40_000e6);
        vm.prank(bob); // permissionless
        uint256 swept = vault.sweepSurplus();
        assertEq(swept, 40_000e6);
        assertEq(usdc.balanceOf(treasury), 40_000e6, "all of it to the fee recipient");
        assertEq(usdc.balanceOf(bob), 1_000e6, "caller gets nothing");
    }

    function test_sweep_respectsLiabilityAndJackpotReserve() public {
        vm.prank(multisig);
        vault.setRestockParams(5_000e6, 20_000e6, 200, 0); // isolate the other two floors
        // Liability floor: 20 x $25 boxes = $455 EV -> $500.50 of USDC stays.
        for (uint256 i; i < 20; ++i) {
            vm.prank(alice);
            boxes.buyWithUsdc(SKU25, alice);
        }
        uint256 usdcNow = usdc.balanceOf(address(vault));
        assertEq(vault.sweepableUsdc(), usdcNow - 500_500_000, "liability floor binds");

        // Reserve floor: the $900 jackpot needs a $3,600 pool. Leave only $4,000 of stock...
        vm.prank(multisig);
        vault.setStockEnabled(address(tsla), false); // inventory: USDC + $10k NVDA
        registry.setStalePrice(address(nvda), NVDA_PRICE, block.timestamp - 6 days); // + $0 NVDA
        uint256 inv = vault.inventoryUsd();
        assertEq(inv, usdcNow);
        assertEq(vault.jackpotReserveUsd(), 3_600e6);
        assertEq(vault.sweepableUsdc(), usdcNow - 3_600e6, "reserve floor binds when stock is gone");
    }

    function test_sweep_pausingASkuDoesNotReleaseItsJackpotReserve() public {
        vm.prank(alice);
        boxes.buyWithUsdc(SKU25, alice); // one $25 box outstanding: a $900 jackpot is live
        vm.prank(multisig);
        boxes.setSkuPaused(SKU25, true);
        assertEq(boxes.maxLivePrizeUsd(), 900e6, "still reserved while a sealed $25 box exists");
        assertEq(vault.jackpotReserveUsd(), 3_600e6);

        vm.prank(multisig);
        boxes.setSkuPaused(SKU10, true);
        vm.prank(multisig);
        boxes.setSkuPaused(SKU1, true);
        // Unsold, paused SKUs release nothing they were not holding.
        assertEq(boxes.maxLivePrizeUsd(), 900e6);
    }

    /* ------------------------------------------------------------------ */
    /*                   6. CHIP is never inventory                         */
    /* ------------------------------------------------------------------ */

    function test_chipNeverStock_butAStrayCanBeReturned() public {
        address liveChip = vault.DEFAULT_CHIP(); // read first: expectRevert binds to the next call
        vm.startPrank(multisig);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.ProtectedAsset.selector, address(chip)));
        vault.addStock(address(chip));
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.ProtectedAsset.selector, liveChip));
        vault.addStock(liveChip);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(PrizeVault.NotRegistered.selector, address(chip)));
        vault.deposit(address(chip), 1);

        chip.mint(address(vault), 5 ether); // someone sends CHIP by mistake
        vm.prank(multisig);
        vault.rescue(address(chip), bob, 5 ether);
        assertEq(chip.balanceOf(address(vault)), 0, "no CHIP can be stuck here");
    }

    function test_noConverter_disablesChipPaymentsOnly() public {
        PrizeVault v3v = new PrizeVault(multisig, address(usdc), address(0), address(registry), address(router), address(router), 2_500);
        Box b3 = new Box(multisig, address(usdc), address(0), treasury, address(v3v), address(0), address(entropy), 0, 0, 0);
        vm.prank(multisig);
        v3v.setBox(address(b3));
        usdc.mint(address(v3v), 200e6);
        _approveBox(alice, b3);
        vm.expectRevert(Box.ChipDisabled.selector);
        vm.prank(alice);
        b3.buyWithChip(SKU1, alice);
        vm.prank(alice);
        b3.buyWithUsdc(SKU1, alice); // USDC is unaffected
    }

    function test_launchTable_isStill91Pct() public view {
        assertEq(boxes.rtpBps(), 9_100);
        assertEq(boxes.oddsTierCount(), 6);
        assertEq(boxes.maxPrizeUsd(SKU1), 36e6);
        assertEq(boxes.maxPrizeUsd(SKU25), 900e6);
        assertEq(boxes.maxLivePrizeUsd(), 900e6);
    }

    /* ------------------------------------------------------------------ */
    /*                              HELPERS                                 */
    /* ------------------------------------------------------------------ */

    function _buyUsdc(address who, uint8 skuId) internal returns (uint256 id) {
        vm.prank(who);
        id = boxes.buyWithUsdc(skuId, who);
    }

    function _freshSystem(uint256 seedUsdc) internal returns (Box b2, PrizeVault v2, ChipConverter c2) {
        v2 = new PrizeVault(multisig, address(usdc), address(chip), address(registry), address(router), address(router), 2_500);
        c2 = new ChipConverter(
            multisig, address(chip), address(weth), address(usdc), address(pm), address(v3), address(ethFeed), 500, _key()
        );
        b2 = new Box(multisig, address(usdc), address(chip), treasury, address(v2), address(c2), address(entropy), CHIP1, CHIP10, CHIP25);
        vm.startPrank(multisig);
        v2.setBox(address(b2));
        c2.setBox(address(b2));
        v2.addStock(address(nvda));
        vm.stopPrank();
        usdc.mint(address(v2), seedUsdc);
    }

    function _approveBox(address who, Box b) internal {
        vm.startPrank(who);
        usdc.approve(address(b), type(uint256).max);
        chip.approve(address(b), type(uint256).max);
        vm.stopPrank();
    }

    function _openOn(Box b, address who, uint256 id) internal returns (uint64) {
        uint128 fee = b.quoteOpenFee();
        vm.prank(who);
        b.open{value: fee}(id);
        return b.boxInfo(id).sequence;
    }

    function _rollForTierOn(Box b, uint8 tierId) internal view returns (bytes32) {
        IBox.PrizeTier[] memory tiers = b.oddsTable();
        uint256 acc;
        for (uint256 i; i < tierId; ++i) {
            acc += tiers[i].weight;
        }
        return bytes32(acc);
    }
}

/// @dev A throwaway 8-dp token for filling the stock list.
contract MockERC20_ {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}
