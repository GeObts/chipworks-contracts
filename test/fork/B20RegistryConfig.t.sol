// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";

import {StockRegistry} from "../../src/StockRegistry.sol";
import {Stock, Venue} from "../../src/interfaces/IStockRegistry.sol";
import {EtchableERC20} from "../mocks/EtchableERC20.sol";

/// @title B20RegistryConfigTest
/// @notice The full thirteen-ticker B20 set, registered against live Base with the REAL
///         Chainlink feeds, and the depth gate holding the line.
///
/// @dev WHAT THIS SUITE IS FOR. The registry config is the one piece of launch state that is
///      entirely external facts — token addresses, feed addresses, pool addresses, venues —
///      and every one of them is a thing somebody could be wrong about. So none of it is
///      pasted here on trust: the venue and pool for each ticker were found by sweeping the
///      real factories (`B20PoolDiscovery.t.sol`), and this suite re-derives them from those
///      same factories every run. If a pool moves, appears, or was never there, this fails.
///
///      THE HEADLINE, RECORDED IN ASSUMPTIONS A-22: **there is no Aerodrome Slipstream pool
///      for any B20 stock on Base.** Not for the four already registered, not for the six the
///      expansion named, not against USDC and not against WETH, at any tick spacing
///      Slipstream supports. Every B20 pool with real depth is on Uniswap v3. The two
///      Aerodrome pools that exist at all (AAPL, NVDA) are basic vAMM pools, not
///      concentrated-liquidity ones, and `Venue.Slipstream` correctly refuses them.
contract B20RegistryConfigTest is Test {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant UNIV3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address internal constant SLIPSTREAM_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;

    /// @dev A launch threshold with the concentration haircut already in mind. The registry's
    ///      figure is headline TVL across both sides; tradeable depth near spot is a fraction
    ///      of it, and `ChipRounds`' per-stock max-impact check is the real protection.
    uint128 internal constant LAUNCH_MIN_USD = 25_000e18;

    struct Cfg {
        string name;
        address token;
        address feed;
        Venue venue;
        address pool;
        uint24 fee;
        int24 tickSpacing;
    }

    Cfg[] internal cfg;

    StockRegistry internal registry;
    address internal multisig = makeAddr("multisig");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        registry = new StockRegistry(multisig, USDC, UNIV3_FACTORY, SLIPSTREAM_FACTORY);

        // --- the four already live -------------------------------------------------
        _cfg(
            "NVDA",
            0xb20000000000000000000078ee7ce2fE4908108C,
            0x04689a41629776563E6822F76f2e57D148d28513,
            0x60661b315553EB81872deEA9a66d567Cf0CCd33B,
            3000
        );
        _cfg(
            "GOOGL",
            0xb2000000000000000000002D0BA3164cc74f58B7,
            0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2,
            0x1f52F46BaC657564c31122b12b43A459E09273C8,
            10000
        );
        _cfg(
            "AAPL",
            0xb200000000000000000000C2e324d24d7eEcd1fb,
            0x787f13dEa48Db0897CbCDD985de77809D837F988,
            0x97F35d1E92795327614BE000cd18cba1Be2c1931,
            3000
        );
        _cfg(
            "META",
            0xb2000000000000000000008bC8786B856E61707C,
            0x6526aE6797A76123638b863AeE4dD27Ba4E4b27D,
            0x583919ec1975a1238C50e1940911894ee6912476,
            3000
        );

        // --- the six the expansion adds --------------------------------------------
        _cfg(
            "TSLA",
            0xb2000000000000000000001e800a7f5189430cD0,
            0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4,
            0xad6A86333C579d5Bbd150F28e74651006Fa87b3B,
            10000
        );
        _cfg(
            "AMZN",
            0xb200000000000000000000d9192b6B456483C2E8,
            0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295,
            0x7F030e5fD657795C0937a3e8af2929Fd90DA91C7,
            10000
        );
        _cfg(
            "MSFT",
            0xB200000000000000000000Ab99cFa739E253872B,
            0xeB10A6c9aa7E537aEd766C08c35Dae35B321b18c,
            0xD73cBeCC0F62C7C1704332ED119514d6d84DC607,
            10000
        );
        _cfg(
            "MSTR",
            0xb2000000000000000000004884b426556b92883d,
            0xB3cE282CD188b35DA0E38D8Bc7d58e33173D202a,
            0x5237817130DFc43F176A9146D3aE1Be85cBacAFb,
            10000
        );
        _cfg(
            "SNDK",
            0xb200000000000000000000397293Cb8cda9a10c5,
            0x388b0dC46C0Fb05A74BeE0994fa5b02c6Fcca2eA,
            0x26fa54cdfc64fAacb5364c09De7Ac2F72308052D,
            10000
        );
        _cfg(
            "SPCX",
            0xb2000000000000000000007b9fcbd005511aCBd5,
            0x6A634B235903C4ad6376892180d6fF8612e3Fa68,
            0x127a12FC0953ab2ab89558c67Ba6D597D7140431,
            10000
        );

        // --- the three with no pool anywhere ---------------------------------------
        _cfgNoPool("COIN", 0xb200000000000000000000c85a31389D71F3ecfb, 0x408e44f504A7371a345F03a73dDC96A4b48e8aa7);
        _cfgNoPool("CRCL", 0xB20000000000000000000019f6E7C675b73C2e4D, 0x0231cF2635D1E17bB5c2462cc7504Ba1fBd61f33);
        _cfgNoPool("INTC", 0xB2000000000000000000004AFF16039bA04bdFBc, 0xAB657C39bac0D5886250D70849e2E3E008F2EECB);
    }

    /* ------------------------------------------------------------------ */
    /*     THE CLAIM THE EXPANSION WAS BUILT ON, CHECKED AGAINST THE CHAIN  */
    /* ------------------------------------------------------------------ */

    /// @notice NO B20 STOCK HAS AN AERODROME SLIPSTREAM POOL ON BASE.
    ///
    /// @dev The expansion was specified as "all with live Aerodrome Slipstream pools". That is
    ///      not what the chain says, and this is the assertion that will tell us the day it
    ///      changes. The control at the end is what makes a zero here mean "no pool" rather
    ///      than "we are calling the factory wrong".
    function test_noB20StockHasASlipstreamPool() public view {
        for (uint256 i; i < cfg.length; ++i) {
            for (uint256 j; j < 10; ++j) {
                int24 ts = [int24(1), 2, 5, 10, 25, 50, 100, 200, 500, 2000][j];
                address pool = _slipPool(cfg[i].token, ts);
                assertEq(pool, address(0), string.concat("unexpected Slipstream pool for ", cfg[i].name));
            }
        }

        // Control: the same call on the same factory does resolve a pool that exists.
        assertTrue(_slipPool(0x4200000000000000000000000000000000000006, 100) != address(0), "WETH/USDC ts=100");
    }

    /// @notice And the registry cannot be told otherwise. Registering a Slipstream venue for
    ///         a ticker with no Slipstream pool is refused by the factory check, whatever
    ///         address is handed in — including the ticker's real Uniswap pool.
    function test_slipstreamVenueCannotBeFakedForAB20() public {
        Cfg memory tsla = _byName("TSLA");

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(StockRegistry.PoolNotFoundInFactory.selector, tsla.token, tsla.pool));
        registry.addStock(
            StockRegistry.AddStockParams({
                token: tsla.token,
                feed: tsla.feed,
                venue: Venue.Slipstream, // the venue the expansion assumed
                pool: tsla.pool, // its real pool, which is a Uniswap one
                fee: 0,
                tickSpacing: 100,
                minLiquidityUsd: LAUNCH_MIN_USD,
                tokenDecimals: 8
            })
        );
    }

    /* ------------------------------------------------------------------ */
    /*                      THE CONFIG, AND THE GATE                        */
    /* ------------------------------------------------------------------ */

    /// @notice All thirteen register, with their real Chainlink feeds, all disabled.
    function test_allThirteenRegisterDisabledWithRealFeeds() public {
        _registerAll();

        assertEq(registry.stockCount(), 13, "the full B20 set");
        assertEq(registry.enabledTokens().length, 0, "nothing enables on registration");

        for (uint256 i; i < cfg.length; ++i) {
            Stock memory s = registry.getStock(cfg[i].token);
            assertTrue(s.registered, cfg[i].name);
            assertFalse(s.enabled, cfg[i].name);
            assertEq(s.feed, cfg[i].feed, cfg[i].name);
            assertEq(s.feedDecimals, 8, "every Coinbase feed is 8dp");
            assertEq(s.pool, cfg[i].pool, cfg[i].name);

            // The real feed answers, and answers sanely.
            (uint256 price1e18, uint256 updatedAt) = registry.priceUsd(cfg[i].token);
            assertGt(price1e18, 0, string.concat("no price for ", cfg[i].name));
            assertGt(updatedAt, 0);
            console2.log(cfg[i].name, "USD 1e18:", price1e18);
        }
    }

    /// @notice THE POOL-LESS THREE CANNOT BE ENABLED, BY CONSTRUCTION.
    ///
    /// @dev Not by a threshold they happen to fail — by the shape of the record. With no
    ///      venue there is nothing to measure depth in, so `setEnabled(true)` refuses before
    ///      it ever reaches the number. This is what "register but can't enable" means, and
    ///      it holds no matter what `minLiquidityUsd` is set to, including zero.
    function test_theEnableGateBlocksThePoollessTickersByConstruction() public {
        _registerAll();

        string[3] memory poolless = ["COIN", "CRCL", "INTC"];
        for (uint256 i; i < 3; ++i) {
            Cfg memory c = _byName(poolless[i]);
            assertEq(c.pool, address(0), c.name);

            vm.prank(multisig);
            vm.expectRevert(abi.encodeWithSelector(StockRegistry.PoolNotSet.selector, c.token));
            registry.setEnabled(c.token, true);

            // Even with the threshold dropped to zero.
            vm.prank(multisig);
            registry.setMinLiquidityUsd(c.token, 0);
            vm.prank(multisig);
            vm.expectRevert(abi.encodeWithSelector(StockRegistry.PoolNotSet.selector, c.token));
            registry.setEnabled(c.token, true);

            assertFalse(registry.clearsMinLiquidity(c.token), c.name);
            assertFalse(registry.isEnabled(c.token), c.name);
        }
    }

    /// @notice The measured depth of every B20 pool that exists, and which clear the launch
    ///         threshold. This is the table the launch decision is made from.
    ///
    /// @dev B20 tokens are node-native precompiles and cannot execute in a forked EVM
    ///      (ASSUMPTIONS A-15), so the stock side is read over raw RPC and then etched back in
    ///      at the same balance. The USDC side is a normal contract and is read directly.
    function test_measuredDepthAcrossTheWholeSet() public {
        _registerAll();

        uint256 clearing;
        for (uint256 i; i < cfg.length; ++i) {
            Cfg memory c = cfg[i];
            if (c.pool == address(0)) {
                console2.log(string.concat(c.name, ": no pool at any venue"));
                continue;
            }

            uint256 realStock = _rpcBalanceOf(c.token, c.pool);
            vm.etch(c.token, address(new EtchableERC20()).code);
            EtchableERC20(c.token).init(c.name, c.name, 8);
            EtchableERC20(c.token).mint(c.pool, realStock);

            uint256 usd = registry.poolLiquidityUsd(c.token);
            bool ok = registry.clearsMinLiquidity(c.token);
            if (ok) ++clearing;
            console2.log(string.concat(c.name, " depth USD:"), usd / 1e18, ok ? "CLEARS" : "blocked");
        }

        console2.log("clearing the 25k launch threshold:", clearing, "of 13");
        assertLt(clearing, 13, "the gate is doing something");
    }

    /// @notice The gate is a real threshold, not a rubber stamp: it refuses just above the
    ///         measured figure and allows just below, on a live pool.
    function test_theGateIsExactOnALivePool() public {
        _registerAll();
        Cfg memory c = _byName("GOOGL"); // the deepest B20 pool on Base

        uint256 realStock = _rpcBalanceOf(c.token, c.pool);
        vm.etch(c.token, address(new EtchableERC20()).code);
        EtchableERC20(c.token).init(c.name, c.name, 8);
        EtchableERC20(c.token).mint(c.pool, realStock);

        uint256 measured = registry.poolLiquidityUsd(c.token);
        assertGt(measured, 0, "GOOGL has depth");

        vm.prank(multisig);
        registry.setMinLiquidityUsd(c.token, uint128(measured + 1e18));
        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(StockRegistry.InsufficientLiquidity.selector, c.token, measured, measured + 1e18)
        );
        registry.setEnabled(c.token, true);

        vm.prank(multisig);
        registry.setMinLiquidityUsd(c.token, uint128(measured));
        vm.prank(multisig);
        registry.setEnabled(c.token, true);
        assertTrue(registry.isEnabled(c.token), "clears, so it enables");
    }

    /// @notice A pool that exists but is empty is exactly as blocked as one that does not
    ///         exist. MSTR and SNDK have deployed pools holding no USDC.
    function test_anEmptyPoolIsAsBlockedAsAMissingOne() public {
        _registerAll();

        string[2] memory empties = ["MSTR", "SNDK"];
        for (uint256 i; i < 2; ++i) {
            Cfg memory c = _byName(empties[i]);
            assertTrue(c.pool != address(0), "the pool contract exists");

            uint256 realStock = _rpcBalanceOf(c.token, c.pool);
            vm.etch(c.token, address(new EtchableERC20()).code);
            EtchableERC20(c.token).init(c.name, c.name, 8);
            EtchableERC20(c.token).mint(c.pool, realStock);

            assertFalse(registry.clearsMinLiquidity(c.token), c.name);
            vm.prank(multisig);
            vm.expectPartialRevert(StockRegistry.InsufficientLiquidity.selector);
            registry.setEnabled(c.token, true);
        }
    }

    /* -------------------------------- helpers -------------------------------- */

    function _registerAll() internal {
        for (uint256 i; i < cfg.length; ++i) {
            Cfg memory c = cfg[i];
            vm.prank(multisig);
            registry.addStock(
                StockRegistry.AddStockParams({
                    token: c.token,
                    feed: c.feed,
                    venue: c.venue,
                    pool: c.pool,
                    fee: c.fee,
                    tickSpacing: c.tickSpacing,
                    minLiquidityUsd: LAUNCH_MIN_USD,
                    tokenDecimals: 8
                })
            );
        }
    }

    function _cfg(string memory name, address token, address feed, address pool, uint24 fee) internal {
        cfg.push(Cfg(name, token, feed, Venue.UniswapV3, pool, fee, int24(0)));
    }

    function _cfgNoPool(string memory name, address token, address feed) internal {
        cfg.push(Cfg(name, token, feed, Venue.None, address(0), 0, int24(0)));
    }

    function _byName(string memory name) internal view returns (Cfg memory) {
        for (uint256 i; i < cfg.length; ++i) {
            if (keccak256(bytes(cfg[i].name)) == keccak256(bytes(name))) return cfg[i];
        }
        revert("no such ticker");
    }

    function _slipPool(address token, int24 tickSpacing) internal view returns (address) {
        (bool ok, bytes memory ret) = SLIPSTREAM_FACTORY.staticcall(
            abi.encodeWithSignature("getPool(address,address,int24)", token, USDC, tickSpacing)
        );
        if (!ok || ret.length < 32) return address(0);
        return abi.decode(ret, (address));
    }

    function _rpcBalanceOf(address token, address who) internal returns (uint256) {
        bytes memory data = abi.encodeWithSignature("balanceOf(address)", who);
        string memory params =
            string.concat('[{"to":"', vm.toString(token), '","data":"', vm.toString(data), '"},"latest"]');
        return abi.decode(vm.rpc("eth_call", params), (uint256));
    }
}
