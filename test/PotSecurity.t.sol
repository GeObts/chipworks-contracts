// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Pot} from "../src/Pot.sol";
import {ConversionRoutes} from "../src/base/ConversionRoutes.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {MockWETH} from "./mocks/MockWETH.sol";

/// @title PotSecurityTest
/// @notice The Bankr Pot/ConversionRoutes findings, each pinned by the behaviour it asked for.
contract PotSecurityTest is Test {
    address internal multisig = makeAddr("multisig");
    address internal keeper = makeAddr("keeper");
    address internal uniV3Factory = makeAddr("uniV3Factory");
    address internal slipstreamFactory = makeAddr("slipstreamFactory");

    Pot internal pot;
    MockERC20 internal usdc;
    MockWETH internal weth;
    MockAggregatorV3 internal ethFeed;
    MockSwapRouter internal router;

    uint256 internal constant ETH_USD = 2_000;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockWETH();
        ethFeed = new MockAggregatorV3(8, int256(ETH_USD * 1e8), "ETH / USD");

        router = new MockSwapRouter();
        router.setFactory(uniV3Factory);
        router.setRate(address(weth), address(usdc), ETH_USD * 1e6, 1e18);
        usdc.mint(address(router), 10_000_000e6);

        pot = new Pot(multisig, address(usdc), uniV3Factory);

        vm.prank(multisig);
        pot.setConversionConfig(address(weth), address(ethFeed), address(router), 500, 100, 100 ether, 0, 1 hours);
    }

    /* ------------------------------------------------------------------ */
    /*        SEC-POT-001 — the router must be a Uniswap v3 router          */
    /* ------------------------------------------------------------------ */

    /// @notice A Slipstream router is rejected at CONFIGURATION time, not discovered at
    ///         conversion time. This contract can only encode Uniswap v3 calldata.
    function test_aSlipstreamRouterIsRejectedWhenTheRouteIsSet() public {
        MockSwapRouter slipstream = new MockSwapRouter();
        slipstream.setFactory(slipstreamFactory); // a different protocol, a different factory

        MockERC20 aero = new MockERC20("Aerodrome", "AERO", 18);
        MockAggregatorV3 aeroFeed = new MockAggregatorV3(8, 1e8, "AERO / USD");

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(ConversionRoutes.RouterNotUniswapV3.selector, address(slipstream)));
        pot.setRoute(address(aero), address(aeroFeed), address(slipstream), 500, 100, 1_000 ether, 0, 1 days);

        // And nothing was written: the token has no route at all.
        assertFalse(pot.routeOf(address(aero)).enabled);
    }

    function test_aRouterThatIsNotAContractIsRejected() public {
        MockERC20 aero = new MockERC20("Aerodrome", "AERO", 18);
        MockAggregatorV3 aeroFeed = new MockAggregatorV3(8, 1e8, "AERO / USD");
        address eoa = makeAddr("notARouter");

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(ConversionRoutes.NotAContract.selector, eoa));
        pot.setRoute(address(aero), address(aeroFeed), eoa, 500, 100, 1_000 ether, 0, 1 days);
    }

    /// @notice The Uniswap router the Pot actually uses passes, so the guard is not simply
    ///         refusing everything.
    function test_aUniswapV3RouterIsAccepted() public view {
        assertTrue(pot.routeOf(address(weth)).enabled, "the WETH route configured fine");
        assertEq(pot.routeOf(address(weth)).router, address(router));
    }

    /* ------------------------------------------------------------------ */
    /*     SEC-POT-005 — a feed pinned at its circuit breaker is refused    */
    /* ------------------------------------------------------------------ */

    /// @notice A crash pins the aggregator at `minAnswer`. The reported price is then a
    ///         circuit-breaker artefact, not a market price, and converting against it would
    ///         insist on far more USDC than the pool can give.
    ///
    /// @dev Before the band check this failed as `UnderMinOut` — indistinguishable from "the
    ///      pool moved". Now it fails as `FeedAtBand`, so an operator can tell the difference
    ///      and knows to reach for `disableRoute`.
    function test_aFeedPinnedAtItsFloorIsRefusedByName() public {
        BandedAggregator banded = new BandedAggregator(8, int256(ETH_USD * 1e8), 100e8, 100_000e8);
        MockERC20 tok = new MockERC20("Token", "TOK", 18);

        vm.prank(multisig);
        pot.setRoute(address(tok), address(banded), address(router), 500, 100, 1_000 ether, 0, 1 days);

        // Healthy: prices fine.
        assertGt(pot.minOutFor(address(tok), 1 ether), 0);

        // Crash: the aggregator clamps to its floor.
        banded.setAnswer(100e8);
        vm.expectRevert(abi.encodeWithSelector(ConversionRoutes.FeedAtBand.selector, int256(100e8)));
        pot.minOutFor(address(tok), 1 ether);

        // And at the ceiling, for the same reason in the other direction.
        banded.setAnswer(100_000e8);
        vm.expectRevert(abi.encodeWithSelector(ConversionRoutes.FeedAtBand.selector, int256(100_000e8)));
        pot.minOutFor(address(tok), 1 ether);
    }

    /// @notice THE ESCAPE THE FINDING ASKED FOR ALREADY EXISTED. A token whose feed is stuck
    ///         is not locked: disable the route, sweep the token, convert it elsewhere.
    function test_aTokenWithAStuckFeedCanBeDisabledAndRescued() public {
        BandedAggregator banded = new BandedAggregator(8, int256(ETH_USD * 1e8), 100e8, 100_000e8);
        MockERC20 tok = new MockERC20("Token", "TOK", 18);
        tok.mint(address(pot), 500 ether);

        vm.prank(multisig);
        pot.setRoute(address(tok), address(banded), address(router), 500, 100, 1_000 ether, 0, 1 days);

        banded.setAnswer(100e8); // pinned

        vm.prank(multisig);
        pot.disableRoute(address(tok));

        vm.prank(multisig);
        pot.sweepNonQuote(address(tok), multisig);

        assertEq(tok.balanceOf(multisig), 500 ether, "rescued in full");
        assertEq(tok.balanceOf(address(pot)), 0);
    }

    /// @notice A feed that does not expose a band must not be treated as out of band — the
    ///         check must never be the reason a healthy conversion fails.
    function test_aFeedWithoutABandIsUnaffected() public view {
        assertGt(pot.minOutFor(address(weth), 1 ether), 0, "MockAggregatorV3 exposes no band");
    }

    /* ------------------------------------------------------------------ */
    /*        SEC-POT-003 — the L2 sequencer uptime feed                    */
    /* ------------------------------------------------------------------ */

    function test_conversionIsRefusedWhileTheSequencerIsDown() public {
        SequencerFeed seq = new SequencerFeed();
        vm.prank(multisig);
        pot.setSequencerFeed(address(seq), 1 hours);

        seq.set(1, block.timestamp - 10 days); // 1 == down

        vm.expectRevert(ConversionRoutes.SequencerDown.selector);
        pot.minOutFor(address(weth), 1 ether);

        vm.deal(address(pot), 1 ether);
        vm.prank(keeper);
        vm.expectRevert(ConversionRoutes.SequencerDown.selector);
        pot.convert();
    }

    /// @notice And for a grace period after it returns, because the first blocks back are the
    ///         thin ones an arbitrageur is waiting for.
    function test_conversionIsRefusedDuringTheGracePeriodAndAllowedAfter() public {
        SequencerFeed seq = new SequencerFeed();
        vm.prank(multisig);
        pot.setSequencerFeed(address(seq), 1 hours);

        uint256 backAt = block.timestamp;
        seq.set(0, backAt); // up, just now

        vm.expectRevert(
            abi.encodeWithSelector(ConversionRoutes.SequencerGracePeriod.selector, backAt, uint64(backAt) + 1 hours)
        );
        pot.minOutFor(address(weth), 1 ether);

        vm.warp(backAt + 1 hours);
        assertGt(pot.minOutFor(address(weth), 1 ether), 0, "trusted once the grace period passes");
    }

    function test_theSequencerCheckIsOffUntilConfigured() public view {
        assertEq(pot.sequencerUptimeFeed(), address(0));
        assertGt(pot.minOutFor(address(weth), 1 ether), 0, "inert by default");
    }

    /* ------------------------------------------------------------------ */
    /*        SEC-POT-002 — a caller may tighten the floor, never widen it  */
    /* ------------------------------------------------------------------ */

    /// @notice A keeper holding a real quote can refuse a fill the 2% Chainlink haircut would
    ///         otherwise have accepted.
    function test_aKeeperCanInsistOnATighterMinOut() public {
        vm.deal(address(pot), 1 ether);

        uint256 chainlinkFloor = pot.minOutFor(address(weth), 1 ether);
        assertApproxEqRel(chainlinkFloor, 1_980e6, 1e16, "2000 less the 1% haircut");

        // Asking for more than the pool will give is refused, and nothing moves.
        vm.prank(keeper);
        vm.expectRevert();
        pot.convert(uint256(2_500e6));
        assertEq(address(pot).balance, 1 ether, "untouched");

        // A realistic tighter floor goes through.
        vm.prank(keeper);
        (, uint256 out) = pot.convert(uint256(1_999e6));
        assertGe(out, 1_999e6);
    }

    /// @notice And it can only ever TIGHTEN. Passing a lower number does not widen the
    ///         Chainlink bound — the floor is the max of the two.
    function test_aCallerCannotWidenTheChainlinkBound() public {
        vm.deal(address(pot), 1 ether);
        uint256 chainlinkFloor = pot.minOutFor(address(weth), 1 ether);

        router.setRate(address(weth), address(usdc), 1_500e6, 1e18); // pool now far below the mark

        vm.prank(keeper);
        vm.expectRevert(); // still bounded by Chainlink, not by the caller's slack number
        pot.convert(uint256(1));

        assertEq(address(pot).balance, 1 ether);
        assertGt(chainlinkFloor, 1_500e6, "the mark really was above what the pool offered");
    }

    /* ------------------------------------------------------------------ */
    /*        SEC-POT-004 — a dust conversion is not worth doing            */
    /* ------------------------------------------------------------------ */

    function test_aConversionBelowTheFloorIsRefused() public {
        vm.prank(multisig);
        pot.setConversionConfig(
            address(weth), address(ethFeed), address(router), 500, 100, 100 ether, 0.01 ether, 1 hours
        );

        vm.deal(address(pot), 0.001 ether);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(ConversionRoutes.BelowMinPerCall.selector, uint256(0.001 ether), uint128(0.01 ether))
        );
        pot.convert();

        // Once enough accumulates it goes through, so nothing is stuck — only delayed.
        vm.deal(address(pot), 0.02 ether);
        vm.prank(keeper);
        (uint256 inAmt,) = pot.convert();
        assertEq(inAmt, 0.02 ether);
    }

    function test_theFloorMustNotExceedTheCap() public {
        vm.prank(multisig);
        vm.expectRevert(ConversionRoutes.RouteBadConfig.selector);
        pot.setConversionConfig(address(weth), address(ethFeed), address(router), 500, 100, 1 ether, 2 ether, 1 hours);
    }

    /* ------------------------------------------------------------------ */
    /*        SEC-POT-006 — the engine must be a contract                   */
    /* ------------------------------------------------------------------ */

    function test_setRewardsRefusesAnEoaAndTheZeroAddress() public {
        address eoa = makeAddr("fatFinger");

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(ConversionRoutes.NotAContract.selector, eoa));
        pot.setRewards(eoa);

        vm.prank(multisig);
        vm.expectRevert(Pot.ZeroAddress.selector);
        pot.setRewards(address(0));

        // A contract is accepted.
        address ok = address(new RoundsStub());
        vm.prank(multisig);
        pot.setRewards(ok);
        assertEq(pot.rewards(), ok);
    }
}

