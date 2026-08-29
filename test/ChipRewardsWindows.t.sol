// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChipRewardsBase} from "./ChipRewardsBase.t.sol";
import {ChipRewards} from "../src/ChipRewards.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Weekly claim windows and the 30-day expiry.
///
/// @dev The gate is new claim-BLOCKING logic, which makes it the highest-risk change in the
///      contract: a bug here does not lose money, it locks it. These tests are written from
///      that angle — every case where a holder might be wrongly refused, and every case
///      where a sweep might take something still claimable.
contract ChipRewardsWindowsTest is ChipRewardsBase {
    uint32 internal constant WEEK = 7 days;
    uint32 internal constant OPEN = 48 hours;

    /// @dev One finalized round, alice owed 5 NVDA.
    function _round() internal returns (uint256 id) {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        id = _openAndAccumulate(_ids(1));
        rewards.settleStock(id, address(nvda));
        rewards.finalizeRound(id);
    }

    /* ------------------------------------------------------------------ */
    /*                            THE SCHEDULE                              */
    /* ------------------------------------------------------------------ */

    function test_defaultsAreSevenDaysAndFortyEightHours() public view {
        assertEq(rewards.windowLength(), WEEK);
        assertEq(rewards.windowOpenDuration(), OPEN);
        assertEq(rewards.creditExpiry(), 30 days);
        assertEq(rewards.MIN_WINDOWS_BEFORE_EXPIRY(), 3);
    }

    /// @notice The cycle is anchored at deploy, so the first window opens immediately.
    function test_anchoredAtDeployAndOpenAtOnce() public view {
        assertEq(rewards.windowAnchor(), uint64(block.timestamp));
        assertTrue(rewards.isClaimOpen(), "open from the moment it exists");
    }

    function test_windowOpensEverySevenDaysForFortyEightHours() public {
        uint64 anchor = rewards.windowAnchor();

        for (uint256 week; week < 5; ++week) {
            uint256 base = anchor + week * WEEK;

            vm.warp(base);
            assertTrue(rewards.isClaimOpen(), "open at the top of the cycle");

            vm.warp(base + OPEN - 1);
            assertTrue(rewards.isClaimOpen(), "still open one second before close");

            vm.warp(base + OPEN);
            assertFalse(rewards.isClaimOpen(), "shut the moment it closes");

            vm.warp(base + WEEK - 1);
            assertFalse(rewards.isClaimOpen(), "still shut one second before reopening");
        }
    }

    function test_windowStateReportsTheNextOpening() public {
        uint64 anchor = rewards.windowAnchor();
        vm.warp(anchor + 3 days); // between windows

        (bool open, uint64 opensAt, uint64 closesAt) = rewards.claimWindowState();
        assertFalse(open);
        assertEq(opensAt, anchor + WEEK, "next opening");
        assertEq(closesAt, anchor + WEEK + OPEN);
        assertEq(rewards.nextWindowOpensAt(), anchor + WEEK);
    }

    /* ------------------------------------------------------------------ */
    /*                             THE GATE                                 */
    /* ------------------------------------------------------------------ */

    function test_claimWorksInsideAWindow() public {
        uint256 id = _round();
        _openClaimWindow();

        vm.prank(alice);
        assertEq(rewards.claim(id, address(nvda)), 5e8);
        assertEq(nvda.balanceOf(alice), 5e8);
    }

    /// @notice The headline behaviour: refused between windows, and the error carries the
    ///         exact timestamp to come back at.
    function test_claimRevertsBetweenWindowsWithTheNextOpening() public {
        uint256 id = _round();
        uint64 anchor = rewards.windowAnchor();
        vm.warp(anchor + 3 days);

        uint64 expectedNext = anchor + WEEK;
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ChipRewards.ClaimsClosed.selector, uint64(block.timestamp), expectedNext)
        );
        rewards.claim(id, address(nvda));

        // Return at exactly the advertised moment and it works.
        vm.warp(expectedNext);
        vm.prank(alice);
        assertEq(rewards.claim(id, address(nvda)), 5e8);
    }

    /// @notice Credits keep accruing and stay visible while claims are shut. They are
    ///         deferred, not withheld.
    function test_creditsAreVisibleWhileTheWindowIsShut() public {
        uint256 id = _round();
        vm.warp(rewards.windowAnchor() + 3 days);

        assertFalse(rewards.isClaimOpen());
        assertEq(rewards.claimable(id, address(nvda), alice), 5e8, "still visible");
        assertFalse(rewards.hasClaimed(id, address(nvda), alice));
    }

    /// @notice Rounds continue to open, buy and credit while claims are shut. Only the
    ///         taking is gated.
    function test_roundsKeepRunningWhileClaimsAreShut() public {
        _round();
        vm.warp(rewards.windowAnchor() + 3 days);
        assertFalse(rewards.isClaimOpen());

        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 2, bob, 0);
        _setSplit(address(basedNouns), 2, bob, _one(address(nvda)), _one(uint8(100)));
        uint256 id2 = _openAndAccumulate(_ids(2));
        rewards.settleStock(id2, address(nvda));
        rewards.finalizeRound(id2);

        assertGt(rewards.claimable(id2, address(nvda), bob), 0, "credited while shut");
    }

    function test_claimForAndClaimManyObeyTheSameGate() public {
        uint256 id = _round();
        vm.warp(rewards.windowAnchor() + 3 days);

        vm.expectRevert();
        rewards.claimFor(alice, id, address(nvda));

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(alice);
        vm.expectRevert();
        rewards.claimMany(ids, _one(address(nvda)));
    }

    /// @notice Required case: a claim late in a round's life, but inside a window.
    function test_claimAfterTwentyNineDaysInsideAWindowWorks() public {
        uint256 id = _round();
        uint64 finalizedAt = rewards.getRound(id).finalizedAt;

        vm.warp(finalizedAt + 29 days);
        _openClaimWindow();
        assertLt(block.timestamp, rewards.getRound(id).expiresAt, "still before expiry");

        vm.prank(alice);
        assertEq(rewards.claim(id, address(nvda)), 5e8, "day 29 claim honoured");
    }

    /* ------------------------------------------------------------------ */
    /*                        FROZEN PER ROUND                              */
    /* ------------------------------------------------------------------ */

    /// @notice A round's schedule is fixed when it finalizes. Governance retuning the
    ///         config afterwards must not narrow or shorten a round that already exists.
    function test_aRoundKeepsTheScheduleItWasFinalizedUnder() public {
        uint256 id = _round();
        ChipRewards.Round memory before = rewards.getRound(id);
        assertEq(before.windowLengthAt, WEEK);
        assertEq(before.openDurationAt, OPEN);
        assertEq(before.expiresAt, before.finalizedAt + 30 days);

        // Governance widens the cadence for future rounds.
        vm.startPrank(multisig);
        rewards.setCreditExpiry(90 days);
        rewards.setClaimSchedule(30 days, 1 days);
        vm.stopPrank();

        ChipRewards.Round memory after_ = rewards.getRound(id);
        assertEq(after_.windowLengthAt, WEEK, "old round unchanged");
        assertEq(after_.expiresAt, before.expiresAt, "expiry unchanged");
        assertGe(rewards.guaranteedWindows(id), 3, "still guaranteed its windows");
    }

    function test_guaranteedWindowsIsAtLeastThreeOnTheDefaults() public {
        uint256 id = _round();
        assertGe(rewards.guaranteedWindows(id), 3);
        // 30 days at a 7-day cadence: four openings.
        assertEq(rewards.guaranteedWindows(id), 4);
    }

    function test_windowsRemainingCountsDown() public {
        uint256 id = _round();
        uint256 start = rewards.windowsRemaining(id);
        assertGe(start, 3);

        vm.warp(block.timestamp + 21 days);
        assertLt(rewards.windowsRemaining(id), start, "fewer chances left");

        vm.warp(rewards.getRound(id).expiresAt);
        assertEq(rewards.windowsRemaining(id), 0);
    }

    /* ------------------------------------------------------------------ */
    /*                          CONFIG LIMITS                               */
    /* ------------------------------------------------------------------ */

    /// @notice THE RULE: no configuration may leave a round fewer than three windows.
    function test_configCannotStarveARoundOfWindows() public {
        vm.startPrank(multisig);

        // 30-day expiry with a 14-day cadence would give only two openings.
        vm.expectRevert(ChipRewards.BadConfig.selector);
        rewards.setClaimSchedule(14 days, 1 days);

        // Same rule from the other direction.
        vm.expectRevert(ChipRewards.BadConfig.selector);
        rewards.setCreditExpiry(20 days); // 20 < 3 * 7

        // Exactly three windows is allowed.
        rewards.setCreditExpiry(21 days);
        assertEq(rewards.creditExpiry(), 21 days);
        vm.stopPrank();
    }

    function test_configRejectsNonsense() public {
        vm.startPrank(multisig);
        vm.expectRevert(ChipRewards.BadConfig.selector);
        rewards.setClaimSchedule(1 hours, 1 hours); // below the minimum cadence

        vm.expectRevert(ChipRewards.BadConfig.selector);
        rewards.setClaimSchedule(7 days, 8 days); // open longer than the cycle

        vm.expectRevert(ChipRewards.BadConfig.selector);
        rewards.setClaimSchedule(7 days, 1 minutes); // open too briefly

        vm.expectRevert(ChipRewards.BadConfig.selector);
        rewards.setCreditExpiry(400 days); // beyond the ceiling
        vm.stopPrank();
    }

    function test_configOnlyMultisig() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        rewards.setClaimSchedule(7 days, 1 days);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        rewards.setCreditExpiry(60 days);
        vm.stopPrank();
    }

    /// @notice The anchor cannot be moved. If it could, governance could slide every future
    ///         window forward and block claims without ever changing a duration.
    function test_thereIsNoWayToMoveTheAnchor() public {
        uint64 anchor = rewards.windowAnchor();
        vm.startPrank(multisig);
        rewards.setClaimSchedule(10 days, 2 days);
        rewards.setCreditExpiry(60 days);
        vm.stopPrank();
        assertEq(rewards.windowAnchor(), anchor, "immutable");
    }

    /// @notice An open duration equal to the cycle means permanently open. Legal, and it
    ///         must actually behave that way rather than being an off-by-one that shuts.
    function test_openDurationEqualToCycleMeansAlwaysOpen() public {
        vm.startPrank(multisig);
        rewards.setCreditExpiry(90 days);
        rewards.setClaimSchedule(7 days, 7 days);
        vm.stopPrank();

        for (uint256 i; i < 10; ++i) {
            vm.warp(block.timestamp + 17 hours);
            assertTrue(rewards.isClaimOpen(), "never shuts");
        }
    }

    /* ------------------------------------------------------------------ */
    /*                               FUZZ                                   */
    /* ------------------------------------------------------------------ */

    /// @notice For EVERY accepted configuration and EVERY moment a round could finalize at,
    ///         the round gets at least three full claim windows before it expires.
    ///         This is the interaction rule, pinned.
    function testFuzz_everyAcceptedConfigGivesAtLeastThreeWindows(uint32 w, uint32 d, uint64 e, uint32 offset) public {
        w = uint32(bound(w, rewards.MIN_WINDOW_LENGTH(), rewards.MAX_WINDOW_LENGTH()));
        d = uint32(bound(d, rewards.MIN_OPEN_DURATION(), w));
        e = uint64(bound(e, 0, rewards.MAX_CREDIT_EXPIRY()));
        offset = uint32(bound(offset, 0, 400 days));

        vm.startPrank(multisig);
        // Order matters: raise the expiry first so the cadence change can be accepted.
        try rewards.setCreditExpiry(e) {}
        catch {
            vm.stopPrank();
            return; // rejected config, nothing to prove
        }
        try rewards.setClaimSchedule(w, d) {}
        catch {
            vm.stopPrank();
            return;
        }
        vm.stopPrank();

        // A round finalizing at an arbitrary moment under this accepted config.
        uint64 finalizedAt = uint64(rewards.windowAnchor() + offset);
        uint64 expiresAt = finalizedAt + e;

        uint256 openings = rewards.openingsInFor(finalizedAt, expiresAt, w);
        assertGe(openings, 3, "an accepted config must never starve a round of windows");
    }

    /// @notice The same property, but measured on real finalized rounds rather than on
    ///         arithmetic: whatever the config, a finalized round reports >= 3.
    function testFuzz_realRoundsAlwaysReportAtLeastThreeWindows(uint32 w, uint32 d, uint64 e, uint32 skew) public {
        w = uint32(bound(w, rewards.MIN_WINDOW_LENGTH(), rewards.MAX_WINDOW_LENGTH()));
        d = uint32(bound(d, rewards.MIN_OPEN_DURATION(), w));
        e = uint64(bound(e, 0, rewards.MAX_CREDIT_EXPIRY()));
        skew = uint32(bound(skew, 0, 30 days));

        vm.startPrank(multisig);
        try rewards.setCreditExpiry(e) {}
        catch {
            vm.stopPrank();
            return;
        }
        try rewards.setClaimSchedule(w, d) {}
        catch {
            vm.stopPrank();
            return;
        }
        vm.stopPrank();

        vm.warp(block.timestamp + skew); // finalize at an arbitrary point in the cycle
        uint256 id = _round();

        assertGe(rewards.guaranteedWindows(id), 3, "real round starved of claim windows");
    }
}
