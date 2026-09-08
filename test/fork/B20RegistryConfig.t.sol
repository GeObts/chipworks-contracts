// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";

import {StockRegistry} from "../../src/StockRegistry.sol";
import {Stock, Venue} from "../../src/interfaces/IStockRegistry.sol";
import {EtchableERC20} from "../mocks/EtchableERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISlipstreamQuoterV2} from "src/interfaces/IVenueQuoters.sol";

/// @title B20RegistryConfigTest
/// @notice The full thirteen-ticker B20 set, registered against live Base with the REAL
///         Chainlink feeds, on the venue they actually trade on, with the depth gate holding
///         the line.
///
/// @dev WHAT THIS SUITE IS FOR. The registry config is the one piece of launch state that is
///      entirely external facts — token addresses, feed addresses, pool addresses, venues —
///      and every one of them is a thing somebody could be wrong about. So none of it is
///      pasted here on trust: the venue and pool for each ticker are re-derived from the real
///      factory every run. If a pool moves, appears, or was never there, this fails.
///
///      **THE VENUE IS AERODROME SLIPSTREAM, ON FACTORY B.** This suite used to assert the
///      opposite — that no B20 stock had a Slipstream pool and every one of them registered
///      as `Venue.UniswapV3`. That was measured against Aerodrome CL factory
///      `0x5e7BB1…809A`, and it was true of that factory. It was not true of Aerodrome.
///      There are **two** Aerodrome CL factories, and the B20 liquidity is on the other one,
///      `0xf8f2eB…061Ef` — same Voter, same owner, same factory registry, different pool
///      implementation. ASSUMPTIONS A-22 carries the correction and the reasoning.
///
///      `test_noB20StockHasAPoolOnFactoryA` keeps the original measurement rather than
///      deleting it, because the original measurement was never wrong — the conclusion drawn
///      from it was. A control proves the call works; it does not prove you are calling the
///      right contract.
contract B20RegistryConfigTest is Test {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant UNIV3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;

    /// @dev The Aerodrome CL factory A-22 originally swept. No B20 pool lives here.
    address internal constant SLIPSTREAM_FACTORY_A = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;

    /// @dev The Aerodrome CL factory the B20 pools are actually on. This is what the registry
    ///      is constructed with, and `slipstreamFactory` is immutable — see DEPLOY.md step 2.
    address internal constant SLIPSTREAM_FACTORY_B = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef;

    /// @dev Every B20 pool on factory B is at this tick spacing, fee 500.
    int24 internal constant B20_TICK_SPACING = 10;

    /// @dev Historical threshold retained for the registration test. A $1 quote probe does
    ///      not certify $25k capacity; enabling needs separately reviewed configuration.
    uint128 internal constant LAUNCH_MIN_USD = 25_000e18;

    struct Cfg {
        string name;
        address token;
        address feed;
        Venue venue;
        address pool; // the factory-B Slipstream pool, and what gets registered
        address uniPool; // the Uniswap v3 pool, kept only for the negative test
        uint24 uniFee;
        int24 tickSpacing;
    }

    Cfg[] internal cfg;

    StockRegistry internal registry;
    address internal multisig = makeAddr("multisig");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        registry = new StockRegistry(multisig, USDC, UNIV3_FACTORY, SLIPSTREAM_FACTORY_B);

        // --- the four already live -------------------------------------------------
        _cfg(
            "NVDA",
            0xb20000000000000000000078ee7ce2fE4908108C,
            0x04689a41629776563E6822F76f2e57D148d28513,
            0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9,
            0x60661b315553EB81872deEA9a66d567Cf0CCd33B,
            3000
        );
        _cfg(
            "GOOGL",
            0xb2000000000000000000002D0BA3164cc74f58B7,
            0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2,
            0xB1987CAD1682841b4b641d50E520777eC5Ab5542,
            0x1f52F46BaC657564c31122b12b43A459E09273C8,
            10000
        );
        _cfg(
            "AAPL",
            0xb200000000000000000000C2e324d24d7eEcd1fb,
            0x787f13dEa48Db0897CbCDD985de77809D837F988,
            0xA3b1E3f9747065e2073722Ff4c9027d3eA4994F0,
            0x97F35d1E92795327614BE000cd18cba1Be2c1931,
            3000
        );
        _cfg(
            "META",
            0xb2000000000000000000008bC8786B856E61707C,
            0x6526aE6797A76123638b863AeE4dD27Ba4E4b27D,
            0xEAF57753BC382E0324a1D43F72E7027705a2273E,
            0x583919ec1975a1238C50e1940911894ee6912476,
            3000
        );

        // --- the six the expansion adds --------------------------------------------
        _cfg(
            "TSLA",
            0xb2000000000000000000001e800a7f5189430cD0,
            0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4,
            0x469337fDcc5E8f38e2E4B670B04F57865D13a7BB,
            0xad6A86333C579d5Bbd150F28e74651006Fa87b3B,
            10000
        );
        _cfg(
            "AMZN",
            0xb200000000000000000000d9192b6B456483C2E8,
            0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295,
            0xd03Bc8C7F2FAedCe2aac81bF0444AEA08Ea06E9b,
            0x7F030e5fD657795C0937a3e8af2929Fd90DA91C7,
            10000
        );
        _cfg(
            "MSFT",
            0xB200000000000000000000Ab99cFa739E253872B,
            0xeB10A6c9aa7E537aEd766C08c35Dae35B321b18c,
            0x7103eB3c9590d1281f7dc03b2A9EE27C39dF5D54,
            0xD73cBeCC0F62C7C1704332ED119514d6d84DC607,
            10000
        );
        _cfg(
            "MSTR",
            0xb2000000000000000000004884b426556b92883d,
            0xB3cE282CD188b35DA0E38D8Bc7d58e33173D202a,
            0x8b27f626ab668197000BC722A1012022CAeD10E2,
            0x5237817130DFc43F176A9146D3aE1Be85cBacAFb,
            10000
        );
        _cfg(
            "SNDK",
            0xb200000000000000000000397293Cb8cda9a10c5,
            0x388b0dC46C0Fb05A74BeE0994fa5b02c6Fcca2eA,
            0x5A8236f575471e7BfCA2C8462a200c28f737246E,
            0x26fa54cdfc64fAacb5364c09De7Ac2F72308052D,
            10000
        );
        _cfg(
            "SPCX",
            0xb2000000000000000000007b9fcbd005511aCBd5,
            0x6A634B235903C4ad6376892180d6fF8612e3Fa68,
            0x0bf58fe0FAc935Ac69595c19B12Ba0d75E3F8c0E,
            0x127a12FC0953ab2ab89558c67Ba6D597D7140431,
            10000
        );

        // --- the three with no pool anywhere ---------------------------------------
        _cfgNoPool("COIN", 0xb200000000000000000000c85a31389D71F3ecfb, 0x408e44f504A7371a345F03a73dDC96A4b48e8aa7);
        _cfgNoPool("CRCL", 0xB20000000000000000000019f6E7C675b73C2e4D, 0x0231cF2635D1E17bB5c2462cc7504Ba1fBd61f33);
        _cfgNoPool("INTC", 0xB2000000000000000000004AFF16039bA04bdFBc, 0xAB657C39bac0D5886250D70849e2E3E008F2EECB);
    }

    /* ------------------------------------------------------------------ */
    /*                THE VENUE, CHECKED AGAINST THE CHAIN                  */
    /* ------------------------------------------------------------------ */

    /// @notice EVERY B20 POOL WE REGISTER IS ON AERODROME CL FACTORY B, AT TICK SPACING 10.
    ///
    /// @dev This is the assertion the venue flip rests on. The pool address in the config
    ///      above is not trusted: it is re-derived from factory B every run, and the pool is
    ///      asked what factory it believes it belongs to.
    function test_everyRegisteredPoolIsDerivedFromFactoryB() public view {
        for (uint256 i; i < cfg.length; ++i) {
            Cfg memory c = cfg[i];
            if (c.venue == Venue.None) continue;

            assertEq(
                _slipPool(SLIPSTREAM_FACTORY_B, c.token, B20_TICK_SPACING),
                c.pool,
                string.concat("factory B does not derive the configured pool for ", c.name)
            );

            (bool ok, bytes memory ret) = c.pool.staticcall(abi.encodeWithSignature("factory()"));
            assertTrue(ok && ret.length >= 32, c.name);
            assertEq(abi.decode(ret, (address)), SLIPSTREAM_FACTORY_B, string.concat(c.name, " pool.factory()"));
        }
    }

    /// @notice AND NONE OF THEM IS ON FACTORY A — the original A-22 measurement, kept.
    ///
    /// @dev The sweep was real and its control passed. Every zero it returned was correct.
    ///      The error was assuming factory A was the only Aerodrome CL factory, and this
    ///      assertion is what keeps that distinction visible rather than quietly rewritten.
    function test_noB20StockHasAPoolOnFactoryA() public view {
        for (uint256 i; i < cfg.length; ++i) {
            for (uint256 j; j < 10; ++j) {
                int24 ts = [int24(1), 2, 5, 10, 25, 50, 100, 200, 500, 2000][j];
                assertEq(
                    _slipPool(SLIPSTREAM_FACTORY_A, cfg[i].token, ts),
                    address(0),
                    string.concat("unexpected factory-A pool for ", cfg[i].name)
                );
            }
        }

        // Control: the same call on the same factory does resolve a pool that exists.
        assertTrue(
            _slipPool(SLIPSTREAM_FACTORY_A, 0x4200000000000000000000000000000000000006, 100) != address(0),
            "WETH/USDC ts=100"
        );
    }

    /// @notice A registry built on factory A cannot register these stocks as Slipstream at
    ///         all — which is exactly why `slipstreamFactory_` is a deploy argument that has
    ///         to be right, and why it is immutable.
    function test_aFactoryARegistryCannotRegisterTheB20Venue() public {
        StockRegistry wrong = new StockRegistry(multisig, USDC, UNIV3_FACTORY, SLIPSTREAM_FACTORY_A);
        Cfg memory nvda = _byName("NVDA");

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(StockRegistry.PoolNotFoundInFactory.selector, nvda.token, nvda.pool));
        wrong.addStock(
            StockRegistry.AddStockParams({
                token: nvda.token,
                feed: nvda.feed,
                venue: Venue.Slipstream,
                pool: nvda.pool,
                fee: 0,
                tickSpacing: B20_TICK_SPACING,
                minLiquidityUsd: LAUNCH_MIN_USD,
                tokenDecimals: 8
            })
        );
    }

    /// @notice The venue still cannot be faked. Handing in the ticker's Uniswap pool under a
    ///         Slipstream venue is refused by the factory check, exactly as before.
    function test_slipstreamVenueCannotBeFakedWithAUniswapPool() public {
        Cfg memory tsla = _byName("TSLA");

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(StockRegistry.PoolNotFoundInFactory.selector, tsla.token, tsla.uniPool));
        registry.addStock(
            StockRegistry.AddStockParams({
                token: tsla.token,
                feed: tsla.feed,
                venue: Venue.Slipstream,
                pool: tsla.uniPool, // its real pool, but a Uniswap one
                fee: 0,
                tickSpacing: B20_TICK_SPACING,
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
            assertEq(uint8(s.venue), uint8(cfg[i].venue), cfg[i].name);
            if (cfg[i].venue == Venue.Slipstream) {
                assertEq(s.tickSpacing, B20_TICK_SPACING, cfg[i].name);
            }

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
    ///
    ///      **The venue flip is what makes this table interesting.** Against the Uniswap pools
    ///      only two tickers cleared $25,000. On factory B all ten clear it, the smallest by
    ///      several times over.
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
        assertEq(clearing, 0, "$1 probes cannot certify the historical $25k TVL threshold");
        assertLt(clearing, 13, "the gate is still doing something");
    }

    /// @notice The gate is a real threshold, not a rubber stamp: it refuses just above the
    ///         measured figure and allows just below, on a live pool.
    function test_theGateIsExactOnALivePool() public {
        _registerAll();
        Cfg memory c = _byName("NVDA"); // the deepest B20 pool on factory B

        uint256 realStock = _rpcBalanceOf(c.token, c.pool);
        vm.etch(c.token, address(new EtchableERC20()).code);
        EtchableERC20(c.token).init(c.name, c.name, 8);
        EtchableERC20(c.token).mint(c.pool, realStock);

        uint256 measured = registry.poolLiquidityUsd(c.token);
        assertGt(measured, 0, "NVDA has depth");
        _assertDonationsDoNotChangeQuote(c, measured);

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
    ///         exist.
    ///
    /// @dev On the Uniswap venue this could be shown with a live ticker, because MSTR and SNDK
    ///      had deployed pools holding no USDC. **On factory B there is no such ticker** — all
    ///      ten hold real depth on both sides — so the property is shown by emptying the
    ///      shallowest pool instead. That is a stronger test anyway: it does not quietly stop
    ///      testing anything the day somebody adds liquidity.
    function test_anEmptyPoolIsAsBlockedAsAMissingOne() public {
        _registerAll();
        Cfg memory c = _byName("MSTR"); // the shallowest factory-B pool

        assertTrue(c.pool != address(0), "the pool contract exists");

        // Both sides to zero: an existing, registered, correctly-derived pool with nothing in
        // it. The stock side is etched empty and the USDC side is dealt away.
        vm.etch(c.token, address(new EtchableERC20()).code);
        EtchableERC20(c.token).init(c.name, c.name, 8);
        deal(USDC, c.pool, 0);

        assertEq(registry.poolLiquidityUsd(c.token), 0, "nothing in it");
        assertFalse(registry.clearsMinLiquidity(c.token), c.name);

        vm.prank(multisig);
        vm.expectPartialRevert(StockRegistry.InsufficientLiquidity.selector);
        registry.setEnabled(c.token, true);

        // And it stays blocked even with the threshold at its lowest meaningful setting.
        vm.prank(multisig);
        registry.setMinLiquidityUsd(c.token, 1);
        vm.prank(multisig);
        vm.expectPartialRevert(StockRegistry.InsufficientLiquidity.selector);
        registry.setEnabled(c.token, true);
    }

    /* -------------------------------- helpers -------------------------------- */

    /// @dev Real factory-B pool/quoter; only the B20 precompile's ERC20 transfer is etched.
    function _assertDonationsDoNotChangeQuote(Cfg memory c, uint256 measured) internal {
        ISlipstreamQuoterV2 q = ISlipstreamQuoterV2(0x514c8B5f54112481E28028F1166Bd78501089259);
        ISlipstreamQuoterV2.QuoteExactInputSingleParams memory p =
            ISlipstreamQuoterV2.QuoteExactInputSingleParams(USDC, c.token, 1e6, c.tickSpacing, 0);
        (uint256 beforeOut,,,) = q.quoteExactInputSingle(p);
        bytes32 beforeState = _poolState(c.pool);
        uint256 beforeQuoteBalance = IERC20(USDC).balanceOf(c.pool);
        deal(USDC, address(this), 1_000_000e6);
        assertTrue(IERC20(USDC).transfer(c.pool, 1_000_000e6));
        assertEq(IERC20(USDC).balanceOf(c.pool), beforeQuoteBalance + 1_000_000e6);
        (uint256 afterQuoteDonation,,,) = q.quoteExactInputSingle(p);
        assertEq(afterQuoteDonation, beforeOut);
        assertEq(registry.poolLiquidityUsd(c.token), measured);
        uint256 beforeStockBalance = IERC20(c.token).balanceOf(c.pool);
        EtchableERC20(c.token).mint(address(this), 1_000_000e8);
        assertTrue(IERC20(c.token).transfer(c.pool, 1_000_000e8));
        assertEq(IERC20(c.token).balanceOf(c.pool), beforeStockBalance + 1_000_000e8);
        (uint256 afterStockDonation,,,) = q.quoteExactInputSingle(p);
        assertEq(afterStockDonation, beforeOut);
        assertEq(_poolState(c.pool), beforeState);
        assertEq(registry.poolLiquidityUsd(c.token), measured);
    }

    function _poolState(address pool) internal view returns (bytes32) {
        (bool a, bytes memory liquidity) = pool.staticcall(abi.encodeWithSignature("liquidity()"));
        (bool b, bytes memory slot) = pool.staticcall(abi.encodeWithSignature("slot0()"));
        assertTrue(a && b);
        return keccak256(abi.encode(liquidity, slot));
    }

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
                    // `fee` is not read on the Slipstream path — the pool is derived from the
                    // tick spacing — so it is left at zero rather than carrying a number
                    // nothing consults. The factory-B pools are all fee 500.
                    fee: 0,
                    tickSpacing: c.tickSpacing,
                    minLiquidityUsd: LAUNCH_MIN_USD,
                    tokenDecimals: 8
                })
            );
            if (c.pool != address(0)) {
                vm.prank(multisig);
                registry.setDepthConfig(c.token, 0x514c8B5f54112481E28028F1166Bd78501089259, 1e6, 500, 120 hours);
            }
        }
    }

    function _cfg(string memory name, address token, address feed, address pool, address uniPool, uint24 uniFee)
        internal
    {
        cfg.push(Cfg(name, token, feed, Venue.Slipstream, pool, uniPool, uniFee, B20_TICK_SPACING));
    }

    function _cfgNoPool(string memory name, address token, address feed) internal {
        cfg.push(Cfg(name, token, feed, Venue.None, address(0), address(0), 0, int24(0)));
    }

    function _byName(string memory name) internal view returns (Cfg memory) {
        for (uint256 i; i < cfg.length; ++i) {
            if (keccak256(bytes(cfg[i].name)) == keccak256(bytes(name))) return cfg[i];
        }
        revert("no such ticker");
    }

    function _slipPool(address factory, address token, int24 tickSpacing) internal view returns (address) {
        (bool ok, bytes memory ret) =
            factory.staticcall(abi.encodeWithSignature("getPool(address,address,int24)", token, USDC, tickSpacing));
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
