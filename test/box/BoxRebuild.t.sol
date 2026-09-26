// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BoxTestBase} from "./BoxTestBase.sol";
import {Box} from "../../src/box/Box.sol";
import {PrizeVault} from "../../src/box/PrizeVault.sol";
import {ChipConverter} from "../../src/box/ChipConverter.sol";
import {IBox} from "../../src/interfaces/IBox.sol";
import {Venue} from "../../src/interfaces/IStockRegistry.sol";
import {MockSwapRouter} from "../mocks/MockSwapRouter.sol";

/// @notice The rebuild's own properties: CHIP swapped to the exact price at buy, stocks-only prizes, never-short
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
    /*        1. $CHIP payments: swapped to the exact price at buy          */
    /* ------------------------------------------------------------------ */

    /// @dev The whole point of swap-at-buy: a $CHIP box funds the pool exactly like a USDC box,
    ///      in the same transaction. 200,000 $CHIP -> 0.005 ETH -> $10 at the base's rates.
    function test_chipBuy_fundsThePoolAtFace_inTheSameTransaction() public {
        uint256 vault0 = usdc.balanceOf(address(vault));
        uint256 chip0 = chip.balanceOf(alice);
        (, uint256 cost) = _chipQuote(USD10);
        assertEq(cost, CHIP10, "a $10 box costs 200k CHIP at these rates");

        uint256 id = _buyChip(alice, SKU10); // allows 1% over the quote

        assertEq(boxes.ownerOf(id), alice);
        assertEq(usdc.balanceOf(treasury), 500_000, "5% to the fee recipient, in USDC");
        assertEq(usdc.balanceOf(address(vault)) - vault0, 9_500_000, "95% to the vault, now");
        assertEq(chip0 - chip.balanceOf(alice), cost, "the buyer spent the quote; the 1% headroom came back");
        (uint256 c, uint256 w, uint256 u) = converter.sweepZero();
        assertEq(c + w + u, 0, "the converter holds nothing afterwards");
        assertEq(chip.balanceOf(address(vault)) + chip.balanceOf(address(boxes)) + chip.balanceOf(treasury), 0);
        assertEq(boxes.outstandingLiabilityUsd(), 9_100_000);
    }

    function test_chipBuy_theBuyerBoundsTheirOwnCost() public {
        (uint256 wethNeeded, uint256 cost) = _chipQuote(USD10);
        vm.expectRevert(abi.encodeWithSelector(ChipConverter.ChipCostAboveMax.selector, cost, cost - 1));
        vm.prank(alice);
        boxes.buyWithChip(SKU10, alice, wethNeeded, cost - 1, _deadline());

        vm.expectRevert(abi.encodeWithSelector(Box.DeadlinePassed.selector, block.timestamp, block.timestamp - 1));
        vm.prank(alice);
        boxes.buyWithChip(SKU10, alice, wethNeeded, cost, block.timestamp - 1);
    }

    function test_chipBuy_batchIsOneSwapForNBoxes() public {
        (uint256 wethNeeded, uint256 cost) = _chipQuote(3 * USD10);
        uint256 vault0 = usdc.balanceOf(address(vault));
        vm.prank(alice);
        uint256 first = boxes.buyWithChipBatch(SKU10, bob, 3, wethNeeded, cost, _deadline());
        for (uint256 i; i < 3; ++i) assertEq(boxes.ownerOf(first + i), bob, "gifted: minted to bob");
        assertEq(usdc.balanceOf(address(vault)) - vault0, 3 * 9_500_000);
        assertEq(usdc.balanceOf(treasury), 3 * 500_000);
    }

    function test_chipBuy_canBeTurnedOffPerSku() public {
        vm.startPrank(multisig);
        boxes.queueSku(SKU10, true, uint96(USD10), false);
        vm.warp(block.timestamp + 48 hours);
        boxes.executeSku();
        vm.stopPrank();
        registry.setPrice(address(nvda), NVDA_PRICE);
        registry.setPrice(address(tsla), TSLA_PRICE);
        (uint256 wethNeeded, uint256 cost) = _chipQuote(USD10);
        vm.expectRevert(Box.ChipDisabled.selector);
        vm.prank(alice);
        boxes.buyWithChip(SKU10, alice, wethNeeded, cost, _deadline());
        vm.prank(alice);
        boxes.buyWithUsdc(SKU10, alice); // USDC unaffected
    }

    function test_converter_onlyTheBoxCanSwap() public {
        vm.expectRevert(abi.encodeWithSelector(ChipConverter.NotBox.selector, alice));
        vm.prank(alice);
        converter.swapToUsdc(USD10, 1, 1, alice);
    }

    /* ------------------------------------------------------------------ */
    /*                  2. Prizes are stocks, never $CHIP                    */
    /* ------------------------------------------------------------------ */

    /// @dev Every tier, Dust to Jackpot, pays a stock at the registry mark. _rollForTier picks
    ///      rolls whose hashed stock walk starts at NVDA ($100): the raw 8-dp NVDA paid equals
    ///      the 6-dp USD prize exactly. $10 box: 0.50x $5, 0.60x $6, 1x $10, 2x $20, 8x $80, 36x $360.
    function test_everyTier_paysAStock_neverChip() public {
        uint256[6] memory prize = [uint256(5e6), 6e6, 10e6, 20e6, 80e6, 360e6];
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
        _openAndFulfill(alice, id, _rollForTier(DUST)); // 0.50x of $10 = $5
        assertEq(usdc.balanceOf(alice) - u0, 5e6, "the full $5, in USDC");
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
        uint64 readyAt = boxes.boxInfo(id).openingStartedAt + 30 days;
        vm.warp(readyAt - 1);
        uint128 fee = boxes.quoteOpenFee();
        vm.expectRevert(abi.encodeWithSelector(Box.RevealNotTimedOut.selector, readyAt - 1, readyAt));
        vm.prank(alice);
        boxes.retryOpen{value: fee}(id);
    }

    /* ------------------------------------------------------------------ */
    /*                     4. Keeper restock                                */
    /* ------------------------------------------------------------------ */

    function test_restock_buysIntoTheVault_withinBounds() public {
        vm.prank(multisig);
        vault.setRestockParams(5_000e6, 20_000e6, 200, 2_500);
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
        vault.setRestockParams(1_000e6, 1_500e6, 200, 2_500);

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

        // A router that fills 3% under the mark is refused by the 2% bound. The vault passes
        // that bound to the router as amountOutMinimum, so the revert comes from the router's
        // own minimum check (the mock's TooLittleReceived), not from a vault-side error.
        router.setRate(address(usdc), address(tsla), 97, 200);
        vm.expectRevert(MockSwapRouter.TooLittleReceived.selector);
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

    /// @dev The USDC share can no longer be set below maxPrizeBps (BOX-L4), so each floor is
    ///      isolated by the pool's shape instead: stock off the books makes the share floor trivial.
    function test_sweep_respectsLiabilityAndJackpotReserve() public {
        vm.startPrank(multisig);
        vault.setStockEnabled(address(nvda), false);
        vault.setStockEnabled(address(tsla), false); // inventory = USDC: the share floor is moot
        boxes.setSkuPaused(SKU10, true);
        boxes.setSkuPaused(SKU25, true); // unsold, so the reserve is the $1 jackpot's alone
        vm.stopPrank();

        // Liability floor: 400 x $1 boxes = $364 EV -> $400.40 of USDC stays.
        for (uint256 i; i < 400; ++i) {
            vm.prank(alice);
            boxes.buyWithUsdc(SKU1, alice);
        }
        uint256 usdcNow = usdc.balanceOf(address(vault));
        assertLt(vault.jackpotReserveUsd(), 400_400_000, "the reserve is below the liability floor here");
        assertEq(vault.sweepableUsdc(), usdcNow - 400_400_000, "liability floor binds");
    }

    function test_sweep_reserveFloorBinds_whenStockIsGone() public {
        // 20 x $25 boxes: liability floor $500.50, under the $3,600 reserve for the $900 jackpot.
        for (uint256 i; i < 20; ++i) {
            vm.prank(alice);
            boxes.buyWithUsdc(SKU25, alice);
        }
        uint256 usdcNow = usdc.balanceOf(address(vault));
        vm.prank(multisig);
        vault.setStockEnabled(address(tsla), false); // inventory: USDC + $10k NVDA
        registry.setStalePrice(address(nvda), NVDA_PRICE, block.timestamp - 6 days); // + $0 NVDA
        uint256 inv = vault.inventoryUsd();
        assertEq(inv, usdcNow);
        assertEq(vault.jackpotReserveUsd(), 3_600e6);
        assertEq(vault.sweepableUsdc(), usdcNow - 3_600e6, "reserve floor binds when stock is gone");
    }

    /// @dev BOX-L4: with stock on the books the kept-USDC share binds, and it is never below the
    ///      prize cap's share, so USDC alone covers the largest prize the gate can sell.
    function test_sweep_usdcShareFloor_coversTheLargestPrize() public {
        vm.prank(multisig);
        vault.setRestockParams(5_000e6, 20_000e6, 200, 2_500);
        // $10k USDC + $20k stock. Keep x: (10k - x) >= 25% of (30k - x) -> x <= 3,333.33.
        uint256 sweepable = vault.sweepableUsdc();
        assertApproxEqAbs(sweepable, 3_333_333_333, 1);
        uint256 usdcAfter = usdc.balanceOf(address(vault)) - sweepable;
        assertGe(usdcAfter, vault.prizeCapUsd() / 1e12, "USDC left covers the cap");
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

    /// @dev A sold box keeps its mint face and odds (H-05). Cutting the top tier or the price
    ///      afterwards must not shrink the reserve the sweep leaves under that box's jackpot.
    function test_sweep_reserveCoversJackpotsAlreadySold_afterOddsAndPriceCuts() public {
        vm.prank(alice);
        boxes.buyWithUsdc(SKU25, alice); // this box can win $900 forever
        assertEq(boxes.maxSoldPrizeUsd(), 900e6);

        // Owner cuts the jackpot to 10x and the $25 SKU to $20 (both 48h-timelocked).
        IBox.PrizeTier[] memory t = boxes.oddsTable();
        t[5].prizeBps = 100_000;
        vm.startPrank(multisig);
        boxes.queueOdds(t);
        boxes.queueSku(SKU25, true, 20e6, true);
        vm.warp(block.timestamp + 48 hours);
        boxes.executeOdds();
        boxes.executeSku();
        vm.stopPrank();

        assertEq(boxes.maxPrizeUsd(SKU25), 200e6, "a NEW $25-slot box now tops out at $200");
        assertEq(boxes.maxLivePrizeUsd(), 900e6, "the sold box still reserves its $900");
        assertEq(vault.jackpotReserveUsd(), 3_600e6);
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
        Box b3 = new Box(multisig, address(usdc), address(0), treasury, address(v3v), address(0), address(entropy));
        vm.prank(multisig);
        v3v.setBox(address(b3));
        usdc.mint(address(v3v), 200e6);
        _approveBox(alice, b3);
        vm.expectRevert(Box.ChipDisabled.selector);
        vm.prank(alice);
        b3.buyWithChip(SKU1, alice, 1, 1, block.timestamp);
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
            multisig, address(chip), address(weth), address(usdc), address(pm), address(v3), 500, _key()
        );
        b2 = new Box(multisig, address(usdc), address(chip), treasury, address(v2), address(c2), address(entropy));
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
