// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {StockRegistry} from "../src/StockRegistry.sol";
import {IStockRegistry, Stock, Venue} from "../src/interfaces/IStockRegistry.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockUniswapV3Factory, MockSlipstreamFactory} from "./mocks/MockFactories.sol";

import {MockDepthQuoter, MockDepthPool} from "test/mocks/MockDepthQuoter.sol";

contract StockRegistryTest is Test {
    MockDepthQuoter internal quoter;
    StockRegistry internal registry;

    address internal multisig = makeAddr("multisig");
    address internal randomer = makeAddr("randomer");

    MockERC20 internal usdc;
    MockERC20 internal nvda;
    MockERC20 internal googl;
    MockAggregatorV3 internal nvdaFeed;
    MockAggregatorV3 internal googlFeed;
    MockUniswapV3Factory internal uniFactory;
    MockSlipstreamFactory internal slipFactory;

    address internal nvdaPool = makeAddr("nvdaPool");
    address internal googlPool = makeAddr("googlPool");
    address internal nvdaSlipPool = makeAddr("nvdaSlipPool");

    uint24 internal constant FEE_030 = 3000;
    uint24 internal constant FEE_100 = 10000;
    int24 internal constant TICK_100 = 100;

    // 8-decimal stock tokens, 6-decimal quote, 8-decimal feeds: the real Base shapes.
    uint8 internal constant STOCK_DECIMALS = 8;

    event StockAdded(address indexed token, address indexed feed, uint128 minLiquidityUsd);
    event VenueUpdated(address indexed token, Venue venue, address indexed pool, uint24 fee, int24 tickSpacing);
    event EnabledUpdated(address indexed token, bool enabled);
    event MinLiquidityUpdated(address indexed token, uint128 previousMin, uint128 newMin);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        nvda = new MockERC20("NVIDIA Corporation", "NVDAc", STOCK_DECIMALS);
        googl = new MockERC20("Alphabet Inc.", "GOOGLc", STOCK_DECIMALS);

        nvdaFeed = new MockAggregatorV3(8, 180e8, "NVDAc / USD");
        googlFeed = new MockAggregatorV3(8, 250e8, "GOOGLc / USD");

        uniFactory = new MockUniswapV3Factory();
        slipFactory = new MockSlipstreamFactory();

        uniFactory.setPool(address(nvda), address(usdc), FEE_030, nvdaPool);
        uniFactory.setPool(address(googl), address(usdc), FEE_100, googlPool);
        slipFactory.setPool(address(nvda), address(usdc), TICK_100, nvdaSlipPool);

        registry = new StockRegistry(multisig, address(usdc), address(uniFactory), address(slipFactory));
        quoter = new MockDepthQuoter(address(uniFactory));
        vm.etch(nvdaPool, address(new MockDepthPool()).code);
        vm.etch(googlPool, address(new MockDepthPool()).code);
        quoter.setQuote(address(nvda), 10_330.8e6, 1e8, 180e6);
        quoter.setQuote(address(googl), 10_330.8e6, 1e8, 250e6);
    }

    /* ----------------------------- helpers ----------------------------- */

    function _addNvda(uint128 minLiquidityUsd) internal {
        vm.prank(multisig);
        registry.addStock(
            StockRegistry.AddStockParams({
                token: address(nvda),
                feed: address(nvdaFeed),
                venue: Venue.UniswapV3,
                pool: nvdaPool,
                fee: FEE_030,
                tickSpacing: 0,
                minLiquidityUsd: minLiquidityUsd,
                tokenDecimals: STOCK_DECIMALS
            })
        );
    }

    function _configureDepth(address token, uint128 amount) internal {
        vm.prank(multisig);
        registry.setDepthConfig(token, address(quoter), amount, 200, 120 hours);
    }

    /// @notice Seed balances and independently configure executable probe capacity.
    function _fundNvdaPool() internal {
        nvda.mint(nvdaPool, 16.06e8);
        usdc.mint(nvdaPool, 7_440e6);
        MockDepthPool(nvdaPool).setLiquidity(1e18);
        _configureDepth(address(nvda), 10_330.8e6);
    }

    /* ------------------------------------------------------------------ */
    /*                           CONSTRUCTOR                                */
    /* ------------------------------------------------------------------ */

    function test_constructor_setsState() public view {
        assertEq(registry.owner(), multisig);
        assertEq(registry.quoteToken(), address(usdc));
        assertEq(registry.quoteDecimals(), 6);
        assertEq(registry.uniswapV3Factory(), address(uniFactory));
        assertEq(registry.slipstreamFactory(), address(slipFactory));
        assertEq(registry.stockCount(), 0);
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(StockRegistry.ZeroAddress.selector);
        new StockRegistry(multisig, address(0), address(uniFactory), address(slipFactory));

        vm.expectRevert(StockRegistry.ZeroAddress.selector);
        new StockRegistry(multisig, address(usdc), address(0), address(slipFactory));

        vm.expectRevert(StockRegistry.ZeroAddress.selector);
        new StockRegistry(multisig, address(usdc), address(uniFactory), address(0));
    }

    /* ------------------------------------------------------------------ */
    /*                            ADD STOCK                                 */
    /* ------------------------------------------------------------------ */

    function test_addStock_storesEverythingAndStartsDisabled() public {
        _addNvda(1_000e18);

        Stock memory s = registry.getStock(address(nvda));
        assertTrue(s.registered, "registered");
        assertFalse(s.enabled, "must start disabled");
        assertEq(uint8(s.venue), uint8(Venue.UniswapV3));
        assertEq(s.pool, nvdaPool);
        assertEq(s.fee, FEE_030);
        assertEq(s.tickSpacing, 0);
        assertEq(s.feed, address(nvdaFeed));
        assertEq(s.tokenDecimals, STOCK_DECIMALS);
        assertEq(s.feedDecimals, 8);
        assertEq(s.minLiquidityUsd, 1_000e18);

        assertEq(registry.stockCount(), 1);
        assertEq(registry.tokenAt(0), address(nvda));
        assertTrue(registry.isRegistered(address(nvda)));
        assertFalse(registry.isEnabled(address(nvda)));
    }

    function test_addStock_onlyMultisig() public {
        vm.prank(randomer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, randomer));
        registry.addStock(
            StockRegistry.AddStockParams({
                token: address(nvda),
                feed: address(nvdaFeed),
                venue: Venue.UniswapV3,
                pool: nvdaPool,
                fee: FEE_030,
                tickSpacing: 0,
                minLiquidityUsd: 0,
                tokenDecimals: STOCK_DECIMALS
            })
        );
    }

    function test_addStock_rejectsDuplicate() public {
        _addNvda(0);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(StockRegistry.AlreadyRegistered.selector, address(nvda)));
        registry.addStock(
            StockRegistry.AddStockParams({
                token: address(nvda),
                feed: address(nvdaFeed),
                venue: Venue.UniswapV3,
                pool: nvdaPool,
                fee: FEE_030,
                tickSpacing: 0,
                minLiquidityUsd: 0,
                tokenDecimals: STOCK_DECIMALS
            })
        );
    }

    function test_addStock_rejectsZeroToken() public {
        vm.prank(multisig);
        vm.expectRevert(StockRegistry.ZeroAddress.selector);
        registry.addStock(
            StockRegistry.AddStockParams({
                token: address(0),
                feed: address(nvdaFeed),
                venue: Venue.None,
                pool: address(0),
                fee: 0,
                tickSpacing: 0,
                minLiquidityUsd: 0,
                tokenDecimals: STOCK_DECIMALS
            })
        );
    }

    function test_addStock_rejectsWrongDecimals() public {
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(StockRegistry.DecimalsMismatch.selector, address(nvda), 18, 8));
        registry.addStock(
            StockRegistry.AddStockParams({
                token: address(nvda),
                feed: address(nvdaFeed),
                venue: Venue.None,
                pool: address(0),
                fee: 0,
                tickSpacing: 0,
                minLiquidityUsd: 0,
                tokenDecimals: 18
            })
        );
    }

    /// @notice TSLA, AMZN, MSFT, COIN and MSTR have no pool on Base today. They must still
    ///         be registerable now and enableable later without a redeploy.
    function test_addStock_worksWithNoPoolAndNoFeedYet() public {
        MockERC20 tsla = new MockERC20("Tesla Inc.", "TSLAc", STOCK_DECIMALS);

        vm.prank(multisig);
        registry.addStock(
            StockRegistry.AddStockParams({
                token: address(tsla),
                feed: address(0),
                venue: Venue.None,
                pool: address(0),
                fee: 0,
                tickSpacing: 0,
                minLiquidityUsd: 25_000e18,
                tokenDecimals: STOCK_DECIMALS
            })
        );

        Stock memory s = registry.getStock(address(tsla));
        assertTrue(s.registered);
        assertFalse(s.enabled);
        assertEq(s.pool, address(0));
        assertEq(s.feed, address(0));
        assertEq(uint8(s.venue), uint8(Venue.None));
        assertEq(s.minLiquidityUsd, 25_000e18);
        assertFalse(registry.clearsMinLiquidity(address(tsla)), "cannot clear without a pool");
    }

    /* ------------------------------------------------------------------ */
    /*                        VENUE VERIFICATION                            */
    /* ------------------------------------------------------------------ */

    function test_setVenue_rejectsPoolTheFactoryDoesNotKnow() public {
        _addNvda(0);
        address fatFinger = makeAddr("fatFinger");

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(StockRegistry.PoolNotFoundInFactory.selector, address(nvda), fatFinger));
        registry.setVenue(address(nvda), Venue.UniswapV3, fatFinger, FEE_030, 0);
    }

    function test_setVenue_rejectsRightPoolWrongFeeTier() public {
        _addNvda(0);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(StockRegistry.PoolNotFoundInFactory.selector, address(nvda), nvdaPool));
        registry.setVenue(address(nvda), Venue.UniswapV3, nvdaPool, FEE_100, 0);
    }

    function test_setVenue_rejectsUniswapPoolClaimedAsSlipstream() public {
        _addNvda(0);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(StockRegistry.PoolNotFoundInFactory.selector, address(nvda), nvdaPool));
        registry.setVenue(address(nvda), Venue.Slipstream, nvdaPool, 0, TICK_100);
    }

    function test_setVenue_rejectsZeroFeeAndZeroTickSpacing() public {
        _addNvda(0);
        vm.prank(multisig);
        vm.expectRevert(StockRegistry.InvalidVenue.selector);
        registry.setVenue(address(nvda), Venue.UniswapV3, nvdaPool, 0, 0);

        vm.prank(multisig);
        vm.expectRevert(StockRegistry.InvalidVenue.selector);
        registry.setVenue(address(nvda), Venue.Slipstream, nvdaSlipPool, 0, 0);
    }

    function test_setVenue_rejectsNoneVenueWithAPool() public {
        _addNvda(0);
        vm.prank(multisig);
        vm.expectRevert(StockRegistry.InvalidVenue.selector);
        registry.setVenue(address(nvda), Venue.None, nvdaPool, 0, 0);
    }

    /// @notice The whole point of storing venue per stock: migrate without redeploying.
    function test_setVenue_canMigrateFromUniswapToSlipstream() public {
        _addNvda(0);

        vm.prank(multisig);
        registry.setVenue(address(nvda), Venue.Slipstream, nvdaSlipPool, 0, TICK_100);

        Stock memory s = registry.getStock(address(nvda));
        assertEq(uint8(s.venue), uint8(Venue.Slipstream));
        assertEq(s.pool, nvdaSlipPool);
        assertEq(s.tickSpacing, TICK_100);
        assertEq(s.fee, 0, "stale fee cleared");
    }

    /// @notice Changing venue invalidates the depth that justified enabling, so the flag
    ///         must drop and require a fresh, explicit decision.
    function test_setVenue_disablesAnEnabledStock() public {
        _addNvda(1_000e18);
        _fundNvdaPool();
        vm.prank(multisig);
        registry.setEnabled(address(nvda), true);
        assertTrue(registry.isEnabled(address(nvda)));

        vm.expectEmit(true, false, false, true, address(registry));
        emit EnabledUpdated(address(nvda), false);
        vm.prank(multisig);
        registry.setVenue(address(nvda), Venue.Slipstream, nvdaSlipPool, 0, TICK_100);

        assertFalse(registry.isEnabled(address(nvda)), "must re-enable deliberately");
    }

    function test_setVenue_onlyMultisig() public {
        _addNvda(0);
        vm.prank(randomer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, randomer));
        registry.setVenue(address(nvda), Venue.Slipstream, nvdaSlipPool, 0, TICK_100);
    }

    function test_setVenue_revertsForUnregisteredToken() public {
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(StockRegistry.NotRegistered.selector, address(googl)));
        registry.setVenue(address(googl), Venue.UniswapV3, googlPool, FEE_100, 0);
    }

    /* ------------------------------------------------------------------ */
    /*                          PRICE AND DEPTH                             */
    /* ------------------------------------------------------------------ */

    function test_priceUsd_scalesFeedTo18Decimals() public {
        _addNvda(0);
        (uint256 price, uint256 updatedAt) = registry.priceUsd(address(nvda));
        assertEq(price, 180e18, "$180 as 1e18");
        assertEq(updatedAt, block.timestamp);
    }

    function test_priceUsd_revertsOnNonPositiveAnswer() public {
        _addNvda(0);
        nvdaFeed.setAnswer(0);
        vm.expectRevert(abi.encodeWithSelector(StockRegistry.BadFeedAnswer.selector, address(nvda)));
        registry.priceUsd(address(nvda));

        nvdaFeed.setAnswer(-1);
        vm.expectRevert(abi.encodeWithSelector(StockRegistry.BadFeedAnswer.selector, address(nvda)));
        registry.priceUsd(address(nvda));
    }

    /// @notice Equity feeds hold the last close overnight and at weekends. The registry
    ///         must NOT treat that as a fault; freshness policy belongs to the round logic.
    function test_priceUsd_acceptsStaleFeedAndReportsUpdatedAt() public {
        _addNvda(0);
        vm.warp(block.timestamp + 3 days);
        uint256 fridayClose = block.timestamp - 3 days;
        nvdaFeed.setStaleAnswer(180e8, fridayClose);

        (uint256 price, uint256 updatedAt) = registry.priceUsd(address(nvda));
        assertEq(price, 180e18);
        assertEq(updatedAt, fridayClose, "caller can judge staleness itself");
    }

    function test_poolTvlUsd_valuesBothSidesAcrossDecimals() public {
        _addNvda(0);
        _fundNvdaPool();

        (uint256 stockBal, uint256 quoteBal) = registry.poolBalances(address(nvda));
        assertEq(stockBal, 16.06e8);
        assertEq(quoteBal, 7_440e6);

        // 16.06 shares * $180 = $2,890.80, plus $7,440 = $10,330.80
        assertEq(registry.poolTvlUsd(address(nvda)), 10_330.8e18);
    }

    function test_poolTvlUsd_tracksThePriceFeed() public {
        _addNvda(0);
        _fundNvdaPool();
        uint256 before = registry.poolTvlUsd(address(nvda));

        nvdaFeed.setAnswer(90e8); // stock halves
        assertEq(registry.poolTvlUsd(address(nvda)), before - 1_445.4e18);
    }

    /// @notice A concentrated-liquidity pool's ERC20 balances are not its active liquidity.
    ///         A direct transfer changes the former while leaving the latter untouched.
    ///         This is the accounting distinction a depth gate must preserve.
    function test_poolTvlUsd_inflatesOnDonationWithoutIncreasingActiveLiquidity() public {
        MockConcentratedAccountingPool pool = new MockConcentratedAccountingPool(1e18);
        uniFactory.setPool(address(nvda), address(usdc), FEE_030, address(pool));
        nvdaPool = address(pool);
        _addNvda(1_000_000e18);
        _configureDepth(address(nvda), 10_330.8e6);
        address donor = makeAddr("donor");
        nvda.mint(donor, 50e8);
        usdc.mint(donor, 1_001_000e6);
        vm.startPrank(donor);
        nvda.transfer(address(pool), 50e8);
        usdc.transfer(address(pool), 1_000e6);
        vm.stopPrank();
        uint128 activeBefore = pool.liquidity();
        uint256 depthBefore = registry.poolLiquidityUsd(address(nvda));
        assertGt(depthBefore, 0);
        assertEq(registry.poolTvlUsd(address(nvda)), 10_000e18);
        assertFalse(registry.clearsMinLiquidity(address(nvda)));
        vm.prank(donor);
        usdc.transfer(address(pool), 1_000_000e6);
        assertEq(pool.liquidity(), activeBefore);
        assertEq(usdc.balanceOf(address(pool)), 1_001_000e6);
        assertEq(registry.poolTvlUsd(address(nvda)), 1_010_000e18);
        assertEq(registry.poolLiquidityUsd(address(nvda)), depthBefore);
        assertFalse(registry.clearsMinLiquidity(address(nvda)));
        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(
                StockRegistry.InsufficientLiquidity.selector, address(nvda), depthBefore, uint256(1_000_000e18)
            )
        );
        registry.setEnabled(address(nvda), true);
    }

    function test_poolBalances_revertsWithoutPool() public {
        MockERC20 tsla = new MockERC20("Tesla Inc.", "TSLAc", STOCK_DECIMALS);
        vm.prank(multisig);
        registry.addStock(
            StockRegistry.AddStockParams({
                token: address(tsla),
                feed: address(0),
                venue: Venue.None,
                pool: address(0),
                fee: 0,
                tickSpacing: 0,
                minLiquidityUsd: 0,
                tokenDecimals: STOCK_DECIMALS
            })
        );
        vm.expectRevert(abi.encodeWithSelector(StockRegistry.PoolNotSet.selector, address(tsla)));
        registry.poolBalances(address(tsla));
    }

    /* ------------------------------------------------------------------ */
    /*                          ENABLE / DISABLE                            */
    /* ------------------------------------------------------------------ */

    function test_setEnabled_requiresDepthToClearThreshold() public {
        _addNvda(20_000e18); // needs $20k, pool will hold $10,330.80
        _fundNvdaPool();

        assertFalse(registry.clearsMinLiquidity(address(nvda)));
        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(
                StockRegistry.InsufficientLiquidity.selector, address(nvda), 10_330.8e18, uint256(20_000e18)
            )
        );
        registry.setEnabled(address(nvda), true);
    }

    function test_setEnabled_succeedsOnceDepthArrives() public {
        _addNvda(20_000e18);
        _fundNvdaPool();

        usdc.mint(nvdaPool, 10_000e6);
        // A position change increases executable capacity separately from raw balances.
        MockDepthPool(nvdaPool).setLiquidity(2e18);
        quoter.setQuote(address(nvda), 20_330.8e6, 1e8, 180e6);
        _configureDepth(address(nvda), 20_330.8e6);

        assertTrue(registry.clearsMinLiquidity(address(nvda)));
        vm.expectEmit(true, false, false, true, address(registry));
        emit EnabledUpdated(address(nvda), true);
        vm.prank(multisig);
        registry.setEnabled(address(nvda), true);
        assertTrue(registry.isEnabled(address(nvda)));
    }

    function test_setEnabled_requiresFeed() public {
        MockERC20 tsla = new MockERC20("Tesla Inc.", "TSLAc", STOCK_DECIMALS);
        uniFactory.setPool(address(tsla), address(usdc), FEE_030, makeAddr("tslaPool"));
        vm.prank(multisig);
        registry.addStock(
            StockRegistry.AddStockParams({
                token: address(tsla),
                feed: address(0),
                venue: Venue.UniswapV3,
                pool: makeAddr("tslaPool"),
                fee: FEE_030,
                tickSpacing: 0,
                minLiquidityUsd: 0,
                tokenDecimals: STOCK_DECIMALS
            })
        );

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(StockRegistry.FeedNotSet.selector, address(tsla)));
        registry.setEnabled(address(tsla), true);
    }

    function test_setEnabled_requiresPool() public {
        MockERC20 tsla = new MockERC20("Tesla Inc.", "TSLAc", STOCK_DECIMALS);
        vm.prank(multisig);
        registry.addStock(
            StockRegistry.AddStockParams({
                token: address(tsla),
                feed: address(nvdaFeed),
                venue: Venue.None,
                pool: address(0),
                fee: 0,
                tickSpacing: 0,
                minLiquidityUsd: 0,
                tokenDecimals: STOCK_DECIMALS
            })
        );

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(StockRegistry.PoolNotSet.selector, address(tsla)));
        registry.setEnabled(address(tsla), true);
    }

    /// @notice A stock whose market breaks must always be switchable off, with no gate.
    function test_setEnabled_disableIsNeverBlocked() public {
        _addNvda(1_000e18);
        _fundNvdaPool();
        vm.prank(multisig);
        registry.setEnabled(address(nvda), true);

        nvdaFeed.setRevertOnRead(true); // feed dies

        vm.prank(multisig);
        registry.setEnabled(address(nvda), false);
        assertFalse(registry.isEnabled(address(nvda)));
    }

    function test_setEnabled_rejectsNoOpChange() public {
        _addNvda(0);
        vm.prank(multisig);
        vm.expectRevert(StockRegistry.AlreadyInThatState.selector);
        registry.setEnabled(address(nvda), false);
    }

    function test_setEnabled_onlyMultisig() public {
        _addNvda(0);
        _fundNvdaPool();
        vm.prank(randomer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, randomer));
        registry.setEnabled(address(nvda), true);
    }

    function test_setMinLiquidityUsd_movesTheBar() public {
        _addNvda(20_000e18);
        _fundNvdaPool();

        vm.expectEmit(true, false, false, true, address(registry));
        emit MinLiquidityUpdated(address(nvda), 20_000e18, 5_000e18);
        vm.prank(multisig);
        registry.setMinLiquidityUsd(address(nvda), 5_000e18);

        vm.prank(multisig);
        registry.setEnabled(address(nvda), true);
        assertTrue(registry.isEnabled(address(nvda)));
    }

    function test_setMinLiquidityUsd_disablesStockWhenNewBarIsNotMet() public {
        _addNvda(1_000e18);
        _fundNvdaPool();

        vm.prank(multisig);
        registry.setEnabled(address(nvda), true);
        assertTrue(registry.isEnabled(address(nvda)));

        vm.expectEmit(true, false, false, true, address(registry));
        emit EnabledUpdated(address(nvda), false);
        vm.prank(multisig);
        registry.setMinLiquidityUsd(address(nvda), 20_000e18);

        assertFalse(registry.clearsMinLiquidity(address(nvda)));
        assertFalse(registry.isEnabled(address(nvda)));
    }

    function testFuzz_setMinLiquidityUsd_keepsEnabledAtOrBelowMeasuredLiquidity(uint128 newMin) public {
        _addNvda(1_000e18);
        _fundNvdaPool();
        vm.prank(multisig);
        registry.setEnabled(address(nvda), true);

        newMin = uint128(bound(newMin, 0, 10_330.8e18));
        vm.prank(multisig);
        registry.setMinLiquidityUsd(address(nvda), newMin);

        assertTrue(registry.isEnabled(address(nvda)));
        assertTrue(registry.clearsMinLiquidity(address(nvda)));
    }

    function test_setMinLiquidityUsd_disablesStockWhenLiquidityCannotBeRead() public {
        _addNvda(1_000e18);
        _fundNvdaPool();
        vm.prank(multisig);
        registry.setEnabled(address(nvda), true);
        nvdaFeed.setRevertOnRead(true);

        vm.prank(multisig);
        registry.setMinLiquidityUsd(address(nvda), 20_000e18);

        assertEq(registry.getStock(address(nvda)).minLiquidityUsd, 20_000e18);
        assertFalse(registry.isEnabled(address(nvda)));
    }

    function test_setMinLiquidityUsd_doesNotEnableDisabledStock() public {
        _addNvda(20_000e18);
        _fundNvdaPool();

        vm.prank(multisig);
        registry.setMinLiquidityUsd(address(nvda), 1_000e18);

        assertTrue(registry.clearsMinLiquidity(address(nvda)));
        assertFalse(registry.isEnabled(address(nvda)));
    }

    function test_setFeed_updatesFeedAndDecimals() public {
        _addNvda(0);
        MockAggregatorV3 newFeed = new MockAggregatorV3(18, 200e18, "NVDAc / USD v2");

        vm.prank(multisig);
        registry.setFeed(address(nvda), address(newFeed));

        Stock memory s = registry.getStock(address(nvda));
        assertEq(s.feed, address(newFeed));
        assertEq(s.feedDecimals, 18);

        (uint256 price,) = registry.priceUsd(address(nvda));
        assertEq(price, 200e18, "18-decimal feed scales correctly too");
    }

    function test_setFeed_rejectsZero() public {
        _addNvda(0);
        vm.prank(multisig);
        vm.expectRevert(StockRegistry.ZeroAddress.selector);
        registry.setFeed(address(nvda), address(0));
    }

    /* ------------------------------------------------------------------ */
    /*                            ENUMERATION                               */
    /* ------------------------------------------------------------------ */

    function test_enabledTokens_reflectsFlags() public {
        _addNvda(0);
        _fundNvdaPool();

        vm.prank(multisig);
        registry.addStock(
            StockRegistry.AddStockParams({
                token: address(googl),
                feed: address(googlFeed),
                venue: Venue.UniswapV3,
                pool: googlPool,
                fee: FEE_100,
                tickSpacing: 0,
                minLiquidityUsd: 0,
                tokenDecimals: STOCK_DECIMALS
            })
        );
        googl.mint(googlPool, 145.68e8);
        usdc.mint(googlPool, 48_309e6);
        MockDepthPool(googlPool).setLiquidity(1e18);
        _configureDepth(address(googl), 10_330.8e6);

        assertEq(registry.allTokens().length, 2);
        assertEq(registry.enabledTokens().length, 0, "none enabled yet");

        vm.prank(multisig);
        registry.setEnabled(address(googl), true);

        address[] memory enabled = registry.enabledTokens();
        assertEq(enabled.length, 1);
        assertEq(enabled[0], address(googl));

        vm.prank(multisig);
        registry.setEnabled(address(nvda), true);
        assertEq(registry.enabledTokens().length, 2);

        vm.prank(multisig);
        registry.setEnabled(address(googl), false);
        enabled = registry.enabledTokens();
        assertEq(enabled.length, 1);
        assertEq(enabled[0], address(nvda), "order preserved");
    }

    /// @notice The launch decision in one call.
    function test_liquidityReport_neverRevertsAndFlagsWhatClears() public {
        _addNvda(5_000e18);
        _fundNvdaPool();

        MockERC20 tsla = new MockERC20("Tesla Inc.", "TSLAc", STOCK_DECIMALS);
        vm.prank(multisig);
        registry.addStock(
            StockRegistry.AddStockParams({
                token: address(tsla),
                feed: address(0),
                venue: Venue.None,
                pool: address(0),
                fee: 0,
                tickSpacing: 0,
                minLiquidityUsd: 25_000e18,
                tokenDecimals: STOCK_DECIMALS
            })
        );

        (address[] memory tokens, uint256[] memory measured, uint256[] memory required, bool[] memory ok) =
            registry.liquidityReport();

        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(nvda));
        assertEq(measured[0], 10_330.8e18);
        assertEq(required[0], 5_000e18);
        assertTrue(ok[0], "NVDA clears");

        assertEq(tokens[1], address(tsla));
        assertEq(measured[1], 0, "no pool, reported as zero not a revert");
        assertEq(required[1], 25_000e18);
        assertFalse(ok[1]);
    }

    function test_clearsMinLiquidity_falseWhenFeedIsDown() public {
        _addNvda(1_000e18);
        _fundNvdaPool();
        assertTrue(registry.clearsMinLiquidity(address(nvda)));

        nvdaFeed.setRevertOnRead(true);
        assertFalse(registry.clearsMinLiquidity(address(nvda)), "must not revert the sweep");
    }

    function test_clearsMinLiquidity_falseForUnregistered() public {
        assertFalse(registry.clearsMinLiquidity(makeAddr("nobody")));
    }

    /* ------------------------------------------------------------------ */
    /*                               FUZZ                                   */
    /* ------------------------------------------------------------------ */

    function testFuzz_liquidityMathMatchesHandComputation(uint96 stockUnits, uint96 quoteUnits, uint64 priceRaw)
        public
    {
        priceRaw = uint64(bound(priceRaw, 1, 1_000_000e8));
        _addNvda(0);
        nvdaFeed.setAnswer(int256(uint256(priceRaw)));
        nvda.mint(nvdaPool, stockUnits);
        usdc.mint(nvdaPool, quoteUnits);

        uint256 expectedStockSide = (uint256(stockUnits) * (uint256(priceRaw) * 1e10)) / 1e8;
        uint256 expectedQuoteSide = (uint256(quoteUnits) * 1e18) / 1e6;

        assertEq(registry.poolTvlUsd(address(nvda)), expectedStockSide + expectedQuoteSide);
    }

    function testFuzz_enableGateIsExactlyTheThreshold(uint128 threshold) public {
        threshold = uint128(bound(threshold, 0, 50_000e18));
        _addNvda(threshold);
        _fundNvdaPool();

        uint256 measured = registry.poolLiquidityUsd(address(nvda));
        bool shouldClear = measured >= threshold;
        assertEq(registry.clearsMinLiquidity(address(nvda)), shouldClear);

        if (shouldClear) {
            vm.prank(multisig);
            registry.setEnabled(address(nvda), true);
            assertTrue(registry.isEnabled(address(nvda)));
        } else {
            vm.prank(multisig);
            vm.expectRevert(
                abi.encodeWithSelector(
                    StockRegistry.InsufficientLiquidity.selector, address(nvda), measured, uint256(threshold)
                )
            );
            registry.setEnabled(address(nvda), true);
        }
    }
}

/// @dev Small faithful accounting double: CL pools track active liquidity separately from
///      ERC20 balances, and unsolicited transfers update only the latter.
contract MockConcentratedAccountingPool {
    uint128 public immutable liquidity;

    constructor(uint128 activeLiquidity) {
        liquidity = activeLiquidity;
    }
}
