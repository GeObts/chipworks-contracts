// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The minimal surface {ChipRounds} needs on {ChipClaims}.
/// @dev Four writes and two reads. None of the writes can move a token out of the ledger,
///      which is the whole point of the split: the engine can create entitlements and hand
///      over assets, but only the ledger can pay anyone.
interface IChipClaims {
    function creditWeight(uint256 roundId, address stock, address owner, uint256 weight) external;
    function recordAcquired(uint256 roundId, address stock, uint256 amount) external;
    function freezeSchedule(uint256 roundId) external returns (uint64 roundExpiresAt);

    function totalWeight(uint256 roundId, address stock) external view returns (uint256);
    function isFinalized(uint256 roundId) external view returns (bool);
}
