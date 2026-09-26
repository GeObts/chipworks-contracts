// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Which AMM a stock is bought on. Stored per stock so depth can migrate
///         between venues without redeploying anything.
enum Venue {
    None, // not configured yet
    UniswapV3, // uses `fee`
    Slipstream // Aerodrome concentrated liquidity, uses `tickSpacing`
}

/// @notice Everything Chipworks knows about one tokenized stock.
struct Stock {
    // --- slot 0 ---
    address pool; // AMM pool against the registry quote token
    uint24 fee; // UniswapV3 fee tier, e.g. 3000 == 0.3%
    int24 tickSpacing; // Slipstream tick spacing
    bool registered;
    bool enabled;
    Venue venue;
    // --- slot 1 ---
    address feed; // Chainlink aggregator, USD-denominated
    uint8 tokenDecimals; // cached, B20 stocks are 8
    uint8 feedDecimals; // cached, Chainlink USD feeds are typically 8
    // --- slot 2 ---
    uint128 minLiquidityUsd; // 18-decimal USD, gate for enabling
}

interface IStockRegistry {
    function quoteToken() external view returns (address);
    function quoteDecimals() external view returns (uint8);

    /// @notice The factory each venue's pools are derived from. Immutable on the registry.
    /// @dev Exposed so a consumer can check that a ROUTER it is about to be pointed at belongs
    ///      to the same factory this registry resolves pools from. `ChipRounds.setRouters`
    ///      does exactly that: a router on the wrong factory cannot reach a single pool the
    ///      registry registered, and would revert every buy.
    function uniswapV3Factory() external view returns (address);
    function slipstreamFactory() external view returns (address);
    function isEnabled(address token) external view returns (bool);
    function getStock(address token) external view returns (Stock memory);
    function enabledTokens() external view returns (address[] memory);
    function allTokens() external view returns (address[] memory);
    function priceUsd(address token) external view returns (uint256 price1e18, uint256 updatedAt);
    function poolLiquidityUsd(address token) external view returns (uint256);
    function clearsMinLiquidity(address token) external view returns (bool);
}
