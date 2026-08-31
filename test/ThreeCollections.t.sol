// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChipRewardsBase} from "./ChipRewardsBase.t.sol";
import {ChipRounds} from "../src/ChipRounds.sol";
import {MockNoun} from "./mocks/MockNoun.sol";
import {MockSoftStakingVault} from "./mocks/MockSoftStakingVault.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice Lil Based Nouns joins Based and Dark as a third collection.
///
/// @dev The point of this suite is to prove the claim that adding a collection is
///      DEPLOY CONFIGURATION, not a code change. Everything collection-shaped in
///      `ChipRounds` and `ClutchVaultAdapter` is keyed by address in a mapping — there are
///      no fixed-size arrays, no enumeration, and nothing that counts collections — so a
///      third, fourth or tenth is two multisig calls: `setCollectionBaseBps` on the engine
///      and `setVault` on the adapter.
///
///      Lil is also the first collection with a base BELOW 1.0 (0.5x), so these tests check
///      the fractional weight arithmetic rather than assuming it falls out.
contract ThreeCollectionsTest is ChipRewardsBase {
    /* ------------------------------------------------------------------ */
    /*                       WEIGHTS ACROSS THREE                           */
    /* ------------------------------------------------------------------ */

    /// @notice One tier-0 Noun from each collection, in one round. The three bases must
    ///         produce exactly 0.5x / 1.0x / 2.0x of each other.
    function test_threeCollectionsWeighAtTheirConfiguredBases() public {
        _fundPot(4_000e6);
        _chip(lilNouns, lilVault, 1, alice, 0); // 0.5x
        _chip(basedNouns, basedVault, 1, bob, 0); // 1.0x
        _chip(darkNouns, darkVault, 1, carol, 0); // 2.0x

        uint256 id = rounds.openRound();
        rounds.contributeWeights(id, address(lilNouns), _ids(1));
        rounds.contributeWeights(id, address(basedNouns), _ids(1));
        rounds.contributeWeights(id, address(darkNouns), _ids(1));

        uint256 lil = claims.weightOf(id, address(usdc), alice);
        uint256 based = claims.weightOf(id, address(usdc), bob);
        uint256 dark = claims.weightOf(id, address(usdc), carol);

        assertEq(lil, 5_000, "Lil is half a Based Noun");
        assertEq(based, 10_000);
        assertEq(dark, 20_000, "Dark is two Based Nouns");

        assertEq(based, lil * 2, "Based is exactly twice Lil");
        assertEq(dark, lil * 4, "Dark is exactly four times Lil");
        assertEq(rounds.getRound(id).totalWeight, 35_000);
    }

    /// @notice And the money follows the weights, end to end.
    function test_payoutsSplitOneTwoFourAcrossTheThree() public {
        _fundPot(3_500e6); // 35,000 weight total, so 100 USDC per 1,000 weight
        _chip(lilNouns, lilVault, 1, alice, 0);
        _chip(basedNouns, basedVault, 1, bob, 0);
        _chip(darkNouns, darkVault, 1, carol, 0);

        uint256 id = rounds.openRound();
        rounds.contributeWeights(id, address(lilNouns), _ids(1));
        rounds.contributeWeights(id, address(basedNouns), _ids(1));
        rounds.contributeWeights(id, address(darkNouns), _ids(1));
        vm.warp(block.timestamp + 2 hours);
        rounds.closeAccumulation(id);
        rounds.settleStock(id, address(usdc));
        rounds.finalizeRound(id);

        uint256 lilOwed = claims.claimable(id, address(usdc), alice);
        uint256 basedOwed = claims.claimable(id, address(usdc), bob);
        uint256 darkOwed = claims.claimable(id, address(usdc), carol);

        assertEq(lilOwed, 500e6, "1/7 of 3,500");
        assertEq(basedOwed, 1_000e6, "2/7");
        assertEq(darkOwed, 2_000e6, "4/7");
        assertEq(lilOwed + basedOwed + darkOwed, 3_500e6, "every cent allocated");

        _openClaimWindow();
        vm.prank(alice);
        assertEq(claims.claim(id, address(usdc)), 500e6);
    }

    /// @notice A Lil Noun's split works exactly like any other collection's.
    function test_lilNounsCanPickTheirOwnStockSplit() public {
        _fundPot(1_000e6);
        _chip(lilNouns, lilVault, 1, alice, 0);
        _setSplit(address(lilNouns), 1, alice, _two(address(nvda), address(googl)), _two(uint8(60), uint8(40)));

        uint256 id = _openAndAccumulateFor(address(lilNouns), _ids(1));
        rounds.settleStock(id, address(nvda));
        rounds.settleStock(id, address(googl));
        rounds.finalizeRound(id);

        // weight 5,000 split 60/40 => 3,000 NVDA, 2,000 GOOGL
        assertEq(claims.weightOf(id, address(nvda), alice), 3_000);
        assertEq(claims.weightOf(id, address(googl), alice), 2_000);
        assertGt(claims.acquired(id, address(nvda)), 0);
    }

    /// @notice The hoodie boost composes with a fractional base rather than colliding.
    function test_hoodieBoostAppliesOnTopOfTheHalfBase() public {
        _fundPot(1_000e6);
        _chip(lilNouns, lilVault, 1, alice, 0);
        _chip(lilNouns, lilVault, 2, bob, 0);
        hoodies.mint(bob, 1);

        uint256 id = rounds.openRound();
        rounds.contributeWeights(id, address(lilNouns), _ids(1, 2));

        assertEq(claims.weightOf(id, address(usdc), alice), 5_000);
        assertEq(claims.weightOf(id, address(usdc), bob), 5_500, "0.5x base then 1.10x boost");
    }

    /// @notice Tiers scale a fractional base without rounding to zero.
    function test_everyTierIsRepresentableAtHalfBase() public {
        _fundPot(1_000e6);
        _chip(lilNouns, lilVault, 1, alice, 0); // 1.00x -> 5,000
        _chip(lilNouns, lilVault, 2, bob, 1); // 1.25x -> 6,250
        _chip(lilNouns, lilVault, 3, carol, 4); // 3.33x -> 16,650

        uint256 id = rounds.openRound();
        rounds.contributeWeights(id, address(lilNouns), _ids(1, 2, 3));

        assertEq(claims.weightOf(id, address(usdc), alice), 5_000);
        assertEq(claims.weightOf(id, address(usdc), bob), 6_250);
        assertEq(claims.weightOf(id, address(usdc), carol), 16_650);
    }

    /* ------------------------------------------------------------------ */
    /*                    ADDING ONE IS PURE CONFIGURATION                  */
    /* ------------------------------------------------------------------ */

    /// @notice THE CLAIM: a fourth collection needs two multisig calls and no new code.
    ///         If this ever stops being true, something has grown a hard-coded list.
    function test_aFourthCollectionNeedsNoCodeChange() public {
        MockNoun fourth = new MockNoun("Some Future Nouns", "FUTURE");
        MockSoftStakingVault fourthVault = new MockSoftStakingVault(IERC721(address(fourth)));

        // Exactly two calls. Nothing is deployed, nothing is upgraded.
        vm.startPrank(multisig);
        adapter.setVault(address(fourth), address(fourthVault));
        rounds.setCollectionBaseBps(address(fourth), 15_000); // 1.5x
        vm.stopPrank();

        _fundPot(1_000e6);
        fourth.mint(alice, 7);
        vm.prank(alice);
        fourthVault.activate(7, 0);

        uint256 id = rounds.openRound();
        rounds.contributeWeights(id, address(fourth), _ids(7));
        assertEq(claims.weightOf(id, address(usdc), alice), 15_000, "earns immediately");
    }

    /// @notice An unconfigured collection earns nothing rather than defaulting to 1.0x.
    ///         Forgetting `setCollectionBaseBps` must fail closed, not pay out silently.
    function test_aCollectionWithNoBaseEarnsNothing() public {
        MockNoun stray = new MockNoun("Unconfigured", "NOPE");
        MockSoftStakingVault strayVault = new MockSoftStakingVault(IERC721(address(stray)));
        vm.prank(multisig);
        adapter.setVault(address(stray), address(strayVault));
        // deliberately NO setCollectionBaseBps

        _fundPot(1_000e6);
        stray.mint(alice, 1);
        vm.prank(alice);
        strayVault.activate(1, 0);

        uint256 id = rounds.openRound();
        rounds.contributeWeights(id, address(stray), _ids(1));
        assertEq(rounds.getRound(id).totalWeight, 0, "no base means no weight");
    }

    /// @notice Collections share nothing: the same token id in each is a separate Noun.
    function test_sameTokenIdInThreeCollectionsDoesNotCollide() public {
        _fundPot(3_000e6);
        _chip(lilNouns, lilVault, 5, alice, 0);
        _chip(basedNouns, basedVault, 5, bob, 0);
        _chip(darkNouns, darkVault, 5, carol, 0);

        uint256 id = rounds.openRound();
        rounds.contributeWeights(id, address(lilNouns), _ids(5));
        rounds.contributeWeights(id, address(basedNouns), _ids(5));
        rounds.contributeWeights(id, address(darkNouns), _ids(5));

        // Three different owners, three different weights, one token id.
        assertEq(claims.weightOf(id, address(usdc), alice), 5_000);
        assertEq(claims.weightOf(id, address(usdc), bob), 10_000);
        assertEq(claims.weightOf(id, address(usdc), carol), 20_000);
    }

    /// @notice Splits are per (collection, tokenId) too.
    function test_splitsDoNotCollideAcrossCollections() public {
        _chip(lilNouns, lilVault, 9, alice, 0);
        _chip(basedNouns, basedVault, 9, bob, 0);

        _setSplit(address(lilNouns), 9, alice, _one(address(nvda)), _one(uint8(100)));
        _setSplit(address(basedNouns), 9, bob, _one(address(googl)), _one(uint8(100)));

        assertEq(rounds.splitOf(address(lilNouns), 9).stocks[0], address(nvda));
        assertEq(rounds.splitOf(address(basedNouns), 9).stocks[0], address(googl));
    }

    /// @notice Disabling one collection leaves the others untouched.
    function test_zeroingOneCollectionDoesNotAffectTheOthers() public {
        _fundPot(3_000e6);
        _chip(lilNouns, lilVault, 1, alice, 0);
        _chip(basedNouns, basedVault, 1, bob, 0);

        vm.prank(multisig);
        rounds.setCollectionBaseBps(address(lilNouns), 0); // switched off

        uint256 id = rounds.openRound();
        rounds.contributeWeights(id, address(lilNouns), _ids(1));
        rounds.contributeWeights(id, address(basedNouns), _ids(1));

        assertEq(claims.weightOf(id, address(usdc), alice), 0, "Lil earns nothing");
        assertEq(claims.weightOf(id, address(usdc), bob), 10_000, "Based unaffected");
    }

    /* ------------------------------------------------------------------ */
    /*                               HELPER                                 */
    /* ------------------------------------------------------------------ */

    function _openAndAccumulateFor(address collection, uint256[] memory ids) internal returns (uint256 id) {
        id = rounds.openRound();
        rounds.contributeWeights(id, collection, ids);
        vm.warp(block.timestamp + 2 hours);
        rounds.closeAccumulation(id);
    }
}
