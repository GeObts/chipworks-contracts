// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {IUniswapV3SwapRouter} from "../interfaces/ISwapRouters.sol";
import {IWETH} from "../interfaces/IWETH.sol";

/// @title ConversionRoutes
/// @notice Shared machinery for turning an arbitrary asset into the quote token, with the
///         minimum output bounded by that asset's own Chainlink mark.
///
/// @dev Both {Pot} and {POLTreasury} need this and there is exactly ONE implementation of
///      it on purpose. A Chainlink-bounded swap is the most security-sensitive code in the
///      repo; having two copies would double the surface an auditor has to check and
///      guarantee they drift. Everything here is configuration — route, fee tier, slippage
///      bound, per-call cap, staleness limit — so adding an asset is a multisig call.
///
///      THREE PROPERTIES EVERY CONVERSION HAS:
///      1. Bounded by Chainlink. `amountOutMinimum` comes from the feed, never from a quote.
///      2. Capped per call, so a large balance cannot be walked through the pool in one
///         swap. Verified on a Base fork: an uncapped 500 ETH breached its bound and was
///         refused, while capped conversions landed comfortably inside it.
///      3. Measured by balance delta, never by the router's return value, so a token that
///         lies about transferring cannot inflate what we think we received.
/// @dev UNISWAP V3 CALLDATA, AND ONLY UNISWAP V3 CALLDATA.
///
///      This contract encodes exactly one swap shape: `IUniswapV3SwapRouter`'s 7-field
///      `exactInputSingle`. It does NOT encode Aerodrome Slipstream's 8-field variant
///      (tickSpacing + deadline), and it never has — there is no dead branch here, and
///      `ISlipstreamSwapRouter` is not imported.
///
///      **That is a design decision, not an omission.** ASSUMPTIONS A-16 established that the
///      liquidity Chipworks converts against is on Uniswap v3, not Slipstream. Both live
///      routes — WETH and AERO — trade in Uniswap v3 pools. Aerodrome appears in this
///      protocol only in `POLTreasury`, and only for LP positions and gauge staking through
///      the Slipstream position manager, never for a swap. `ChipRounds` does encode the
///      Slipstream shape, because stock BUYS may route through either venue; that is a
///      different contract with a different job.
///
///      External review (TRIAGE SEC-POT-001) noted that pointing a route at a Slipstream
///      router would revert on the ABI mismatch. Correct — so {_setRoute} now refuses any
///      router whose `factory()` is not the Uniswap v3 factory, which a Slipstream router's
///      never is. The misconfiguration is rejected at configuration time rather than
///      discovered at conversion time.
abstract contract ConversionRoutes {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;

    /// @notice Gas cap on the one-off `decimals()` probe when registering a route.
    uint256 public constant PROBE_GAS = 50_000;

    /// @notice Asset every route converts into.
    address public immutable quoteToken;

    /// @notice Cached decimals of `quoteToken`.
    uint8 public immutable quoteDecimals;

    /// @notice Wrapped native token. Native ETH is wrapped into this on the way through.
    address public weth;

    /// @notice The Uniswap v3 factory every routed router must belong to.
    /// @dev Immutable and constructor-set rather than a wiring call, deliberately: an
    ///      optional guard that silently does nothing when forgotten is the anti-pattern this
    ///      repo already documents once (the `setCustodian` trap in LAUNCH_CONFIG). This one
    ///      cannot be forgotten.
    address public immutable uniswapV3Factory;

    /// @notice Chainlink L2 sequencer uptime feed. Zero disables the check.
    address public sequencerUptimeFeed;

    /// @notice How long after the sequencer comes back before prices are trusted again.
    uint64 public sequencerGracePeriod;

    struct Route {
        bool enabled;
        address feed; // Chainlink <token>/USD aggregator
        address router; // Uniswap v3 style router
        uint24 fee; // pool fee tier
        uint32 maxSlippageBps; // how far below the Chainlink mark execution may land
        uint128 maxPerCall; // largest amount one convert() may push through the pool
        uint128 minPerCall; // smallest amount worth converting. 0 disables the floor
        uint64 maxFeedAge; // reject a feed older than this. 0 disables the check
        uint8 tokenDecimals; // cached
        uint8 feedDecimals; // cached
    }

    mapping(address token => Route) internal _routes;
    address[] internal _routedTokens;

    event Converted(address indexed token, uint256 amountIn, uint256 quoteOut, uint256 minOut, address indexed caller);
    event RouteSet(
        address indexed token,
        address feed,
        address router,
        uint24 fee,
        uint32 slippageBps,
        uint128 cap,
        uint64 maxFeedAge
    );
    event RouteDisabled(address indexed token);
    event SequencerFeedUpdated(address indexed feed, uint64 gracePeriod);
    event WethUpdated(address indexed previousWeth, address indexed newWeth);

    error RouteZeroAddress();
    error RouteBadConfig();
    error StaleFeed(uint256 updatedAt, uint256 maxAge);
    error BadFeedAnswer();
    error UnderMinOut(uint256 received, uint256 minOut);
    error NoRoute(address token);
    error CannotRouteQuoteToken();
    error NothingToConvert();

    /// @dev Raised when the amount is so small that the Chainlink-derived minimum output
    ///      rounds to zero. Swapping then would be an unbounded swap, so it is refused.
    ///      Dust simply waits until enough accumulates to be priced.
    error AmountTooSmall(uint256 amountIn);

    /// @notice The router is not a Uniswap v3 router of the expected factory. SEC-POT-001.
    error RouterNotUniswapV3(address router);
    /// @notice The feed is pinned at its aggregator's floor or ceiling, so the price is a
    ///         circuit-breaker artefact rather than a market price. SEC-POT-005.
    error FeedAtBand(int256 answer);
    /// @notice The L2 sequencer is down, or has not been back long enough to trust. SEC-POT-003.
    error SequencerDown();
    error SequencerGracePeriod(uint256 backAt, uint64 graceEndsAt);
    /// @notice Below the route's `minPerCall` floor. SEC-POT-004.
    error BelowMinPerCall(uint256 amountIn, uint128 minPerCall);
    /// @notice A caller-supplied `minOut` the Chainlink floor could not be raised to meet.
    error NotAContract(address target);

    constructor(address quoteToken_, address uniswapV3Factory_) {
        if (quoteToken_ == address(0) || uniswapV3Factory_ == address(0)) revert RouteZeroAddress();
        quoteToken = quoteToken_;
        quoteDecimals = IDecimals(quoteToken_).decimals();
        uniswapV3Factory = uniswapV3Factory_;
    }

    /* ------------------------------------------------------------------ */
    /*                               VIEWS                                  */
    /* ------------------------------------------------------------------ */

    function routeOf(address token) external view returns (Route memory) {
        return _routes[token];
    }

    function routedTokens() external view returns (address[] memory) {
        return _routedTokens;
    }

    /// @notice ETH plus WETH waiting to be converted, before the per-call cap.
    function convertibleBalance() public view returns (uint256) {
        uint256 wethBalance = weth == address(0) ? 0 : IERC20(weth).balanceOf(address(this));
        return address(this).balance + wethBalance;
    }

    /// @notice Balance of `token` waiting to be converted, before the per-call cap.
    /// @dev For WETH this includes native ETH, since ETH is wrapped on the way through.
    function convertibleBalance(address token) public view returns (uint256) {
        if (token == weth) return convertibleBalance();
        return IERC20(token).balanceOf(address(this));
    }

    /// @notice How much the next conversion of `token` would push through the pool.
    function nextConversionAmount(address token) public view returns (uint256) {
        uint256 total = convertibleBalance(token);
        uint256 cap = _routes[token].maxPerCall;
        return (cap != 0 && total > cap) ? cap : total;
    }

    /// @notice Minimum quote-token output a conversion of `amount` would insist on.
    function minOutFor(address token, uint256 amount) public view returns (uint256) {
        Route storage r = _routes[token];
        if (!r.enabled) revert NoRoute(token);

        _requireSequencerUp();

        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(r.feed).latestRoundData();
        if (answer <= 0) revert BadFeedAnswer();
        if (r.maxFeedAge != 0 && block.timestamp > updatedAt + r.maxFeedAge) {
            revert StaleFeed(updatedAt, r.maxFeedAge);
        }
        _requireInBand(r.feed, answer);

        // amount (tokenDecimals) x USD per token -> quote units, then the slippage haircut.
        uint256 gross =
            (amount * uint256(answer) * (10 ** quoteDecimals)) / (10 ** r.feedDecimals) / (10 ** r.tokenDecimals);
        return (gross * (BPS - r.maxSlippageBps)) / BPS;
    }

    /* ------------------------------------------------------------------ */
    /*                            INTERNALS                                 */
    /* ------------------------------------------------------------------ */

    /// @param callerMinOut A floor the caller insists on, on top of the Chainlink one. Zero
    ///        means "no opinion". SEC-POT-002: `convert` is permissionless so anyone can push
    ///        it along, but that also means it executes against whatever the pool says at the
    ///        moment it lands, bounded only by a 2% Chainlink haircut. A keeper holding a real
    ///        quote can pass a tighter number and refuse a worse fill. The floor can only ever
    ///        be raised — a caller cannot widen the Chainlink bound, only tighten it.
    function _convert(address token, uint256 callerMinOut) internal returns (uint256 amountIn, uint256 quoteOut) {
        Route storage r = _routes[token];

        amountIn = nextConversionAmount(token);
        if (amountIn == 0) revert NothingToConvert();
        // SEC-POT-004: a dust-sized conversion pays a full swap's gas and moves the pool for
        // nothing. Below the floor it simply waits for more to accumulate.
        if (r.minPerCall != 0 && amountIn < r.minPerCall) revert BelowMinPerCall(amountIn, r.minPerCall);

        uint256 minOut = minOutFor(token, amountIn);
        if (minOut == 0) revert AmountTooSmall(amountIn);
        if (callerMinOut > minOut) minOut = callerMinOut;

        // Wrap only the shortfall: WETH already held is used as-is.
        if (token == weth) {
            uint256 wethBalance = IERC20(weth).balanceOf(address(this));
            if (wethBalance < amountIn) IWETH(weth).deposit{value: amountIn - wethBalance}();
        }

        uint256 before = IERC20(quoteToken).balanceOf(address(this));

        IERC20(token).forceApprove(r.router, amountIn);
        IUniswapV3SwapRouter(r.router)
            .exactInputSingle(
                IUniswapV3SwapRouter.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: quoteToken,
                fee: r.fee,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
            );
        IERC20(token).forceApprove(r.router, 0);

        // Trust the measured delta, never the router's return value.
        quoteOut = IERC20(quoteToken).balanceOf(address(this)) - before;
        if (quoteOut < minOut) revert UnderMinOut(quoteOut, minOut);

        emit Converted(token, amountIn, quoteOut, minOut, msg.sender);
    }

    /// @dev SEC-POT-003. On an L2 a Chainlink feed keeps returning its last answer while the
    ///      sequencer is down, so "fresh enough" is not the same as "true". Chipworks
    ///      converts against that price, so a stale-but-recent mark is exactly the input an
    ///      arbitrageur wants us to trade on when the chain comes back.
    ///
    ///      Standard Base hygiene: `answer == 0` means up, anything else means down, and a
    ///      grace period after it returns stops us trading on the first, thinnest blocks.
    ///      Zero feed disables the check, so this is inert until configured and every
    ///      existing test is unaffected.
    function _requireSequencerUp() internal view {
        address feed = sequencerUptimeFeed;
        if (feed == address(0)) return;

        (, int256 up, uint256 startedAt,,) = IAggregatorV3(feed).latestRoundData();
        if (up != 0) revert SequencerDown();

        uint64 grace = sequencerGracePeriod;
        if (grace != 0 && block.timestamp < startedAt + grace) {
            revert SequencerGracePeriod(startedAt, uint64(startedAt) + grace);
        }
    }

    /// @dev SEC-POT-005. A Chainlink aggregator clamps its answer to `minAnswer`/`maxAnswer`.
    ///      In a crash the feed reports the FLOOR, not the market — which here would inflate
    ///      the expected output and make every conversion of that token revert `UnderMinOut`
    ///      for as long as the price stayed pinned. Reverting is the safe direction, but
    ///      reverting with a misleading reason is not: this fails as {FeedAtBand} so an
    ///      operator can tell "the pool moved" from "the oracle is at its circuit breaker".
    ///
    ///      The band lives on the AGGREGATOR behind the proxy, and not every feed exposes it.
    ///      Both hops are gas-capped staticcalls and a feed that does not answer simply skips
    ///      the check — this must never be the reason a healthy conversion fails.
    ///
    ///      Recovery if a token does get pinned: `disableRoute(token)` then
    ///      `sweepNonQuote(token, ...)`. Both already existed; see TRIAGE SEC-POT-005.
    function _requireInBand(address feed, int256 answer) internal view {
        (bool okAgg, bytes memory aggRet) = feed.staticcall{gas: PROBE_GAS}(abi.encodeWithSignature("aggregator()"));
        if (!okAgg || aggRet.length < 32) return;
        address agg = abi.decode(aggRet, (address));
        if (agg == address(0)) return;

        (bool okMin, bytes memory minRet) = agg.staticcall{gas: PROBE_GAS}(abi.encodeWithSignature("minAnswer()"));
        if (okMin && minRet.length >= 32) {
            int256 minAnswer = abi.decode(minRet, (int256));
            if (answer <= minAnswer) revert FeedAtBand(answer);
        }

        (bool okMax, bytes memory maxRet) = agg.staticcall{gas: PROBE_GAS}(abi.encodeWithSignature("maxAnswer()"));
        if (okMax && maxRet.length >= 32) {
            int256 maxAnswer = abi.decode(maxRet, (int256));
            if (answer >= maxAnswer) revert FeedAtBand(answer);
        }
    }

    function _setSequencerFeed(address feed, uint64 gracePeriod) internal {
        sequencerUptimeFeed = feed;
        sequencerGracePeriod = gracePeriod;
        emit SequencerFeedUpdated(feed, gracePeriod);
    }

    function _setWeth(address weth_) internal {
        if (weth_ == address(0)) revert RouteZeroAddress();
        emit WethUpdated(weth, weth_);
        weth = weth_;
    }

    function _setRoute(
        address token,
        address feed,
        address router,
        uint24 fee,
        uint32 maxSlippageBps,
        uint128 maxPerCall,
        uint128 minPerCall,
        uint64 maxFeedAge
    ) internal {
        if (token == address(0) || feed == address(0) || router == address(0)) {
            revert RouteZeroAddress();
        }
        if (token == quoteToken) revert CannotRouteQuoteToken();
        if (fee == 0 || maxSlippageBps >= BPS || maxPerCall == 0) revert RouteBadConfig();
        if (minPerCall > maxPerCall) revert RouteBadConfig();

        // SEC-POT-001. This contract can only encode Uniswap v3 calldata, so it accepts only
        // a Uniswap v3 router. A Slipstream router reports the Slipstream factory and is
        // rejected here rather than reverting on an ABI mismatch at conversion time.
        _requireUniswapV3Router(router);

        uint8 tokenDecimals = _probeDecimals(token);
        uint8 feedDecimals = IAggregatorV3(feed).decimals();
        if (feedDecimals == 0 || feedDecimals > 18) revert RouteBadConfig();

        if (_routes[token].feed == address(0)) _routedTokens.push(token);

        _routes[token] = Route({
            enabled: true,
            feed: feed,
            router: router,
            fee: fee,
            maxSlippageBps: maxSlippageBps,
            maxPerCall: maxPerCall,
            minPerCall: minPerCall,
            maxFeedAge: maxFeedAge,
            tokenDecimals: tokenDecimals,
            feedDecimals: feedDecimals
        });

        emit RouteSet(token, feed, router, fee, maxSlippageBps, maxPerCall, maxFeedAge);
    }

    function _disableRoute(address token) internal {
        _routes[token].enabled = false;
        emit RouteDisabled(token);
    }

    /// @dev Rejects anything that is not a Uniswap v3 router of our factory. The factory is
    ///      the discriminator that actually holds: Aerodrome Slipstream is a separate
    ///      protocol with a separate factory, so its router can never report ours. Not
    ///      gas-capped and not tolerant of failure — this is configuration time, and a router
    ///      that cannot answer `factory()` is one we should not be pointing money at.
    function _requireUniswapV3Router(address router) internal view {
        if (router.code.length == 0) revert NotAContract(router);
        (bool ok, bytes memory ret) = router.staticcall(abi.encodeWithSignature("factory()"));
        if (!ok || ret.length < 32) revert RouterNotUniswapV3(router);
        if (abi.decode(ret, (address)) != uniswapV3Factory) revert RouterNotUniswapV3(router);
    }

    /// @dev Gas-capped, per ASSUMPTIONS.md A-17. A token whose decimals cannot be read is
    ///      rejected rather than guessed at: getting this wrong silently mis-prices every
    ///      conversion of that token.
    function _probeDecimals(address token) internal view returns (uint8) {
        (bool ok, bytes memory ret) = token.staticcall{gas: PROBE_GAS}(abi.encodeWithSignature("decimals()"));
        if (!ok || ret.length != 32) revert RouteBadConfig();
        uint256 d = abi.decode(ret, (uint256));
        if (d == 0 || d > 36) revert RouteBadConfig();
        return uint8(d);
    }
}

interface IDecimals {
    function decimals() external view returns (uint8);
}
