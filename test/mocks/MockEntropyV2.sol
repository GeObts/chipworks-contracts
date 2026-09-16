// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Pyth Entropy v2 test double. Records the requester and lets tests fulfill.
contract MockEntropyV2 {
    uint128 public fee = 0.001 ether;
    uint64 public nextSeq = 1;
    mapping(uint64 => address) public requester;
    mapping(uint64 => uint32) public gasLimitOf;

    error Underpaid();

    function setFee(uint128 v) external {
        fee = v;
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

    function fulfill(uint64 sequence, bytes32 randomNumber) external {
        address target = requester[sequence];
        IEntropyCallback(target)._entropyCallback(sequence, address(this), randomNumber);
    }

    function _request(uint32 gasLimit) internal returns (uint64 seq) {
        if (msg.value < fee) revert Underpaid();
        seq = nextSeq++;
        requester[seq] = msg.sender;
        gasLimitOf[seq] = gasLimit;
    }
}

interface IEntropyCallback {
    function _entropyCallback(uint64 sequence, address provider, bytes32 randomNumber) external;
}
