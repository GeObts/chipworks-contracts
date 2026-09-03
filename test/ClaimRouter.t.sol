// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChipRewardsBase} from "./ChipRewardsBase.t.sol";
import {ClaimRouter} from "../src/ClaimRouter.sol";
import {ChipRounds} from "../src/ChipRounds.sol";
import {ChipClaims} from "../src/ChipClaims.sol";
import {Round, RoundState} from "../src/interfaces/IChipRounds.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice The router after the Clutch leg was dropped.
///
/// @dev Every property this suite asserted before is still asserted, minus the ones that
///      only existed to hedge Clutch's unknown `claim` semantics. Those are gone because the
///      leg is gone: Clutch's `claim` is permissioned to the owner of record and reverts
///      `NotOwner()` for a router (CLUTCH_RECON section 4), and Chipworks now runs its own
///      activation vault where activation is a burned cost, not a second reward stream.
///
///      What is deliberately still here: leg independence, per-leg gas bounding, "routing is
///      never worse than direct", the credit surviving a failed leg, the claim window gate
///      not being bypassed, and the permissionless sweep as a safety valve.
contract ClaimRouterTest is ChipRewardsBase {
    ClaimRouter internal router_;

    function setUp() public override {
        super.setUp();
        router_ = new ClaimRouter(multisig, address(claims), 1_000_000);
    }

    function _chipClaims(uint256 roundId, address stock) internal pure returns (ClaimRouter.ChipClaim[] memory c) {
        c = new ClaimRouter.ChipClaim[](1);
        c[0] = ClaimRouter.ChipClaim({roundId: roundId, stock: stock});
    }

    function _chipClaims2(uint256 roundId, address s1, address s2)
        internal
        pure
        returns (ClaimRouter.ChipClaim[] memory c)
    {
        c = new ClaimRouter.ChipClaim[](2);
        c[0] = ClaimRouter.ChipClaim({roundId: roundId, stock: s1});
        c[1] = ClaimRouter.ChipClaim({roundId: roundId, stock: s2});
    }

    function _noChip() internal pure returns (ClaimRouter.ChipClaim[] memory) {
        return new ClaimRouter.ChipClaim[](0);
    }

    /// @dev Alice: one Noun, split 50/50 NVDA + AAPL, one finalized round.
    function _setup() internal returns (uint256 id) {
        _fundPot(2_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _two(address(nvda), address(aapl)), _two(uint8(50), uint8(50)));

        id = _openAndAccumulate(_ids(1));
        rounds.settleStock(id, address(nvda));
        rounds.settleStock(id, address(aapl));
        rounds.finalizeRound(id);
    }

    /* ------------------------------------------------------------------ */
    /*                            HAPPY PATH                                */
    /* ------------------------------------------------------------------ */

    function test_oneCallClaimsEveryCredit() public {
        uint256 id = _setup();

        vm.prank(alice);
        uint256 ok = router_.claimEverything(_chipClaims2(id, address(nvda), address(aapl)));

        assertEq(ok, 2, "both stocks claimed");
        assertEq(nvda.balanceOf(alice), 5e8);
        assertEq(aapl.balanceOf(alice), 4e8);
    }

    /// @notice The router must never become the claimant or keep anything.
    function test_routerHoldsNothingAfterwards() public {
        uint256 id = _setup();

        vm.prank(alice);
        router_.claimEverything(_chipClaims2(id, address(nvda), address(aapl)));

        assertEq(nvda.balanceOf(address(router_)), 0);
        assertEq(aapl.balanceOf(address(router_)), 0);
    }

    function test_aSingleCreditRoutesFine() public {
        uint256 id = _setup();
        vm.prank(alice);
        assertEq(router_.claimEverything(_chipClaims(id, address(nvda))), 1);
        assertEq(nvda.balanceOf(alice), 5e8);
    }

    function test_revertsWhenNothingRequested() public {
        vm.prank(alice);
        vm.expectRevert(ClaimRouter.NothingRequested.selector);
        router_.claimEverything(_noChip());
    }

    /* ------------------------------------------------------------------ */
    /*                        LEG INDEPENDENCE                              */
    /* ------------------------------------------------------------------ */

    /// @notice A frozen stock must not stop the others paying out.
    function test_oneFrozenStockDoesNotBlockTheRest() public {
        uint256 id = _setup();
        aapl.setBlacklisted(alice, true); // her AAPL claim will revert

        vm.prank(alice);
        uint256 ok = router_.claimEverything(_chipClaims2(id, address(aapl), address(nvda)));

        assertEq(ok, 1, "AAPL failed, NVDA succeeded");
        assertEq(nvda.balanceOf(alice), 5e8);
        assertEq(aapl.balanceOf(alice), 0);

        // And the frozen credit survives for later.
        aapl.setBlacklisted(alice, false);
        vm.prank(alice);
        assertEq(claims.claim(id, address(aapl)), 4e8, "nothing lost");
    }

    /// @notice A hostile leg must not starve the legs after it of gas. This is the concrete
    ///         form of "routing must never be worse than direct", and it is the reason every
    ///         leg is a gas-capped `call` rather than a plain external call.
    ///
    /// @dev Pointed at a ledger that burns every wei it is handed for one particular stock.
    ///      Without the per-leg cap the first leg would consume the whole transaction and
    ///      the two healthy legs after it would never run — the caller would be strictly
    ///      worse off for having routed. See ASSUMPTIONS A-17.
    function test_oneGasBurningLegDoesNotStarveTheRest() public {
        SelectiveGasBombLedger bombLedger = new SelectiveGasBombLedger(address(aapl));
        ClaimRouter r = new ClaimRouter(multisig, address(bombLedger), 1_000_000);

        ClaimRouter.ChipClaim[] memory legs = new ClaimRouter.ChipClaim[](3);
        legs[0] = ClaimRouter.ChipClaim({roundId: 1, stock: address(aapl)}); // burns all gas
        legs[1] = ClaimRouter.ChipClaim({roundId: 1, stock: address(nvda)});
        legs[2] = ClaimRouter.ChipClaim({roundId: 1, stock: address(googl)});

        vm.prank(alice);
        uint256 ok = r.claimEverything(legs);

        assertEq(ok, 2, "both healthy legs ran after the gas bomb");
        assertEq(bombLedger.calls(), 2);
    }

    function test_revertsOnlyWhenEveryLegFails() public {
        uint256 id = _setup();
        vm.prank(alice);
        claims.claim(id, address(nvda)); // already taken

        vm.prank(alice);
        vm.expectRevert(ClaimRouter.EverythingFailed.selector);
        router_.claimEverything(_chipClaims(id, address(nvda)));
    }

    function test_anUnknownRoundIsAFailedLegNotARevert() public {
        uint256 id = _setup();
        ClaimRouter.ChipClaim[] memory legs = new ClaimRouter.ChipClaim[](2);
        legs[0] = ClaimRouter.ChipClaim({roundId: 999, stock: address(nvda)});
        legs[1] = ClaimRouter.ChipClaim({roundId: id, stock: address(nvda)});

        vm.prank(alice);
        assertEq(router_.claimEverything(legs), 1);
        assertEq(nvda.balanceOf(alice), 5e8);
    }

    /// @notice Someone else's credit is a failed leg, never a theft.
    function test_routingCannotClaimSomebodyElsesCredit() public {
        uint256 id = _setup();

        vm.prank(bob);
        vm.expectRevert(ClaimRouter.EverythingFailed.selector);
        router_.claimEverything(_chipClaims(id, address(nvda)));

        assertEq(nvda.balanceOf(bob), 0);
        assertGt(claims.claimable(id, address(nvda), alice), 0, "alice's credit untouched");
    }

    /* ------------------------------------------------------------------ */
    /*                  NEVER WORSE THAN CLAIMING DIRECTLY                  */
    /* ------------------------------------------------------------------ */

    /// @notice Same starting state, two paths, identical outcome.
    function test_routedOutcomeEqualsDirectOutcome() public {
        uint256 id = _setup();
        uint256 snap = vm.snapshotState();

        vm.startPrank(alice);
        claims.claim(id, address(nvda));
        claims.claim(id, address(aapl));
        vm.stopPrank();

        uint256 directNvda = nvda.balanceOf(alice);
        uint256 directAapl = aapl.balanceOf(alice);

        vm.revertToState(snap);
        vm.prank(alice);
        router_.claimEverything(_chipClaims2(id, address(nvda), address(aapl)));

        assertEq(nvda.balanceOf(alice), directNvda, "NVDA identical");
        assertEq(aapl.balanceOf(alice), directAapl, "AAPL identical");
    }

    /// @notice Even when one leg is broken, routing recovers exactly what direct claiming
    ///         would have recovered — no more, no less.
    function test_routedOutcomeEqualsDirectOutcomeWhenALegIsBroken() public {
        uint256 id = _setup();
        aapl.setBlacklisted(alice, true);
        uint256 snap = vm.snapshotState();

        vm.prank(alice);
        claims.claim(id, address(nvda));
        vm.prank(alice);
        try claims.claim(id, address(aapl)) {} catch {}

        uint256 directNvda = nvda.balanceOf(alice);
        uint256 directAapl = aapl.balanceOf(alice);

        vm.revertToState(snap);
        vm.prank(alice);
        router_.claimEverything(_chipClaims2(id, address(nvda), address(aapl)));

        assertEq(nvda.balanceOf(alice), directNvda);
        assertEq(aapl.balanceOf(alice), directAapl);
    }

    /// @notice Routing must not consume a credit it failed to deliver.
    function test_failedLegLeavesTheCreditClaimable() public {
        uint256 id = _setup();
        aapl.setBlacklisted(alice, true);

        uint256 owedBefore = claims.claimable(id, address(aapl), alice);
        vm.prank(alice);
        router_.claimEverything(_chipClaims2(id, address(nvda), address(aapl)));

        assertEq(claims.claimable(id, address(aapl), alice), owedBefore, "credit intact");
        assertFalse(claims.hasClaimed(id, address(aapl), alice), "not marked claimed");
    }

    /* ------------------------------------------------------------------ */
    /*                        THE SAFETY VALVE                              */
    /* ------------------------------------------------------------------ */

    /// @notice The router should never hold a balance. If something arrives anyway, anyone
    ///         can push it out — but only to the address they name, never to themselves by
    ///         default.
    function test_sweepToRescuesStrandedTokens() public {
        chip.mint(address(router_), 77 ether);
        vm.prank(makeAddr("goodSamaritan"));
        router_.sweepTo(alice, _one(address(chip)));
        assertEq(chip.balanceOf(alice), 77 ether);
        assertEq(chip.balanceOf(address(router_)), 0);
    }

    /// @notice A frozen token must not strand the others in the same sweep.
    function test_aFrozenTokenDoesNotBlockTheRestOfTheSweep() public {
        chip.mint(address(router_), 10 ether);
        aapl.mint(address(router_), 5e8);
        aapl.setBlacklisted(address(router_), true);

        router_.sweepTo(alice, _two(address(aapl), address(chip)));

        assertEq(chip.balanceOf(alice), 10 ether, "the healthy token moved");
        assertEq(aapl.balanceOf(address(router_)), 5e8, "the frozen one stays, still recoverable");
    }

    function test_sweepToRejectsZeroAddress() public {
        vm.expectRevert(ClaimRouter.ZeroAddress.selector);
        router_.sweepTo(address(0), _one(address(chip)));
    }

    /* ------------------------------------------------------------------ */
    /*                            GOVERNANCE                                */
    /* ------------------------------------------------------------------ */

    function test_configOnlyMultisig() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        router_.setRewards(address(claims));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        router_.setLegGasLimit(500_000);
        vm.stopPrank();
    }

    function test_legGasLimitHasAFloor() public {
        vm.prank(multisig);
        vm.expectRevert(ClaimRouter.BadGasLimit.selector);
        router_.setLegGasLimit(99_999);
    }

    function test_constructorRejectsAZeroLedger() public {
        vm.expectRevert(ClaimRouter.ZeroAddress.selector);
        new ClaimRouter(multisig, address(0), 1_000_000);
    }

    /* ------------------------------------------------------------------ */
    /*                    THE CLAIM WINDOW GATE                             */
    /* ------------------------------------------------------------------ */

    /// @notice Routing must not bypass the window gate.
    function test_routedClaimRevertsWhileClaimsAreShut() public {
        uint256 id = _setup();
        vm.warp(claims.windowAnchor() + 3 days); // between windows
        assertFalse(claims.isClaimOpen());

        vm.prank(alice);
        vm.expectRevert(ClaimRouter.EverythingFailed.selector);
        router_.claimEverything(_chipClaims2(id, address(nvda), address(aapl)));

        assertEq(nvda.balanceOf(alice), 0);
        assertGt(claims.claimable(id, address(nvda), alice), 0, "credits untouched");
    }

    function test_routedClaimWorksWhenTheWindowReopens() public {
        uint256 id = _setup();
        vm.warp(claims.windowAnchor() + 3 days);

        (bool open, uint64 nextOpenAt) = router_.claimWindowStatus();
        assertFalse(open);

        vm.warp(nextOpenAt);
        vm.prank(alice);
        assertEq(router_.claimEverything(_chipClaims2(id, address(nvda), address(aapl))), 2);
        assertEq(nvda.balanceOf(alice), 5e8);
    }

    /// @notice Routing is still never worse than direct, gate included.
    function test_routedEqualsDirectWhileShut() public {
        uint256 id = _setup();
        vm.warp(claims.windowAnchor() + 3 days);
        uint256 snap = vm.snapshotState();

        vm.prank(alice);
        try claims.claim(id, address(nvda)) {} catch {}
        uint256 directNvda = nvda.balanceOf(alice);

        vm.revertToState(snap);
        vm.prank(alice);
        try router_.claimEverything(_chipClaims(id, address(nvda))) {} catch {}

        assertEq(nvda.balanceOf(alice), directNvda, "identical outcome");
    }

    function test_claimWindowStatusReportsOpenState() public {
        (bool open,) = router_.claimWindowStatus();
        assertTrue(open, "open right after deploy");

        vm.warp(claims.windowAnchor() + 3 days);
        (bool shut, uint64 next) = router_.claimWindowStatus();
        assertFalse(shut);
        assertEq(next, claims.windowAnchor() + 7 days);
    }
}

/// @notice A ledger that burns every wei of gas it is given for one nominated stock, and
///         behaves normally for everything else.
contract SelectiveGasBombLedger {
    address public immutable bombStock;
    uint256 public calls;

    constructor(address bombStock_) {
        bombStock = bombStock_;
    }

    function claimFor(address, uint256, address stock) external returns (uint256) {
        if (stock == bombStock) {
            assembly {
                invalid()
            }
        }
        calls += 1;
        return 1;
    }

    function claimable(uint256, address, address) external pure returns (uint256) {
        return 1;
    }

    function isClaimOpen() external pure returns (bool) {
        return true;
    }

    function nextWindowOpensAt() external pure returns (uint64) {
        return 0;
    }
}
