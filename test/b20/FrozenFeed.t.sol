// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChipRewardsBase} from "../ChipRewardsBase.t.sol";
import {ChipRounds} from "../../src/ChipRounds.sol";

/// @title FrozenFeedTest
/// @notice A dead equity feed must skip and carry, never price a purchase.
///
/// @dev THE TENSION THIS SETTLES, from OPEN_ITEMS item 6.
///
///      A Chainlink equity feed that has genuinely stopped updating still returns its last
///      answer forever. A round would keep buying against it, and the Chainlink bound —
///      normally the thing that protects us — would be enforced against a mark nobody is
///      maintaining, which is worse than having no bound at all.
///
///      The obvious fix, "reject a stale feed", is a trap. These feeds have NO heartbeat
///      outside market hours (ASSUMPTIONS A-14): they hold the last close all weekend, so on
///      a Monday morning every one of them is ~65 hours old while being perfectly healthy.
///      A naive staleness check switches the protocol off on the busiest day of the week and
///      does it silently, because a skip is safe and quiet.
///
///      So the resolution is a SKIP, not a revert — the slice carries to the next round and
///      nobody loses anything — with a `MIN_FEED_AGE` floor of 72 hours on any non-zero
///      setting, so the liveness trap cannot be walked into by tightening the number.
contract FrozenFeedTest is ChipRewardsBase {
    uint64 internal constant FIVE_DAYS = 120 hours;

    function setUp() public override {
        super.setUp();
        vm.prank(multisig);
        rounds.setMaxFeedAge(FIVE_DAYS);
    }

    /// @dev Alice on NVDA, Bob on GOOGL, so one stock can freeze while the other proceeds.
    function _twoStockRound(uint256 potUsdc) internal returns (uint256 id) {
        _fundPot(potUsdc);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _chip(basedNouns, basedVault, 2, bob, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        _setSplit(address(basedNouns), 2, bob, _one(address(googl)), _one(uint8(100)));
        id = _openAndAccumulate(_ids(1, 2));
    }

    /* ------------------------------- the skip -------------------------------- */

    function test_aFrozenFeedSkipsAndCarriesItsBudget() public {
        uint256 id = _twoStockRound(2_000e6);

        // NVDA's feed died a week ago. GOOGL is healthy.
        nvdaFeed.setStaleAnswer(int256(NVDA_USD * 1e8), block.timestamp - 7 days);
        assertTrue(rounds.isFeedStale(address(nvda)));
        assertFalse(rounds.isFeedStale(address(googl)));

        rounds.settleStock(id, address(nvda));
        rounds.settleStock(id, address(googl));
        rounds.finalizeRound(id);

        assertTrue(rounds.stockSkipped(id, address(nvda)), "skipped, not bought at a dead mark");
        assertEq(claims.acquired(id, address(nvda)), 0);

        // GOOGL was unaffected, and NVDA's whole slice went back to the Pot.
        assertGt(claims.acquired(id, address(googl)), 0, "the healthy stock still bought");
        assertEq(pot.available(), 1_000e6, "NVDA's slice carried, to the cent");
    }

    /// @notice And the carried budget is spendable the moment the feed comes back.
    function test_theCarriedBudgetBuysOnceTheFeedRecovers() public {
        uint256 id = _twoStockRound(2_000e6);
        nvdaFeed.setStaleAnswer(int256(NVDA_USD * 1e8), block.timestamp - 7 days);
        rounds.settleStock(id, address(nvda));
        rounds.settleStock(id, address(googl));
        rounds.finalizeRound(id);
        assertEq(pot.available(), 1_000e6);

        // The feed publishes again.
        nvdaFeed.setAnswer(int256(NVDA_USD * 1e8));
        assertFalse(rounds.isFeedStale(address(nvda)));

        vm.warp(block.timestamp + 24 hours);
        uint256 id2 = rounds.openRound();
        rounds.contributeWeights(id2, address(basedNouns), _ids(1));
        vm.warp(block.timestamp + 2 hours);
        rounds.closeAccumulation(id2);
        rounds.settleStock(id2, address(nvda));
        rounds.finalizeRound(id2);

        assertFalse(rounds.stockSkipped(id2, address(nvda)));
        assertEq(claims.acquired(id2, address(nvda)), 5e8, "$1,000 at $200, nothing lost");
    }

    /// @notice A frozen feed must not be able to wedge the round for everyone else.
    function test_aFrozenFeedDoesNotBlockFinalization() public {
        uint256 id = _twoStockRound(2_000e6);
        nvdaFeed.setStaleAnswer(int256(NVDA_USD * 1e8), block.timestamp - 30 days);

        rounds.settleStock(id, address(nvda));
        rounds.settleStock(id, address(googl));
        rounds.finalizeRound(id); // must not revert

        _openClaimWindow();
        vm.prank(bob);
        assertGt(claims.claim(id, address(googl)), 0, "bob is paid regardless");
    }

    /* ---------------------- the off-hours trap it avoids ---------------------- */

    /// @notice THE POINT OF THE 72-HOUR FLOOR. A weekend-old feed is healthy, not dead, and
    ///         must still buy. Friday 16:00 to Monday 09:30 is about 65 hours.
    function test_aWeekendOldFeedIsStillHealthyAndStillBuys() public {
        uint256 id = _twoStockRound(2_000e6);
        nvdaFeed.setStaleAnswer(int256(NVDA_USD * 1e8), block.timestamp - 65 hours);

        assertFalse(rounds.isFeedStale(address(nvda)), "a normal weekend is not staleness");

        rounds.settleStock(id, address(nvda));
        rounds.settleStock(id, address(googl));
        rounds.finalizeRound(id);
        assertFalse(rounds.stockSkipped(id, address(nvda)));
        assertEq(claims.acquired(id, address(nvda)), 5e8);
    }

    /// @notice A long holiday weekend runs past 110 hours and must also still buy, which is
    ///         why the recommended setting is 120 rather than the floor.
    function test_aHolidayWeekendOldFeedStillBuysAtTheRecommendedSetting() public {
        uint256 id = _twoStockRound(2_000e6);
        nvdaFeed.setStaleAnswer(int256(NVDA_USD * 1e8), block.timestamp - 113 hours);

        assertFalse(rounds.isFeedStale(address(nvda)), "Thanksgiving is not a dead feed");
        rounds.settleStock(id, address(nvda));
        rounds.settleStock(id, address(googl));
        rounds.finalizeRound(id);
        assertEq(claims.acquired(id, address(nvda)), 5e8);
    }

    /// @notice The floor is what stops someone tightening this into a silent outage.
    function test_theFloorRejectsASettingThatWouldSkipEveryMonday() public {
        vm.startPrank(multisig);
        vm.expectRevert(ChipRounds.BadConfig.selector);
        rounds.setMaxFeedAge(36 hours); // the originally recommended value: too tight

        vm.expectRevert(ChipRounds.BadConfig.selector);
        rounds.setMaxFeedAge(71 hours);

        rounds.setMaxFeedAge(72 hours); // exactly the floor is allowed
        assertEq(rounds.maxFeedAge(), 72 hours);
        vm.stopPrank();
    }

    /* ------------------------------ off by default --------------------------- */

    function test_theCheckIsOffByDefaultAndCanBeSwitchedBackOff() public {
        vm.prank(multisig);
        rounds.setMaxFeedAge(0);
        assertEq(rounds.maxFeedAge(), 0);

        uint256 id = _twoStockRound(2_000e6);
        nvdaFeed.setStaleAnswer(int256(NVDA_USD * 1e8), block.timestamp - 400 days);
        assertFalse(rounds.isFeedStale(address(nvda)), "zero means the check is off");

        rounds.settleStock(id, address(nvda));
        rounds.settleStock(id, address(googl));
        rounds.finalizeRound(id);
        assertFalse(rounds.stockSkipped(id, address(nvda)));
    }

    function test_onlyTheMultisigCanSetIt() public {
        vm.prank(alice);
        vm.expectRevert();
        rounds.setMaxFeedAge(FIVE_DAYS);
    }

    /* --------------------------------- edges --------------------------------- */

    /// @notice Exactly at the limit is fresh; one second past is stale. A skip is cheap, so
    ///         the boundary is not load-bearing — but an off-by-one here would move a whole
    ///         day of rounds, so it is pinned.
    function test_theBoundaryIsExactAndInclusive() public {
        uint256 id = _twoStockRound(2_000e6);

        nvdaFeed.setStaleAnswer(int256(NVDA_USD * 1e8), block.timestamp - FIVE_DAYS);
        assertFalse(rounds.isFeedStale(address(nvda)), "exactly at the limit is still fresh");

        nvdaFeed.setStaleAnswer(int256(NVDA_USD * 1e8), block.timestamp - FIVE_DAYS - 1);
        assertTrue(rounds.isFeedStale(address(nvda)), "one second past is stale");

        rounds.settleStock(id, address(nvda));
        assertTrue(rounds.stockSkipped(id, address(nvda)));
    }

    /// @notice An unregistered stock has no feed to be stale. The staleness check must not
    ///         claim otherwise — "no price" is a different skip with a different reason.
    function test_anUnregisteredStockIsNotReportedStale() public {
        assertFalse(rounds.isFeedStale(makeAddr("neverRegistered")));
    }

    /// @notice A feed that reverts outright is not this check's business either.
    function test_aRevertingFeedIsNotReportedStale() public {
        nvdaFeed.setRevertOnRead(true);
        assertFalse(rounds.isFeedStale(address(nvda)), "handled as 'no price', not as stale");
    }

    /// @notice A dead feed still cannot be bought against even when the pool looks fine —
    ///         belt and braces with the slippage bound, which is priced off the same mark.
    function test_stalenessIsCheckedBeforeTheSlippageBound() public {
        uint256 id = _twoStockRound(2_000e6);
        nvdaFeed.setStaleAnswer(int256(NVDA_USD * 1e8), block.timestamp - 10 days);

        vm.prank(multisig);
        rounds.setMaxSlippageBps(address(nvda), 9_000); // wide open: the swap would clear

        rounds.settleStock(id, address(nvda));
        assertTrue(rounds.stockSkipped(id, address(nvda)), "staleness wins over a loose bound");
        assertEq(claims.acquired(id, address(nvda)), 0);
    }
}
