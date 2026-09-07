// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChipRewardsBase} from "../ChipRewardsBase.t.sol";
import {ChipActivation} from "../../src/activation/ChipActivation.sol";
import {MockCustodian} from "../mocks/MockCustodian.sol";

/// @title ChipActivationParityTest
/// @notice THE MIGRATION PROOF: the same round machinery, on our own vault instead of Clutch.
///
/// @dev This contract inherits the standard fixture and changes **only wiring** in `setUp`:
///      deploy `ChipActivation`, price the three collections, and call
///      `rounds.setActivationSource`. Not one line of `ChipRounds`, `ChipClaims`, `Pot`,
///      `StockRegistry` or `POLTreasury` changed to adopt it, and none of them knows which
///      implementation is behind {IActivationSource}.
///
///      The assertions below are deliberately the same claims the Clutch-backed suite makes
///      — tier times collection base, three collections not colliding, a sold
///      Noun earning nothing, a full round crediting pro rata, a credit following the
///      address and not the Noun — so a divergence shows up as a failure here rather than as
///      a difference nobody notices.
///
///      Then it adds the two things Clutch could not do at all: activating a Noun that is
///      sitting in a custodian, and a full round paying a borrower whose Noun is collateral.
contract ChipActivationParityTest is ChipRewardsBase {
    ChipActivation internal activation;

    uint32[5] internal TIER_TABLE = [uint32(10_000), 12_500, 16_000, 20_000, 33_300];
    uint256[5] internal COST_TABLE = [uint256(100 ether), 250 ether, 600 ether, 1_200 ether, 4_000 ether];

    function setUp() public virtual override {
        super.setUp();

        // ---- the ONLY change: a different activation source behind the same interface ----
        activation = new ChipActivation(multisig, address(chip), 0x000000000000000000000000000000000000dEaD, TIER_TABLE);
        _price(address(basedNouns));
        _price(address(darkNouns));
        _price(address(lilNouns));

        vm.prank(multisig);
        rounds.setActivationSource(address(activation));

        // Everyone who chips needs $CHIP and an allowance. Clutch charged for activation too.
        address[3] memory who = [alice, bob, carol];
        for (uint256 i; i < who.length; ++i) {
            chip.mint(who[i], 1_000_000 ether);
            vm.prank(who[i]);
            chip.approve(address(activation), type(uint256).max);
        }
    }

    function _price(address collection) internal {
        vm.prank(multisig);
        activation.queueCosts(collection, COST_TABLE);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        activation.executeCosts(collection);
    }

    /// @dev Pricing three collections costs three 48h warps, so this fixture starts outside
    ///      the weekly claim window where the Clutch-backed suite starts inside it. The
    ///      inherited `_openClaimWindow` handles it before every claim: that is the gate
    ///      working as designed, not a difference between the two activation sources.

    /// @dev The native equivalent of the fixture's `_chip` helper. Mint, then activate — no
    ///      vault to register, no `kick` to schedule.
    function _chipNative(address collection, uint256 tokenId, address owner, uint8 tier) internal {
        MockNounLike(collection).mint(owner, tokenId);
        vm.prank(owner);
        activation.activate(collection, tokenId, tier);
    }

    /* ------------------------------------------------------------------ */
    /*             THE SAME CLAIMS THE CLUTCH-BACKED SUITE MAKES           */
    /* ------------------------------------------------------------------ */

    function test_parity_weightIsTierTimesCollectionBase() public {
        _chipNative(address(basedNouns), 1, alice, 0); // 1.00 x 1.0
        _chipNative(address(darkNouns), 1, bob, 0); // 1.00 x 2.0

        _fundPot(1_000e6);
        uint256 id = rounds.openRound();
        rounds.contributeWeights(id, address(basedNouns), _ids(1));
        rounds.contributeWeights(id, address(darkNouns), _ids(1));
        vm.warp(block.timestamp + 2 hours);
        rounds.closeAccumulation(id);

        assertEq(rounds.getRound(id).totalWeight, 10_000 + 20_000, "1.0x + 2.0x");
    }

    function test_parity_higherTierEarnsMore() public {
        _chipNative(address(basedNouns), 1, alice, 0); // 1.00x
        _chipNative(address(basedNouns), 2, bob, 4); // 3.33x

        _fundPot(1_000e6);
        uint256 id = _openAndAccumulate(_ids(1, 2));
        assertEq(rounds.getRound(id).totalWeight, 10_000 + 33_300);
    }

    function test_parity_lilNounsHalfWeight() public {
        _chipNative(address(lilNouns), 1, alice, 0);
        _chipNative(address(basedNouns), 1, bob, 0);

        _fundPot(1_000e6);
        uint256 id = rounds.openRound();
        rounds.contributeWeights(id, address(lilNouns), _ids(1));
        rounds.contributeWeights(id, address(basedNouns), _ids(1));
        vm.warp(block.timestamp + 2 hours);
        rounds.closeAccumulation(id);

        assertEq(rounds.getRound(id).totalWeight, 5_000 + 10_000, "0.5x + 1.0x");
    }

    /// @notice Weight carries no owner-dependent term on the new vault either.
    function test_parity_weightHasNoOwnerDependentTerm() public {
        _chipNative(address(basedNouns), 1, alice, 0);
        _chipNative(address(basedNouns), 2, bob, 0);

        _fundPot(1_000e6);
        uint256 id = _openAndAccumulate(_ids(1, 2));
        assertEq(rounds.getRound(id).totalWeight, 20_000, "two 1.0x Nouns, no boost");
    }

    /// @notice The property Clutch demonstrably fails in production. Here it is structural.
    function test_parity_aSoldNounEarnsNothingWithNoKick() public {
        _chipNative(address(basedNouns), 1, alice, 4);
        vm.prank(alice);
        basedNouns.transferFrom(alice, bob, 1);

        _fundPot(1_000e6);
        uint256 id = rounds.openRound();
        rounds.contributeWeights(id, address(basedNouns), _ids(1));
        assertEq(rounds.getRound(id).totalWeight, 0, "no kick was called, and none is needed");
    }

    function test_parity_anUnactivatedNounIsIgnored() public {
        basedNouns.mint(alice, 1); // never activated
        _fundPot(1_000e6);
        uint256 id = rounds.openRound();
        rounds.contributeWeights(id, address(basedNouns), _ids(1));
        assertEq(rounds.getRound(id).totalWeight, 0);
    }

    function test_parity_collectionsDoNotCollide() public {
        _chipNative(address(basedNouns), 5, alice, 0);
        _chipNative(address(darkNouns), 5, bob, 0);
        _chipNative(address(lilNouns), 5, carol, 0);

        _fundPot(1_000e6);
        uint256 id = rounds.openRound();
        rounds.contributeWeights(id, address(basedNouns), _ids(5));
        rounds.contributeWeights(id, address(darkNouns), _ids(5));
        rounds.contributeWeights(id, address(lilNouns), _ids(5));
        vm.warp(block.timestamp + 2 hours);
        rounds.closeAccumulation(id);

        assertEq(rounds.getRound(id).totalWeight, 10_000 + 20_000 + 5_000, "three Nouns, not one");
    }

    function test_parity_paddedListCannotInflateAShare() public {
        _chipNative(address(basedNouns), 1, alice, 0);
        _fundPot(1_000e6);
        uint256 id = rounds.openRound();

        uint256[] memory padded = new uint256[](4);
        padded[0] = 1;
        padded[1] = 1;
        padded[2] = 1;
        padded[3] = 999; // does not exist
        rounds.contributeWeights(id, address(basedNouns), padded);

        assertEq(rounds.getRound(id).totalWeight, 10_000, "counted once");
    }

    function test_parity_fullRoundBuysAndCreditsProRata() public {
        _fundPot(1_000e6);
        _chipNative(address(basedNouns), 1, alice, 0);
        _chipNative(address(basedNouns), 2, bob, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        _setSplit(address(basedNouns), 2, bob, _one(address(nvda)), _one(uint8(100)));

        uint256 id = _openAndAccumulate(_ids(1, 2));
        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);

        assertEq(claims.acquired(id, address(nvda)), 5e8, "$1,000 of NVDA at $200");
        assertEq(claims.claimable(id, address(nvda), alice), 2.5e8);
        assertEq(claims.claimable(id, address(nvda), bob), 2.5e8);

        _openClaimWindow();
        vm.prank(alice);
        claims.claim(id, address(nvda));
        assertEq(nvda.balanceOf(alice), 2.5e8);
    }

    function test_parity_creditFollowsTheAddressNotTheNoun() public {
        _fundPot(1_000e6);
        _chipNative(address(basedNouns), 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));

        uint256 id = _openAndAccumulate(_ids(1));
        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);

        // Alice sells the Noun AFTER the round. The credit is hers.
        vm.prank(alice);
        basedNouns.transferFrom(alice, bob, 1);

        assertEq(claims.claimable(id, address(nvda), bob), 0);
        _openClaimWindow();
        vm.prank(alice);
        claims.claim(id, address(nvda));
        assertEq(nvda.balanceOf(alice), 5e8);
    }

    /* ------------------------------------------------------------------ */
    /*                   WHAT CLUTCH COULD NOT DO AT ALL                    */
    /* ------------------------------------------------------------------ */

    /// @notice A full round paying a borrower whose Noun is sitting in a custodian.
    function test_collateralisedNounEarnsAFullRoundForTheBorrower() public {
        MockCustodian vault = new MockCustodian();
        vm.prank(multisig);
        activation.setCustodian(address(vault), true);

        _chipNative(address(basedNouns), 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));

        // Alice deposits her chipped Noun as collateral.
        vm.startPrank(alice);
        basedNouns.approve(address(vault), 1);
        vault.deposit(address(basedNouns), 1);
        vm.stopPrank();
        assertEq(basedNouns.ownerOf(1), address(vault), "the Noun really is in the vault");

        _fundPot(1_000e6);
        uint256 id = _openAndAccumulate(_ids(1));
        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);

        assertEq(claims.claimable(id, address(nvda), alice), 5e8, "the borrower, not the vault");
        assertEq(claims.claimable(id, address(nvda), address(vault)), 0);

        _openClaimWindow();
        vm.prank(alice);
        claims.claim(id, address(nvda));
        assertEq(nvda.balanceOf(alice), 5e8);
    }

    /// @notice Liquidation mid-round: the weight was booked while the loan was healthy, and
    ///         the credit stays with the address that earned it. The NEXT round scores zero.
    function test_liquidationMidRoundKeepsTheEarnedCreditAndStopsTheNextOne() public {
        MockCustodian vault = new MockCustodian();
        vm.prank(multisig);
        activation.setCustodian(address(vault), true);

        _chipNative(address(basedNouns), 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        vm.startPrank(alice);
        basedNouns.approve(address(vault), 1);
        vault.deposit(address(basedNouns), 1);
        vm.stopPrank();

        _fundPot(1_000e6);
        uint256 id = _openAndAccumulate(_ids(1));

        // Liquidated after the weight was booked.
        vault.setBeneficiary(address(basedNouns), 1, carol);

        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);
        assertEq(claims.claimable(id, address(nvda), alice), 5e8, "already earned, still hers");

        // The next round sees nothing for alice.
        _fundPot(1_000e6);
        vm.warp(block.timestamp + 24 hours);
        uint256 id2 = rounds.openRound();
        rounds.contributeWeights(id2, address(basedNouns), _ids(1));
        assertEq(rounds.getRound(id2).totalWeight, 0, "the activation ended with the loan");
    }

    /// @notice Chipping a Noun that is ALREADY collateral, then earning on it.
    function test_chipWhileCollateralisedThenEarn() public {
        MockCustodian vault = new MockCustodian();
        vm.prank(multisig);
        activation.setCustodian(address(vault), true);

        basedNouns.mint(alice, 1);
        vm.startPrank(alice);
        basedNouns.approve(address(vault), 1);
        vault.deposit(address(basedNouns), 1);
        activation.activate(address(basedNouns), 1, 2); // 1.60x, from inside the vault
        rounds.setSplit(address(basedNouns), 1, _one(address(nvda)), _one(uint8(100)));
        vm.stopPrank();

        _fundPot(1_000e6);
        uint256 id = _openAndAccumulate(_ids(1));
        assertEq(rounds.getRound(id).totalWeight, 16_000, "tier 2 on a collateralised Noun");

        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);
        assertEq(claims.claimable(id, address(nvda), alice), 5e8);
    }

    /// @notice Deregistering a custodian mid-flight stops the weight, without touching any
    ///         credit already booked. The emergency stop is safe to pull.
    function test_deregisteringACustodianStopsFutureWeightOnly() public {
        MockCustodian vault = new MockCustodian();
        vm.prank(multisig);
        activation.setCustodian(address(vault), true);

        _chipNative(address(basedNouns), 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        vm.startPrank(alice);
        basedNouns.approve(address(vault), 1);
        vault.deposit(address(basedNouns), 1);
        vm.stopPrank();

        _fundPot(1_000e6);
        uint256 id = _openAndAccumulate(_ids(1));
        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);
        assertEq(claims.claimable(id, address(nvda), alice), 5e8);

        vm.prank(multisig);
        activation.setCustodian(address(vault), false);

        _fundPot(1_000e6);
        vm.warp(block.timestamp + 24 hours);
        uint256 id2 = rounds.openRound();
        rounds.contributeWeights(id2, address(basedNouns), _ids(1));
        assertEq(rounds.getRound(id2).totalWeight, 0);

        // The already-booked credit is untouched.
        _openClaimWindow();
        vm.prank(alice);
        claims.claim(id, address(nvda));
        assertEq(nvda.balanceOf(alice), 5e8);
    }
}

interface MockNounLike {
    function mint(address to, uint256 tokenId) external;
}
