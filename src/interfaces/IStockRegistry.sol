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
    function isEnabled(address token) external view returns (bool);
    function getStock(address token) external view returns (Stock memory);
    function enabledTokens() external view returns (address[] memory);
    function allTokens() external view returns (address[] memory);
    function priceUsd(address token) external view returns (uint256 price1e18, uint256 updatedAt);
    /// @notice Validated buy-probe notional in 18-decimal USD, zero when unavailable.
    /// @dev Non-view for canonical quoter simulation; off-chain callers use eth_call.
    function poolLiquidityUsd(address token) external returns (uint256);
    function clearsMinLiquidity(address token) external returns (bool);
}
