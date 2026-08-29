// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChipRewardsBase} from "./ChipRewardsBase.t.sol";
import {ChipRounds} from "../src/ChipRounds.sol";
import {ChipClaims} from "../src/ChipClaims.sol";
import {Round, RoundState} from "../src/interfaces/IChipRounds.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice The rescue function, ported from the BasedPacks `recoverExcessERC20` pattern.
///         THE RULE: it may only ever move tokens above the sum of everything owed to
///         claimants. It can never touch a user credit, no matter who calls it or what
///         state the contract is in.
contract ChipRewardsRecoverTest is ChipRewardsBase {
    address internal rescueTo = makeAddr("rescueTo");

    /// @dev One finalized round: 5 NVDA acquired and owed to alice, nothing else.
    function _roundWithOwedNvda() internal returns (uint256 id) {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        id = _openAndAccumulate(_ids(1));
        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);
    }

    /* ------------------------------------------------------------------ */
    /*                         THE CORE INVARIANT                           */
    /* ------------------------------------------------------------------ */

    function test_cannotTouchOwedCredits() public {
        _roundWithOwedNvda();

        assertEq(claims.totalOwed(address(nvda)), 5e8);
        assertEq(nvda.balanceOf(address(claims)), 5e8);
        assertEq(claims.excess(address(nvda)), 0, "everything here is spoken for");

        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(ChipClaims.InsufficientExcess.selector, address(nvda), uint256(1), uint256(0))
        );
        claims.recoverExcess(address(nvda), rescueTo, 1);
    }

    function test_cannotTakeEvenOneWeiMoreThanExcess() public {
        _roundWithOwedNvda();
        nvda.mint(address(claims), 3e8); // a stray airdrop of the same stock

        assertEq(claims.excess(address(nvda)), 3e8);

        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChipClaims.InsufficientExcess.selector, address(nvda), uint256(3e8 + 1), uint256(3e8)
            )
        );
        claims.recoverExcess(address(nvda), rescueTo, 3e8 + 1);

        vm.prank(multisig);
        claims.recoverExcess(address(nvda), rescueTo, 3e8); // exactly the excess is fine
        assertEq(nvda.balanceOf(rescueTo), 3e8);
        assertEq(nvda.balanceOf(address(claims)), 5e8, "alice's credit untouched");
    }

    function test_creditsRemainClaimableAfterARescue() public {
        uint256 id = _roundWithOwedNvda();
        nvda.mint(address(claims), 3e8);

        vm.prank(multisig);
        claims.recoverExcess(address(nvda), rescueTo, 3e8);

        vm.prank(alice);
        assertEq(claims.claim(id, address(nvda)), 5e8, "claim unaffected by the rescue");
        assertEq(nvda.balanceOf(alice), 5e8);
    }

    function test_strayAirdropOfAnUnrelatedTokenIsFullyRecoverable() public {
        MockERC20 junk = new MockERC20("Airdrop", "JUNK", 18);
        junk.mint(address(claims), 777 ether);

        assertEq(claims.totalOwed(address(junk)), 0);
        assertEq(claims.excess(address(junk)), 777 ether);

        vm.prank(multisig);
        claims.recoverExcess(address(junk), rescueTo, 777 ether);
        assertEq(junk.balanceOf(rescueTo), 777 ether);
    }

    /// @notice A live round's budget is COMMITTED the moment it is pulled from the Pot.
    ///         It is not yet anyone's credit, but the rescue must still not reach it.
    /// @dev Regression test. The solvency invariant caught this: when the rescue could
    ///      drain an open round's budget, a later settlement still credited holders for
    ///      money that had already left the contract, leaving it insolvent.
    function test_liveRoundBudgetIsNotRescuable() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        rounds.openRound();

        assertEq(rounds.committedQuote(), 1_000e6);
        assertEq(claims.excess(address(usdc)), 0, "committed, not excess");

        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(ChipClaims.InsufficientExcess.selector, address(usdc), uint256(1), uint256(0))
        );
        claims.recoverExcess(address(usdc), rescueTo, 1);
    }

    /// @notice An airdrop on top of a live budget is still rescuable: the commitment is a
    ///         floor, not a blanket freeze.
    function test_rescueStillWorksAboveTheCommittedBudget() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        rounds.openRound();
        usdc.mint(address(rounds), 42e6); // stray

        assertEq(rounds.excess(address(usdc)), 42e6);
        vm.prank(multisig);
        rounds.recoverExcess(address(usdc), rescueTo, 42e6);
        assertEq(usdc.balanceOf(rescueTo), 42e6);
        assertEq(usdc.balanceOf(address(rounds)), 1_000e6, "budget intact");
    }

    /// @notice Committed funds must never be able to lock up forever.
    function test_abandonedRoundReturnsItsBudgetToThePot() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        uint256 id = rounds.openRound();

        vm.expectRevert();
        rounds.cancelRound(id); // too early

        vm.warp(block.timestamp + 24 hours);
        rounds.cancelRound(id); // permissionless

        assertEq(rounds.committedQuote(), 0);
        assertEq(pot.available(), 1_000e6, "budget back in the pot");
        assertEq(usdc.balanceOf(address(claims)), 0);
    }

    /// @notice After the budget becomes credits, the same money is out of reach.
    function test_onceBudgetBecomesCreditsItIsOutOfReach() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        uint256 id = _openAndAccumulate(_ids(1)); // no split -> USDC
        rounds.settleStock(id, address(usdc));
        rounds.finalizeRound(id);

        assertEq(claims.totalOwed(address(usdc)), 1_000e6);
        assertEq(claims.excess(address(usdc)), 0);

        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(ChipClaims.InsufficientExcess.selector, address(usdc), uint256(1), uint256(0))
        );
        claims.recoverExcess(address(usdc), rescueTo, 1);
    }

    /* ------------------------------------------------------------------ */
    /*                       OWED TRACKING OVER TIME                        */
    /* ------------------------------------------------------------------ */

    function test_owedFallsAsHoldersClaim() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _chip(basedNouns, basedVault, 2, bob, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        _setSplit(address(basedNouns), 2, bob, _one(address(nvda)), _one(uint8(100)));

        uint256 id = _openAndAccumulate(_ids(1, 2));
        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);

        assertEq(claims.totalOwed(address(nvda)), 5e8);
        vm.prank(alice);
        claims.claim(id, address(nvda));
        assertEq(claims.totalOwed(address(nvda)), 2.5e8);
        vm.prank(bob);
        claims.claim(id, address(nvda));
        assertEq(claims.totalOwed(address(nvda)), 0);
        assertEq(nvda.balanceOf(address(claims)), 0);
    }

    function test_owedFallsWhenExpiredCreditsAreSwept() public {
        uint256 id = _roundWithOwedNvda();
        assertEq(claims.totalOwed(address(nvda)), 5e8);

        vm.warp(block.timestamp + 91 days);
        claims.sweepExpired(id, address(nvda));

        assertEq(claims.totalOwed(address(nvda)), 0);
        assertEq(claims.excess(address(nvda)), 0, "swept out entirely");
    }

    /// @notice Expired-but-not-yet-swept credits still count as owed. The rescue must not
    ///         be a back door around the sweep, which is meant to go to the POL treasury.
    function test_expiredButUnsweptCreditsAreStillProtected() public {
        _roundWithOwedNvda();
        vm.warp(block.timestamp + 91 days);

        assertEq(claims.totalOwed(address(nvda)), 5e8, "still owed until swept");
        assertEq(claims.excess(address(nvda)), 0);

        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(ChipClaims.InsufficientExcess.selector, address(nvda), uint256(1), uint256(0))
        );
        claims.recoverExcess(address(nvda), rescueTo, 1);
    }

    /* ------------------------------------------------------------------ */
    /*                            PERMISSIONS                               */
    /* ------------------------------------------------------------------ */

    function test_recoverExcess_onlyMultisig() public {
        MockERC20 junk = new MockERC20("Airdrop", "JUNK", 18);
        junk.mint(address(claims), 100 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        claims.recoverExcess(address(junk), rescueTo, 100 ether);
    }

    function test_recoverExcess_rejectsZeroAddressAndZeroAmount() public {
        MockERC20 junk = new MockERC20("Airdrop", "JUNK", 18);
        junk.mint(address(claims), 100 ether);

        vm.prank(multisig);
        vm.expectRevert(ChipRounds.ZeroAddress.selector);
        claims.recoverExcess(address(junk), address(0), 1 ether);

        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChipClaims.InsufficientExcess.selector, address(junk), uint256(0), uint256(100 ether)
            )
        );
        claims.recoverExcess(address(junk), rescueTo, 0);
    }

    /* ------------------------------------------------------------------ */
    /*                               FUZZ                                   */
    /* ------------------------------------------------------------------ */

    /// @notice For any airdrop size and any rescue amount, solvency must hold afterwards.
    function testFuzz_solvencyHoldsAfterAnyRescue(uint128 airdrop, uint128 rescueAmount) public {
        uint256 id = _roundWithOwedNvda();
        uint256 owed = claims.totalOwed(address(nvda));
        nvda.mint(address(claims), airdrop);

        uint256 avail = claims.excess(address(nvda));
        assertEq(avail, airdrop, "excess is exactly the airdrop");

        if (rescueAmount == 0 || rescueAmount > avail) {
            vm.prank(multisig);
            vm.expectRevert(
                abi.encodeWithSelector(
                    ChipClaims.InsufficientExcess.selector, address(nvda), uint256(rescueAmount), avail
                )
            );
            claims.recoverExcess(address(nvda), rescueTo, rescueAmount);
        } else {
            vm.prank(multisig);
            claims.recoverExcess(address(nvda), rescueTo, rescueAmount);
        }

        // THE INVARIANT.
        assertGe(nvda.balanceOf(address(claims)), claims.totalOwed(address(nvda)), "solvent");
        assertEq(claims.totalOwed(address(nvda)), owed, "owed never changed");

        // And the holder can still be paid in full.
        vm.prank(alice);
        assertEq(claims.claim(id, address(nvda)), 5e8);
    }
}
