// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChipRewardsBase} from "./ChipRewardsBase.t.sol";
import {ChipClaims} from "../src/ChipClaims.sol";
import {Round, RoundState} from "../src/interfaces/IChipRounds.sol";

/// @title ChipClaimsGovernanceTest
/// @notice What the owner of the LEDGER can and cannot reach.
///
/// @dev External review (TRIAGE EXT-C-H-1) claimed the owner could combine a retarget with
///      `claimFor` to drain unclaimed credits. Half of that is wrong and half of it is right,
///      and both halves are pinned here:
///
///      - `claimFor` is **not** the lever. It is permissionless on purpose (ASSUMPTIONS C-16)
///        and always pays the recorded owner, so a stranger calling it can only help. No
///        argument to it redirects a payout.
///      - `setRounds` **is** the lever. The ledger trusts whatever address sits in `rounds`
///        to write weights, and weight is the numerator of every claim. Retarget it to a
///        hostile contract while a round is still open and that contract can mint itself
///        weight against stock the round has already bought.
///
///      The fix is a 48-hour timelock on the retarget, so the change is visible on chain long
///      before it binds and holders can claim out ahead of it.
contract ChipClaimsGovernanceTest is ChipRewardsBase {
    /* ------------------------------------------------------------------ */
    /*                    WHAT `claimFor` CANNOT DO                         */
    /* ------------------------------------------------------------------ */

    /// @notice `claimFor` pays the credit's owner and nobody else, whoever calls it and
    ///         whatever they pass. This is the half of EXT-C-H-1 that is simply not true.
    function test_claimForCannotRedirectAPayoutToTheCaller() public {
        uint256 id = _aFinalizedRound();
        uint256 owed = claims.claimable(id, address(nvda), alice);
        assertGt(owed, 0);

        _openClaimWindow();

        // The owner calls it, naming itself. It pays ALICE, because the credit is alice's.
        vm.prank(multisig);
        claims.claimFor(alice, id, address(nvda));

        assertEq(nvda.balanceOf(alice), owed, "paid the owner of the credit");
        assertEq(nvda.balanceOf(multisig), 0, "and not the caller");

        // Naming the owner as the beneficiary pays the owner's own (empty) credit, not alice's.
        vm.prank(multisig);
        vm.expectRevert();
        claims.claimFor(multisig, id, address(nvda));
    }

    /// @notice And the rescue cannot reach a booked credit either — the other path the
    ///         finding assumed. `excess` is balance minus `totalOwed`, and the call re-checks
    ///         solvency after transferring.
    function test_recoverExcessCannotReachABookedCredit() public {
        _aFinalizedRound();
        uint256 owed = claims.totalOwed(address(nvda));
        assertGt(owed, 0);
        assertEq(claims.excess(address(nvda)), 0, "nothing is spare");

        vm.prank(multisig);
        vm.expectRevert();
        claims.recoverExcess(address(nvda), multisig, 1);

        assertEq(claims.totalOwed(address(nvda)), owed, "untouched");
    }

    /* ------------------------------------------------------------------ */
    /*              WHAT `setRounds` COULD DO, AND NOW CANNOT               */
    /* ------------------------------------------------------------------ */

    /// @notice THE REAL FINDING. A retargeted `rounds` can mint weight against stock a live
    ///         round has already bought, diluting the holders who earned it.
    ///
    /// @dev The timelock is what defeats it: the retarget is announced 48 hours before it
    ///      binds, which is longer than a round lives, so the round this would attack has
    ///      finalized and been claimable long before the new `rounds` can write anything.
    ///      `creditWeight` already refuses a finalized round, so there is nothing left to
    ///      attack by the time the change lands.
    function test_aRetargetedRoundsCannotFabricateWeightWithinARoundsLifetime() public {
        // A live round that has already bought stock but is not yet finalized.
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        uint256 id = _openAndAccumulate(_ids(1));
        rounds.settleStock(id, address(nvda));

        uint256 acquired = claims.acquired(id, address(nvda));
        assertGt(acquired, 0, "the round is holding real stock");
        assertEq(claims.weightOf(id, address(nvda), alice), 10_000);

        HostileRounds attacker = new HostileRounds(claims);

        // The retarget is now QUEUED, not applied.
        vm.prank(multisig);
        claims.queueRounds(address(attacker));
        assertEq(claims.rounds(), address(rounds), "still the real engine");

        // The attacker cannot write anything yet.
        vm.expectRevert(abi.encodeWithSelector(ChipClaims.NotRounds.selector, address(attacker)));
        attacker.mintWeight(id, address(nvda), 1_000_000);

        // Executing early is refused.
        vm.warp(block.timestamp + 48 hours - 1);
        vm.prank(multisig);
        vm.expectRevert();
        claims.executeRounds();

        // Meanwhile the round finishes and alice's share is fixed, exactly as it should be.
        rounds.finalizeRound(id);

        // Now the retarget lands. It is too late to matter: the round is finalized.
        vm.warp(block.timestamp + 1);
        vm.prank(multisig);
        claims.executeRounds();
        assertEq(claims.rounds(), address(attacker));

        vm.expectRevert(abi.encodeWithSelector(ChipClaims.AlreadyFinalized.selector, id));
        attacker.mintWeight(id, address(nvda), 1_000_000);

        // Alice's credit is whole.
        assertEq(claims.weightOf(id, address(nvda), alice), 10_000);
        assertEq(claims.claimable(id, address(nvda), alice), acquired, "the entire round is hers");

        _openClaimWindow();
        vm.prank(alice);
        assertEq(claims.claim(id, address(nvda)), acquired);
    }

    /// @notice The first wiring is immediate, because at deploy there is nothing to protect
    ///         and a 48-hour gap would only mean a half-wired system sitting exposed longer.
    function test_theFirstWiringIsImmediateAndEveryLaterOneIsNot() public {
        ChipClaims fresh = new ChipClaims(multisig, address(registry));
        assertEq(fresh.rounds(), address(0));

        vm.prank(multisig);
        fresh.setRounds(address(rounds)); // immediate: rounds was unset
        assertEq(fresh.rounds(), address(rounds));

        // The second one is not.
        vm.prank(multisig);
        vm.expectRevert(ChipClaims.AlreadyWired.selector);
        fresh.setRounds(address(0xBEEF));
    }

    function test_aQueuedRetargetCanBeCancelled() public {
        vm.prank(multisig);
        claims.queueRounds(address(0xBEEF));
        vm.prank(multisig);
        claims.cancelRounds();

        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        vm.expectRevert(ChipClaims.NothingQueued.selector);
        claims.executeRounds();
        assertEq(claims.rounds(), address(rounds));
    }

    function test_retargetIsMultisigOnly() public {
        vm.startPrank(alice);
        vm.expectRevert();
        claims.queueRounds(address(0xBEEF));
        vm.expectRevert();
        claims.executeRounds();
        vm.expectRevert();
        claims.queuePolTreasury(address(0xBEEF));
        vm.stopPrank();
    }

    /// @notice The POL target is timelocked for the same reason: `sweepExpired` sends
    ///         forfeited credits there, so retargeting it diverts real value.
    function test_thePolTargetIsAlsoTimelocked() public {
        vm.prank(multisig);
        claims.queuePolTreasury(address(0xBEEF));
        assertEq(claims.polTreasury(), polTreasury, "unchanged while queued");

        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        claims.executePolTreasury();
        assertEq(claims.polTreasury(), address(0xBEEF));
    }

    /* ------------------------------------------------------------------ */
    /*                    EXT-C-M-1 and EXT-C-M-2                           */
    /* ------------------------------------------------------------------ */

    /// @notice EXT-C-M-1 disputed: there is no block in which a credit is both claimable and
    ///         sweepable, so a sweep cannot be raced against a claim at the boundary.
    function test_claimAndSweepAreStrictlyDisjointAtTheBoundary() public {
        uint256 id = _aFinalizedRound();
        uint64 expiresAt = claims.scheduleOf(id).expiresAt;

        // The last instant a claim is legal: sweeping is refused.
        vm.warp(expiresAt);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ChipClaims.NotExpiredYet.selector, id, expiresAt));
        claims.sweepExpired(id, address(nvda), 0);

        // The first instant a sweep is legal: claiming is refused.
        vm.warp(uint256(expiresAt) + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ChipClaims.CreditsExpired.selector, id, expiresAt));
        claims.claim(id, address(nvda));
    }

    /// @notice And a dust-sized sweep cannot grief: batching is idempotent, advances a
    ///         cursor the caller pays for, and changes nobody's amount.
    function test_dustSizedSweepBatchesCannotGriefAnyone() public {
        _fundPot(3_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _chip(basedNouns, basedVault, 2, bob, 0);
        _chip(basedNouns, basedVault, 3, carol, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        _setSplit(address(basedNouns), 2, bob, _one(address(nvda)), _one(uint8(100)));
        _setSplit(address(basedNouns), 3, carol, _one(address(nvda)), _one(uint8(100)));

        uint256 id = rounds.openRound();
        rounds.contributeWeights(id, address(basedNouns), _ids(1, 2, 3));
        vm.warp(block.timestamp + 2 hours);
        rounds.closeAccumulation(id);
        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);

        uint256 owed = claims.totalOwed(address(nvda));
        vm.warp(uint256(claims.scheduleOf(id).expiresAt) + 1);

        // A griefer sweeps one holder at a time, repeatedly, at their own gas cost.
        vm.startPrank(makeAddr("griefer"));
        claims.sweepExpired(id, address(nvda), 1);
        claims.sweepExpired(id, address(nvda), 1);
        claims.sweepExpired(id, address(nvda), 1);

        // And once the last holder is done it refuses further calls outright, rather than
        // silently no-opping — so a griefer cannot even burn gas pretending to make progress.
        vm.expectRevert(abi.encodeWithSelector(ChipClaims.AlreadySwept.selector, id, address(nvda)));
        claims.sweepExpired(id, address(nvda), 1);
        vm.stopPrank();

        // Everything reached POL exactly once, and the ledger owes nothing.
        assertEq(nvda.balanceOf(polTreasury), owed, "every token swept exactly once");
        assertEq(claims.totalOwed(address(nvda)), 0);
    }

    /// @notice EXT-C-M-2 disputed: no credit can land after the round's expiry is computed,
    ///         because both write paths refuse a finalized round. Invariant 11.
    function test_noCreditCanLandAfterTheScheduleIsFrozen() public {
        uint256 id = _aFinalizedRound();
        assertGt(claims.scheduleOf(id).expiresAt, 0, "the schedule is frozen");

        // Both of the ledger's write paths refuse, from the real engine.
        vm.startPrank(address(rounds));
        vm.expectRevert(abi.encodeWithSelector(ChipClaims.AlreadyFinalized.selector, id));
        claims.creditWeight(id, address(nvda), alice, 1);
        vm.expectRevert(abi.encodeWithSelector(ChipClaims.AlreadyFinalized.selector, id));
        claims.recordAcquired(id, address(nvda), 1);
        vm.stopPrank();
    }

    /* -------------------------------- helpers -------------------------------- */

    function _aFinalizedRound() internal returns (uint256 id) {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        id = _openAndAccumulate(_ids(1));
        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);
    }
}

/// @notice A hostile replacement for the engine: mints itself weight if it is ever trusted.
contract HostileRounds {
    ChipClaims internal immutable claims;

    constructor(ChipClaims claims_) {
        claims = claims_;
    }

    function mintWeight(uint256 roundId, address stock, uint256 weight) external {
        claims.creditWeight(roundId, stock, address(this), weight);
    }
}
