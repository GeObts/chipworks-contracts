// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IEntropyV2
/// @notice Minimal Pyth Entropy v2 surface used by ChipWorks Box.
/// @dev Full interface: https://github.com/pyth-network/pyth-crosschain (Apache-2.0).
///      Base mainnet Entropy: 0x6E7D74FA7d5c90FEF9F0512987605a6d546181Bb.
///      Always read {getFeeV2} immediately before {requestV2}; the fee is not constant.
interface IEntropyV2 {
    function getDefaultProvider() external view returns (address provider);

    function getFeeV2() external view returns (uint128 feeAmount);

    function getFeeV2(uint32 gasLimit) external view returns (uint128 feeAmount);

    function getFeeV2(address provider, uint32 gasLimit) external view returns (uint128 feeAmount);

    function requestV2() external payable returns (uint64 assignedSequenceNumber);

    function requestV2(uint32 gasLimit) external payable returns (uint64 assignedSequenceNumber);

    function requestV2(address provider, uint32 gasLimit) external payable returns (uint64 assignedSequenceNumber);

    function requestV2(address provider, bytes32 userRandomNumber, uint32 gasLimit)
        external
        payable
        returns (uint64 assignedSequenceNumber);
}
