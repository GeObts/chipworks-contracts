// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ChipRounds} from "../src/ChipRounds.sol";
import {ChipClaims} from "../src/ChipClaims.sol";
import {Round, RoundState} from "../src/interfaces/IChipRounds.sol";
import {Pot} from "../src/Pot.sol";
import {MockDepthQuoter, MockDepthPool} from "test/mocks/MockDepthQuoter.sol";
import {StockRegistry} from "../src/StockRegistry.sol";
import {ClutchVaultAdapter} from "../src/adapters/ClutchVaultAdapter.sol";
import {Venue} from "../src/interfaces/IStockRegistry.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {BlacklistToken, PausableToken} from "./mocks/HostileTokens.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockUniswapV3Factory, MockSlipstreamFactory} from "./mocks/MockFactories.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {MockNoun} from "./mocks/MockNoun.sol";
import {MockSoftStakingVault} from "./mocks/MockSoftStakingVault.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice Shared fixture: a full Chipworks stack wired to mocks, with two collections,
///         two normal stocks and one freezable stock.
abstract contract ChipRewardsBase is Test {
    // actors
    address internal multisig = makeAddr("multisig");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal keeper = makeAddr("keeper");
    address internal polTreasury = makeAddr("polTreasury");

    // stack
    StockRegistry internal registry;
    Pot internal pot;
    ChipRounds internal rounds;
    ChipClaims internal claims;
    ClutchVaultAdapter internal adapter;

    // tokens
    MockERC20 internal usdc;
    MockERC20 internal nvda;
    MockERC20 internal googl;
    BlacklistToken internal aapl; // the freezable one
    MockERC20 internal chip;

    // feeds
    MockAggregatorV3 internal nvdaFeed;
    MockAggregatorV3 internal googlFeed;
    MockAggregatorV3 internal aaplFeed;

    // infra
    MockUniswapV3Factory internal uniFactory;
    MockSlipstreamFactory internal slipFactory;
    MockSwapRouter internal router;

    MockSwapRouter internal slipRouter;
    // collections
    MockNoun internal basedNouns;
    MockNoun internal darkNouns;
    MockNoun internal lilNouns;
    MockSoftStakingVault internal basedVault;
    MockSoftStakingVault internal darkVault;
    MockSoftStakingVault internal lilVault;

    uint24 internal constant FEE = 3000;
    uint8 internal constant STOCK_DEC = 8;

    // Prices: NVDA $200, GOOGL $400, AAPL $250.
    uint256 internal constant NVDA_USD = 200;
    uint256 internal constant GOOGL_USD = 400;
    uint256 internal constant AAPL_USD = 250;

    uint128 internal constant MIN_POT = 250e6; // $250
    /// @dev Retained only as a convenient "a large round" figure for tests. There is no
    ///      round cap any more; nothing in `src/` reads a maximum.
    uint128 internal constant MAX_BUDGET = 10_000e6;
    uint256 internal constant SPLIT_FEE = 5_000 ether; // 5,000 CHIP

    function setUp() public virtual {
        vm.warp(1_700_000_000);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        nvda = new MockERC20("NVIDIA Corporation", "NVDAc", STOCK_DEC);
        googl = new MockERC20("Alphabet Inc.", "GOOGLc", STOCK_DEC);
        aapl = new BlacklistToken("Apple Inc.", "AAPLc", STOCK_DEC);
        chip = new MockERC20("Chipworks", "CHIP", 18);

        nvdaFeed = new MockAggregatorV3(8, int256(NVDA_USD * 1e8), "NVDAc / USD");
        googlFeed = new MockAggregatorV3(8, int256(GOOGL_USD * 1e8), "GOOGLc / USD");
        aaplFeed = new MockAggregatorV3(8, int256(AAPL_USD * 1e8), "AAPLc / USD");

        uniFactory = new MockUniswapV3Factory();
        slipFactory = new MockSlipstreamFactory();

        // Two routers, because `setRouters` now checks each one against the factory the
        // REGISTRY resolves that venue's pools from, and a single double cannot answer
        // `factory()` with two different addresses. Only `router` is ever swapped through --
        // every stock in this base registers as `Venue.UniswapV3` -- but the Slipstream slot
        // has to hold something that belongs to the Slipstream factory.
        router = new MockSwapRouter();
        router.setFactory(address(uniFactory));
        slipRouter = new MockSwapRouter();
        slipRouter.setFactory(address(slipFactory));

        registry = new StockRegistry(multisig, address(usdc), address(uniFactory), address(slipFactory));
        pot = new Pot(multisig, address(usdc), address(uniFactory));
        adapter = new ClutchVaultAdapter(multisig, [uint32(10_000), 12_500, 16_000, 20_000, 33_300]);
        claims = new ChipClaims(multisig, address(registry));
        rounds = new ChipRounds(
            multisig,
            address(registry),
            address(pot),
            address(adapter),
            address(claims),
            SPLIT_FEE,
            0x000000000000000000000000000000000000dEaD
        );

        basedNouns = new MockNoun("Based Nouns", "BASED");
        darkNouns = new MockNoun("DarkNOUNs", "DARK");
        lilNouns = new MockNoun(unicode"⌐◨-◨ Lil Based Nouns!", "LIL");
        basedVault = new MockSoftStakingVault(IERC721(address(basedNouns)));
        darkVault = new MockSoftStakingVault(IERC721(address(darkNouns)));
        lilVault = new MockSoftStakingVault(IERC721(address(lilNouns)));

        _registerStocks();
        _wire();
        _fundRouter();
    }

    function _registerStocks() internal {
        MockDepthQuoter depthQuoter = new MockDepthQuoter(address(uniFactory));
        address[3] memory toks = [address(nvda), address(googl), address(aapl)];
        address[3] memory feeds = [address(nvdaFeed), address(googlFeed), address(aaplFeed)];
        for (uint256 i; i < 3; ++i) {
            address pool = address(uint160(1000 + i));
            uniFactory.setPool(toks[i], address(usdc), FEE, pool);
            vm.prank(multisig);
            registry.addStock(
                StockRegistry.AddStockParams({
                    token: toks[i],
                    feed: feeds[i],
                    venue: Venue.UniswapV3,
                    pool: pool,
                    fee: FEE,
                    tickSpacing: 0,
                    minLiquidityUsd: 0,
                    tokenDecimals: STOCK_DEC
                })
            );
            vm.etch(pool, address(new MockDepthPool()).code);
            MockDepthPool(pool).setLiquidity(1e18);
            (uint256 mark,) = registry.priceUsd(toks[i]);
            depthQuoter.setQuote(toks[i], 10_000_000e6, 1e20, mark);
            vm.prank(multisig);
            registry.setDepthConfig(toks[i], address(depthQuoter), 10_000_000e6, 200, 120 hours);
            vm.prank(multisig);
            registry.setEnabled(toks[i], true);
        }
        _fundPools();
    }

    /// @dev Give each registered pool real balances, so `poolLiquidityUsd` measures something.
    ///
    ///      Needed since the depth-aware impact trim landed: `settleStock` sizes every buy
    ///      from `registry.poolLiquidityUsd(stock)` and refuses to buy at all when depth reads
    ///      zero. Before the trim these pool addresses were empty placeholders that only had
    ///      to exist in the factory; now they have to hold something. Deep on purpose — $10m
    ///      a side pair — so the trim never binds in suites that are testing something else.
    ///      `UncappedRoundsTest` is where thin pools are the subject.
    function _fundPools() internal {
        _fundPool(address(nvda), NVDA_USD);
        _fundPool(address(googl), GOOGL_USD);
        _fundPool(address(aapl), AAPL_USD);
    }

    /// @dev Same job for a stock a derived suite registers itself, whatever its token type.
    ///      Low-level `mint` so it works for MockERC20 and every HostileTokens variant alike.
    function _seedPoolDepth(address stock, address pool, uint256 priceUsd, uint8 dec) internal {
        usdc.mint(pool, 5_000_000e6);
        (bool ok,) =
            stock.call(abi.encodeWithSignature("mint(address,uint256)", pool, (5_000_000 / priceUsd) * (10 ** dec)));
        require(ok, "seed pool: mint failed");
    }

    function _fundPool(address stock, uint256 priceUsd) internal {
        address pool = registry.getStock(stock).pool;
        usdc.mint(pool, 5_000_000e6);
        MockERC20(stock).mint(pool, (5_000_000 / priceUsd) * 1e8);
    }

    /// @dev Caller is already pranking the multisig when registering an extra hostile token.
    function _configureExtraStockDepth(address token, address pool) internal {
        MockDepthQuoter extraQuoter = new MockDepthQuoter(address(uniFactory));
        vm.etch(pool, address(new MockDepthPool()).code);
        MockDepthPool(pool).setLiquidity(1e18);
        (uint256 mark,) = registry.priceUsd(token);
        extraQuoter.setQuote(token, 10_000_000e6, 1e20, mark);
        registry.setDepthConfig(token, address(extraQuoter), 10_000_000e6, 200, 120 hours);
    }

    function _wire() internal {
        vm.startPrank(multisig);
        pot.setRewards(address(rounds));
        claims.setRounds(address(rounds));
        claims.setPolTreasury(polTreasury);
        adapter.setVault(address(basedNouns), address(basedVault));
        adapter.setVault(address(darkNouns), address(darkVault));
        adapter.setVault(address(lilNouns), address(lilVault));
        rounds.setCollectionBaseBps(address(basedNouns), 10_000); // 1.0x
        rounds.setCollectionBaseBps(address(darkNouns), 20_000); // 2.0x
        rounds.setCollectionBaseBps(address(lilNouns), 5_000); // 0.5x
        rounds.setRoundParams(24 hours, 2 hours, MIN_POT);
        rounds.setRouters(address(router), address(slipRouter));
        rounds.setPolTreasury(polTreasury);
        rounds.setChip(address(chip));
        vm.stopPrank();
    }

    /// @dev Rates model the prices above, converting 6-decimal USDC into 8-decimal stock.
    ///      out = in * 1e8 / (price * 1e6)
    function _fundRouter() internal {
        router.setRate(address(usdc), address(nvda), 1e8, NVDA_USD * 1e6);
        router.setRate(address(usdc), address(googl), 1e8, GOOGL_USD * 1e6);
        router.setRate(address(usdc), address(aapl), 1e8, AAPL_USD * 1e6);
        nvda.mint(address(router), 1_000_000e8);
        googl.mint(address(router), 1_000_000e8);
        aapl.mint(address(router), 1_000_000e8);
    }

    /* ------------------------------- helpers ------------------------------- */

    function _fundPot(uint256 amount) internal {
        usdc.mint(address(pot), amount);
    }

    /// @dev Mint a Noun to `owner` and activate it at `tier` in the matching vault.
    function _chip(MockNoun collection, MockSoftStakingVault vault, uint256 tokenId, address owner, uint8 tier)
        internal
    {
        collection.mint(owner, tokenId);
        vm.prank(owner);
        vault.activate(tokenId, tier);
    }

    function _setSplit(address collection, uint256 tokenId, address owner, address[] memory s, uint8[] memory p)
        internal
    {
        vm.prank(owner);
        rounds.setSplit(collection, tokenId, s, p);
    }

    function _one(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _one(uint8 a) internal pure returns (uint8[] memory out) {
        out = new uint8[](1);
        out[0] = a;
    }

    function _two(address a, address b) internal pure returns (address[] memory out) {
        out = new address[](2);
        out[0] = a;
        out[1] = b;
    }

    function _two(uint8 a, uint8 b) internal pure returns (uint8[] memory out) {
        out = new uint8[](2);
        out[0] = a;
        out[1] = b;
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = a;
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        out[0] = a;
        out[1] = b;
    }

    function _ids(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory out) {
        out = new uint256[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }

    /// @dev Move time forward to the next open claim window, if one is not open already.
    ///      Claims are only possible inside a window, so most tests need this before
    ///      calling claim().
    function _openClaimWindow() internal {
        if (claims.isClaimOpen()) return;
        (, uint64 opensAt,) = claims.claimWindowState();
        vm.warp(opensAt);
    }

    /// @dev Warp `d` forward, then land inside a claim window.
    function _warpToWindow(uint256 d) internal {
        vm.warp(block.timestamp + d);
        _openClaimWindow();
    }

    /// @dev Jump just past a round's expiry, where sweeping becomes possible.
    function _warpPastExpiry(uint256 roundId) internal {
        vm.warp(claims.expiresAt(roundId) + 1);
    }

    /// @dev Open a round, contribute the given Based Nouns, close accumulation.
    function _openAndAccumulate(uint256[] memory basedIds) internal returns (uint256 roundId) {
        roundId = rounds.openRound();
        rounds.contributeWeights(roundId, address(basedNouns), basedIds);
        vm.warp(block.timestamp + 2 hours);
        rounds.closeAccumulation(roundId);
    }
}
