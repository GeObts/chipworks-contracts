// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Chainlink AggregatorV3 read surface.
/// @dev Base tokenized-equity feeds use this standard interface. Note they have no
///      heartbeat while equity markets are closed and hold the last close instead,
///      so `updatedAt` going stale on a weekend is expected, not a fault.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
