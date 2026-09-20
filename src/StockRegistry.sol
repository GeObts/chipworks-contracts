// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IStockRegistry, Stock, Venue} from "./interfaces/IStockRegistry.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IUniswapV3Factory, ISlipstreamFactory} from "./interfaces/IAmmFactories.sol";

/// @title StockRegistry
/// @notice The DAO-controlled list of tokenized stocks Chipworks may buy, and where to
///         buy each one. Owned by the multisig.
///
/// @dev Design notes:
///      - VENUE IS PER STOCK. Each entry stores whether it trades on Uniswap v3 or on
///        Aerodrome Slipstream, plus the pool and that venue's parameter (fee tier or
///        tick spacing). If a stock's depth migrates to another venue later, the multisig
///        flips two fields instead of redeploying. The round buyer reads the venue from
///        here and takes the matching code path, so the keeper stays fully on-chain with
///        no aggregator and no off-chain quotes.
///      - POOLS ARE VERIFIED, NOT TRUSTED. Whenever a pool is set, the registry asks the
///        venue's own factory whether that pool really is the (stock, quote, param) pool.
///        A fat-fingered pool address cannot be stored.
///      - REGISTER EARLY, ENABLE LATE. A stock may be registered before any pool exists
///        for it, which is the situation today for TSLA, AMZN, MSFT, COIN and MSTR. It
///        simply cannot be enabled until a verified pool and feed are set and its depth
///        clears `minLiquidityUsd`.
///      - THE DEPTH GATE IS ENFORCED ON CHAIN. `setEnabled(token, true)` reverts unless
///        the pool's measured liquidity clears the stock's threshold, so "enabled when
///        depth clears minLiquidityUsd" is a rule the contract keeps, not a promise a
///        human remembers. Lowering the bar is a separate, visible multisig action.
///      - NOTHING IS HARDCODED. Quote token, both factories, every threshold and every
///        venue parameter are constructor arguments or multisig-settable fields.
contract StockRegistry is IStockRegistry, Ownable2Step {
    /// @notice Token every stock is quoted and bought against. USDC on Base.
    address public immutable override quoteToken;

    /// @notice Cached decimals of `quoteToken`.
    uint8 public immutable override quoteDecimals;

    /// @notice Uniswap v3 factory used to verify `Venue.UniswapV3` pools.
    address public immutable override uniswapV3Factory;

    /// @notice Aerodrome Slipstream factory used to verify `Venue.Slipstream` pools.
    address public immutable override slipstreamFactory;

    /// @notice Gas cap for the optional `decimals()` cross-check in {addStock}.
    /// @dev Bounds the loss when the probe hits a non-executable address. See {_checkedDecimals}.
    uint256 public constant DECIMALS_PROBE_GAS = 50_000;

    mapping(address token => Stock) internal _stocks;
    address[] internal _tokenList;

    event StockAdded(address indexed token, address indexed feed, uint128 minLiquidityUsd);
    event VenueUpdated(address indexed token, Venue venue, address indexed pool, uint24 fee, int24 tickSpacing);
    event FeedUpdated(address indexed token, address indexed previousFeed, address indexed newFeed);
    event MinLiquidityUpdated(address indexed token, uint128 previousMin, uint128 newMin);
    event EnabledUpdated(address indexed token, bool enabled);

    error ZeroAddress();
    error AlreadyRegistered(address token);
    error NotRegistered(address token);
    error InvalidVenue();
    error PoolNotFoundInFactory(address token, address pool);
    error DecimalsMismatch(address token, uint8 provided, uint8 actual);
    error FeedNotSet(address token);
    error PoolNotSet(address token);
    error InsufficientLiquidity(address token, uint256 measuredUsd, uint256 requiredUsd);
    error BadFeedAnswer(address token);
    error AlreadyInThatState();

    /// @param multisig            Owner.
    /// @param quoteToken_         USDC on Base.
    /// @param uniswapV3Factory_   Uniswap v3 factory on Base.
    /// @param slipstreamFactory_  Aerodrome Slipstream (CL) factory on Base.
    constructor(address multisig, address quoteToken_, address uniswapV3Factory_, address slipstreamFactory_)
        Ownable(multisig)
    {
        if (quoteToken_ == address(0) || uniswapV3Factory_ == address(0) || slipstreamFactory_ == address(0)) {
            revert ZeroAddress();
        }
        quoteToken = quoteToken_;
        quoteDecimals = IERC20Metadata(quoteToken_).decimals();
        uniswapV3Factory = uniswapV3Factory_;
        slipstreamFactory = slipstreamFactory_;
    }

    /* ------------------------------------------------------------------ */
    /*                            REGISTRATION                              */
    /* ------------------------------------------------------------------ */

    /// @notice Arguments for {addStock}, grouped to keep the call readable.
    /// @param token           The B20 stock token.
    /// @param feed            Chainlink USD aggregator. May be zero and set later.
    /// @param venue           Where it trades. May be `None` and set later.
    /// @param pool            Pool for that venue. May be zero and set later.
    /// @param fee             Uniswap v3 fee tier. Ignored for other venues.
    /// @param tickSpacing     Slipstream tick spacing. Ignored for other venues.
    /// @param minLiquidityUsd 18-decimal USD depth required before this stock can be enabled.
    /// @param tokenDecimals   Expected decimals. Cross-checked against the token when the
    ///                        token is callable; B20 stocks are 8.
    struct AddStockParams {
        address token;
        address feed;
        Venue venue;
        address pool;
        uint24 fee;
        int24 tickSpacing;
        uint128 minLiquidityUsd;
        uint8 tokenDecimals;
    }

    /// @notice Register a stock. Always starts disabled.
    function addStock(AddStockParams calldata p) external onlyOwner {
        if (p.token == address(0)) revert ZeroAddress();
        if (_stocks[p.token].registered) revert AlreadyRegistered(p.token);

        Stock storage s = _stocks[p.token];
        s.registered = true;
        s.enabled = false;
        s.tokenDecimals = _checkedDecimals(p.token, p.tokenDecimals);
        s.minLiquidityUsd = p.minLiquidityUsd;

        _tokenList.push(p.token);
        emit StockAdded(p.token, p.feed, p.minLiquidityUsd);

        if (p.feed != address(0)) _setFeed(p.token, p.feed);
        if (p.venue != Venue.None || p.pool != address(0)) {
            _setVenue(p.token, p.venue, p.pool, p.fee, p.tickSpacing);
        }
        emit MinLiquidityUpdated(p.token, 0, p.minLiquidityUsd);
    }

    /// @notice Point a stock at a different venue or pool. Multisig only.
    /// @dev The pool is verified against that venue's factory before it is stored.
    function setVenue(address token, Venue venue, address pool, uint24 fee, int24 tickSpacing) external onlyOwner {
        _requireRegistered(token);
        _setVenue(token, venue, pool, fee, tickSpacing);
    }

    /// @notice Change a stock's Chainlink feed. Multisig only.
    function setFeed(address token, address feed) external onlyOwner {
        _requireRegistered(token);
        if (feed == address(0)) revert ZeroAddress();
        _setFeed(token, feed);
    }

    /// @notice Change the depth a stock must clear before it can be enabled. Multisig only.
    /// @dev Disables an enabled stock if it no longer clears the updated gate.
    function setMinLiquidityUsd(address token, uint128 newMin) external onlyOwner {
        _requireRegistered(token);
        Stock storage s = _stocks[token];
        emit MinLiquidityUpdated(token, s.minLiquidityUsd, newMin);
        s.minLiquidityUsd = newMin;
        if (s.enabled && !clearsMinLiquidity(token)) {
            s.enabled = false;
            emit EnabledUpdated(token, false);
        }
    }

    /// @notice Enable or disable a stock. Multisig only.
    /// @dev Enabling requires a feed, a verified pool, and measured depth at or above
    ///      `minLiquidityUsd`. Disabling is always allowed and never blocked, so a stock
    ///      whose market breaks can always be switched off.
    function setEnabled(address token, bool enabled) external onlyOwner {
        _requireRegistered(token);
        Stock storage s = _stocks[token];
        if (s.enabled == enabled) revert AlreadyInThatState();

        if (enabled) {
            if (s.feed == address(0)) revert FeedNotSet(token);
            if (s.pool == address(0) || s.venue == Venue.None) revert PoolNotSet(token);
            uint256 measured = poolLiquidityUsd(token);
            if (measured < s.minLiquidityUsd) {
                revert InsufficientLiquidity(token, measured, s.minLiquidityUsd);
            }
        }

        s.enabled = enabled;
        emit EnabledUpdated(token, enabled);
    }

    /* ------------------------------------------------------------------ */
    /*                               VIEWS                                  */
    /* ------------------------------------------------------------------ */

    function isEnabled(address token) external view override returns (bool) {
        return _stocks[token].enabled;
    }

    function isRegistered(address token) external view returns (bool) {
        return _stocks[token].registered;
    }

    function getStock(address token) external view override returns (Stock memory) {
        return _stocks[token];
    }

    function stockCount() external view returns (uint256) {
        return _tokenList.length;
    }

    function tokenAt(uint256 i) external view returns (address) {
        return _tokenList[i];
    }

    function allTokens() external view override returns (address[] memory) {
        return _tokenList;
    }

    /// @notice Every currently enabled stock, in registration order.
    function enabledTokens() external view override returns (address[] memory out) {
        uint256 n;
        uint256 len = _tokenList.length;
        for (uint256 i; i < len; ++i) {
            if (_stocks[_tokenList[i]].enabled) ++n;
        }
        out = new address[](n);
        uint256 k;
        for (uint256 i; i < len; ++i) {
            address t = _tokenList[i];
            if (_stocks[t].enabled) out[k++] = t;
        }
    }

    /// @notice Chainlink USD price for one whole token, scaled to 18 decimals.
    /// @dev Reverts if the feed is unset or returns a non-positive answer. Staleness is
    ///      deliberately NOT judged here: B20 equity feeds have no heartbeat outside
    ///      market hours and legitimately hold the last close, so the freshness policy
    ///      belongs to the round logic that consumes it, not to the registry.
    ///      See ASSUMPTIONS.md A-14.
    function priceUsd(address token) public view override returns (uint256 price1e18, uint256 updatedAt) {
        Stock storage s = _stocks[token];
        if (s.feed == address(0)) revert FeedNotSet(token);
        (, int256 answer,, uint256 updatedAt_,) = IAggregatorV3(s.feed).latestRoundData();
        if (answer <= 0) revert BadFeedAnswer(token);
        price1e18 = uint256(answer) * (10 ** (18 - s.feedDecimals));
        updatedAt = updatedAt_;
    }

    /// @notice Raw token balances sitting in the stock's pool.
    function poolBalances(address token) public view returns (uint256 stockBalance, uint256 quoteBalance) {
        Stock storage s = _stocks[token];
        if (s.pool == address(0)) revert PoolNotSet(token);
        stockBalance = IERC20(token).balanceOf(s.pool);
        quoteBalance = IERC20(quoteToken).balanceOf(s.pool);
    }

    /// @notice Total value in the stock's pool, in 18-decimal USD.
    /// @dev Both sides valued: the quote side at par, the stock side at the Chainlink mark.
    ///      This is a headline TVL figure. It is NOT tradeable depth: Uniswap v3 and
    ///      Slipstream are concentrated, so the amount actually buyable near spot is a
    ///      fraction of this. Set `minLiquidityUsd` with that haircut in mind, and keep
    ///      the per-stock max-impact check in the round logic as the real protection.
    function poolLiquidityUsd(address token) public view override returns (uint256) {
        (uint256 stockBalance, uint256 quoteBalance) = poolBalances(token);
        (uint256 price1e18,) = priceUsd(token);
        Stock storage s = _stocks[token];

        uint256 stockSideUsd = (stockBalance * price1e18) / (10 ** s.tokenDecimals);
        uint256 quoteSideUsd = (quoteBalance * 1e18) / (10 ** quoteDecimals);
        return stockSideUsd + quoteSideUsd;
    }

    /// @notice Whether this stock would pass the depth gate right now.
    /// @dev Never reverts. Returns false when the stock is unconfigured or the feed is bad,
    ///      so a deploy-time script can sweep the whole registry in one call.
    function clearsMinLiquidity(address token) public view override returns (bool) {
        Stock storage s = _stocks[token];
        if (!s.registered || s.pool == address(0) || s.feed == address(0) || s.venue == Venue.None) return false;
        try this.poolLiquidityUsd(token) returns (uint256 measured) {
            return measured >= s.minLiquidityUsd;
        } catch {
            return false;
        }
    }

    /// @notice One-call sweep for the launch decision: every registered stock, its measured
    ///         depth, its threshold, and whether it clears.
    function liquidityReport()
        external
        view
        returns (address[] memory tokens, uint256[] memory measuredUsd, uint256[] memory requiredUsd, bool[] memory ok)
    {
        uint256 len = _tokenList.length;
        tokens = _tokenList;
        measuredUsd = new uint256[](len);
        requiredUsd = new uint256[](len);
        ok = new bool[](len);
        for (uint256 i; i < len; ++i) {
            address t = _tokenList[i];
            requiredUsd[i] = _stocks[t].minLiquidityUsd;
            try this.poolLiquidityUsd(t) returns (uint256 m) {
                measuredUsd[i] = m;
            } catch {
                measuredUsd[i] = 0;
            }
            ok[i] = clearsMinLiquidity(t);
        }
    }

    /* ------------------------------------------------------------------ */
    /*                             INTERNALS                                */
    /* ------------------------------------------------------------------ */

    function _requireRegistered(address token) internal view {
        if (!_stocks[token].registered) revert NotRegistered(token);
    }

    function _setFeed(address token, address feed) internal {
        Stock storage s = _stocks[token];
        emit FeedUpdated(token, s.feed, feed);
        s.feed = feed;
        s.feedDecimals = IAggregatorV3(feed).decimals();
    }

    /// @dev Verifies the pool against the venue's own factory before storing it.
    function _setVenue(address token, Venue venue, address pool, uint24 fee, int24 tickSpacing) internal {
        if (venue == Venue.None) {
            if (pool != address(0)) revert InvalidVenue();
        } else {
            if (pool == address(0)) revert ZeroAddress();
            address expected;
            if (venue == Venue.UniswapV3) {
                if (fee == 0) revert InvalidVenue();
                expected = IUniswapV3Factory(uniswapV3Factory).getPool(token, quoteToken, fee);
            } else if (venue == Venue.Slipstream) {
                if (tickSpacing == 0) revert InvalidVenue();
                expected = ISlipstreamFactory(slipstreamFactory).getPool(token, quoteToken, tickSpacing);
            } else {
                revert InvalidVenue();
            }
            if (expected != pool) revert PoolNotFoundInFactory(token, pool);
        }

        Stock storage s = _stocks[token];
        s.venue = venue;
        s.pool = pool;
        s.fee = fee;
        s.tickSpacing = tickSpacing;

        // A venue change can invalidate the depth that justified enabling. Force a
        // fresh, explicit re-enable rather than silently carrying the flag across.
        if (s.enabled) {
            s.enabled = false;
            emit EnabledUpdated(token, false);
        }
        emit VenueUpdated(token, venue, pool, fee, tickSpacing);
    }

    /// @dev B20 stock tokens are native precompiles. They answer correctly on a real node
    ///      but are not executable inside a forked EVM, so `decimals()` can fail in
    ///      simulation. Cross-check when the call works, trust the caller when it does not.
    ///      See ASSUMPTIONS.md A-15.
    ///
    ///      This uses a GAS-CAPPED staticcall rather than try/catch on purpose. A forked
    ///      precompile fails with OpcodeNotFound, which consumes every wei of gas handed to
    ///      the subcall — with plain try/catch a single registration burns the whole block
    ///      budget and the second one in the same transaction runs out. The cap bounds the
    ///      loss to `DECIMALS_PROBE_GAS`, which is far more than a real `decimals()` needs.
    function _checkedDecimals(address token, uint8 provided) internal view returns (uint8) {
        (bool ok, bytes memory ret) =
            token.staticcall{gas: DECIMALS_PROBE_GAS}(abi.encodeWithSelector(IERC20Metadata.decimals.selector));

        if (ok && ret.length == 32) {
            uint256 actual = abi.decode(ret, (uint256));
            if (actual <= type(uint8).max) {
                if (uint8(actual) != provided) revert DecimalsMismatch(token, provided, uint8(actual));
                return uint8(actual);
            }
        }
        return provided;
    }
}
