// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChipRewardsBase} from "./ChipRewardsBase.t.sol";
import {ChipRounds} from "../src/ChipRounds.sol";
import {ChipClaims} from "../src/ChipClaims.sol";
import {Round, RoundState} from "../src/interfaces/IChipRounds.sol";
import {Pot} from "../src/Pot.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract ChipRewardsTest is ChipRewardsBase {
    /* ------------------------------------------------------------------ */
    /*                          OPENING A ROUND                             */
    /* ------------------------------------------------------------------ */

    function test_openRound_permissionlessAndPullsBudget() public {
        _fundPot(1_000e6);

        vm.prank(keeper); // anyone
        uint256 id = rounds.openRound();

        assertEq(id, 1);
        Round memory r = rounds.getRound(id);
        assertEq(uint8(r.state), uint8(RoundState.Accumulating));
        assertEq(r.budget, 1_000e6);
        assertEq(usdc.balanceOf(address(rounds)), 1_000e6, "budget moved out of the pot");
        assertEq(pot.available(), 0);
    }

    function test_openRound_revertsBelowMinimum() public {
        _fundPot(249e6);
        vm.expectRevert(abi.encodeWithSelector(ChipRounds.PotTooSmall.selector, uint256(249e6), uint256(MIN_POT)));
        rounds.openRound();
    }

    function test_openRound_capsBudgetAndLeavesRemainderForNextRound() public {
        _fundPot(25_000e6);
        uint256 id = rounds.openRound();
        assertEq(rounds.getRound(id).budget, MAX_BUDGET, "capped at $10k");
        assertEq(pot.available(), 15_000e6, "remainder stays for the next round");
    }

    function test_openRound_enforces24hSpacing() public {
        _fundPot(20_000e6);
        rounds.openRound();

        vm.expectRevert(
            abi.encodeWithSelector(
                ChipRounds.TooSoon.selector, uint64(block.timestamp), uint64(block.timestamp + 24 hours)
            )
        );
        rounds.openRound();

        vm.warp(block.timestamp + 24 hours);
        rounds.openRound(); // fine now
        assertEq(rounds.roundCount(), 2);
    }

    /* ------------------------------------------------------------------ */
    /*                              WEIGHTS                                 */
    /* ------------------------------------------------------------------ */

    function test_weight_tierTimesCollectionBase() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0); // tier 0 -> 1.00x, Based 1.0x
        _chip(darkNouns, darkVault, 1, bob, 0); // tier 0 -> 1.00x, Dark 2.0x

        uint256 id = rounds.openRound();
        rounds.contributeWeights(id, address(basedNouns), _ids(1));
        rounds.contributeWeights(id, address(darkNouns), _ids(1));

        // No split set -> weight lands on the quote token.
        assertEq(claims.weightOf(id, address(usdc), alice), 10_000);
        assertEq(claims.weightOf(id, address(usdc), bob), 20_000, "Dark Noun is worth 2x");
        assertEq(rounds.getRound(id).totalWeight, 30_000);
    }

    function test_weight_higherTierEarnsMore() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0); // 1.00x
        _chip(basedNouns, basedVault, 2, bob, 4); // 3.33x

        uint256 id = rounds.openRound();
        rounds.contributeWeights(id, address(basedNouns), _ids(1, 2));

        assertEq(claims.weightOf(id, address(usdc), alice), 10_000);
        assertEq(claims.weightOf(id, address(usdc), bob), 33_300);
    }

    function test_weight_hoodieBoostApplies() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _chip(basedNouns, basedVault, 2, bob, 0);
        hoodies.mint(bob, 1); // bob has a hoodie

        uint256 id = rounds.openRound();
        rounds.contributeWeights(id, address(basedNouns), _ids(1, 2));

        assertEq(claims.weightOf(id, address(usdc), alice), 10_000);
        assertEq(claims.weightOf(id, address(usdc), bob), 11_000, "1.10x boost");
    }

    /// @notice ASSUMPTIONS A-8: a sold Noun must stop earning immediately, even though the
    ///         Clutch vault still reports it active because nobody has called kick().
    function test_weight_soldNounEarnsNothingEvenWithoutAKick() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);

        vm.prank(alice);
        basedNouns.transferFrom(alice, bob, 1);

        // The vault has NOT been kicked and still claims the activation is live.
        assertTrue(basedVault.isActive(1), "vault still says active");
        assertEq(basedVault.ownerOfRecord(1), alice);

        uint256 id = rounds.openRound();
        rounds.contributeWeights(id, address(basedNouns), _ids(1));

        assertEq(claims.weightOf(id, address(usdc), alice), 0, "seller earns nothing");
        assertEq(claims.weightOf(id, address(usdc), bob), 0, "buyer must re-chip");
        assertEq(rounds.getRound(id).totalWeight, 0);
    }

    function test_weight_unactivatedNounIsIgnored() public {
        _fundPot(1_000e6);
        basedNouns.mint(alice, 1); // minted but never chipped

        uint256 id = rounds.openRound();
        rounds.contributeWeights(id, address(basedNouns), _ids(1));
        assertEq(rounds.getRound(id).totalWeight, 0);
    }

    function test_weight_cannotDoubleCountTheSameNoun() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);

        uint256 id = rounds.openRound();
        rounds.contributeWeights(id, address(basedNouns), _ids(1, 1, 1));
        rounds.contributeWeights(id, address(basedNouns), _ids(1)); // again, separately
        assertEq(claims.weightOf(id, address(usdc), alice), 10_000, "counted exactly once");
    }

    function test_weight_paddedListCannotInflateAShare() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);

        uint256 id = rounds.openRound();
        // A griefer submits a big list of ids that are not activated.
        rounds.contributeWeights(id, address(basedNouns), _ids(1, 99, 100));
        assertEq(rounds.getRound(id).totalWeight, 10_000, "only the real one counted");
    }

    /* ------------------------------------------------------------------ */
    /*                               SPLITS                                 */
    /* ------------------------------------------------------------------ */

    function test_setSplit_firstIsFreeThenCostsChip() public {
        _chip(basedNouns, basedVault, 1, alice, 0);
        chip.mint(alice, 20_000 ether);
        vm.prank(alice);
        chip.approve(address(rounds), type(uint256).max);

        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        assertEq(chip.balanceOf(alice), 20_000 ether, "first split free");

        _setSplit(address(basedNouns), 1, alice, _one(address(googl)), _one(uint8(100)));
        assertEq(chip.balanceOf(alice), 15_000 ether, "change burned 5,000 CHIP");
        assertEq(chip.balanceOf(address(0xdead)), 5_000 ether);
    }

    function test_setSplit_onlyCurrentOwner() public {
        _chip(basedNouns, basedVault, 1, alice, 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ChipRounds.NotNounOwner.selector, bob));
        rounds.setSplit(address(basedNouns), 1, _one(address(nvda)), _one(uint8(100)));
    }

    function test_setSplit_rejectsBadPercentages() public {
        _chip(basedNouns, basedVault, 1, alice, 0);
        vm.startPrank(alice);

        vm.expectRevert(ChipRounds.BadSplit.selector);
        rounds.setSplit(address(basedNouns), 1, _two(address(nvda), address(googl)), _two(uint8(50), uint8(40)));

        vm.expectRevert(ChipRounds.BadSplit.selector);
        rounds.setSplit(address(basedNouns), 1, _one(address(nvda)), _one(uint8(0)));

        vm.expectRevert(ChipRounds.BadSplit.selector);
        rounds.setSplit(address(basedNouns), 1, _two(address(nvda), address(nvda)), _two(uint8(50), uint8(50)));

        vm.stopPrank();
    }

    function test_setSplit_rejectsDisabledStock() public {
        _chip(basedNouns, basedVault, 1, alice, 0);
        vm.prank(multisig);
        registry.setEnabled(address(nvda), false);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ChipRounds.StockNotEnabled.selector, address(nvda)));
        rounds.setSplit(address(basedNouns), 1, _one(address(nvda)), _one(uint8(100)));
    }

    function test_split_routesWeightAcrossChosenStocks() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _two(address(nvda), address(googl)), _two(uint8(60), uint8(40)));

        uint256 id = rounds.openRound();
        rounds.contributeWeights(id, address(basedNouns), _ids(1));

        assertEq(claims.weightOf(id, address(nvda), alice), 6_000);
        assertEq(claims.weightOf(id, address(googl), alice), 4_000);
        assertEq(rounds.getRound(id).totalWeight, 10_000);
    }

    /// @notice Spec: "Disabling blocks new picks; existing slices route to USDC."
    function test_split_sliceOfADisabledStockRoutesToUsdc() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _two(address(nvda), address(googl)), _two(uint8(50), uint8(50)));

        vm.prank(multisig);
        registry.setEnabled(address(nvda), false);

        uint256 id = rounds.openRound();
        rounds.contributeWeights(id, address(basedNouns), _ids(1));

        assertEq(claims.weightOf(id, address(nvda), alice), 0);
        assertEq(claims.weightOf(id, address(usdc), alice), 5_000, "rerouted to USDC");
        assertEq(claims.weightOf(id, address(googl), alice), 5_000, "untouched");
    }

    /* ------------------------------------------------------------------ */
    /*                        BUYING AND FINALIZING                         */
    /* ------------------------------------------------------------------ */

    function test_fullRound_buysAndCreditsProRata() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _chip(basedNouns, basedVault, 2, bob, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        _setSplit(address(basedNouns), 2, bob, _one(address(nvda)), _one(uint8(100)));

        uint256 id = _openAndAccumulate(_ids(1, 2));
        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);

        // $1,000 of NVDA at $200 = 5 shares, split evenly.
        assertEq(claims.acquired(id, address(nvda)), 5e8);
        assertEq(claims.claimable(id, address(nvda), alice), 2.5e8);
        assertEq(claims.claimable(id, address(nvda), bob), 2.5e8);

        vm.prank(alice);
        claims.claim(id, address(nvda));
        assertEq(nvda.balanceOf(alice), 2.5e8);
    }

    function test_fullRound_budgetSplitsByDemandNotEvenly() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _chip(basedNouns, basedVault, 2, bob, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        _setSplit(address(basedNouns), 2, bob, _one(address(googl)), _one(uint8(100)));

        uint256 id = _openAndAccumulate(_ids(1, 2));
        rounds.settleStock(id, address(nvda));
        rounds.settleStock(id, address(googl));
        rounds.finalizeRound(id);

        assertEq(claims.acquired(id, address(nvda)), 2.5e8, "$500 at $200");
        assertEq(claims.acquired(id, address(googl)), 1.25e8, "$500 at $400");
        assertEq(usdc.balanceOf(address(rounds)), 0, "budget fully deployed");
    }

    function test_quoteTokenSliceNeedsNoSwap() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0); // no split -> all USDC

        uint256 id = _openAndAccumulate(_ids(1));
        rounds.settleStock(id, address(usdc));
        rounds.finalizeRound(id);

        assertEq(claims.acquired(id, address(usdc)), 1_000e6);
        vm.prank(alice);
        claims.claim(id, address(usdc));
        assertEq(usdc.balanceOf(alice), 1_000e6);
    }

    function test_skipAndCarry_badExecutionSkipsAndReturnsBudget() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _chip(basedNouns, basedVault, 2, bob, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        _setSplit(address(basedNouns), 2, bob, _one(address(googl)), _one(uint8(100)));

        // NVDA now executes 50% worse than the Chainlink mark: past the 2% bound.
        router.setRate(address(usdc), address(nvda), 1e8, NVDA_USD * 2e6);

        uint256 id = _openAndAccumulate(_ids(1, 2));
        rounds.settleStock(id, address(nvda));
        rounds.settleStock(id, address(googl));
        rounds.finalizeRound(id);

        assertTrue(rounds.stockSkipped(id, address(nvda)), "NVDA skipped");
        assertEq(claims.acquired(id, address(nvda)), 0);
        assertEq(claims.acquired(id, address(googl)), 1.25e8, "GOOGL unaffected");
        assertEq(pot.available(), 500e6, "NVDA's slice carried back to the pot");
    }

    function test_slippageBoundIsConfigurablePerStock() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));

        // 10% worse than the mark.
        router.setRate(address(usdc), address(nvda), 90e8, NVDA_USD * 100e6);

        vm.prank(multisig);
        rounds.setMaxSlippageBps(address(nvda), 1_500); // tolerate 15%

        uint256 id = _openAndAccumulate(_ids(1));
        rounds.settleStock(id, address(nvda));
        assertFalse(rounds.stockSkipped(id, address(nvda)), "within the widened bound");
        assertEq(claims.acquired(id, address(nvda)), 4.5e8);
    }

    function test_finalize_requiresEveryStockSettled() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _chip(basedNouns, basedVault, 2, bob, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        _setSplit(address(basedNouns), 2, bob, _one(address(googl)), _one(uint8(100)));

        uint256 id = _openAndAccumulate(_ids(1, 2));
        rounds.settleStock(id, address(nvda));

        vm.expectRevert(abi.encodeWithSelector(ChipRounds.NotSettled.selector, id, address(googl)));
        rounds.finalizeRound(id);
    }

    function test_totalPaidUsd_marksAtChainlink() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));

        uint256 id = _openAndAccumulate(_ids(1));
        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);

        // 5 NVDA at $200 = $1,000
        assertEq(rounds.totalPaidUsd(), 1_000e18);
    }

    /* ------------------------------------------------------------------ */
    /*                       ACCUMULATION GRIEFING                          */
    /* ------------------------------------------------------------------ */

    /// @notice A griefer must not be able to open a round, add only their own Noun and
    ///         close it before anyone else can join.
    function test_cannotCloseAccumulationEarly() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);

        uint256 id = rounds.openRound();
        rounds.contributeWeights(id, address(basedNouns), _ids(1));

        vm.expectRevert(
            abi.encodeWithSelector(
                ChipRounds.AccumulationStillOpen.selector, uint64(block.timestamp), uint64(block.timestamp + 2 hours)
            )
        );
        rounds.closeAccumulation(id);
    }

    /// @notice And anyone excluded can add themselves during the window, without needing
    ///         permission from the opener.
    function test_anyoneCanContributeForAnyoneDuringTheWindow() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _chip(basedNouns, basedVault, 2, bob, 0);

        vm.prank(alice);
        uint256 id = rounds.openRound();
        vm.prank(alice);
        rounds.contributeWeights(id, address(basedNouns), _ids(1));

        // Carol, a total stranger, adds bob's Noun.
        vm.prank(carol);
        rounds.contributeWeights(id, address(basedNouns), _ids(2));

        assertEq(claims.weightOf(id, address(usdc), bob), 10_000, "bob is in");
    }

    function test_closeAccumulation_revertsWithNoWeight() public {
        _fundPot(1_000e6);
        uint256 id = rounds.openRound();
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(abi.encodeWithSelector(ChipRounds.NoWeight.selector, id));
        rounds.closeAccumulation(id);
    }

    /* ------------------------------------------------------------------ */
    /*                         CLAIMS AND EXPIRY                            */
    /* ------------------------------------------------------------------ */

    function test_claim_cannotClaimTwice() public {
        uint256 id = _simpleNvdaRound();
        vm.prank(alice);
        claims.claim(id, address(nvda));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ChipClaims.AlreadyClaimed.selector, id, address(nvda), alice));
        claims.claim(id, address(nvda));
    }

    function test_claim_creditFollowsTheAddressNotTheNoun() public {
        uint256 id = _simpleNvdaRound();

        // Alice sells the Noun AFTER the round was booked.
        vm.prank(alice);
        basedNouns.transferFrom(alice, bob, 1);

        vm.prank(alice);
        uint256 got = claims.claim(id, address(nvda));
        assertEq(got, 5e8, "seller keeps what was already earned");
        assertEq(nvda.balanceOf(alice), 5e8);
    }

    function test_claim_revertsAfterCreditsExpire() public {
        uint256 id = _simpleNvdaRound();
        uint64 expiresAt = claims.expiresAt(id);
        vm.warp(expiresAt + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ChipClaims.CreditsExpired.selector, id, expiresAt));
        claims.claim(id, address(nvda));
    }

    function test_sweepExpired_sendsRemainderToPol() public {
        uint256 id = _simpleNvdaRound();
        _warpPastExpiry(id);

        uint256 swept = claims.sweepExpired(id, address(nvda));
        assertEq(swept, 5e8);
        assertEq(nvda.balanceOf(polTreasury), 5e8);
        assertEq(claims.totalOwed(address(nvda)), 0, "no longer owed");
    }

    function test_sweepExpired_onlyTakesWhatWasNotClaimed() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _chip(basedNouns, basedVault, 2, bob, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        _setSplit(address(basedNouns), 2, bob, _one(address(nvda)), _one(uint8(100)));

        uint256 id = _openAndAccumulate(_ids(1, 2));
        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);

        vm.prank(alice);
        claims.claim(id, address(nvda)); // 2.5

        _warpPastExpiry(id);
        assertEq(claims.sweepExpired(id, address(nvda)), 2.5e8, "only bob's unclaimed half");
        assertEq(nvda.balanceOf(polTreasury), 2.5e8);
    }

    function test_sweepExpired_revertsBeforeExpiry() public {
        uint256 id = _simpleNvdaRound();
        uint64 expiresAt = claims.expiresAt(id);
        vm.expectRevert(abi.encodeWithSelector(ChipClaims.NotExpiredYet.selector, id, expiresAt));
        claims.sweepExpired(id, address(nvda));
    }

    function test_autoCompound_routesToPolAndLogsUsd() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        vm.prank(alice);
        claims.setAutoCompound(true);

        uint256 id = _openAndAccumulate(_ids(1));
        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);

        vm.prank(alice);
        claims.claim(id, address(nvda));

        assertEq(nvda.balanceOf(alice), 0, "went to POL instead");
        assertEq(nvda.balanceOf(polTreasury), 5e8);
        assertEq(claims.polCreditUsd(alice), 1_000e18, "share ledger in USD");
    }

    /* ------------------------------------------------------------------ */
    /*                              HELPERS                                 */
    /* ------------------------------------------------------------------ */

    /// @dev One round, one Noun (alice, tier 0, 100% NVDA), $1,000 budget, finalized.
    function _simpleNvdaRound() internal returns (uint256 id) {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        id = _openAndAccumulate(_ids(1));
        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);
    }
}
