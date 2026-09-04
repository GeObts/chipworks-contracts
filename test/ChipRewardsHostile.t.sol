// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChipRewardsBase} from "./ChipRewardsBase.t.sol";
import {ChipRounds} from "../src/ChipRounds.sol";
import {ChipClaims} from "../src/ChipClaims.sol";
import {Round, RoundState} from "../src/interfaces/IChipRounds.sol";
import {GasBombNoun} from "./mocks/MockNoun.sol";
import {FeeOnTransferToken} from "./mocks/HostileTokens.sol";
import {StockRegistry} from "../src/StockRegistry.sol";
import {Venue} from "../src/interfaces/IStockRegistry.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";

/// @notice The property that matters most: a stock whose token misbehaves must fail IN
///         ISOLATION. It must not strand another stock's claims, block a round from
///         finishing, or trap anyone else's credits.
///
/// @dev Base's own B20 docs say onchain policies can block specific addresses and that a
///      blocked transfer reverts, and that the standard includes a pause mechanism. So
///      "AAPLc suddenly refuses to move" is a documented behaviour of the real asset, not
///      an invented threat. See ASSUMPTIONS.md A-15.
contract ChipRewardsHostileTest is ChipRewardsBase {
    /* ------------------------------------------------------------------ */
    /*                     A FROZEN STOCK AT BUY TIME                       */
    /* ------------------------------------------------------------------ */

    /// @notice AAPL is frozen before the round buys. Its buy must skip, every other stock
    ///         must still buy, and the round must still finalize.
    function test_frozenStockSkipsItsOwnBuyAndTheRoundStillCompletes() public {
        _fundPot(3_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _chip(basedNouns, basedVault, 2, bob, 0);
        _chip(basedNouns, basedVault, 3, carol, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        _setSplit(address(basedNouns), 2, bob, _one(address(googl)), _one(uint8(100)));
        _setSplit(address(basedNouns), 3, carol, _one(address(aapl)), _one(uint8(100)));

        // The issuer blocks the engine from receiving AAPL, so the buy itself fails.
        aapl.setBlacklisted(address(rounds), true);

        uint256 id = _openAndAccumulate(_ids(1, 2, 3));

        rounds.settleStock(id, address(nvda));
        rounds.settleStock(id, address(googl));
        rounds.settleStock(id, address(aapl)); // must not revert

        assertTrue(rounds.stockSkipped(id, address(aapl)), "AAPL skipped");
        assertEq(claims.acquired(id, address(aapl)), 0);
        assertEq(claims.acquired(id, address(nvda)), 5e8, "NVDA bought normally");
        assertEq(claims.acquired(id, address(googl)), 2.5e8, "GOOGL bought normally");

        rounds.finalizeRound(id); // must not revert
        assertEq(uint8(rounds.getRound(id).state), uint8(RoundState.Finalized));
        assertEq(pot.available(), 1_000e6, "carol's slice carried back, not lost");

        // Alice and Bob are entirely unaffected.
        vm.prank(alice);
        claims.claim(id, address(nvda));
        vm.prank(bob);
        claims.claim(id, address(googl));
        assertEq(nvda.balanceOf(alice), 5e8);
        assertEq(googl.balanceOf(bob), 2.5e8);
    }

    /* ------------------------------------------------------------------ */
    /*                   A FROZEN STOCK AT CLAIM TIME                       */
    /* ------------------------------------------------------------------ */

    /// @notice The hardest case: the stock was bought fine, then froze. Only claims OF
    ///         THAT STOCK may fail. Everything else keeps working, and nothing is lost.
    function test_stockFrozenAfterPurchaseStrandsOnlyItself() public {
        _fundPot(2_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _chip(basedNouns, basedVault, 2, bob, 0);
        // Alice holds both AAPL and NVDA; Bob holds only NVDA.
        _setSplit(address(basedNouns), 1, alice, _two(address(aapl), address(nvda)), _two(uint8(50), uint8(50)));
        _setSplit(address(basedNouns), 2, bob, _one(address(nvda)), _one(uint8(100)));

        uint256 id = _openAndAccumulate(_ids(1, 2));
        rounds.settleStock(id, address(aapl));
        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);

        uint256 aaplOwed = claims.claimable(id, address(aapl), alice);
        assertGt(aaplOwed, 0);

        // NOW the issuer freezes Alice.
        aapl.setBlacklisted(alice, true);

        // Her AAPL claim fails...
        vm.prank(alice);
        vm.expectRevert(bytes("BLACKLISTED"));
        claims.claim(id, address(aapl));

        // ...but her NVDA claim from the SAME round works.
        vm.prank(alice);
        uint256 gotNvda = claims.claim(id, address(nvda));
        assertGt(gotNvda, 0);
        assertEq(nvda.balanceOf(alice), gotNvda);

        // And Bob is completely untouched.
        vm.prank(bob);
        claims.claim(id, address(nvda));
        assertGt(nvda.balanceOf(bob), 0);

        // Her AAPL credit is still intact and claimable once unfrozen.
        aapl.setBlacklisted(alice, false);
        vm.prank(alice);
        assertEq(claims.claim(id, address(aapl)), aaplOwed, "nothing was lost while frozen");
        assertEq(aapl.balanceOf(alice), aaplOwed);
    }

    /// @notice One frozen holder must not stop a different holder claiming the same stock.
    function test_oneFrozenHolderDoesNotBlockOtherHoldersOfTheSameStock() public {
        _fundPot(2_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _chip(basedNouns, basedVault, 2, bob, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(aapl)), _one(uint8(100)));
        _setSplit(address(basedNouns), 2, bob, _one(address(aapl)), _one(uint8(100)));

        uint256 id = _openAndAccumulate(_ids(1, 2));
        rounds.settleStock(id, address(aapl));
        rounds.finalizeRound(id);

        aapl.setBlacklisted(alice, true);

        vm.prank(alice);
        vm.expectRevert(bytes("BLACKLISTED"));
        claims.claim(id, address(aapl));

        vm.prank(bob);
        uint256 got = claims.claim(id, address(aapl));
        assertGt(got, 0, "bob unaffected by alice being frozen");
        assertEq(aapl.balanceOf(bob), got);
    }

    /// @notice claimMany is a convenience, not a guarantee. A frozen leg reverts the batch,
    ///         so the UI must fall back to single claims. Documented deliberately.
    function test_claimManyRevertsOnAFrozenLegButSingleClaimsStillWork() public {
        _fundPot(2_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _two(address(aapl), address(nvda)), _two(uint8(50), uint8(50)));

        uint256 id = _openAndAccumulate(_ids(1));
        rounds.settleStock(id, address(aapl));
        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);

        aapl.setBlacklisted(alice, true);

        uint256[] memory ids = new uint256[](2);
        ids[0] = id;
        ids[1] = id;
        address[] memory stocks = _two(address(aapl), address(nvda));

        vm.prank(alice);
        vm.expectRevert(bytes("BLACKLISTED"));
        claims.claimMany(ids, stocks);

        // Falling back to the single call recovers the healthy leg.
        vm.prank(alice);
        assertGt(claims.claim(id, address(nvda)), 0);
    }

    /* ------------------------------------------------------------------ */
    /*                   THE REGISTRY DISABLE MITIGATION                    */
    /* ------------------------------------------------------------------ */

    /// @notice The documented mitigation: switch the broken stock off, and future rounds
    ///         route those slices to USDC instead. Holders keep earning.
    function test_disablingAFrozenStockKeepsFutureRoundsWorking() public {
        _fundPot(20_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(aapl)), _one(uint8(100)));

        aapl.setBlacklisted(address(rounds), true);

        // Round 1: AAPL is skipped, so nothing is bought for Alice at all.
        uint256 r1 = _openAndAccumulate(_ids(1));
        rounds.settleStock(r1, address(aapl));
        rounds.finalizeRound(r1);
        assertTrue(rounds.stockSkipped(r1, address(aapl)));
        assertEq(claims.claimable(r1, address(aapl), alice), 0);

        // The multisig switches AAPL off.
        vm.prank(multisig);
        registry.setEnabled(address(aapl), false);

        // Round 2: her slice reroutes to USDC and she earns normally again.
        vm.warp(block.timestamp + 24 hours);
        uint256 r2 = _openAndAccumulate(_ids(1));
        rounds.settleStock(r2, address(usdc));
        rounds.finalizeRound(r2);

        vm.prank(alice);
        uint256 got = claims.claim(r2, address(usdc));
        assertGt(got, 0, "earning again, in USDC");
        assertEq(usdc.balanceOf(alice), got);
    }

    /// @notice Sweeping a frozen stock fails, but sweeping the others still works, so one
    ///         stuck asset cannot hold the POL treasury hostage.
    function test_frozenStockDoesNotBlockSweepingOtherStocks() public {
        _fundPot(2_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _two(address(aapl), address(nvda)), _two(uint8(50), uint8(50)));

        uint256 id = _openAndAccumulate(_ids(1));
        rounds.settleStock(id, address(aapl));
        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);

        aapl.setBlacklisted(address(claims), true);
        vm.warp(block.timestamp + 91 days);

        vm.expectRevert(bytes("BLACKLISTED"));
        claims.sweepExpired(id, address(aapl));

        uint256 swept = claims.sweepExpired(id, address(nvda));
        assertGt(swept, 0);
        assertEq(nvda.balanceOf(polTreasury), swept);
    }

    /* ------------------------------------------------------------------ */
    /*                      HOSTILE FOREIGN CONTRACTS                       */
    /* ------------------------------------------------------------------ */

    /// @notice A collection whose ownerOf burns all gas must not take the round with it.
    ///         This is ASSUMPTIONS A-17 enforced at the adapter boundary.
    function test_gasBombCollectionCannotWedgeARound() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);

        GasBombNoun bomb = new GasBombNoun();
        vm.startPrank(multisig);
        adapter.setVault(address(bomb), address(basedVault));
        rounds.setCollectionBaseBps(address(bomb), 10_000);
        vm.stopPrank();

        uint256 id = rounds.openRound();
        rounds.contributeWeights(id, address(bomb), _ids(1, 2, 3)); // survives
        rounds.contributeWeights(id, address(basedNouns), _ids(1));

        assertEq(claims.weightOf(id, address(usdc), alice), 10_000, "healthy Noun still counted");
    }

    /// @notice REMOVED WITH ITS SUBJECT. `test_gasBombHoodieDegradesToNoBoost` proved that a
    ///         hostile external NFT read during weight scoring degraded to "no boost" rather
    ///         than reverting a round. The hoodie boost is gone, and with it the only place
    ///         weight scoring called an address the protocol did not choose.
    ///
    ///         Weight is now `tier x collectionBase`, read entirely from ChipActivation and
    ///         `collectionBaseBps`. The equivalent hostile surface — a collection whose
    ///         `ownerOf` burns all gas — is covered in `test/activation/ChipActivation.t.sol`
    ///         by `test_aGasBombCollectionCannotWedgeAread`.

    /// @notice A router that reverts must skip the stock, not kill the round.
    function test_deadRouterSkipsRatherThanReverts() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));

        router.setFailAlways(true);

        uint256 id = _openAndAccumulate(_ids(1));
        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);

        assertTrue(rounds.stockSkipped(id, address(nvda)));
        assertEq(pot.available(), 1_000e6, "entire budget carried back");
    }

    /// @notice A dead price feed must skip the stock rather than block the round, and the
    ///         round must still finalize and report a value.
    function test_deadFeedSkipsStockAndRoundStillFinalizes() public {
        _fundPot(2_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _chip(basedNouns, basedVault, 2, bob, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        _setSplit(address(basedNouns), 2, bob, _one(address(googl)), _one(uint8(100)));

        nvdaFeed.setRevertOnRead(true);

        uint256 id = _openAndAccumulate(_ids(1, 2));
        rounds.settleStock(id, address(nvda));
        rounds.settleStock(id, address(googl));
        rounds.finalizeRound(id);

        assertTrue(rounds.stockSkipped(id, address(nvda)));
        assertEq(claims.acquired(id, address(googl)), 2.5e8);
        assertEq(rounds.totalPaidUsd(), 1_000e18, "only the stock that actually settled");
    }

    /* ------------------------------------------------------------------ */
    /*            A NEW FAILURE MODE THE SPLIT INTRODUCED                   */
    /* ------------------------------------------------------------------ */

    /// @notice The engine buys stock and then hands it to the ledger. That handover is a
    ///         second place a policy-blocked token can fail, and it did not exist before the
    ///         contracts were split. It must NOT be able to wedge the round.
    /// @dev Found by running the pre-split test suite against the split: the handover was a
    ///      plain safeTransfer, so a blocked ledger reverted settleStock and left the round
    ///      permanently unfinishable — every other holder in it stuck too. The transfer is
    ///      now measured and tolerated, and the shortfall is reported as stranded.
    function test_aBlockedLedgerStrandsOneStockWithoutWedgingTheRound() public {
        _fundPot(2_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _chip(basedNouns, basedVault, 2, bob, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(aapl)), _one(uint8(100)));
        _setSplit(address(basedNouns), 2, bob, _one(address(nvda)), _one(uint8(100)));

        // The engine may receive AAPL, but the LEDGER may not.
        aapl.setBlacklisted(address(claims), true);

        uint256 id = _openAndAccumulate(_ids(1, 2));
        rounds.settleStock(id, address(aapl)); // must not revert
        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id); // must not revert

        // AAPL was bought but could not be delivered: credited to nobody, stranded in the
        // engine, and recoverable. Nothing is silently lost.
        assertEq(claims.acquired(id, address(aapl)), 0, "nobody credited");
        assertGt(aapl.balanceOf(address(rounds)), 0, "stranded in the engine");
        assertGt(rounds.excess(address(aapl)), 0, "and recoverable by the multisig");

        // Bob's NVDA is completely unaffected.
        _openClaimWindow();
        vm.prank(bob);
        assertGt(claims.claim(id, address(nvda)), 0, "healthy stock still pays out");

        // The ledger is still exactly solvent for what it owes.
        assertEq(aapl.balanceOf(address(claims)), claims.totalOwed(address(aapl)));
        assertEq(nvda.balanceOf(address(claims)), claims.totalOwed(address(nvda)));
    }

    /* ------------------------------------------------------------------ */
    /*        THE LEDGER ACCEPTS THE TOKENS BUT REFUSES TO BOOK THEM        */
    /* ------------------------------------------------------------------ */

    /// @notice EXT-R-M-1. The transfer to the ledger SUCCEEDS, and `recordAcquired` reverts.
    ///
    /// @dev This is the gap `test_aBlockedLedgerStrandsOneStockWithoutWedgingTheRound` does
    ///      not cover. That test blocks the transfer, so `_deliver` sees `ok == false`, books
    ///      nothing and never calls the ledger. Here the transfer lands — so the engine's
    ///      balance delta says it sent the full amount — but a fee-on-transfer stock means the
    ///      LEDGER received less, and `recordAcquired` reverts `Underfunded` because its own
    ///      balance does not cover `totalOwed + amount`.
    ///
    ///      Before the fix that revert propagated: `settleStock` reverted, so the stock could
    ///      never be settled, `finalizeRound` requires every stock settled and could never
    ///      succeed, `cancelRound` is blocked by the `Buying` state, and `committedQuote`
    ///      stranded permanently. One misbehaving stock wedged every holder in the round.
    ///
    ///      After the fix the booking failure is caught, the round completes, and the tokens
    ///      sitting unbooked at the ledger are recoverable — see the assertions at the end.
    function test_aLedgerThatRefusesToBookDoesNotWedgeTheRound() public {
        (FeeOnTransferToken fot,) = _registerFeeOnTransferStock();

        _fundPot(2_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _chip(basedNouns, basedVault, 2, bob, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(fot)), _one(uint8(100)));
        _setSplit(address(basedNouns), 2, bob, _one(address(nvda)), _one(uint8(100)));

        uint256 id = _openAndAccumulate(_ids(1, 2));

        // THE CALL THAT USED TO REVERT.
        rounds.settleStock(id, address(fot));
        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id); // and this could never be reached at all

        // Nobody was credited for the stock the ledger would not book.
        assertEq(claims.acquired(id, address(fot)), 0, "nothing booked");
        assertEq(claims.totalOwed(address(fot)), 0, "and nothing owed");

        // The tokens are at the LEDGER, unbooked. They are excess by definition, because
        // `totalOwed` never rose, so the existing multisig rescue reaches them and cannot
        // touch anybody's credits on the way.
        uint256 atLedger = fot.balanceOf(address(claims));
        assertGt(atLedger, 0, "the tokens really did arrive");
        assertEq(claims.excess(address(fot)), atLedger, "all of it is recoverable");

        vm.prank(multisig);
        claims.recoverExcess(address(fot), multisig, atLedger);

        // The ledger is drained of the unbooked tokens. The multisig receives 1% less than
        // it asked for, because a token that taxes transfers taxes its own rescue too —
        // worth pinning rather than rounding past, since it is the honest outcome of
        // recovering a hostile asset and the site should not promise otherwise.
        assertEq(fot.balanceOf(address(claims)), 0, "nothing unbooked left at the ledger");
        assertEq(fot.balanceOf(multisig), atLedger - (atLedger / 100), "recovered, minus its own 1% tax");

        // Bob's healthy stock is completely unaffected, which is the whole point.
        _openClaimWindow();
        vm.prank(bob);
        assertGt(claims.claim(id, address(nvda)), 0, "healthy stock still pays out");
        assertEq(nvda.balanceOf(address(claims)), claims.totalOwed(address(nvda)), "still solvent");
    }

    /// @notice And the round's quote-token accounting stays honest through it: the money was
    ///         genuinely spent, so it is reported as spent, not silently returned.
    function test_aRefusedBookingStillReleasesTheCommittedBudget() public {
        (FeeOnTransferToken fot,) = _registerFeeOnTransferStock();

        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(fot)), _one(uint8(100)));

        uint256 id = _openAndAccumulate(_ids(1));
        rounds.settleStock(id, address(fot));
        rounds.finalizeRound(id);

        assertEq(rounds.committedQuote(), 0, "nothing left committed");
        assertGt(rounds.getRound(id).spent, 0, "the quote token was genuinely spent");
        assertEq(uint8(rounds.getRound(id).state), uint8(RoundState.Finalized));
    }

    /// @dev A stock that taxes transfers: the engine's balance falls by the full amount, the
    ///      ledger receives less, and the two disagree. 100 bps is enough to trigger it.
    function _registerFeeOnTransferStock() internal returns (FeeOnTransferToken fot, MockAggregatorV3 feed) {
        fot = new FeeOnTransferToken("Taxed Stock", "TAXc", STOCK_DEC, 100);
        feed = new MockAggregatorV3(8, int256(200 * 1e8), "Coinbase TAX");

        address pool = address(uint160(3000));
        uniFactory.setPool(address(fot), address(usdc), FEE, pool);

        vm.startPrank(multisig);
        registry.addStock(
            StockRegistry.AddStockParams({
                token: address(fot),
                feed: address(feed),
                venue: Venue.UniswapV3,
                pool: pool,
                fee: FEE,
                tickSpacing: 0,
                minLiquidityUsd: 0,
                tokenDecimals: STOCK_DEC
            })
        );
        registry.setEnabled(address(fot), true);
        vm.stopPrank();

        router.setRate(address(usdc), address(fot), 1e8, 200 * 1e6);
        fot.mint(address(router), 1_000_000e8);
    }

    /* ------------------------------------------------------------------ */
    /*                 AN UNPRICEABLE ROUND SAYS SO                         */
    /* ------------------------------------------------------------------ */

    /// @notice EXT-R-I-1. A dead feed at finalize must not silently shrink `totalPaidUsd`.
    ///
    /// @dev The round still finalizes and the credit is untouched — refusing to finalize over
    ///      a reporting number would be the wrong trade. But the omission is now announced,
    ///      so the site can show the round as partially priced instead of quietly reporting
    ///      a smaller number than the holders actually received.
    function test_anUnpriceableStockIsAnnouncedRatherThanSilentlyDropped() public {
        _fundPot(2_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _chip(basedNouns, basedVault, 2, bob, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        _setSplit(address(basedNouns), 2, bob, _one(address(googl)), _one(uint8(100)));

        uint256 id = _openAndAccumulate(_ids(1, 2));
        rounds.settleStock(id, address(nvda));
        rounds.settleStock(id, address(googl));

        uint256 nvdaAcquired = claims.acquired(id, address(nvda));

        // NVDA's feed dies between settlement and finalize.
        nvdaFeed.setRevertOnRead(true);

        vm.expectEmit(true, true, false, true, address(rounds));
        emit ChipRounds.RoundValueUnpriced(id, address(nvda), nvdaAcquired);
        rounds.finalizeRound(id);

        // GOOGL still priced; NVDA omitted from the USD figure but NOT from the credits.
        assertGt(rounds.totalPaidUsd(), 0, "the priceable half still counted");
        assertEq(claims.acquired(id, address(nvda)), nvdaAcquired, "credit unaffected");

        _openClaimWindow();
        vm.prank(alice);
        assertEq(claims.claim(id, address(nvda)), nvdaAcquired, "and fully claimable");
    }
}
