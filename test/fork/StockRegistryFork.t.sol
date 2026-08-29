// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {StockRegistry} from "../../src/StockRegistry.sol";
import {Stock, Venue} from "../../src/interfaces/IStockRegistry.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {EtchableERC20} from "../mocks/EtchableERC20.sol";

/// @notice StockRegistry against real Base mainnet factories, pools and B20 tokens.
/// @dev    forge test --match-contract StockRegistryForkTest -vv   (needs BASE_RPC_URL)
///
///         The point of this suite is that the pool-verification logic is exercised by
///         the REAL Uniswap v3 factory, not a mock that agrees with us by construction.
contract StockRegistryForkTest is Test {
    // Tokens (native B20 precompiles).
    address internal constant NVDA = 0xb20000000000000000000078ee7ce2fE4908108C;
    address internal constant GOOGL = 0xb2000000000000000000002D0BA3164cc74f58B7;
    address internal constant AAPL = 0xb200000000000000000000C2e324d24d7eEcd1fb;
    address internal constant META = 0xb2000000000000000000008bC8786B856E61707C;
    address internal constant TSLA = 0xb2000000000000000000001e800a7f5189430cD0;
    address internal constant AMZN = 0xb200000000000000000000d9192b6B456483C2E8;
    address internal constant MSFT = 0xB200000000000000000000Ab99cFa739E253872B;
    address internal constant COIN = 0xb200000000000000000000c85a31389D71F3ecfb;
    address internal constant MSTR = 0xb2000000000000000000004884b426556b92883d;

    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant UNIV3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address internal constant SLIPSTREAM_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;

    // Deepest USDC pool per stock, measured 2026-08-28.
    address internal constant NVDA_POOL = 0x60661b315553EB81872deEA9a66d567Cf0CCd33B; // 0.3%
    address internal constant GOOGL_POOL = 0x1f52F46BaC657564c31122b12b43A459E09273C8; // 1%
    address internal constant AAPL_POOL = 0x97F35d1E92795327614BE000cd18cba1Be2c1931; // 0.3%
    address internal constant META_POOL = 0x583919ec1975a1238C50e1940911894ee6912476; // 0.3%

    StockRegistry internal registry;
    address internal multisig = makeAddr("multisig");
    MockAggregatorV3 internal feed;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        registry = new StockRegistry(multisig, USDC, UNIV3_FACTORY, SLIPSTREAM_FACTORY);
        // Stand-in until Chainlink hands over the real B20 feed addresses (ASSUMPTIONS A-13).
        feed = new MockAggregatorV3(8, 180e8, "stand-in / USD");
    }

    function _add(address token, address pool, uint24 fee, uint128 minUsd) internal {
        vm.prank(multisig);
        registry.addStock(
            StockRegistry.AddStockParams({
                token: token,
                feed: address(feed),
                venue: pool == address(0) ? Venue.None : Venue.UniswapV3,
                pool: pool,
                fee: fee,
                tickSpacing: 0,
                minLiquidityUsd: minUsd,
                tokenDecimals: 8
            })
        );
    }

    /* ------------------------------------------------------------------ */
    /*                    REAL FACTORY VERIFICATION                         */
    /* ------------------------------------------------------------------ */

    function test_acceptsRealUniswapPools() public {
        _add(NVDA, NVDA_POOL, 3000, 0);
        _add(GOOGL, GOOGL_POOL, 10000, 0);
        _add(AAPL, AAPL_POOL, 3000, 0);
        _add(META, META_POOL, 3000, 0);

        assertEq(registry.getStock(NVDA).pool, NVDA_POOL);
        assertEq(registry.getStock(GOOGL).pool, GOOGL_POOL);
        assertEq(registry.getStock(GOOGL).fee, 10000, "GOOGL depth is in the 1% tier");
        assertEq(registry.stockCount(), 4);
    }

    function test_rejectsRealPoolUnderTheWrongFeeTier() public {
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(StockRegistry.PoolNotFoundInFactory.selector, GOOGL, GOOGL_POOL));
        registry.addStock(
            StockRegistry.AddStockParams({
                token: GOOGL,
                feed: address(feed),
                venue: Venue.UniswapV3,
                pool: GOOGL_POOL,
                fee: 3000, // real pool, wrong tier
                tickSpacing: 0,
                minLiquidityUsd: 0,
                tokenDecimals: 8
            })
        );
    }

    function test_rejectsAnotherStocksPool() public {
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(StockRegistry.PoolNotFoundInFactory.selector, NVDA, GOOGL_POOL));
        registry.addStock(
            StockRegistry.AddStockParams({
                token: NVDA,
                feed: address(feed),
                venue: Venue.UniswapV3,
                pool: GOOGL_POOL,
                fee: 10000,
                tickSpacing: 0,
                minLiquidityUsd: 0,
                tokenDecimals: 8
            })
        );
    }

    /// @notice There is no Slipstream pool for any stock today, so the registry must
    ///         refuse to record one. When Aerodrome pools appear, this test will fail
    ///         and that is the signal to flip the venue.
    function test_rejectsSlipstreamVenueBecauseNoSuchPoolExists() public {
        _add(NVDA, NVDA_POOL, 3000, 0);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(StockRegistry.PoolNotFoundInFactory.selector, NVDA, NVDA_POOL));
        registry.setVenue(NVDA, Venue.Slipstream, NVDA_POOL, 0, 100);
    }

    /* ------------------------------------------------------------------ */
    /*                     THE ACTUAL LAUNCH SHAPE                          */
    /* ------------------------------------------------------------------ */

    /// @notice Register all nine B20 stocks the way the deploy script will: the four with
    ///         pools configured, the five without pools registered but venue-less. All
    ///         disabled. Enabling is a later, separate decision driven by measured depth.
    function test_registersAllNineStocksAllDisabled() public {
        _add(NVDA, NVDA_POOL, 3000, 25_000e18);
        _add(GOOGL, GOOGL_POOL, 10000, 25_000e18);
        _add(AAPL, AAPL_POOL, 3000, 25_000e18);
        _add(META, META_POOL, 3000, 25_000e18);
        _add(TSLA, address(0), 0, 25_000e18);
        _add(AMZN, address(0), 0, 25_000e18);
        _add(MSFT, address(0), 0, 25_000e18);
        _add(COIN, address(0), 0, 25_000e18);
        _add(MSTR, address(0), 0, 25_000e18);

        assertEq(registry.stockCount(), 9);
        assertEq(registry.enabledTokens().length, 0, "everything starts disabled");

        address[] memory all = registry.allTokens();
        for (uint256 i; i < all.length; ++i) {
            assertTrue(registry.isRegistered(all[i]));
            assertFalse(registry.isEnabled(all[i]));
        }
    }

    /// @notice B20 decimals() cannot be executed in a fork, so addStock's try/catch must
    ///         fall back to the caller-supplied value rather than reverting.
    function test_decimalsFallbackHandlesPrecompiles() public {
        _add(NVDA, NVDA_POOL, 3000, 0);
        assertEq(registry.getStock(NVDA).tokenDecimals, 8, "fell back to the supplied value");
    }

    /// @notice The depth gate, exercised with the true on-chain balances. Balances are
    ///         read from the real node via raw RPC, then replayed into etched stand-in
    ///         tokens so the forked EVM can run the registry's arithmetic over them.
    function test_depthGateAgainstRealMeasuredBalances() public {
        uint256 realStock = _rpcBalanceOf(NVDA, NVDA_POOL);
        uint256 realUsdc = _rpcBalanceOf(USDC, NVDA_POOL);
        assertGt(realStock, 0, "real pool holds stock");

        _add(NVDA, NVDA_POOL, 3000, 0);

        // Replace the precompile with a runnable token carrying the same balance.
        vm.etch(NVDA, address(new EtchableERC20()).code);
        EtchableERC20(NVDA).init("NVIDIA Corporation", "NVDAc", 8);
        EtchableERC20(NVDA).mint(NVDA_POOL, realStock);

        (uint256 stockBal, uint256 quoteBal) = registry.poolBalances(NVDA);
        assertEq(stockBal, realStock);
        assertEq(quoteBal, realUsdc, "USDC is a normal contract, read directly");

        uint256 measured = registry.poolLiquidityUsd(NVDA);
        console2.log("NVDA pool depth, USD:", measured / 1e18);

        // Threshold just above measured: must refuse. Just below: must allow.
        vm.prank(multisig);
        registry.setMinLiquidityUsd(NVDA, uint128(measured + 1e18));
        assertFalse(registry.clearsMinLiquidity(NVDA));

        vm.prank(multisig);
        registry.setMinLiquidityUsd(NVDA, uint128(measured));
        assertTrue(registry.clearsMinLiquidity(NVDA));
        vm.prank(multisig);
        registry.setEnabled(NVDA, true);
        assertTrue(registry.isEnabled(NVDA));
    }

    function _rpcBalanceOf(address token, address who) internal returns (uint256) {
        bytes memory data = abi.encodeWithSignature("balanceOf(address)", who);
        string memory params =
            string.concat('[{"to":"', vm.toString(token), '","data":"', vm.toString(data), '"},"latest"]');
        return abi.decode(vm.rpc("eth_call", params), (uint256));
    }
}
