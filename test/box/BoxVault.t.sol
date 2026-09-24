// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Box} from "../../src/box/Box.sol";
import {PrizeVault} from "../../src/box/PrizeVault.sol";
import {IBox} from "../../src/interfaces/IBox.sol";
import {IPrizeVault} from "../../src/interfaces/IPrizeVault.sol";
import {Venue} from "../../src/interfaces/IStockRegistry.sol";
import {BoxTestBase} from "./BoxTestBase.sol";
import {BlacklistToken} from "../mocks/HostileTokens.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract BoxVaultTest is BoxTestBase {
    event PrizeOwed(
        address indexed opener, uint256 indexed tokenId, uint8 tierId, uint256 prizeUsd, bool capped
    );

    /// @dev roll 7500: tier 2 (1.00x, pays a stock). Even, so with [NVDA, TSLA] NVDA is tried first.
    bytes32 internal constant PAR_EVEN = bytes32(uint256(7_500));
    /// @dev roll 9950: tier 5 (36x jackpot).
    bytes32 internal constant JACKPOT = bytes32(uint256(9_950));

    /* ------------------------------------------------------------------ */
    /*                    STOCK SELECTION + FALLBACKS                       */
    /* ------------------------------------------------------------------ */

    function test_emptyStockFallsBackToNextStock() public {
        vm.prank(multisig);
        vault.setStockEnabled(address(nvda), false);

        uint256 id = _buy1(alice);
        _openAndFulfill(alice, id, PAR_EVEN);
        assertEq(tsla.balanceOf(alice), 5e5, "paid $1 of the remaining enabled stock ($200 TSLA)");
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

    function test_thinStockIsSkipped() public {
        MockERC20 dustTok = new MockERC20("Dust", "DSTX", 8);
        _listStock(vault, address(dustTok), 100e18);
        dustTok.mint(address(this), 1);
        dustTok.approve(address(vault), 1);
        vault.deposit(address(dustTok), 1);

        // Stocks are [NVDA, TSLA, DSTX]; roll 7502 is tier 2 and starts at index 2 (DSTX).
        uint256 id = _buy1(alice);
        _openAndFulfill(alice, id, bytes32(uint256(7_502)));
        assertEq(dustTok.balanceOf(alice), 0);
        assertEq(nvda.balanceOf(alice), 1e6, "wrapped to the next stock that can cover $1");
    }

    function test_blacklistedStockIsSkippedAndOpenStillSettles() public {
        BlacklistToken blocked = new BlacklistToken("Blocked", "BLKX", 8);
        _listStock(vault, address(blocked), 100e18);
        blocked.mint(address(this), 100e8);
        blocked.approve(address(vault), 100e8);
        vault.deposit(address(blocked), 100e8);
        blocked.setBlacklisted(alice, true);

        uint256 id = _buy1(alice);
        _openAndFulfill(alice, id, bytes32(uint256(7_502)));
        assertEq(blocked.balanceOf(alice), 0);
        assertEq(nvda.balanceOf(alice), 1e6);
        vm.expectRevert();
        boxes.ownerOf(id);
    }

    function test_deadFeedSkipsStock() public {
        registry.setPriceReverts(address(nvda), true);
        assertEq(vault.inventoryUsd(), 20_000e6, "a reverting mark is not counted");
        uint256 id = _buy1(alice);
        _openAndFulfill(alice, id, PAR_EVEN);
        assertEq(nvda.balanceOf(alice), 0);
        assertEq(tsla.balanceOf(alice), 5e5);
    }

    function test_staleFeedSkipsStock() public {
        uint256 maxAge = vault.maxFeedAge();
        registry.setStalePrice(address(nvda), NVDA_PRICE, block.timestamp - maxAge - 1);
        assertEq(vault.inventoryUsd(), 20_000e6, "a stale mark is not counted");
        uint256 id = _buy1(alice);
        _openAndFulfill(alice, id, PAR_EVEN);
        assertEq(nvda.balanceOf(alice), 0);
        assertEq(tsla.balanceOf(alice), 5e5);

        // Exactly maxFeedAge old is still fresh.
        registry.setStalePrice(address(nvda), NVDA_PRICE, block.timestamp - maxAge);
        assertEq(vault.inventoryUsd(), 30_000e6 + 950_000 - 5e5 * TSLA_PRICE / 1e20);
    }

    function test_dollarPrizePaysOneCentOfHundredDollarStock() public {
        uint256 id = _buy1(alice);
        _openAndFulfill(alice, id, _rollForTier(2));
        // $1 at $100/NVDA, entropy 7500 % 2 == 0 -> NVDA first.
        assertEq(nvda.balanceOf(alice), 1e6);
    }

    /// @notice Replaces the removed `quoteTokenAmount` view: marks come from the registry.
    function test_inventoryUsdUsesRegistryMarks() public {
        assertEq(vault.inventoryUsd(), 30_000e6);
        registry.setPrice(address(nvda), 50e18);
        assertEq(vault.inventoryUsd(), 25_000e6);
        vm.prank(multisig);
        vault.setStockEnabled(address(tsla), false);
        assertEq(vault.inventoryUsd(), 15_000e6, "a disabled stock is not inventory");
        chip.mint(address(vault), 1e30);
        assertEq(vault.inventoryUsd(), 15_000e6, "CHIP is never priced inventory");
    }

    /* ------------------------------------------------------------------ */
    /*               COVERAGE + ALL-OR-NOTHING (OWED) PATH                  */
    /* ------------------------------------------------------------------ */

    /// @notice Was `test_chipBuyAgainstEmptyB20AndUsdcIsHonestShortfall`. A box can no longer be
    ///         sold against a pool that could not pay its top prize, in USDC or in $CHIP.
    function test_emptyVaultRefusesToSell() public {
        (Box thinBox, PrizeVault thinVault,) = _newWiredPair(0);
        assertEq(thinVault.prizeCapUsd(), 0);
        assertFalse(thinBox.isSkuCovered(SKU1));

        uint256 usdc0 = usdc.balanceOf(alice);
        uint256 chip0 = chip.balanceOf(alice);
        (uint256 w, uint256 c) = _chipQuote(USD1);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Box.SkuNotCovered.selector, SKU1, uint256(36e6), uint256(0)));
        thinBox.buyWithChip(SKU1, alice, w, c * 2, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(Box.SkuNotCovered.selector, SKU1, uint256(36e6), uint256(0)));
        thinBox.buyWithUsdc(SKU1, alice);
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), usdc0);
        assertEq(chip.balanceOf(alice), chip0);
        assertEq(thinBox.nextId(), 1);
    }

    /// @notice Was `test_prizeCapLimitsJackpotOnThinInventory` (which asserted a capped, short
    ///         jackpot). Now the cap gates the SALE: no SKU whose top prize exceeds it is sold.
    function test_prizeCapBlocksSaleOnThinInventory() public {
        (Box thinBox, PrizeVault thinVault,) = _newWiredPair(40e6);
        uint256 cap = thinVault.prizeCapUsd();
        assertEq(cap, thinVault.inventoryUsd() * 2_500 / 10_000);
        assertEq(cap, 10e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Box.SkuNotCovered.selector, SKU1, uint256(36e6), cap));
        thinBox.buyWithUsdc(SKU1, alice);

        usdc.mint(address(thinVault), 104e6); // $144 -> cap $36, exactly SKU1's jackpot
        assertTrue(thinBox.isSkuCovered(SKU1));
        assertFalse(thinBox.isSkuCovered(SKU10));
        vm.prank(alice);
        thinBox.buyWithUsdc(SKU1, alice);
        uint256 capNow = thinVault.prizeCapUsd(); // read first: an inline call would eat the prank
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Box.SkuNotCovered.selector, SKU10, uint256(360e6), capNow));
        thinBox.buyWithUsdc(SKU10, alice);
    }

    /// @notice The pool shrinks between buy and open (a stock mark halves). The jackpot is
    ///         over the cap at callback time: NOTHING is paid, the box becomes OWED at the exact
    ///         drawn size, and a later {claimOwed} pays it in full once the pool recovers.
    function test_cappedJackpotBecomesOwedThenClaimedInFull() public {
        (Box thinBox, PrizeVault thinVault,) = _newWiredPair(44e6);
        _listStock(thinVault, address(nvda), 0);
        nvda.mint(address(this), 1e8);
        nvda.approve(address(thinVault), 1e8);
        thinVault.deposit(address(nvda), 1e8); // $44 + $100 = $144 -> cap $36

        vm.prank(alice);
        uint256 id = thinBox.buyWithUsdc(SKU1, alice);
        uint128 fee = thinBox.quoteOpenFee();
        vm.prank(alice);
        thinBox.open{value: fee}(id);
        uint64 seq = thinBox.boxInfo(id).sequence;

        registry.setPrice(address(nvda), 50e18); // inventory $94.95 -> cap ~$23.74 < $36
        uint256 vaultUsdc0 = usdc.balanceOf(address(thinVault));
        uint256 vaultNvda0 = nvda.balanceOf(address(thinVault));

        vm.expectEmit(true, true, true, true);
        emit PrizeOwed(alice, id, 5, 36e6, true);
        entropy.fulfill(seq, JACKPOT);

        IBox.BoxView memory b = thinBox.boxInfo(id);
        assertEq(b.state, thinBox.STATE_OWED());
        assertEq(b.owedUsd, 36e6, "owed at exactly the drawn size");
        assertEq(thinBox.ownerOf(id), alice, "not burned");
        assertEq(thinBox.outstandingLiabilityUsd(), 36e6, "mint EV replaced by the owed prize");
        assertEq(usdc.balanceOf(address(thinVault)), vaultUsdc0, "nothing moved: not paid short");
        assertEq(nvda.balanceOf(address(thinVault)), vaultNvda0);
        assertEq(nvda.balanceOf(alice), 0);

        // Locked to the opener while owed.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Box.BoxLocked.selector, id));
        thinBox.transferFrom(alice, bob, id);

        // Still unpayable: the claim reverts and moves nothing.
        vm.expectRevert(abi.encodeWithSelector(Box.StillUnpayable.selector, id, uint256(36e6)));
        thinBox.claimOwed(id);

        // New sales are refused while the top prize is not covered.
        vm.prank(bob);
        vm.expectRevert();
        thinBox.buyWithUsdc(SKU1, bob);

        // The mark recovers; anyone can push the claim, and it pays the opener in full.
        registry.setPrice(address(nvda), NVDA_PRICE);
        vm.prank(bob);
        thinBox.claimOwed(id);
        assertEq(nvda.balanceOf(alice), 36e6, "$36 at $100/NVDA = 0.36 NVDA");
        assertEq(nvda.balanceOf(bob), 0);
        vm.expectRevert();
        thinBox.ownerOf(id);
        assertEq(thinBox.outstandingLiabilityUsd(), 0);
        assertEq(thinBox.sealedSupply(SKU1), 0);

        vm.expectRevert(abi.encodeWithSelector(Box.NotOwed.selector, id));
        thinBox.claimOwed(id);
    }

    /// @notice Under the cap, but no asset can actually be delivered (the only stock blocks the
    ///         winner and USDC is short). Owed, uncapped; paid once the block lifts.
    function test_unpayablePrizeBecomesOwedUncapped() public {
        (Box thinBox, PrizeVault thinVault,) = _newWiredPair(0);
        BlacklistToken blocked = new BlacklistToken("Blocked", "BLKX", 8);
        _listStock(thinVault, address(blocked), 100e18);
        blocked.mint(address(this), 2e8);
        blocked.approve(address(thinVault), 2e8);
        thinVault.deposit(address(blocked), 2e8); // $200 -> cap $50
        blocked.setBlacklisted(alice, true);

        vm.prank(alice);
        uint256 id = thinBox.buyWithUsdc(SKU1, alice); // vault USDC is now $0.95 < the $1 prize
        uint128 fee = thinBox.quoteOpenFee();
        vm.prank(alice);
        thinBox.open{value: fee}(id);
        uint64 seq = thinBox.boxInfo(id).sequence;

        vm.expectEmit(true, true, true, true);
        emit PrizeOwed(alice, id, 2, 1e6, false);
        entropy.fulfill(seq, PAR_EVEN);
        assertEq(thinBox.boxInfo(id).state, thinBox.STATE_OWED());
        assertEq(usdc.balanceOf(address(thinVault)), 950_000, "USDC not paid short");

        blocked.setBlacklisted(alice, false);
        thinBox.claimOwed(id);
        assertEq(blocked.balanceOf(alice), 1e6);
        assertEq(thinBox.outstandingLiabilityUsd(), 0);
    }

    function test_settleIsAllOrNothingOverCap() public {
        // Direct settle from the Box address: a prize over the cap moves nothing.
        uint256 cap = vault.prizeCapUsd();
        uint256 usdc0 = usdc.balanceOf(address(vault));
        vm.prank(address(boxes));
        IPrizeVault.Payout memory p = vault.settle(alice, cap + 1, bytes32(0));
        assertFalse(p.paid);
        assertTrue(p.capped);
        assertEq(p.paidUsd, 0);
        assertEq(usdc.balanceOf(address(vault)), usdc0);
        assertEq(nvda.balanceOf(alice) + tsla.balanceOf(alice), 0);

        vm.prank(address(boxes));
        p = vault.settle(alice, cap, bytes32(0));
        assertTrue(p.paid);
        assertEq(p.paidUsd, cap);
    }

    /* ------------------------------------------------------------------ */
    /*                          RESCUE / SURPLUS                            */
    /* ------------------------------------------------------------------ */

    function test_cannotRescuePrizeAssets() public {
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.ProtectedAsset.selector, address(usdc)));
        vault.rescue(address(usdc), alice, 1);

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.ProtectedAsset.selector, address(nvda)));
        vault.rescue(address(nvda), alice, 1);

        // A registered stock stays protected even while disabled.
        vm.prank(multisig);
        vault.setStockEnabled(address(tsla), false);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.ProtectedAsset.selector, address(tsla)));
        vault.rescue(address(tsla), alice, 1);
    }

    function test_rescueStrayToken() public {
        MockERC20 stray = new MockERC20("Stray", "STRX", 18);
        stray.mint(address(vault), 1 ether);
        vm.prank(multisig);
        vault.rescue(address(stray), alice, 1 ether);
        assertEq(stray.balanceOf(alice), 1 ether);
    }

    /// @notice The vault has no $CHIP flow, so stray $CHIP is an ordinary stray token.
    function test_rescueStrayChipAllowed() public {
        chip.mint(address(vault), 7 ether);
        uint256 a0 = chip.balanceOf(alice);
        vm.prank(multisig);
        vault.rescue(address(chip), alice, 7 ether);
        assertEq(chip.balanceOf(alice) - a0, 7 ether);
        assertEq(chip.balanceOf(address(vault)), 0);
    }

    function test_rescueIsOwnerOnly() public {
        MockERC20 stray = new MockERC20("Stray", "STRX", 18);
        stray.mint(address(vault), 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        vault.rescue(address(stray), alice, 1 ether);
    }

    function test_surplusWithdrawRespectsOutstandingEv() public {
        (Box thinBox, PrizeVault thinVault,) = _newWiredPair(200e6);
        vm.prank(alice);
        thinBox.buyWithUsdc(SKU1, alice);

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
        assertEq(usdc.balanceOf(address(thinVault)), usdcBal);
    }

    /// @notice Second floor: the pool must stay big enough to pay the largest prize on sale.
    function test_surplusWithdrawRespectsJackpotReserve() public {
        uint256 reserve = vault.jackpotReserveUsd();
        assertEq(reserve, 3_600e6, "$900 top prize at a 25% cap");
        // Stale marks: only the $10,000 USDC counts as inventory. No boxes, so no liability floor.
        uint256 old = block.timestamp - vault.maxFeedAge() - 1;
        registry.setStalePrice(address(nvda), NVDA_PRICE, old);
        registry.setStalePrice(address(tsla), TSLA_PRICE, old);
        uint256 inv = vault.inventoryUsd();
        assertEq(inv, 10_000e6);

        // One unit more than the spare leaves inventory $0.000001 under the reserve.
        vm.prank(multisig);
        vault.queueSurplusWithdraw(address(usdc), multisig, inv - reserve + 1);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.InsufficientSurplus.selector, reserve - 1, reserve));
        vault.executeSurplusWithdraw();

        // Exactly the spare is allowed.
        vm.prank(multisig);
        vault.queueSurplusWithdraw(address(usdc), multisig, inv - reserve);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        vault.executeSurplusWithdraw();
        assertEq(usdc.balanceOf(multisig), inv - reserve);
        assertEq(vault.inventoryUsd(), reserve);
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

    function test_surplusWithdrawIsTimelocked() public {
        vm.prank(multisig);
        vault.queueSurplusWithdraw(address(usdc), multisig, 1);
        vm.prank(multisig);
        vm.expectRevert();
        vault.executeSurplusWithdraw();
        vm.warp(block.timestamp + 48 hours + 14 days + 1);
        vm.prank(multisig);
        vm.expectRevert();
        vault.executeSurplusWithdraw();
        vm.prank(multisig);
        vault.cancelSurplusWithdraw();
        vm.prank(multisig);
        vm.expectRevert(PrizeVault.NothingQueued.selector);
        vault.executeSurplusWithdraw();
    }

    function test_surplusWithdrawRefusesUnlistedToken() public {
        MockERC20 stray = new MockERC20("Stray", "STRX", 18);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.NotRegistered.selector, address(stray)));
        vault.queueSurplusWithdraw(address(stray), multisig, 1);
    }

    /* ------------------------------------------------------------------ */
    /*                        CAP (48h) / WIRING                            */
    /* ------------------------------------------------------------------ */

    function test_maxPrizeBpsIsTimelockedAndCeilinged() public {
        vm.startPrank(multisig);
        vm.expectRevert(PrizeVault.BadConfig.selector);
        vault.queueMaxPrizeBps(5_001);
        vm.expectRevert(PrizeVault.BadConfig.selector);
        vault.queueMaxPrizeBps(0);
        vault.queueMaxPrizeBps(1_000);
        vm.expectRevert();
        vault.executeMaxPrizeBps();
        vm.stopPrank();

        vm.warp(block.timestamp + 48 hours);
        // Warping ages the registry marks by 48h; still fresh under the 5d maxFeedAge.
        vm.prank(multisig);
        vault.executeMaxPrizeBps();
        assertEq(vault.maxPrizeBps(), 1_000);
        assertEq(vault.prizeCapUsd(), 3_000e6);
    }

    function test_constructorRejectsBadMaxPrizeBps() public {
        vm.expectRevert(PrizeVault.BadConfig.selector);
        new PrizeVault(multisig, address(usdc), address(chip), address(registry), address(router), address(router), 5_001);
        vm.expectRevert(PrizeVault.BadConfig.selector);
        new PrizeVault(multisig, address(usdc), address(chip), address(registry), address(router), address(router), 0);
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

    function test_addStockReadsRegistry() public {
        MockERC20 unlisted = new MockERC20("Unlisted", "UNLX", 8);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.NotRegistered.selector, address(unlisted)));
        vault.addStock(address(unlisted));

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.AlreadyRegistered.selector, address(nvda)));
        vault.addStock(address(nvda));

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.ProtectedAsset.selector, address(usdc)));
        vault.addStock(address(usdc));

        assertEq(vault.getStock(address(nvda)).tokenDecimals, 8);
        assertEq(vault.stockCount(), 2);
        assertEq(vault.stockAt(0), address(nvda));
        assertEq(vault.stockAt(1), address(tsla));
    }

    function test_depositRefusesUnlistedAndChip() public {
        chip.mint(address(this), 1 ether);
        chip.approve(address(vault), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(PrizeVault.NotRegistered.selector, address(chip)));
        vault.deposit(address(chip), 1 ether);
    }

    /* ------------------------------------------------------------------ */
    /*                              HELPERS                                 */
    /* ------------------------------------------------------------------ */

    /// @dev Register `token` in the mock registry (8 dp, Slipstream) if needed and list it on
    ///      `v`. `price == 0` keeps the registry's current mark.
    function _listStock(PrizeVault v, address token, uint256 price) internal {
        if (!registry.getStock(token).registered) registry.setStock(token, Venue.Slipstream, 0, 10, 8, true);
        if (price != 0) registry.setPrice(token, price);
        vm.prank(multisig);
        v.addStock(token);
    }
}