/// @notice A Chainlink-shaped proxy whose aggregator exposes minAnswer/maxAnswer.
contract BandedAggregator {
    uint8 public immutable decimals;
    string public description = "Banded / USD";
    int256 internal _answer;
    Agg public aggregatorContract;

    constructor(uint8 d, int256 a, int256 minA, int256 maxA) {
        decimals = d;
        _answer = a;
        aggregatorContract = new Agg(minA, maxA);
    }

    function aggregator() external view returns (address) {
        return address(aggregatorContract);
    }

    function setAnswer(int256 a) external {
        _answer = a;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _answer, block.timestamp, block.timestamp, 1);
    }
}

contract Agg {
    int256 public minAnswer;
    int256 public maxAnswer;

    constructor(int256 minA, int256 maxA) {
        minAnswer = minA;
        maxAnswer = maxA;
    }
}

/// @notice Chainlink L2 sequencer uptime feed: answer 0 = up, 1 = down.
contract SequencerFeed {
    int256 internal _answer;
    uint256 internal _startedAt;

    function set(int256 a, uint256 startedAt_) external {
        _answer = a;
        _startedAt = startedAt_;
    }

    function decimals() external pure returns (uint8) {
        return 0;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _answer, _startedAt, _startedAt, 1);
    }
}

contract RoundsStub {}
