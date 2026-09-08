// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {FeeSplitter} from "../../src/FeeSplitter.sol";
import {Pot} from "../../src/Pot.sol";
import {StockRegistry} from "../../src/StockRegistry.sol";
import {ChipRounds} from "../../src/ChipRounds.sol";
import {ChipClaims} from "../../src/ChipClaims.sol";
import {Round, RoundState} from "../../src/interfaces/IChipRounds.sol";
import {POLTreasury} from "../../src/POLTreasury.sol";
import {ClaimRouter} from "../../src/ClaimRouter.sol";
import {ClutchVaultAdapter} from "../../src/adapters/ClutchVaultAdapter.sol";
import {Venue} from "../../src/interfaces/IStockRegistry.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/INonfungiblePositionManager.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockNoun} from "../mocks/MockNoun.sol";
import {MockSoftStakingVault} from "../mocks/MockSoftStakingVault.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @title FullSystemForkTest
/// @notice The whole machine on a Base mainnet fork:
///         fees in -> convert -> round -> claims -> expiry sweep -> POL mint -> POL income
///         back to the splitter.
///
/// @dev WHAT IS REAL HERE. USDC, WETH, the Uniswap v3 router and pool, the Chainlink
///      ETH/USD feed, the Aerodrome Slipstream position manager and its WETH/USDC pool, and
///      AERO. The round's stock purchase is a genuine on-chain swap bounded by a genuine
///      Chainlink mark, and the POL position is genuinely minted.
///
///      WHAT IS MOCKED, AND WHY. Exactly one thing: the Clutch soft-staking vault, because
///      Clutch has no Base deployment (ASSUMPTIONS A-1). Everything the vault touches is
///      therefore unverified against reality. That is THE seam.
///
///      WHY WETH STANDS IN FOR A B20 STOCK. The B20 tokens are native precompiles a forked
///      EVM cannot execute (ASSUMPTIONS A-15), so a fork test cannot both use the real
///      token AND trade it in its real pool. WETH is a real ERC-20 with a real Chainlink
///      feed and a deep real pool, so substituting it exercises every line of our buy,
///      credit, claim, sweep and POL path against live infrastructure. What it does NOT
///      exercise is B20's own behaviour: its policy blocklist, its pause, and its dividend
///      multiplier. Those are covered by the hostile-token suites instead.
contract FullSystemForkTest is Test {
    // --- real Base mainnet ---
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address internal constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant AERO_VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;
    address internal constant UNIV3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address internal constant UNIV3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address internal constant SLIPSTREAM_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
    /// @dev The Slipstream router bound to factory A, to match the registry above. NOT the
    ///      factory-B router the B20 stocks need -- this suite's registry is on A, and
    ///      `setRouters` now refuses a router that does not match it.
    address internal constant SLIPSTREAM_ROUTER_A = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;
    address internal constant SLIPSTREAM_NPM = 0x827922686190790b37229fd06084350E74485b72;
    address internal constant WETH_USDC_UNI_500 = 0xd0b53D9277642d899DF5C87A3966A349A798F224;
    address internal constant AERO_USD_FEED = 0x4EC5970fC728C5f65ba413992CD5fF6FD70fcfF0;

    // --- ours ---
    FeeSplitter internal splitter;
    Pot internal pot;
    StockRegistry internal registry;
    ChipRounds internal rounds;
    ChipClaims internal claims;
    POLTreasury internal polTreasury;
    ClaimRouter internal router;
    ClutchVaultAdapter internal adapter;

    // --- mocked: the Clutch seam ---
    MockNoun internal basedNouns;
    MockNoun internal darkNouns;
    MockSoftStakingVault internal basedVault;
    MockSoftStakingVault internal darkVault;
    MockERC20 internal chipToken;

    address internal multisig = makeAddr("multisig");
    address internal ops = makeAddr("ops");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));

        splitter = new FeeSplitter(multisig, multisig, ops, 2_000, 2_000); // pot set below
        pot = new Pot(multisig, USDC, UNIV3_FACTORY);
        registry = new StockRegistry(multisig, USDC, UNIV3_FACTORY, SLIPSTREAM_FACTORY);
        adapter = new ClutchVaultAdapter(multisig, [uint32(10_000), 12_500, 16_000, 20_000, 33_300]);
        claims = new ChipClaims(multisig, address(registry));
        rounds = new ChipRounds(
            multisig,
            address(registry),
            address(pot),
            address(adapter),
            address(claims),
            5_000 ether,
            0x000000000000000000000000000000000000dEaD
        );
        polTreasury = new POLTreasury(multisig, USDC, SLIPSTREAM_NPM, address(splitter), UNIV3_FACTORY, AERO_VOTER);
        router = new ClaimRouter(multisig, address(claims), 1_000_000);

        basedNouns = new MockNoun("Based Nouns", "BASED");
        darkNouns = new MockNoun("DarkNOUNs", "DARK");
        basedVault = new MockSoftStakingVault(IERC721(address(basedNouns)));
        darkVault = new MockSoftStakingVault(IERC721(address(darkNouns)));
        chipToken = new MockERC20("Chipworks", "CHIP", 18);

        vm.startPrank(multisig);
        splitter.setPot(address(pot));
        pot.setRewards(address(rounds));
        claims.setRounds(address(rounds));
        claims.setPolTreasury(address(polTreasury));
        pot.setConversionConfig(WETH, ETH_USD_FEED, UNIV3_ROUTER, 500, 100, 5 ether, 0, 1 hours);

        // WETH stands in for a B20 stock: real feed, real pool, real swap.
        registry.addStock(
            StockRegistry.AddStockParams({
                token: WETH,
                feed: ETH_USD_FEED,
                venue: Venue.UniswapV3,
                pool: WETH_USDC_UNI_500,
                fee: 500,
                tickSpacing: 0,
                minLiquidityUsd: 50_000e18,
                tokenDecimals: 18
            })
        );
        registry.setEnabled(WETH, true);

        adapter.setVault(address(basedNouns), address(basedVault));
        adapter.setVault(address(darkNouns), address(darkVault));

        rounds.setCollectionBaseBps(address(basedNouns), 10_000);
        rounds.setCollectionBaseBps(address(darkNouns), 20_000);
        rounds.setRoundParams(24 hours, 2 hours, 250e6);
        rounds.setRouters(UNIV3_ROUTER, SLIPSTREAM_ROUTER_A);
        rounds.setPolTreasury(address(polTreasury));
        rounds.setChip(address(chipToken));
        rounds.setHoldbackBps(1_500);
        claims.setCreditExpiry(30 days);

        // Item 1: AERO has its own conversion route, so recycled POL income becomes
        // budget a round can actually spend.
        pot.setRoute(AERO, AERO_USD_FEED, UNIV3_ROUTER, 500, 300, 50_000 ether, 0, 24 hours);

        // Item 2: a slice of every inflow goes to POL, so it can pair its stock holdback
        // without depending on expired credits.
        splitter.setPolTreasury(address(polTreasury));
        splitter.setPolShareBps(1_000); // 10%

        // POL realises its own slice into pairable USDC.
        polTreasury.setWeth(WETH);
        polTreasury.setRoute(WETH, ETH_USD_FEED, UNIV3_ROUTER, 500, 100, 50 ether, 0, 1 hours);

        polTreasury.setRewards(address(claims));
        polTreasury.setManager(keeper);
        // A POL asset now carries the feed that bounds every LP operation on it (H-02). The
        // staleness window is disabled HERE ONLY: this suite warps 91 days forward to exercise
        // the expiry sweep, and a forked feed's `updatedAt` stays at the fork block, so any
        // real window would trip on the fixture rather than on anything the protocol did.
        // Launch config sets a real one (LAUNCH_CONFIG), and the check itself is covered by
        // `test_aStalePolFeedRefusesLiquidityOperations`.
        polTreasury.setPolAsset(WETH, ETH_USD_FEED, 1_000, 0);
        polTreasury.setIncomeToken(AERO, true);
        vm.stopPrank();
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory o) {
        o = new uint256[](1);
        o[0] = a;
    }

    function _one(address a) internal pure returns (address[] memory o) {
        o = new address[](1);
        o[0] = a;
    }

    function _one(uint8 a) internal pure returns (uint8[] memory o) {
        o = new uint8[](1);
        o[0] = a;
    }

    /* ================================================================== */
    /*                        THE WHOLE MACHINE                           */
    /* ================================================================== */

    function test_fullSystem_feesInToPolIncomeBackOut() public {
        // ---------------------------------------------------------------
        // 1. Two chipped Nouns. Alice picks WETH; Bob picks nothing, so his
        //    slice routes to USDC.
        // ---------------------------------------------------------------
        basedNouns.mint(alice, 1);
        vm.prank(alice);
        basedVault.activate(1, 0); // tier 0 -> 1.00x, Based 1.0x  => weight 10_000

        darkNouns.mint(bob, 1);
        vm.prank(bob);
        darkVault.activate(1, 0); // tier 0 -> 1.00x, Dark 2.0x    => weight 20_000

        vm.prank(alice);
        rounds.setSplit(address(basedNouns), 1, _one(WETH), _one(uint8(100)));

        // ---------------------------------------------------------------
        // 2. FEES IN. 3 ETH arrives from the LP locker / royalties.
        // ---------------------------------------------------------------
        vm.deal(address(splitter), 3 ether);
        vm.prank(keeper);
        splitter.distributeETH();

        assertEq(address(pot).balance, 2.1 ether, "70% to the pot");
        assertEq(ops.balance, 0.6 ether, "20% to ops");
        assertEq(address(polTreasury).balance, 0.3 ether, "10% to POL");
        assertEq(pot.available(), 0, "un-converted ETH does not count yet");

        // ---------------------------------------------------------------
        // 3. CONVERT. Permissionless, Chainlink-bounded, real Uniswap swap.
        // ---------------------------------------------------------------
        vm.prank(keeper);
        (uint256 ethIn, uint256 usdcOut) = pot.convert();
        assertEq(ethIn, 2.1 ether);
        assertGt(usdcOut, 0);
        assertEq(pot.available(), usdcOut, "now it counts");
        console2.log("converted 2.1 ETH into USDC:", usdcOut / 1e6);

        // ---------------------------------------------------------------
        // 3b. POL realises its own slice into pairable USDC, at the same time.
        //     No expired credit, no manual ops transfer. OPEN_ITEMS item 2.
        // ---------------------------------------------------------------
        {
            assertEq(address(polTreasury).balance, 0.3 ether, "POL got its slice as ETH");
            vm.prank(keeper); // permissionless
            (, uint256 polUsdcFromSlice) = polTreasury.convert(WETH);
            assertGt(polUsdcFromSlice, 0, "and turned it into pairable USDC");
            console2.log("POL self-funded USDC:", polUsdcFromSlice / 1e6);
        }

        // ---------------------------------------------------------------
        // 4. ROUND. Open, accumulate, close, settle, finalize.
        // ---------------------------------------------------------------
        vm.prank(keeper);
        uint256 roundId = rounds.openRound();
        uint256 budget = rounds.getRound(roundId).budget;
        assertEq(budget, usdcOut, "whole pot, under the $10k cap");

        rounds.contributeWeights(roundId, address(basedNouns), _ids(1));
        rounds.contributeWeights(roundId, address(darkNouns), _ids(1));
        assertEq(rounds.getRound(roundId).totalWeight, 30_000, "10k + 20k");

        vm.warp(block.timestamp + 2 hours);
        rounds.closeAccumulation(roundId);

        uint256 polWethBefore = IERC20(WETH).balanceOf(address(polTreasury));
        rounds.settleStock(roundId, WETH); // REAL swap, Chainlink-bounded
        rounds.settleStock(roundId, USDC); // quote slice, no swap
        rounds.finalizeRound(roundId);

        assertFalse(rounds.stockSkipped(roundId, WETH), "the real swap executed");
        uint256 wethAcquired = claims.acquired(roundId, WETH);
        uint256 usdcAcquired = claims.acquired(roundId, USDC);
        assertGt(wethAcquired, 0);
        assertGt(usdcAcquired, 0);
        console2.log("round bought WETH (wei):", wethAcquired);
        console2.log("round credited USDC:", usdcAcquired / 1e6);

        // ---------------------------------------------------------------
        // 5. HOLDBACK. 15% of the WETH purchase went to POL.
        // ---------------------------------------------------------------
        uint256 polWethGained = IERC20(WETH).balanceOf(address(polTreasury)) - polWethBefore;
        assertGt(polWethGained, 0, "POL received its holdback");
        assertApproxEqRel(polWethGained * 85, wethAcquired * 15, 1e15, "15/85 split");
        console2.log("POL holdback WETH (wei):", polWethGained);

        // Solvency: the contract holds exactly what it owes.
        assertEq(IERC20(WETH).balanceOf(address(claims)), claims.totalOwed(WETH), "WETH solvent");
        assertEq(IERC20(USDC).balanceOf(address(claims)), claims.totalOwed(USDC), "USDC solvent");

        // ---------------------------------------------------------------
        // 6. CLAIMS, through the router. One leg now: the Clutch leg is gone
        //    (CLUTCH_RECON section 4), and activation is a burned cost rather
        //    than a second reward stream, so there is no second side to claim.
        // ---------------------------------------------------------------
        ClaimRouter.ChipClaim[] memory chipClaims = new ClaimRouter.ChipClaim[](1);
        chipClaims[0] = ClaimRouter.ChipClaim({roundId: roundId, stock: WETH});

        vm.prank(alice);
        uint256 chipOk = router.claimEverything(chipClaims);

        assertEq(chipOk, 1, "stock claimed");
        assertEq(IERC20(WETH).balanceOf(alice), wethAcquired, "alice has her WETH");
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "router keeps nothing");

        // ---------------------------------------------------------------
        // 6c. POL income recycles and becomes spendable round budget.
        //     AERO is injected, not earned: accrual is Aerodrome's job, the
        //     routing is ours. OPEN_ITEMS item 1.
        // ---------------------------------------------------------------
        {
            deal(AERO, address(polTreasury), 1_000 ether);
            polTreasury.forwardIncome(AERO); // permissionless
            assertEq(IERC20(AERO).balanceOf(address(splitter)), 1_000 ether, "income reached the splitter");

            splitter.distributeToken(IERC20(AERO)); // permissionless
            assertEq(IERC20(AERO).balanceOf(address(pot)), 700 ether, "70% back to the pot");
            assertEq(IERC20(AERO).balanceOf(ops), 200 ether, "20% to ops");
            assertEq(IERC20(AERO).balanceOf(address(polTreasury)), 100 ether, "10% compounds into POL");

            uint256 beforeAeroConvert = pot.available();
            vm.prank(keeper);
            (, uint256 aeroUsdc) = pot.convert(AERO);
            assertEq(pot.available(), beforeAeroConvert + aeroUsdc, "POL income is now spendable budget");
            assertEq(IERC20(AERO).balanceOf(address(pot)), 0);
            console2.log("AERO recycled and converted into USDC:", aeroUsdc / 1e6);
        }

        // ---------------------------------------------------------------
        // 7. EXPIRY SWEEP. Bob never claims; after 90 days it goes to POL.
        // ---------------------------------------------------------------
        vm.warp(block.timestamp + 91 days);
        {
            uint256 polUsdcBefore = IERC20(USDC).balanceOf(address(polTreasury));
            uint256 swept = claims.sweepExpired(roundId, USDC);
            assertEq(swept, usdcAcquired, "bob's whole unclaimed credit");
            assertEq(IERC20(USDC).balanceOf(address(polTreasury)) - polUsdcBefore, swept);
            assertEq(claims.totalOwed(USDC), 0);
            console2.log("expired to POL, USDC:", swept / 1e6);
        }

        // ---------------------------------------------------------------
        // 8. POL MINT. A real Slipstream WETH/USDC position.
        // ---------------------------------------------------------------
        uint256 polWeth = IERC20(WETH).balanceOf(address(polTreasury));
        uint256 polUsdc = IERC20(USDC).balanceOf(address(polTreasury));
        assertGt(polWeth, 0);
        assertGt(polUsdc, 0);

        vm.prank(keeper); // the Bankr optimizer role
        (uint256 posId,,,) = polTreasury.mintPosition(
            INonfungiblePositionManager.MintParams({
                token0: WETH, // WETH < USDC
                token1: USDC,
                tickSpacing: 100,
                tickLower: -887200,
                tickUpper: 887200,
                amount0Desired: polWeth,
                amount1Desired: polUsdc,
                amount0Min: 1, // blank minimums are refused since batch 6 (H-02)
                amount1Min: 1,
                recipient: address(polTreasury),
                deadline: block.timestamp + 1,
                sqrtPriceX96: 0
            })
        );
        assertEq(INonfungiblePositionManager(SLIPSTREAM_NPM).ownerOf(posId), address(polTreasury));
        assertEq(polTreasury.positionCount(), 1);
        console2.log("POL position id:", posId);

        // Collecting is permissionless and must work against the real position.
        polTreasury.collectFees(posId);

        // ---------------------------------------------------------------
        // 10. And that recycled budget genuinely funds another round.
        // ---------------------------------------------------------------
        vm.warp(block.timestamp + 24 hours);
        vm.prank(keeper);
        uint256 round2 = rounds.openRound();
        assertGt(rounds.getRound(round2).budget, 0, "POL income became a real round budget");
        console2.log("next round budget, USDC:", rounds.getRound(round2).budget / 1e6);
    }

    /* ================================================================== */
    /*                     A SECOND ROUND ON THE CARRY                     */
    /* ================================================================== */

    /// @notice Money a round could not spend must survive into the next one.
    function test_carriedBudgetFundsTheNextRound() public {
        basedNouns.mint(alice, 1);
        vm.prank(alice);
        basedVault.activate(1, 0);
        vm.prank(alice);
        rounds.setSplit(address(basedNouns), 1, _one(WETH), _one(uint8(100)));

        vm.deal(address(splitter), 3 ether);
        splitter.distributeETH();
        pot.convert();

        // Round 1 with an unreachable Chainlink mark: the buy must skip and carry.
        //
        // A TIGHT SLIPPAGE BOUND IS NOT ENOUGH, AND THIS TEST USED TO ASSUME IT WAS. The
        // original version set maxSlippageBps to 1 on the theory that a 0.01% tolerance
        // cannot survive a 0.05% pool fee. It can: when Uniswap spot happens to sit a few
        // bps better than the Chainlink mark, the pool price absorbs the fee and the swap
        // clears the bound. That is exactly what live prices did on 2026-09-02, filling at
        // 0.146 bps off the mark against a 1 bps bound, and the assertion failed on a
        // healthy contract.
        //
        // These fork tests run against the LATEST block, so any threshold derived from a
        // guess about the live spread is a time bomb. Point the stock at a feed marking ETH
        // at a THIRD of its real price instead. The round is buying WETH with USDC, so the
        // expected output is `quoteIn / price`: understating the price triples the WETH the
        // bound demands, `minOut` lands about 3x above anything the pool can deliver, and
        // the skip is guaranteed by arithmetic rather than by market conditions.
        (, int256 livePrice,,,) = IAggregatorV3(ETH_USD_FEED).latestRoundData();
        MockAggregatorV3 cheapFeed = new MockAggregatorV3(8, livePrice / 3, "ETH / USD, third");
        vm.prank(multisig);
        registry.setFeed(WETH, address(cheapFeed));

        uint256 r1 = rounds.openRound();
        uint256 budget = rounds.getRound(r1).budget;
        rounds.contributeWeights(r1, address(basedNouns), _ids(1));
        vm.warp(block.timestamp + 2 hours);
        rounds.closeAccumulation(r1);
        rounds.settleStock(r1, WETH);
        rounds.finalizeRound(r1);

        assertTrue(rounds.stockSkipped(r1, WETH), "impossible bound -> skipped");
        assertEq(pot.available(), budget, "every cent carried back");

        // Round 2 against the real feed spends it.
        vm.prank(multisig);
        registry.setFeed(WETH, ETH_USD_FEED);
        vm.warp(block.timestamp + 24 hours);

        uint256 r2 = rounds.openRound();
        rounds.contributeWeights(r2, address(basedNouns), _ids(1));
        vm.warp(block.timestamp + 2 hours);
        rounds.closeAccumulation(r2);
        rounds.settleStock(r2, WETH);
        rounds.finalizeRound(r2);

        assertFalse(rounds.stockSkipped(r2, WETH));
        assertGt(claims.acquired(r2, WETH), 0, "the carried budget bought stock");
    }

    /// @notice The registry depth gate against a real pool.
    function test_depthGateUsesRealPoolLiquidity() public view {
        uint256 measured = registry.poolLiquidityUsd(WETH);
        assertGt(measured, 50_000e18, "the real WETH/USDC pool clears the $50k bar");
        assertTrue(registry.clearsMinLiquidity(WETH));
        console2.log("WETH/USDC 0.05% pool depth, USD:", measured / 1e18);
    }
}
