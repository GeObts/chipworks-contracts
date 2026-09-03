// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChipRewardsBase} from "../ChipRewardsBase.t.sol";
import {StockRegistry} from "../../src/StockRegistry.sol";
import {Venue} from "../../src/interfaces/IStockRegistry.sol";

import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MultiplierToken} from "../mocks/MultiplierToken.sol";

/// @title MultiplierIndifferenceTest
/// @notice A B20 token is NOT permanently one share. Prove nothing here assumes it is.
///
/// @dev ASSUMPTIONS A-13: Coinbase values a B20 stock as the underlying price times a
///      multiplier that absorbs corporate actions. A cash dividend converts to shares and
///      raises the multiplier instead of paying out; a 10:1 split raises it from 1.0 to 10.0
///      so the token's quoted price stays continuous across the split.
///
///      That is the stated reason every USD figure in Chipworks comes from the feed rather
///      than from a share count. This file is the test of that claim, in two halves.
///
///      **Half one — the documented mechanism.** The multiplier lives in the valuation, so a
///      corporate action moves the FEED and leaves balances alone. Tested by moving the feed
///      under a live round and asserting that what holders are owed is unaffected, because
///      they are owed tokens rather than dollars.
///
///      **Half two — the mechanism we cannot rule out.** B20 tokens are node-native
///      precompiles with no readable implementation (A-15), so "balances never rebase" is an
///      inference from a sentence about valuation, not something anyone has verified. These
///      tests rebase balances underneath the ledger and record exactly what happens. One of
///      them documents a genuine limit rather than a guarantee — see
///      `test_hedge_aDOWNWARDrebaseCanUnderfundTheLedger`.
contract MultiplierIndifferenceTest is ChipRewardsBase {
    MultiplierToken internal msftc;
    MockAggregatorV3 internal msftFeed;

    /// @dev MSFT at $400, 8 decimals, exactly like the real B20 tokens.
    uint256 internal constant MSFT_USD = 400;

    function setUp() public override {
        super.setUp();

        msftc = new MultiplierToken("Microsoft Corporation", "MSFTc", STOCK_DEC);
        msftFeed = new MockAggregatorV3(8, int256(MSFT_USD * 1e8), "Coinbase MSFT");

        address pool = address(uint160(2000));
        uniFactory.setPool(address(msftc), address(usdc), FEE, pool);

        vm.startPrank(multisig);
        registry.addStock(
            StockRegistry.AddStockParams({
                token: address(msftc),
                feed: address(msftFeed),
                venue: Venue.UniswapV3,
                pool: pool,
                fee: FEE,
                tickSpacing: 0,
                minLiquidityUsd: 0,
                tokenDecimals: STOCK_DEC
            })
        );
        registry.setEnabled(address(msftc), true);
        vm.stopPrank();

        router.setRate(address(usdc), address(msftc), 1e8, MSFT_USD * 1e6);
        msftc.mint(address(router), 1_000_000e8);
    }

    /// @dev One Noun, all weight on MSFTc, one finalized round.
    function _roundOnMsft(uint256 potUsdc) internal returns (uint256 id) {
        _fundPot(potUsdc);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(msftc)), _one(uint8(100)));

        id = _openAndAccumulate(_ids(1));
        rounds.settleStock(id, address(msftc));
        rounds.finalizeRound(id);
    }

    /* ------------------------------------------------------------------ */
    /*        HALF ONE — THE DOCUMENTED MECHANISM: THE FEED MOVES          */
    /* ------------------------------------------------------------------ */

    /// @notice A holder is owed TOKENS, not dollars. A corporate action that re-marks the
    ///         feed after a round cannot change what they can claim.
    function test_feedMove_doesNotChangeWhatAHolderIsOwed() public {
        uint256 id = _roundOnMsft(1_000e6);
        uint256 owed = claims.claimable(id, address(msftc), alice);
        assertEq(owed, 2.5e8, "$1,000 at $400");

        // A 10:1 split: the multiplier goes 1.0 -> 10.0 and the feed re-marks with it.
        msftFeed.setAnswer(int256(MSFT_USD * 10 * 1e8));

        assertEq(claims.claimable(id, address(msftc), alice), owed, "unchanged by the re-mark");

        _openClaimWindow();
        vm.prank(alice);
        claims.claim(id, address(msftc));
        assertEq(msftc.balanceOf(alice), owed, "she receives the tokens she was credited");
    }

    /// @notice And downward, which is the direction that would matter if anything cached a
    ///         dollar figure and paid it out later.
    function test_feedMove_downwardIsEquallyIrrelevant() public {
        uint256 id = _roundOnMsft(1_000e6);
        uint256 owed = claims.claimable(id, address(msftc), alice);

        msftFeed.setAnswer(int256((MSFT_USD * 1e8) / 4));

        assertEq(claims.claimable(id, address(msftc), alice), owed);
        _openClaimWindow();
        vm.prank(alice);
        assertEq(claims.claim(id, address(msftc)), owed);
    }

    /// @notice The purchase itself is priced at the feed as it stands when the buy happens,
    ///         so a re-mark between opening and settling changes how much is bought — which
    ///         is correct, not a bug. What must NOT happen is the round mispricing against a
    ///         mark it read earlier.
    function test_feedMove_midRoundPricesTheBuyAtTheNewMark() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(msftc)), _one(uint8(100)));

        uint256 id = _openAndAccumulate(_ids(1));

        // Dividend converts to shares: the token is worth 25% more before we buy.
        msftFeed.setAnswer(int256((MSFT_USD * 125 / 100) * 1e8));
        router.setRate(address(usdc), address(msftc), 1e8, (MSFT_USD * 125 / 100) * 1e6);

        rounds.settleStock(id, address(msftc));
        rounds.finalizeRound(id);

        // $1,000 at $500 is 2 tokens, not 2.5.
        assertEq(claims.acquired(id, address(msftc)), 2e8, "priced at the mark that applied");
        assertFalse(rounds.stockSkipped(id, address(msftc)), "and it was not refused");
    }

    /// @notice USD reporting tracks the feed rather than a share count. This is the figure
    ///         the site shows, and the whole reason it is derived and not stored.
    function test_feedMove_usdReportingComesFromTheFeed() public {
        uint256 id = _roundOnMsft(1_000e6);
        // First round of the fixture, so the cumulative counter is this round's value.
        uint256 paidUsd = rounds.totalPaidUsd();
        assertApproxEqRel(paidUsd, 1_000e18, 1e15, "$1,000 of stock at the mark");

        // The same 2.5 tokens after a 10:1 re-mark are worth ten times as much, and the
        // valuation follows the feed with no migration, no rebase and no stored price.
        msftFeed.setAnswer(int256(MSFT_USD * 10 * 1e8));
        (uint256 price1e18,) = registry.priceUsd(address(msftc));
        uint256 nowWorth = (claims.claimable(id, address(msftc), alice) * price1e18) / 1e8;
        assertApproxEqRel(nowWorth, 10_000e18, 1e15, "valued at the current mark");
    }

    /* ------------------------------------------------------------------ */
    /*      HALF TWO — THE HEDGE: WHAT IF BALANCES REBASE INSTEAD?         */
    /* ------------------------------------------------------------------ */

    /// @notice An UPWARD rebase after a round leaves the ledger over-funded, never short.
    ///         Holders receive exactly what they were credited and the surplus is strictly
    ///         excess, so `recoverExcess` can take it and nothing else.
    function test_hedge_anUpwardRebaseLeavesTheLedgerOverfundedAndSolvent() public {
        uint256 id = _roundOnMsft(1_000e6);
        uint256 owed = claims.claimable(id, address(msftc), alice);
        assertEq(msftc.balanceOf(address(claims)), claims.totalOwed(address(msftc)));

        msftc.applySplit(3); // balances triple underneath the ledger

        assertGt(msftc.balanceOf(address(claims)), claims.totalOwed(address(msftc)), "over-funded");

        _openClaimWindow();
        vm.prank(alice);
        assertEq(claims.claim(id, address(msftc)), owed, "credited amount, not the windfall");

        // One unit of slack, and the reason is worth stating: on a share-backed rebasing
        // token, transferring `owed` moves `owed * 1e18 / multiplier` shares, and that
        // division truncates — so the recipient's balance can read one unit light even
        // though the ledger sent the full amount. Inherent to the token model, not to us,
        // and a further small argument for B20 not working this way.
        assertApproxEqAbs(msftc.balanceOf(alice), owed, 1, "paid in full, modulo rebase dust");

        // The surplus is recoverable, and only the surplus.
        uint256 surplus = msftc.balanceOf(address(claims)) - claims.totalOwed(address(msftc));
        assertGt(surplus, 0);
        vm.prank(multisig);
        claims.recoverExcess(address(msftc), multisig, surplus);
        assertEq(msftc.balanceOf(multisig), surplus);
        assertGe(msftc.balanceOf(address(claims)), claims.totalOwed(address(msftc)), "still solvent");
    }

    /// @notice A rebase between the buy and the hand-off is absorbed, because the ledger
    ///         books what ARRIVED rather than what the engine intended to send.
    function test_hedge_aRebaseDuringTheRoundIsBookedAsWhatActuallyArrived() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(msftc)), _one(uint8(100)));
        uint256 id = _openAndAccumulate(_ids(1));

        msftc.applyDividend(500); // +5% mid-round, before settlement
        rounds.settleStock(id, address(msftc));
        rounds.finalizeRound(id);

        assertEq(
            claims.acquired(id, address(msftc)),
            msftc.balanceOf(address(claims)),
            "the ledger booked exactly what it received"
        );
        assertLe(claims.totalOwed(address(msftc)), msftc.balanceOf(address(claims)), "solvent");
    }

    /// @notice THIS ONE DOCUMENTS A LIMIT, NOT A GUARANTEE.
    ///
    ///         A DOWNWARD rebase shrinks balances the ledger has already promised. Nothing
    ///         in this repo can conjure the missing tokens back, so the last claimant in a
    ///         round finds the ledger short. The failure is contained and honest — the claim
    ///         reverts rather than paying someone else's tokens out, the credit stays on the
    ///         books, and every other stock is untouched — but a holder is genuinely unable
    ///         to be made whole.
    ///
    /// @dev We do NOT believe B20 does this: A-13 puts the multiplier in the valuation, and
    ///      a downward multiplier would mean a reverse split handled by shrinking balances
    ///      rather than re-marking. Recorded because "we would notice and it degrades safely"
    ///      is a much weaker promise than the rest of this suite makes, and an auditor should
    ///      see the difference stated rather than inferred.
    function test_hedge_aDOWNWARDrebaseCanUnderfundTheLedger() public {
        _fundPot(2_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _chip(basedNouns, basedVault, 2, bob, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(msftc)), _one(uint8(100)));
        _setSplit(address(basedNouns), 2, bob, _one(address(msftc)), _one(uint8(100)));

        uint256 id = _openAndAccumulate(_ids(1, 2));
        rounds.settleStock(id, address(msftc));
        rounds.finalizeRound(id);

        uint256 owedEach = claims.claimable(id, address(msftc), alice);
        assertEq(owedEach, claims.claimable(id, address(msftc), bob));

        // A reverse split handled as a balance cut: the ledger now holds half of what it owes.
        msftc.setMultiplier(0.5e18);
        assertLt(msftc.balanceOf(address(claims)), claims.totalOwed(address(msftc)), "under-funded");

        _openClaimWindow();

        // Alice claims first and is paid in full, out of what is left.
        vm.prank(alice);
        assertEq(claims.claim(id, address(msftc)), owedEach);

        // Bob cannot be. The claim reverts; it does NOT pay him a silently reduced amount,
        // and it does not touch anyone else's stock.
        vm.prank(bob);
        vm.expectRevert();
        claims.claim(id, address(msftc));

        assertEq(claims.claimable(id, address(msftc), bob), owedEach, "his credit is still on the books");
        assertFalse(claims.hasClaimed(id, address(msftc), bob), "and not marked claimed");

        // Containment: a different stock in the same ledger is completely unaffected.
        assertEq(nvda.balanceOf(address(claims)), claims.totalOwed(address(nvda)));
    }

    /// @notice A rebase cannot leak across stocks. NVDA's accounting is exact no matter what
    ///         MSFTc does, in either direction.
    function test_hedge_aRebasingStockCannotCorruptAHealthyOne() public {
        _fundPot(2_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _two(address(msftc), address(nvda)), _two(uint8(50), uint8(50)));

        uint256 id = _openAndAccumulate(_ids(1));
        rounds.settleStock(id, address(msftc));
        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);

        uint256 nvdaOwed = claims.claimable(id, address(nvda), alice);
        assertEq(nvdaOwed, 5e8, "$1,000 at $200");

        msftc.applySplit(7);
        assertEq(claims.claimable(id, address(nvda), alice), nvdaOwed, "NVDA untouched");

        _openClaimWindow();
        vm.prank(alice);
        assertEq(claims.claim(id, address(nvda)), nvdaOwed);
        assertEq(nvda.balanceOf(alice), nvdaOwed);
    }
}
