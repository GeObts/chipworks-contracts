// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The slice of ChipRewards the router needs.
interface IChipRewardsClaimable {
    function claimFor(address owner, uint256 roundId, address stock) external returns (uint256 amount);
    function claimable(uint256 roundId, address stock, address owner) external view returns (uint256);
    function isClaimOpen() external view returns (bool);
    function nextWindowOpensAt() external view returns (uint64);
}
