// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChipRewardsBase} from "./ChipRewardsBase.t.sol";
import {ClaimRouter} from "../src/ClaimRouter.sol";
import {ChipRewards} from "../src/ChipRewards.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {GasBombNoun} from "./mocks/MockNoun.sol";

contract ClaimRouterTest is ChipRewardsBase {
    ClaimRouter internal router_;

    function setUp() public override {
        super.setUp();
        router_ = new ClaimRouter(multisig, address(rewards), address(adapter), 1_000_000);
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

    function _clutchClaims(address collection, uint256 tokenId)
        internal
        pure
        returns (ClaimRouter.ClutchClaim[] memory c)
    {
        c = new ClaimRouter.ClutchClaim[](1);
        c[0] = ClaimRouter.ClutchClaim({collection: collection, tokenId: tokenId});
    }

    function _noClutch() internal pure returns (ClaimRouter.ClutchClaim[] memory) {
        return new ClaimRouter.ClutchClaim[](0);
    }

    function _noChip() internal pure returns (ClaimRouter.ChipClaim[] memory) {
        return new ClaimRouter.ChipClaim[](0);
    }

    /// @dev Alice: one Noun, split 50/50 NVDA + AAPL, one finalized round, plus pending
    ///      Clutch $CHIP on the vault side.
    function _setupBothSides() internal returns (uint256 id) {
        _fundPot(2_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _two(address(nvda), address(aapl)), _two(uint8(50), uint8(50)));

        id = _openAndAccumulate(_ids(1));
        rewards.settleStock(id, address(nvda));
        rewards.settleStock(id, address(aapl));
        rewards.finalizeRound(id);

        chip.mint(address(basedVault), 500 ether);
        basedVault.setPendingReward(1, address(chip), 500 ether);
    }

    /* ------------------------------------------------------------------ */
    /*                            HAPPY PATH                                */
    /* ------------------------------------------------------------------ */

    function test_oneCallClaimsBothSides() public {
        uint256 id = _setupBothSides();

        vm.prank(alice);
        (uint256 chipOk, uint256 clutchOk) = router_.claimEverything(
            _chipClaims2(id, address(nvda), address(aapl)), _clutchClaims(address(basedNouns), 1), _one(address(chip))
        );

        assertEq(chipOk, 2, "both stocks claimed");
        assertEq(clutchOk, 1, "Clutch claimed");
        assertEq(nvda.balanceOf(alice), 5e8);
        assertEq(aapl.balanceOf(alice), 4e8);
        assertEq(chip.balanceOf(alice), 500 ether, "CHIP arrived");
    }

    /// @notice The router must never become the claimant or keep anything.
    function test_routerHoldsNothingAfterwards() public {
        uint256 id = _setupBothSides();

        vm.prank(alice);
        router_.claimEverything(
            _chipClaims2(id, address(nvda), address(aapl)), _clutchClaims(address(basedNouns), 1), _one(address(chip))
        );

        assertEq(nvda.balanceOf(address(router_)), 0);
        assertEq(aapl.balanceOf(address(router_)), 0);
        assertEq(chip.balanceOf(address(router_)), 0);
    }

    function test_chipOnlyClaimNeedsNoClutchLeg() public {
        uint256 id = _setupBothSides();
        vm.prank(alice);
        (uint256 chipOk, uint256 clutchOk) =
            router_.claimEverything(_chipClaims(id, address(nvda)), _noClutch(), new address[](0));
        assertEq(chipOk, 1);
        assertEq(clutchOk, 0);
        assertEq(nvda.balanceOf(alice), 5e8);
    }

    function test_clutchOnlyClaimNeedsNoChipLeg() public {
        _setupBothSides();
        vm.prank(alice);
        (uint256 chipOk, uint256 clutchOk) =
            router_.claimEverything(_noChip(), _clutchClaims(address(basedNouns), 1), _one(address(chip)));
        assertEq(chipOk, 0);
        assertEq(clutchOk, 1);
        assertEq(chip.balanceOf(alice), 500 ether);
    }

    function test_revertsWhenNothingRequested() public {
        vm.prank(alice);
        vm.expectRevert(ClaimRouter.NothingRequested.selector);
        router_.claimEverything(_noChip(), _noClutch(), new address[](0));
    }

    /* ------------------------------------------------------------------ */
    /*                        LEG INDEPENDENCE                              */
    /* ------------------------------------------------------------------ */

    /// @notice A dead Clutch vault must not stop the Chipworks side paying out.
    function test_clutchFailureDoesNotBlockChipworks() public {
        uint256 id = _setupBothSides();

        // Vault becomes a gas bomb: any call to it burns everything it is given.
        GasBombNoun bomb = new GasBombNoun();
        vm.prank(multisig);
        adapter.setVault(address(basedNouns), address(bomb));

        vm.prank(alice);
        (uint256 chipOk, uint256 clutchOk) = router_.claimEverything(
            _chipClaims2(id, address(nvda), address(aapl)), _clutchClaims(address(basedNouns), 1), _one(address(chip))
        );

        assertEq(clutchOk, 0, "Clutch leg failed");
        assertEq(chipOk, 2, "Chipworks unaffected");
        assertEq(nvda.balanceOf(alice), 5e8);
        assertEq(aapl.balanceOf(alice), 4e8);
    }

    /// @notice And the reverse: a frozen stock must not stop the Clutch side.
    function test_chipworksFailureDoesNotBlockClutch() public {
        uint256 id = _setupBothSides();
        aapl.setBlacklisted(alice, true); // her AAPL claim will revert

        vm.prank(alice);
        (uint256 chipOk, uint256 clutchOk) = router_.claimEverything(
            _chipClaims2(id, address(aapl), address(nvda)), _clutchClaims(address(basedNouns), 1), _one(address(chip))
        );

        assertEq(chipOk, 1, "AAPL failed, NVDA succeeded");
        assertEq(clutchOk, 1, "Clutch unaffected");
        assertEq(nvda.balanceOf(alice), 5e8);
        assertEq(aapl.balanceOf(alice), 0);
        assertEq(chip.balanceOf(alice), 500 ether);

        // And the frozen credit survives for later.
        aapl.setBlacklisted(alice, false);
        vm.prank(alice);
        assertEq(rewards.claim(id, address(aapl)), 4e8, "nothing lost");
    }

    /// @notice A hostile leg must not starve the legs after it of gas. This is the concrete
    ///         form of "routing must never be worse than direct".
    function test_oneGasBurningLegDoesNotStarveTheRest() public {
        uint256 id = _setupBothSides();

        GasBombNoun bomb = new GasBombNoun();
        vm.prank(multisig);
        adapter.setVault(address(darkNouns), address(bomb));

        ClaimRouter.ClutchClaim[] memory clutch = new ClaimRouter.ClutchClaim[](3);
        clutch[0] = ClaimRouter.ClutchClaim({collection: address(darkNouns), tokenId: 1});
        clutch[1] = ClaimRouter.ClutchClaim({collection: address(darkNouns), tokenId: 2});
        clutch[2] = ClaimRouter.ClutchClaim({collection: address(basedNouns), tokenId: 1});

        vm.prank(alice);
        (uint256 chipOk, uint256 clutchOk) =
            router_.claimEverything(_chipClaims2(id, address(nvda), address(aapl)), clutch, _one(address(chip)));

        assertEq(chipOk, 2, "chip legs still ran");
        assertEq(clutchOk, 1, "the healthy Clutch leg still ran after two gas bombs");
        assertEq(chip.balanceOf(alice), 500 ether);
    }

    function test_revertsOnlyWhenEveryLegFails() public {
        uint256 id = _setupBothSides();
        vm.prank(alice);
        rewards.claim(id, address(nvda)); // already taken

        vm.prank(alice);
        vm.expectRevert(ClaimRouter.EverythingFailed.selector);
        router_.claimEverything(_chipClaims(id, address(nvda)), _noClutch(), new address[](0));
    }

    function test_unknownCollectionIsAFailedLegNotARevert() public {
        uint256 id = _setupBothSides();
        vm.prank(alice);
        (uint256 chipOk, uint256 clutchOk) = router_.claimEverything(
            _chipClaims(id, address(nvda)), _clutchClaims(makeAddr("unknownCollection"), 1), new address[](0)
        );
        assertEq(chipOk, 1);
        assertEq(clutchOk, 0);
    }

    /* ------------------------------------------------------------------ */
    /*                  NEVER WORSE THAN CLAIMING DIRECTLY                  */
    /* ------------------------------------------------------------------ */

    /// @notice Same starting state, two paths, identical outcome.
    function test_routedOutcomeEqualsDirectOutcome() public {
        uint256 id = _setupBothSides();
        uint256 snap = vm.snapshotState();

        // Path A: claim each side directly.
        vm.startPrank(alice);
        rewards.claim(id, address(nvda));
        rewards.claim(id, address(aapl));
        vm.stopPrank();
        basedVault.claim(1);

        uint256 directNvda = nvda.balanceOf(alice);
        uint256 directAapl = aapl.balanceOf(alice);
        uint256 directChip = chip.balanceOf(alice);

        // Path B: one routed call.
        vm.revertToState(snap);
        vm.prank(alice);
        router_.claimEverything(
            _chipClaims2(id, address(nvda), address(aapl)), _clutchClaims(address(basedNouns), 1), _one(address(chip))
        );

        assertEq(nvda.balanceOf(alice), directNvda, "NVDA identical");
        assertEq(aapl.balanceOf(alice), directAapl, "AAPL identical");
        assertEq(chip.balanceOf(alice), directChip, "CHIP identical");
    }

    /// @notice Even when one side is broken, routing must recover exactly what direct
    ///         claiming would have recovered — no more, no less.
    function test_routedOutcomeEqualsDirectOutcomeWhenALegIsBroken() public {
        uint256 id = _setupBothSides();
        aapl.setBlacklisted(alice, true);
        uint256 snap = vm.snapshotState();

        // Direct: NVDA works, AAPL reverts, Clutch works.
        vm.prank(alice);
        rewards.claim(id, address(nvda));
        vm.prank(alice);
        try rewards.claim(id, address(aapl)) {} catch {}
        basedVault.claim(1);

        uint256 directNvda = nvda.balanceOf(alice);
        uint256 directAapl = aapl.balanceOf(alice);
        uint256 directChip = chip.balanceOf(alice);

        vm.revertToState(snap);
        vm.prank(alice);
        router_.claimEverything(
            _chipClaims2(id, address(nvda), address(aapl)), _clutchClaims(address(basedNouns), 1), _one(address(chip))
        );

        assertEq(nvda.balanceOf(alice), directNvda);
        assertEq(aapl.balanceOf(alice), directAapl);
        assertEq(chip.balanceOf(alice), directChip);
    }

    /// @notice Routing must not consume a credit it failed to deliver.
    function test_failedLegLeavesTheCreditClaimable() public {
        uint256 id = _setupBothSides();
        aapl.setBlacklisted(alice, true);

        uint256 owedBefore = rewards.claimable(id, address(aapl), alice);
        vm.prank(alice);
        router_.claimEverything(_chipClaims2(id, address(nvda), address(aapl)), _noClutch(), new address[](0));

        assertEq(rewards.claimable(id, address(aapl), alice), owedBefore, "credit intact");
        assertFalse(rewards.hasClaimed(id, address(aapl), alice), "not marked claimed");
    }

    /* ------------------------------------------------------------------ */
    /*             A-9: WHICHEVER WAY CLUTCH PAYS, IT WORKS                 */
    /* ------------------------------------------------------------------ */

    /// @notice The Clutch docs do not say whether `claim` pays the owner of record or the
    ///         caller. If it pays the CALLER, the tokens land on the router — and the sweep
    ///         must deliver them. Modelled by pre-funding the router.
    function test_sweepDeliversTokensThatLandOnTheRouter() public {
        uint256 id = _setupBothSides();
        chip.mint(address(router_), 123 ether); // as if Clutch had paid the caller

        vm.prank(alice);
        router_.claimEverything(_chipClaims(id, address(nvda)), _noClutch(), _one(address(chip)));

        assertEq(chip.balanceOf(alice), 123 ether, "swept to the owner");
        assertEq(chip.balanceOf(address(router_)), 0);
    }

    /// @notice A frozen sweep token must not undo claims that already succeeded.
    function test_frozenSweepTokenDoesNotUndoSuccessfulClaims() public {
        uint256 id = _setupBothSides();
        aapl.mint(address(router_), 10e8);
        aapl.setBlacklisted(address(router_), true);

        vm.prank(alice);
        (uint256 chipOk,) = router_.claimEverything(_chipClaims(id, address(nvda)), _noClutch(), _one(address(aapl)));

        assertEq(chipOk, 1, "claim still succeeded");
        assertEq(nvda.balanceOf(alice), 5e8, "and paid out");
        assertEq(aapl.balanceOf(address(router_)), 10e8, "stuck token stays, recoverable");
    }

    /// @notice Anyone can push stranded tokens out, but only to the address they name.
    function test_sweepToRescuesStrandedTokens() public {
        chip.mint(address(router_), 77 ether);
        vm.prank(makeAddr("goodSamaritan"));
        router_.sweepTo(alice, _one(address(chip)));
        assertEq(chip.balanceOf(alice), 77 ether);
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
        router_.setRewards(address(rewards));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        router_.setVaultRegistry(address(adapter));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        router_.setLegGasLimit(500_000);
        vm.stopPrank();
    }

    /// @notice If the Clutch ABI turns out to differ, the router follows the new adapter.
    function test_vaultRegistryCanBeRepointed() public {
        vm.prank(multisig);
        router_.setVaultRegistry(address(0));

        uint256 id = _setupBothSides();
        vm.prank(alice);
        (, uint256 clutchOk) = router_.claimEverything(
            _chipClaims(id, address(nvda)), _clutchClaims(address(basedNouns), 1), new address[](0)
        );
        assertEq(clutchOk, 0, "no registry means a failed leg, not a revert");
    }

    function test_legGasLimitHasAFloor() public {
        vm.prank(multisig);
        vm.expectRevert(ClaimRouter.BadGasLimit.selector);
        router_.setLegGasLimit(99_999);
    }

    /* ------------------------------------------------------------------ */
    /*                    THE CLAIM WINDOW GATE                             */
    /* ------------------------------------------------------------------ */

    /// @notice Routing must not bypass the window gate.
    function test_chipLegsFailWhileClaimsAreShut() public {
        uint256 id = _setupBothSides();
        vm.warp(rewards.windowAnchor() + 3 days); // between windows
        assertFalse(rewards.isClaimOpen());

        vm.prank(alice);
        (uint256 chipOk, uint256 clutchOk) = router_.claimEverything(
            _chipClaims2(id, address(nvda), address(aapl)), _clutchClaims(address(basedNouns), 1), _one(address(chip))
        );

        assertEq(chipOk, 0, "Chipworks legs gated");
        assertEq(clutchOk, 1, "Clutch runs on its own schedule, unaffected");
        assertEq(nvda.balanceOf(alice), 0);
        assertEq(chip.balanceOf(alice), 500 ether);

        // The credits are untouched and claimable when the window returns.
        assertGt(rewards.claimable(id, address(nvda), alice), 0);
    }

    /// @notice And a chip-only routed claim while shut reverts, rather than silently
    ///         charging gas for nothing.
    function test_chipOnlyRoutedClaimRevertsWhileShut() public {
        uint256 id = _setupBothSides();
        vm.warp(rewards.windowAnchor() + 3 days);

        vm.prank(alice);
        vm.expectRevert(ClaimRouter.EverythingFailed.selector);
        router_.claimEverything(_chipClaims(id, address(nvda)), _noClutch(), new address[](0));
    }

    function test_routedClaimWorksWhenTheWindowReopens() public {
        uint256 id = _setupBothSides();
        vm.warp(rewards.windowAnchor() + 3 days);

        (bool open, uint64 nextOpenAt) = router_.claimWindowStatus();
        assertFalse(open);

        vm.warp(nextOpenAt);
        vm.prank(alice);
        (uint256 chipOk,) =
            router_.claimEverything(_chipClaims2(id, address(nvda), address(aapl)), _noClutch(), new address[](0));
        assertEq(chipOk, 2, "both legs settle once open");
        assertEq(nvda.balanceOf(alice), 5e8);
    }

    /// @notice Routing is still never worse than direct, gate included.
    function test_routedEqualsDirectWhileShut() public {
        uint256 id = _setupBothSides();
        vm.warp(rewards.windowAnchor() + 3 days);
        uint256 snap = vm.snapshotState();

        vm.prank(alice);
        try rewards.claim(id, address(nvda)) {} catch {}
        uint256 directNvda = nvda.balanceOf(alice);

        vm.revertToState(snap);
        vm.prank(alice);
        try router_.claimEverything(_chipClaims(id, address(nvda)), _noClutch(), new address[](0)) {} catch {}

        assertEq(nvda.balanceOf(alice), directNvda, "identical outcome");
    }

    function test_claimWindowStatusReportsOpenState() public {
        (bool open,) = router_.claimWindowStatus();
        assertTrue(open, "open right after deploy");

        vm.warp(rewards.windowAnchor() + 3 days);
        (bool shut, uint64 next) = router_.claimWindowStatus();
        assertFalse(shut);
        assertEq(next, rewards.windowAnchor() + 7 days);
    }
}
