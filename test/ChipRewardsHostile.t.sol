// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChipRewardsBase} from "./ChipRewardsBase.t.sol";
import {ChipRewards} from "../src/ChipRewards.sol";
import {GasBombNoun} from "./mocks/MockNoun.sol";

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

        // The issuer blocks our contract from receiving AAPL.
        aapl.setBlacklisted(address(rewards), true);

        uint256 id = _openAndAccumulate(_ids(1, 2, 3));

        rewards.settleStock(id, address(nvda));
        rewards.settleStock(id, address(googl));
        rewards.settleStock(id, address(aapl)); // must not revert

        assertTrue(rewards.stockSkipped(id, address(aapl)), "AAPL skipped");
        assertEq(rewards.acquired(id, address(aapl)), 0);
        assertEq(rewards.acquired(id, address(nvda)), 5e8, "NVDA bought normally");
        assertEq(rewards.acquired(id, address(googl)), 2.5e8, "GOOGL bought normally");

        rewards.finalizeRound(id); // must not revert
        assertEq(uint8(rewards.getRound(id).state), uint8(ChipRewards.RoundState.Finalized));
        assertEq(pot.available(), 1_000e6, "carol's slice carried back, not lost");

        // Alice and Bob are entirely unaffected.
        vm.prank(alice);
        rewards.claim(id, address(nvda));
        vm.prank(bob);
        rewards.claim(id, address(googl));
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
        rewards.settleStock(id, address(aapl));
        rewards.settleStock(id, address(nvda));
        rewards.finalizeRound(id);

        uint256 aaplOwed = rewards.claimable(id, address(aapl), alice);
        assertGt(aaplOwed, 0);

        // NOW the issuer freezes Alice.
        aapl.setBlacklisted(alice, true);

        // Her AAPL claim fails...
        vm.prank(alice);
        vm.expectRevert(bytes("BLACKLISTED"));
        rewards.claim(id, address(aapl));

        // ...but her NVDA claim from the SAME round works.
        vm.prank(alice);
        uint256 gotNvda = rewards.claim(id, address(nvda));
        assertGt(gotNvda, 0);
        assertEq(nvda.balanceOf(alice), gotNvda);

        // And Bob is completely untouched.
        vm.prank(bob);
        rewards.claim(id, address(nvda));
        assertGt(nvda.balanceOf(bob), 0);

        // Her AAPL credit is still intact and claimable once unfrozen.
        aapl.setBlacklisted(alice, false);
        vm.prank(alice);
        assertEq(rewards.claim(id, address(aapl)), aaplOwed, "nothing was lost while frozen");
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
        rewards.settleStock(id, address(aapl));
        rewards.finalizeRound(id);

        aapl.setBlacklisted(alice, true);

        vm.prank(alice);
        vm.expectRevert(bytes("BLACKLISTED"));
        rewards.claim(id, address(aapl));

        vm.prank(bob);
        uint256 got = rewards.claim(id, address(aapl));
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
        rewards.settleStock(id, address(aapl));
        rewards.settleStock(id, address(nvda));
        rewards.finalizeRound(id);

        aapl.setBlacklisted(alice, true);

        uint256[] memory ids = new uint256[](2);
        ids[0] = id;
        ids[1] = id;
        address[] memory stocks = _two(address(aapl), address(nvda));

        vm.prank(alice);
        vm.expectRevert(bytes("BLACKLISTED"));
        rewards.claimMany(ids, stocks);

        // Falling back to the single call recovers the healthy leg.
        vm.prank(alice);
        assertGt(rewards.claim(id, address(nvda)), 0);
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

        aapl.setBlacklisted(address(rewards), true);

        // Round 1: AAPL is skipped, so nothing is bought for Alice at all.
        uint256 r1 = _openAndAccumulate(_ids(1));
        rewards.settleStock(r1, address(aapl));
        rewards.finalizeRound(r1);
        assertTrue(rewards.stockSkipped(r1, address(aapl)));
        assertEq(rewards.claimable(r1, address(aapl), alice), 0);

        // The multisig switches AAPL off.
        vm.prank(multisig);
        registry.setEnabled(address(aapl), false);

        // Round 2: her slice reroutes to USDC and she earns normally again.
        vm.warp(block.timestamp + 24 hours);
        uint256 r2 = _openAndAccumulate(_ids(1));
        rewards.settleStock(r2, address(usdc));
        rewards.finalizeRound(r2);

        vm.prank(alice);
        uint256 got = rewards.claim(r2, address(usdc));
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
        rewards.settleStock(id, address(aapl));
        rewards.settleStock(id, address(nvda));
        rewards.finalizeRound(id);

        aapl.setBlacklisted(address(rewards), true);
        vm.warp(block.timestamp + 91 days);

        vm.expectRevert(bytes("BLACKLISTED"));
        rewards.sweepExpired(id, address(aapl));

        uint256 swept = rewards.sweepExpired(id, address(nvda));
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
        rewards.setCollectionBaseBps(address(bomb), 10_000);
        vm.stopPrank();

        uint256 id = rewards.openRound();
        rewards.contributeWeights(id, address(bomb), _ids(1, 2, 3)); // survives
        rewards.contributeWeights(id, address(basedNouns), _ids(1));

        assertEq(rewards.weightOf(id, address(usdc), alice), 10_000, "healthy Noun still counted");
    }

    /// @notice A hoodie contract that burns all gas must degrade to "no boost", not revert.
    function test_gasBombHoodieDegradesToNoBoost() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);

        GasBombNoun bomb = new GasBombNoun();
        vm.prank(multisig);
        rewards.setHoodie(address(bomb), 11_000);

        uint256 id = rewards.openRound();
        rewards.contributeWeights(id, address(basedNouns), _ids(1));
        assertEq(rewards.weightOf(id, address(usdc), alice), 10_000, "unboosted, not reverted");
    }

    /// @notice A router that reverts must skip the stock, not kill the round.
    function test_deadRouterSkipsRatherThanReverts() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));

        router.setFailAlways(true);

        uint256 id = _openAndAccumulate(_ids(1));
        rewards.settleStock(id, address(nvda));
        rewards.finalizeRound(id);

        assertTrue(rewards.stockSkipped(id, address(nvda)));
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
        rewards.settleStock(id, address(nvda));
        rewards.settleStock(id, address(googl));
        rewards.finalizeRound(id);

        assertTrue(rewards.stockSkipped(id, address(nvda)));
        assertEq(rewards.acquired(id, address(googl)), 2.5e8);
        assertEq(rewards.totalPaidUsd(), 1_000e18, "only the stock that actually settled");
    }
}
