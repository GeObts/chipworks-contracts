// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {ChipRounds} from "../src/ChipRounds.sol";
import {ChipClaims} from "../src/ChipClaims.sol";
import {Pot} from "../src/Pot.sol";
import {StockRegistry} from "../src/StockRegistry.sol";
import {ChipActivation} from "../src/activation/ChipActivation.sol";
import {NounLoans} from "../src/loans/NounLoans.sol";
import {Furnace} from "../src/furnace/Furnace.sol";
import {Venue} from "../src/interfaces/IStockRegistry.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockNoun} from "./mocks/MockNoun.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockUniswapV3Factory, MockSlipstreamFactory} from "./mocks/MockFactories.sol";

/// @title DeployOrderTest
/// @notice A HALF-WIRED DEPLOYMENT CANNOT TAKE ANYONE'S MONEY.
///
/// @dev DEPLOY.md's master sequence claims this per step. This file is the proof, so the
///      claim cannot quietly stop being true.
///
///      The realistic bad day is not a malicious deployer, it is an interrupted one: nine
///      contracts, a dozen wiring calls, a multisig with several signers and a two-day
///      timelock in the middle of it. Somebody gets distracted between transactions. The
///      question that matters is whether the partially-built system can accept a user's
///      funds in a state where it cannot pay them back.
///
///      Every check below is written the way an operator would run it — try the thing that
///      should not work yet, and confirm it does not. Each maps to a line in DEPLOY.md's
///      "half-wired cannot take money" block.
contract DeployOrderTest is Test {
    address internal multisig = makeAddr("multisig");
    address internal alice = makeAddr("alice");
    address internal ops = makeAddr("ops");
    address internal treasury = makeAddr("treasury");

    MockERC20 internal usdc;
    MockERC20 internal chip;
    MockNoun internal based;
    MockNoun internal lil;
    MockAggregatorV3 internal feed;
    MockUniswapV3Factory internal uniFactory;
    MockSlipstreamFactory internal slipFactory;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        chip = new MockERC20("Chipworks", "CHIP", 18);
        based = new MockNoun("Based Nouns", "BASED");
        lil = new MockNoun("Lil Based Nouns", "LIL");
        feed = new MockAggregatorV3(8, 200e8, "Coinbase NVDA");
        uniFactory = new MockUniswapV3Factory();
        slipFactory = new MockSlipstreamFactory();

        chip.mint(alice, 1_000_000 ether);
    }

    /* ------------------------------------------------------------------ */
    /*        STEP 2 — a stock with no feed cannot be enabled              */
    /* ------------------------------------------------------------------ */

    /// @notice A stock is registered disabled and stays that way until it has BOTH a feed
    ///         and a verified pool. Registering must be inert, not a loaded gun.
    /// @dev At launch the four extra tickers (CRCL, INTC, SNDK, SPCX) are registered with
    ///      their feeds but no market, so `PoolNotSet` is what actually holds them back.
    ///      Both halves of the gate are checked here because either one alone is enough.
    function test_step2_aStockCannotBeEnabledWithoutBothAFeedAndAPool() public {
        StockRegistry registry = new StockRegistry(multisig, address(usdc), address(uniFactory), address(slipFactory));
        MockERC20 crcl = new MockERC20("Circle", "CRCLc", 8);

        vm.prank(multisig);
        registry.addStock(
            StockRegistry.AddStockParams({
                token: address(crcl),
                feed: address(0), // no Chainlink feed published for this ticker
                venue: Venue.None,
                pool: address(0),
                fee: 0,
                tickSpacing: 0,
                minLiquidityUsd: 0,
                tokenDecimals: 8
            })
        );

        assertTrue(registry.getStock(address(crcl)).registered);
        assertEq(registry.getStock(address(crcl)).feed, address(0));

        // No feed: not even the owner can switch it on.
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(StockRegistry.FeedNotSet.selector, address(crcl)));
        registry.setEnabled(address(crcl), true);

        // Give it a real feed. Still refused, because there is no market to buy in — this is
        // the state the four extra tickers actually ship in.
        vm.prank(multisig);
        registry.setFeed(address(crcl), address(feed));
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(StockRegistry.PoolNotSet.selector, address(crcl)));
        registry.setEnabled(address(crcl), true);

        assertEq(registry.enabledTokens().length, 0, "still nothing enabled");
    }

    /* ------------------------------------------------------------------ */
    /*        STEP 3 — the Pot will not release a budget to nobody         */
    /* ------------------------------------------------------------------ */

    function test_step3_thePotRefusesToFundAnUnwiredEngine() public {
        Pot pot = new Pot(multisig, address(usdc));
        usdc.mint(address(pot), 10_000e6);

        // `rewards` is unset, so nobody is authorised to pull.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Pot.NotRewards.selector, alice));
        pot.pullBudget(1_000e6);

        assertEq(usdc.balanceOf(address(pot)), 10_000e6, "the pot is untouched");
    }

    /* ------------------------------------------------------------------ */
    /*   STEP 4 — an unpriced collection cannot be activated by anyone     */
    /* ------------------------------------------------------------------ */

    function test_step4_anUnpricedCollectionCannotBeActivated() public {
        ChipActivation act =
            new ChipActivation(multisig, address(chip), [uint32(10_000), 12_500, 16_000, 20_000, 33_300]);

        based.mint(alice, 1);
        vm.startPrank(alice);
        chip.approve(address(act), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(ChipActivation.CollectionNotConfigured.selector, address(based)));
        act.activate(address(based), 1, 0);
        vm.stopPrank();

        assertFalse(act.isSupportedCollection(address(based)));
        assertEq(chip.balanceOf(alice), 1_000_000 ether, "not a wei was taken");
    }

    /// @notice And queueing alone is not enough — the 48h execute is what makes it live.
    function test_step4_queueingWithoutExecutingLeavesItClosed() public {
        ChipActivation act =
            new ChipActivation(multisig, address(chip), [uint32(10_000), 12_500, 16_000, 20_000, 33_300]);

        vm.prank(multisig);
        act.queueCosts(address(based), [uint256(1 ether), 2 ether, 3 ether, 4 ether, 5 ether]);

        based.mint(alice, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ChipActivation.CollectionNotConfigured.selector, address(based)));
        act.activate(address(based), 1, 0);
    }

    /* ------------------------------------------------------------------ */
    /*   STEP 5 — THE IMPORTANT ONE: the ledger rejects an unknown engine  */
    /* ------------------------------------------------------------------ */

    /// @notice Before `claims.setRounds(rounds)`, a round cannot book a single weight — so it
    ///         cannot take anyone's Noun into a round it would then be unable to pay out of.
    function test_step5_aRoundCannotBookWeightBeforeTheLedgerKnowsTheEngine() public {
        (ChipRounds rounds, ChipClaims claims, Pot pot, ChipActivation act) = _stackWithoutSetRounds();

        // The engine is otherwise fully wired: the Pot funds it, the collection is priced.
        usdc.mint(address(pot), 1_000e6);
        based.mint(alice, 1);
        vm.startPrank(alice);
        chip.approve(address(act), type(uint256).max);
        act.activate(address(based), 1, 0);
        vm.stopPrank();

        uint256 id = rounds.openRound();

        // And it still cannot write a credit.
        vm.expectRevert(abi.encodeWithSelector(ChipClaims.NotRounds.selector, address(rounds)));
        rounds.contributeWeights(id, address(based), _ids(1));

        assertEq(claims.totalWeight(id, address(usdc)), 0, "nothing was booked");

        // One wiring call, and the same round works.
        vm.prank(multisig);
        claims.setRounds(address(rounds));
        rounds.contributeWeights(id, address(based), _ids(1));
        assertGt(rounds.getRound(id).totalWeight, 0);
    }

    /* ------------------------------------------------------------------ */
    /*        STEP 8 — a Furnace with no stock cannot consume a Lil        */
    /* ------------------------------------------------------------------ */

    /// @notice Stock is checked BEFORE inputs are burned, so a doomed forge burns nothing.
    function test_step8_anEmptyFurnaceBurnsNothing() public {
        Furnace furnace = new Furnace(
            multisig,
            address(chip),
            address(lil),
            Furnace.Recipe({
                exists: true, paused: false, outputCollection: address(based), lilCost: 3, chipCost: 1 ether
            }),
            Furnace.Recipe({
                    exists: true, paused: false, outputCollection: address(based), lilCost: 5, chipCost: 2 ether
                })
        );

        for (uint256 i = 1; i <= 3; ++i) {
            lil.mint(alice, i);
        }
        vm.startPrank(alice);
        lil.setApprovalForAll(address(furnace), true);
        chip.approve(address(furnace), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(Furnace.OutOfStock.selector, uint8(0), address(based)));
        furnace.forge(0, _ids(1, 2, 3));
        vm.stopPrank();

        assertEq(lil.ownerOf(1), alice, "the Lils are still hers");
        assertEq(chip.balanceOf(alice), 1_000_000 ether, "and not a wei of $CHIP burned");
    }

    /* ------------------------------------------------------------------ */
    /*   STEP 9 — a loan vault with no cap and no pool takes no collateral */
    /* ------------------------------------------------------------------ */

    /// @notice Collateral is pulled AFTER both checks, so a Noun is never locked against a
    ///         loan the pool cannot fund.
    function test_step9_anUnfundedLoanVaultNeverTakesCollateral() public {
        NounLoans.Terms memory t;
        t.length = [uint64(30 days), 90 days, 180 days];
        t.feeBps = [uint32(200), 500, 900];
        t.bountyBps = 200;
        NounLoans loans = new NounLoans(multisig, address(chip), makeAddr("splitter"), treasury, t);

        based.mint(alice, 1);
        vm.startPrank(alice);
        based.approve(address(loans), 1);

        // No cap set: the collection is not lendable at all.
        vm.expectRevert(abi.encodeWithSelector(NounLoans.CollectionNotLendable.selector, address(based)));
        loans.borrow(address(based), 1, 0, 1_000 ether);
        vm.stopPrank();

        // Cap set, pool still empty.
        vm.prank(multisig);
        loans.setMaxPrincipal(address(based), 10_000 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NounLoans.PoolTooSmall.selector, 1_000 ether, 0));
        loans.borrow(address(based), 1, 0, 1_000 ether);

        assertEq(based.ownerOf(1), alice, "her Noun never moved");
        assertEq(loans.openLoanCount(), 0);
    }

    /* ------------------------------------------------------------------ */
    /*     THE ONE THAT FAILS SILENTLY, AND SO NEEDS CHECKING BY HAND      */
    /* ------------------------------------------------------------------ */

    /// @notice Forgetting `ChipActivation.setCustodian(nounLoans, true)` is the only wiring
    ///         mistake in the sequence that does NOT revert. Loans keep working; borrowers
    ///         simply stop earning the moment they deposit, exactly as if they had sold.
    ///
    ///         There is no error to catch it, which is why DEPLOY.md asks for it to be
    ///         checked explicitly and why this test exists — to state the failure mode
    ///         rather than to guard it.
    function test_theCustodianWireIsTheOneMistakeThatFailsSilently() public {
        (ChipRounds rounds, ChipClaims claims, Pot pot, ChipActivation act) = _stackWithoutSetRounds();
        vm.prank(multisig);
        claims.setRounds(address(rounds));

        NounLoans.Terms memory t;
        t.length = [uint64(30 days), 90 days, 180 days];
        t.feeBps = [uint32(200), 500, 900];
        t.bountyBps = 200;
        NounLoans loans = new NounLoans(multisig, address(chip), makeAddr("splitter"), treasury, t);

        chip.mint(multisig, 100_000 ether);
        vm.startPrank(multisig);
        loans.setMaxPrincipal(address(based), 10_000 ether);
        chip.approve(address(loans), 100_000 ether);
        loans.depositPool(100_000 ether);
        vm.stopPrank();

        based.mint(alice, 1);
        vm.startPrank(alice);
        chip.approve(address(act), type(uint256).max);
        act.activate(address(based), 1, 3);
        based.approve(address(loans), 1);
        loans.borrow(address(based), 1, 0, 1_000 ether);
        vm.stopPrank();

        // The loan worked. Nothing reverted. And the borrower is earning nothing.
        assertEq(loans.openLoanCount(), 1, "the loan is live");
        assertFalse(act.isCustodian(address(loans)), "the wire was forgotten");
        assertFalse(act.isActive(address(based), 1), "and she silently stopped earning");

        usdc.mint(address(pot), 1_000e6);
        uint256 id = rounds.openRound();
        rounds.contributeWeights(id, address(based), _ids(1));
        assertEq(rounds.getRound(id).totalWeight, 0, "no weight, no revert, no clue");

        // The fix is one call, needs no user action, and is retroactive.
        vm.prank(multisig);
        act.setCustodian(address(loans), true);
        assertTrue(act.isActive(address(based), 1), "and everything is back");
    }

    /* ------------------------------------------------------------------ */
    /*                              fixtures                               */
    /* ------------------------------------------------------------------ */

    /// @dev A stack wired in the documented order but stopping short of
    ///      `claims.setRounds(rounds)` — the state an interrupted deploy lands in.
    function _stackWithoutSetRounds()
        internal
        returns (ChipRounds rounds, ChipClaims claims, Pot pot, ChipActivation act)
    {
        StockRegistry registry = new StockRegistry(multisig, address(usdc), address(uniFactory), address(slipFactory));
        pot = new Pot(multisig, address(usdc));
        act = new ChipActivation(multisig, address(chip), [uint32(10_000), 12_500, 16_000, 20_000, 33_300]);
        claims = new ChipClaims(multisig, address(registry));
        rounds = new ChipRounds(multisig, address(registry), address(pot), address(act), address(claims), 5_000 ether);

        vm.startPrank(multisig);
        act.queueCosts(address(based), [uint256(0), 0, 0, 0, 0]);
        vm.warp(block.timestamp + 48 hours);
        act.executeCosts(address(based));

        pot.setRewards(address(rounds));
        rounds.setCollectionBaseBps(address(based), 10_000);
        rounds.setRoundParams(24 hours, 2 hours, 250e6, 10_000e6);
        // deliberately NOT claims.setRounds(address(rounds))
        vm.stopPrank();
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = a;
    }

    function _ids(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory out) {
        out = new uint256[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }
}
