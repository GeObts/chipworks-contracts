// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChipRewardsBase} from "./ChipRewardsBase.t.sol";
import {ChipRounds} from "../src/ChipRounds.sol";
import {ChipClaims} from "../src/ChipClaims.sol";
import {Round, RoundState} from "../src/interfaces/IChipRounds.sol";

/// @notice The 30-day expiry sweep: full, permissionless, per-round, per-holder events,
///         and no compound-share credit for anyone whose credit expires.
contract ChipRewardsExpiryTest is ChipRewardsBase {
    event CreditExpired(uint256 indexed roundId, address indexed stock, address indexed owner, uint256 amount);
    event Swept(uint256 indexed roundId, address indexed stock, uint256 amount, bool complete);

    /// @dev One round, three holders of NVDA in known proportions.
    function _threeHolderRound() internal returns (uint256 id) {
        _fundPot(3_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0); // weight 10_000
        _chip(basedNouns, basedVault, 2, bob, 0); // weight 10_000
        _chip(darkNouns, darkVault, 1, carol, 0); // weight 20_000
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        _setSplit(address(basedNouns), 2, bob, _one(address(nvda)), _one(uint8(100)));
        _setSplit(address(darkNouns), 1, carol, _one(address(nvda)), _one(uint8(100)));

        id = rounds.openRound();
        rounds.contributeWeights(id, address(basedNouns), _ids(1, 2));
        rounds.contributeWeights(id, address(darkNouns), _ids(1));
        vm.warp(block.timestamp + 2 hours);
        rounds.closeAccumulation(id);
        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);
    }

    /* ------------------------------------------------------------------ */
    /*                         THIRTY DAYS, EXACTLY                         */
    /* ------------------------------------------------------------------ */

    function test_expiryIsThirtyDaysAfterFinalize() public {
        uint256 id = _threeHolderRound();
        ChipClaims.Schedule memory sch = claims.scheduleOf(id);
        assertEq(sch.expiresAt, sch.finalizedAt + 30 days);
    }

    function test_sweepWorksOnceExpired() public {
        uint256 id = _threeHolderRound();
        uint256 owed = claims.totalOwed(address(nvda));

        _warpPastExpiry(id);
        (uint256 moved, bool complete) = claims.sweepExpired(id, address(nvda), 0);

        assertEq(moved, owed, "everything unclaimed went");
        assertTrue(complete);
        assertEq(nvda.balanceOf(polTreasury), owed);
        assertEq(claims.totalOwed(address(nvda)), 0);
        assertEq(nvda.balanceOf(address(claims)), 0, "nothing left behind");
    }

    /// @notice Required case: a sweep must never touch a round younger than its expiry.
    ///         Checked right up to the last second.
    function test_sweepCanNeverTouchARoundYoungerThanThirtyDays() public {
        uint256 id = _threeHolderRound();
        uint64 expiresAt = claims.expiresAt(id);

        uint64[5] memory tooEarly = [
            uint64(block.timestamp),
            expiresAt - 30 days + 1,
            expiresAt - 7 days,
            expiresAt - 1,
            expiresAt // exactly at expiry is still too early: the check is strict
        ];

        for (uint256 i; i < tooEarly.length; ++i) {
            vm.warp(tooEarly[i]);
            vm.expectRevert(abi.encodeWithSelector(ChipClaims.NotExpiredYet.selector, id, expiresAt));
            claims.sweepExpired(id, address(nvda), 0);
        }

        // One second later it is allowed.
        vm.warp(uint256(expiresAt) + 1);
        (uint256 moved,) = claims.sweepExpired(id, address(nvda), 0);
        assertGt(moved, 0);
    }

    /// @notice Required case: nothing still claimable is ever swept mid-window. Walk every
    ///         claim window in the round's life and try to sweep inside each one.
    function test_nothingClaimableIsEverSweptMidWindow() public {
        uint256 id = _threeHolderRound();
        uint64 expiresAt = claims.expiresAt(id);
        uint64 anchor = claims.windowAnchor();

        for (uint256 k; k < 10; ++k) {
            uint256 opensAt = uint256(anchor) + k * 7 days;
            if (opensAt <= block.timestamp) continue;
            if (opensAt > expiresAt) break;

            vm.warp(opensAt); // inside an open claim window, before expiry
            assertTrue(claims.isClaimOpen(), "window open");
            assertGt(claims.claimable(id, address(nvda), alice), 0, "still claimable");

            vm.expectRevert(abi.encodeWithSelector(ChipClaims.NotExpiredYet.selector, id, expiresAt));
            claims.sweepExpired(id, address(nvda), 0);
        }

        // And the credit really was still there the whole time.
        vm.warp(expiresAt - 2 days);
        _openClaimWindow();
        vm.prank(alice);
        assertGt(claims.claim(id, address(nvda)), 0, "claimable right up to the end");
    }

    /* ------------------------------------------------------------------ */
    /*                        PER-HOLDER REPORTING                          */
    /* ------------------------------------------------------------------ */

    /// @notice The site needs to show who lost what, so the sweep emits one event per holder.
    function test_emitsPerHolderAmounts() public {
        uint256 id = _threeHolderRound();
        uint256 total = claims.acquired(id, address(nvda));

        uint256 aliceOwed = claims.claimable(id, address(nvda), alice);
        uint256 bobOwed = claims.claimable(id, address(nvda), bob);
        uint256 carolOwed = claims.claimable(id, address(nvda), carol);
        assertEq(aliceOwed + bobOwed + carolOwed, total, "shares add up");
        assertEq(carolOwed, aliceOwed * 2, "dark noun is worth double");

        _warpPastExpiry(id);

        vm.expectEmit(true, true, true, true, address(claims));
        emit CreditExpired(id, address(nvda), alice, aliceOwed);
        vm.expectEmit(true, true, true, true, address(claims));
        emit CreditExpired(id, address(nvda), bob, bobOwed);
        vm.expectEmit(true, true, true, true, address(claims));
        emit CreditExpired(id, address(nvda), carol, carolOwed);

        claims.sweepExpired(id, address(nvda), 0);
    }

    function test_holdersAreTrackedInCreditOrder() public {
        uint256 id = _threeHolderRound();
        address[] memory list = claims.holders(id, address(nvda));
        assertEq(list.length, 3);
        assertEq(list[0], alice);
        assertEq(list[1], bob);
        assertEq(list[2], carol);
    }

    function test_aHolderIsListedOnceEvenWithSeveralNouns() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _chip(basedNouns, basedVault, 2, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        _setSplit(address(basedNouns), 2, alice, _one(address(nvda)), _one(uint8(100)));

        uint256 id = _openAndAccumulate(_ids(1, 2));
        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);

        assertEq(claims.holderCount(id, address(nvda)), 1, "one entry, both Nouns");
        assertEq(claims.claimable(id, address(nvda), alice), claims.acquired(id, address(nvda)));
    }

    /// @notice A holder who claimed in time must not appear as having lost anything.
    function test_alreadyClaimedHoldersAreSkipped() public {
        uint256 id = _threeHolderRound();
        _openClaimWindow();
        vm.prank(alice);
        uint256 got = claims.claim(id, address(nvda));

        _warpPastExpiry(id);
        (uint256 moved,) = claims.sweepExpired(id, address(nvda), 0);

        assertEq(moved, claims.acquired(id, address(nvda)) - got, "only the unclaimed part");
        assertEq(nvda.balanceOf(alice), got, "alice keeps hers");
    }

    /* ------------------------------------------------------------------ */
    /*                            BATCHING                                  */
    /* ------------------------------------------------------------------ */

    function test_sweepCanBeBatchedAndIsIdempotent() public {
        uint256 id = _threeHolderRound();
        uint256 owed = claims.totalOwed(address(nvda));
        _warpPastExpiry(id);

        (uint256 first, bool done1) = claims.sweepExpired(id, address(nvda), 2);
        assertFalse(done1, "two of three");
        assertEq(claims.sweepCursor(id, address(nvda)), 2);

        (uint256 second, bool done2) = claims.sweepExpired(id, address(nvda), 2);
        assertTrue(done2, "finished");
        assertEq(first + second, owed, "same total as a single call");
        assertEq(nvda.balanceOf(polTreasury), owed);

        vm.expectRevert(abi.encodeWithSelector(ChipClaims.AlreadySwept.selector, id, address(nvda)));
        claims.sweepExpired(id, address(nvda), 0);
    }

    function test_batchedSweepLeavesNoDust() public {
        // Weights that do not divide evenly, so per-holder shares are floored.
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 4); // 3.33x
        _chip(basedNouns, basedVault, 2, bob, 1); // 1.25x
        _chip(darkNouns, darkVault, 1, carol, 2); // 1.60x * 2
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        _setSplit(address(basedNouns), 2, bob, _one(address(nvda)), _one(uint8(100)));
        _setSplit(address(darkNouns), 1, carol, _one(address(nvda)), _one(uint8(100)));

        uint256 id = rounds.openRound();
        rounds.contributeWeights(id, address(basedNouns), _ids(1, 2));
        rounds.contributeWeights(id, address(darkNouns), _ids(1));
        vm.warp(block.timestamp + 2 hours);
        rounds.closeAccumulation(id);
        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);

        uint256 acquired = claims.acquired(id, address(nvda));
        _warpPastExpiry(id);

        claims.sweepExpired(id, address(nvda), 1);
        claims.sweepExpired(id, address(nvda), 1);
        claims.sweepExpired(id, address(nvda), 1);

        assertEq(nvda.balanceOf(polTreasury), acquired, "dust settled on the final batch");
        assertEq(nvda.balanceOf(address(claims)), 0);
        assertEq(claims.totalOwed(address(nvda)), 0);
    }

    function test_sweepIsPermissionless() public {
        uint256 id = _threeHolderRound();
        _warpPastExpiry(id);
        vm.prank(makeAddr("passerby"));
        (uint256 moved,) = claims.sweepExpired(id, address(nvda), 0);
        assertGt(moved, 0);
    }

    /* ------------------------------------------------------------------ */
    /*                    EXPIRY IS FORFEIT, NOT COMPOUND                   */
    /* ------------------------------------------------------------------ */

    /// @notice An expired credit earns the holder nothing. No POL share, no ledger entry.
    function test_expiryCreditsNobodysCompoundLedger() public {
        uint256 id = _threeHolderRound();
        _warpPastExpiry(id);
        claims.sweepExpired(id, address(nvda), 0);

        assertEq(claims.polCreditUsd(alice), 0, "no ledger entry for an expired credit");
        assertEq(claims.polCreditUsd(bob), 0);
        assertEq(claims.polCreditUsd(carol), 0);
    }

    /// @notice Even for a holder who opted into auto-compound. Expiry is not a voluntary
    ///         compound; it is a forfeit, and the ledger must not blur the two.
    function test_expiryIgnoresAutoCompoundOptIn() public {
        vm.prank(alice);
        claims.setAutoCompound(true);

        uint256 id = _threeHolderRound();
        _warpPastExpiry(id);
        claims.sweepExpired(id, address(nvda), 0);

        assertTrue(claims.autoCompound(alice), "opt-in still set");
        assertEq(claims.polCreditUsd(alice), 0, "but expiry credited nothing");
    }

    /// @notice The voluntary path still works and still credits, so the two are clearly
    ///         distinguishable.
    function test_voluntaryAutoCompoundStillCreditsTheLedger() public {
        vm.prank(alice);
        claims.setAutoCompound(true);

        uint256 id = _threeHolderRound();
        _openClaimWindow();
        vm.prank(alice);
        claims.claim(id, address(nvda));

        assertGt(claims.polCreditUsd(alice), 0, "voluntary compound is credited");
    }

    /* ------------------------------------------------------------------ */
    /*                               FUZZ                                   */
    /* ------------------------------------------------------------------ */

    /// @notice However the claims and the sweep interleave, the contract ends solvent and
    ///         every token is accounted for exactly once.
    function testFuzz_claimsAndSweepNeverDoublePay(bool aliceClaims, bool bobClaims, uint8 batch) public {
        uint256 id = _threeHolderRound();
        uint256 acquired = claims.acquired(id, address(nvda));

        _openClaimWindow();
        uint256 claimed;
        if (aliceClaims) {
            vm.prank(alice);
            claimed += claims.claim(id, address(nvda));
        }
        if (bobClaims) {
            vm.prank(bob);
            claimed += claims.claim(id, address(nvda));
        }

        _warpPastExpiry(id);
        uint256 swept;
        uint256 guard;
        while (!claims.stockSwept(id, address(nvda)) && guard < 10) {
            (uint256 moved,) = claims.sweepExpired(id, address(nvda), uint256(bound(batch, 1, 3)));
            swept += moved;
            ++guard;
        }

        assertEq(claimed + swept, acquired, "every unit accounted for exactly once");
        assertEq(nvda.balanceOf(address(claims)), 0, "solvent and empty");
        assertEq(claims.totalOwed(address(nvda)), 0);
    }
}
