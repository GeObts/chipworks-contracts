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

    struct Route {
        bool enabled;
        address feed; // Chainlink <token>/USD aggregator
        address router; // Uniswap v3 style router
        uint24 fee; // pool fee tier
        uint32 maxSlippageBps; // how far below the Chainlink mark execution may land
        uint128 maxPerCall; // largest amount one convert() may push through the pool
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

    constructor(address quoteToken_) {
        if (quoteToken_ == address(0)) revert RouteZeroAddress();
        quoteToken = quoteToken_;
        quoteDecimals = IDecimals(quoteToken_).decimals();
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

        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(r.feed).latestRoundData();
        if (answer <= 0) revert BadFeedAnswer();
        if (r.maxFeedAge != 0 && block.timestamp > updatedAt + r.maxFeedAge) {
            revert StaleFeed(updatedAt, r.maxFeedAge);
        }

        // amount (tokenDecimals) x USD per token -> quote units, then the slippage haircut.
        uint256 gross =
            (amount * uint256(answer) * (10 ** quoteDecimals)) / (10 ** r.feedDecimals) / (10 ** r.tokenDecimals);
        return (gross * (BPS - r.maxSlippageBps)) / BPS;
    }

    /* ------------------------------------------------------------------ */
    /*                            INTERNALS                                 */
    /* ------------------------------------------------------------------ */

    function _convert(address token) internal returns (uint256 amountIn, uint256 quoteOut) {
        Route storage r = _routes[token];

        amountIn = nextConversionAmount(token);
        if (amountIn == 0) revert NothingToConvert();

        uint256 minOut = minOutFor(token, amountIn);
        if (minOut == 0) revert AmountTooSmall(amountIn);

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
        uint64 maxFeedAge
    ) internal {
        if (token == address(0) || feed == address(0) || router == address(0)) {
            revert RouteZeroAddress();
        }
        if (token == quoteToken) revert CannotRouteQuoteToken();
        if (fee == 0 || maxSlippageBps >= BPS || maxPerCall == 0) revert RouteBadConfig();

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
