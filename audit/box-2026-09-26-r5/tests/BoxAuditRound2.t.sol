// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BoxTestBase} from "./BoxTestBase.sol";
import {Box} from "../../src/box/Box.sol";
import {PrizeVault} from "../../src/box/PrizeVault.sol";
import {ChipConverter} from "../../src/box/ChipConverter.sol";
import {PoolKey} from "../../src/interfaces/IUniswapV4.sol";
import {Venue} from "../../src/interfaces/IStockRegistry.sol";
import {BlacklistToken} from "../mocks/HostileTokens.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Vm} from "forge-std/Test.sol";

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
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
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

    /* ---------------- BOX-L6: the failed-transfer walk is bounded ---------------- */

    /// @dev Grok BOX-L6. An opener every stock refuses made the walk try all 16 transfers, each
    ///      a caught revert, which came to an estimated 0.8-1.0M gas on real B20s. The walk now
    ///      stops after MAX_FAILED_TRANSFERS and pays in USDC.
    function test_BOXL6_sixteenRefusingStocks_twoTriesThenUsdc() public {
        (Box b, PrizeVault v,) = _newWiredPair(1_000e6);
        for (uint256 i; i < 16; ++i) {
            BlacklistToken t = new BlacklistToken("Blocked", "BLK", 8);
            registry.setStock(address(t), Venue.Slipstream, 0, 10, 8, true);
            registry.setPrice(address(t), 100e18);
            vm.prank(multisig);
            v.addStock(address(t));
            t.mint(address(v), 10e8); // $1,000 each
            t.setBlacklisted(alice, true);
        }
        assertEq(v.stockCount(), v.MAX_STOCKS());

        vm.prank(alice);
        uint256 id = b.buyWithUsdc(SKU1, alice);
        uint128 fee = b.quoteOpenFee();
        vm.prank(alice);
        b.open{value: fee}(id);
        uint64 seq = b.boxInfo(id).sequence;

        uint256 u0 = usdc.balanceOf(alice);
        vm.recordLogs();
        uint256 g0 = gasleft();
        entropy.fulfill(seq, bytes32(uint256(8_500))); // tier 2: $1
        uint256 used = g0 - gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 tries;
        bytes32 sig = keccak256("StockSkipped(address,bytes32)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 3 && logs[i].topics[0] == sig && logs[i].topics[2] == bytes32("transfer")) {
                ++tries;
            }
        }
        assertEq(tries, v.MAX_FAILED_TRANSFERS(), "stops after two refused transfers");
        assertEq(usdc.balanceOf(alice) - u0, 1e6, "and pays the full $1 in USDC");
        assertLt(used, 900_000, "within the callback floor, mocks included");
    }

    /* ---------------- BOX-I4: the first stock is not a function of the tier ---------------- */

    /// @dev Grok BOX-I4. With `entropy % n` and n = 2, every roll in a tier that starts on an even
    ///      number went to NVDA first. The start is now keccak(entropy) % n.
    function test_BOXI4_firstStockFollowsTheHash_notTheRoll() public {
        bool sawTsla;
        for (uint256 j; j < 8; ++j) {
            bytes32 rand = bytes32(8_500 + 10_000 * j); // always tier 2 ($1), always even
            uint256 id = _buy1(alice);
            uint256 n0 = nvda.balanceOf(alice);
            uint256 t0 = tsla.balanceOf(alice);
            _openAndFulfill(alice, id, rand);
            if (uint256(keccak256(abi.encode(rand))) % 2 == 0) {
                assertEq(nvda.balanceOf(alice) - n0, 1e6, "hash picks NVDA");
            } else {
                assertEq(tsla.balanceOf(alice) - t0, 0.5e6, "hash picks TSLA");
                sawTsla = true;
            }
        }
        assertTrue(sawTsla, "even rolls no longer all go to NVDA");
    }

    /* ---------------- BOX-L3: a ceiling on the feed age ---------------- */

    function test_BOXL3_feedAgeHasACeiling() public {
        uint64 max = vault.MAX_FEED_AGE();
        vm.startPrank(multisig);
        vm.expectRevert(PrizeVault.BadConfig.selector);
        vault.setMaxFeedAge(max + 1);
        vault.setMaxFeedAge(max);
        vm.stopPrank();
        assertEq(vault.maxFeedAge(), max);
    }

    /* ---------------- BOX-L4: USDC kept back always covers the cap ---------------- */

    function test_BOXL4_usdcShareCannotGoBelowThePrizeCap() public {
        vm.startPrank(multisig);
        vm.expectRevert(PrizeVault.BadConfig.selector);
        vault.setRestockParams(5_000e6, 20_000e6, 200, 2_499); // cap is 2,500
        vault.setRestockParams(5_000e6, 20_000e6, 200, 3_000);

        vm.expectRevert(PrizeVault.BadConfig.selector);
        vault.queueMaxPrizeBps(3_001); // above the kept share
        vault.queueMaxPrizeBps(3_000);

        // The share moves down while the cap raise waits: the raise must not land.
        vault.setRestockParams(5_000e6, 20_000e6, 200, 2_500);
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(PrizeVault.BadConfig.selector);
        vault.executeMaxPrizeBps();
        vm.stopPrank();
        assertEq(vault.maxPrizeBps(), 2_500);
    }

    /* ---------------- Mutants M4, M8, M16: checks the mocks used to do for us ---------------- */

    /// @dev M4 survived because the mock router enforced the minimum itself. A router that
    ///      ignores it and short-fills must still be refused by the vault's own balance check.
    function test_M4_restockRefusesARouterThatShortFills() public {
        router.setLie(true);
        vm.prank(keeper);
        // $1,000 at $100 = 10 NVDA; minimum 98% = 9.8; the lying router delivers 5.
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.RestockShort.selector, 5e8, 9.8e8));
        vault.restock(address(nvda), 1_000e6);
    }

    /// @dev M8: the v3 leg delivers one unit under the exact output. The converter must refuse.
    function test_M8_converterRefusesAShortUsdcLeg() public {
        v3.setLie(true);
        (uint256 wethNeeded, uint256 chipCost) = _chipQuote(USD10);
        uint256 max = chipCost * 101 / 100;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ChipConverter.UsdcShort.selector, USD10 - 1, USD10));
        boxes.buyWithChip(SKU10, alice, wethNeeded, max, block.timestamp + 600);
    }

    /// @dev M16: the v4 leg fills part of an exact-output swap. The converter must refuse.
    function test_M16_converterRefusesAPartialV4Fill() public {
        pm.setShortOut(1);
        (uint256 wethNeeded, uint256 chipCost) = _chipQuote(USD10);
        uint256 max = chipCost * 101 / 100;
        vm.prank(alice);
        vm.expectRevert(ChipConverter.NothingSwapped.selector);
        boxes.buyWithChip(SKU10, alice, wethNeeded, max, block.timestamp + 600);
    }

    /* ---------------- Production currency order: $CHIP is currency1 ---------------- */

    /// @dev Grok: the unit suite only ran chipIsCurrency0 = true. On Base, WETH (0x4200...) sorts
    ///      first, so production is false. Same buy, with a $CHIP that sorts after WETH.
    function test_converter_chipAsCurrency1_asOnBase() public {
        MockERC20 chip2 = new MockERC20("Chipworks", "CHIP", 18);
        while (address(chip2) < address(weth)) chip2 = new MockERC20("Chipworks", "CHIP", 18);
        pm.setRate(address(chip2), address(weth), 25, 1e9);
        pm.setRate(address(weth), address(chip2), 1e9, 25);
        chip2.mint(address(pm), 1e33);

        PoolKey memory key = PoolKey({
            currency0: address(weth), currency1: address(chip2), fee: 0x800000, tickSpacing: 200, hooks: address(0)
        });
        ChipConverter c2 = new ChipConverter(
            multisig, address(chip2), address(weth), address(usdc), address(pm), address(v3), 500, key
        );
        assertFalse(c2.chipIsCurrency0());
        PrizeVault v2 = new PrizeVault(
            multisig, address(usdc), address(chip2), address(registry), address(router), address(router), 2_500
        );
        Box b2 = _newBox(address(v2), address(chip2), address(c2));
        vm.startPrank(multisig);
        v2.setBox(address(b2));
        c2.setBox(address(b2));
        vm.stopPrank();
        usdc.mint(address(v2), 10_000e6);

        chip2.mint(alice, 1_000_000 ether);
        vm.prank(alice);
        chip2.approve(address(b2), type(uint256).max);
        (uint256 wethNeeded, uint256 chipCost) = _chipQuote(USD10); // same rates as the base CHIP
        uint256 vault0 = usdc.balanceOf(address(v2));
        uint256 chip0 = chip2.balanceOf(alice);
        vm.prank(alice);
        b2.buyWithChip(SKU10, alice, wethNeeded, chipCost * 101 / 100, block.timestamp + 600);
        assertEq(usdc.balanceOf(address(v2)) - vault0, 9_500_000, "95% of face to the vault");
        assertEq(chip0 - chip2.balanceOf(alice), chipCost, "the buyer paid the quote");
        (uint256 c, uint256 w, uint256 u) = c2.sweepZero();
        assertEq(c + w + u, 0);
    }
}
