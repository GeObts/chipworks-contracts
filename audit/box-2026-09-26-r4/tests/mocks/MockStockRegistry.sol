// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Stock, Venue} from "../../src/interfaces/IStockRegistry.sol";

/// @notice StockRegistry test double: the reads PrizeVault makes, with settable marks.
contract MockStockRegistry {
    address public quoteToken;
    uint8 public quoteDecimals = 6;

    mapping(address => Stock) internal _stocks;
    mapping(address => uint256) public price1e18;
    mapping(address => uint256) public updatedAt;
    mapping(address => bool) public priceReverts;

    constructor(address quote) {
        quoteToken = quote;
    }

    function setStock(address token, Venue venue, uint24 fee, int24 tickSpacing, uint8 decimals, bool enabled) external {
        _stocks[token] = Stock({
            pool: address(0xBEEF),
            fee: fee,
            tickSpacing: tickSpacing,
            registered: true,
            enabled: enabled,
            venue: venue,
            feed: address(0xFEED),
            tokenDecimals: decimals,
            feedDecimals: 8,
            minLiquidityUsd: 0
        });
    }

    function setEnabled(address token, bool v) external {
        _stocks[token].enabled = v;
    }

    function setPrice(address token, uint256 p1e18) external {
        price1e18[token] = p1e18;
        updatedAt[token] = block.timestamp;
    }

    function setStalePrice(address token, uint256 p1e18, uint256 at) external {
        price1e18[token] = p1e18;
        updatedAt[token] = at;
    }

    function setPriceReverts(address token, bool v) external {
        priceReverts[token] = v;
    }

    function getStock(address token) external view returns (Stock memory) {
        return _stocks[token];
    }

    function isEnabled(address token) external view returns (bool) {
        return _stocks[token].enabled;
    }

    function priceUsd(address token) external view returns (uint256, uint256) {
        require(!priceReverts[token], "feed down");
        return (price1e18[token], updatedAt[token]);
    }
}
