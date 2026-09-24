// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IEntropyV2} from "../../src/interfaces/IEntropyV2.sol";

/// @notice Pyth Entropy v2 test double. Records the requester and lets tests fulfill.
/// @dev Tracks the callback status the way Entropy does: 1 NOT_STARTED on request, cleared
///      (all zero) after a successful callback, 3 FAILED after a reverting one. {fulfill} calls
///      `_entropyCallback`, the selector the real Entropy calls.
contract MockEntropyV2 {
    uint128 public fee = 0.001 ether;
    uint64 public nextSeq = 1;
    mapping(uint64 => address) public requester;
    mapping(uint64 => uint32) public gasLimitOf;
    mapping(uint64 => uint8) public statusOf;

    error Underpaid();

    function setFee(uint128 v) external {
        fee = v;
    }

    /// @notice Force a status, e.g. 3 to model a callback that failed and published its number.
    function setStatus(uint64 sequence, uint8 status) external {
        statusOf[sequence] = status;
    }

    function getFeeV2() external view returns (uint128) {
        return fee;
    }

    function getFeeV2(uint32) external view returns (uint128) {
        return fee;
    }

    function getFeeV2(address, uint32) external view returns (uint128) {
        return fee;
    }

    function getDefaultProvider() external view returns (address) {
        return address(this);
    }

    function requestV2() external payable returns (uint64) {
        return _request(0);
    }

    function requestV2(uint32 gasLimit) external payable returns (uint64) {
        return _request(gasLimit);
    }

    function requestV2(address, uint32 gasLimit) external payable returns (uint64) {
        return _request(gasLimit);
    }

    function requestV2(address, bytes32, uint32 gasLimit) external payable returns (uint64) {
        return _request(gasLimit);
    }

    function getRequestV2(address provider, uint64 sequence) external view returns (IEntropyV2.RequestV2 memory r) {
        uint8 st = statusOf[sequence];
        if (st == 0) return r; // cleared, or never requested: all zero, as on Entropy
        r.provider = provider;
        r.sequenceNumber = sequence;
        r.requester = requester[sequence];
        r.callbackStatus = st;
        r.gasLimit10k = uint16(gasLimitOf[sequence] / 10_000);
    }

    function fulfill(uint64 sequence, bytes32 randomNumber) external {
        address target = requester[sequence];
        try IEntropyCallback(target)._entropyCallback(sequence, address(this), randomNumber) {
            statusOf[sequence] = 0;
        } catch {
            statusOf[sequence] = 3;
        }
    }

    function _request(uint32 gasLimit) internal returns (uint64 seq) {
        if (msg.value < fee) revert Underpaid();
        seq = nextSeq++;
        requester[seq] = msg.sender;
        gasLimitOf[seq] = gasLimit;
        statusOf[seq] = 1;
    }
}

interface IEntropyCallback {
    function _entropyCallback(uint64 sequence, address provider, bytes32 randomNumber) external;
}
