// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IEntropyV2
/// @notice Minimal Pyth Entropy v2 surface used by ChipWorks Box.
/// @dev Full interface: https://github.com/pyth-network/pyth-crosschain (Apache-2.0).
///      Base mainnet Entropy: 0x6E7D74FA7d5c90FEF9F0512987605a6d546181Bb.
///      Always read {getFeeV2} immediately before {requestV2}; the fee is not constant.
interface IEntropyV2 {
    /// @notice EntropyStructsV2.Request, field for field (read from the verified Base
    ///         implementation 0x4ced6985…b83b). Order is load-bearing for the ABI decode.
    struct RequestV2 {
        address provider;
        uint64 sequenceNumber;
        uint32 numHashes;
        bytes32 commitment;
        uint64 blockNumber;
        address requester;
        bool useBlockhash;
        /// @dev EntropyStatusConstants: 0 no callback, 1 NOT_STARTED, 2 IN_PROGRESS, 3 FAILED.
        uint8 callbackStatus;
        uint16 gasLimit10k;
    }

    function getRequestV2(address provider, uint64 sequenceNumber) external view returns (RequestV2 memory req);

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
