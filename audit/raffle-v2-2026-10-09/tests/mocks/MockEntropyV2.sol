// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IEntropyV2} from "../../src/interfaces/IEntropyV2.sol";

/// @notice Pyth Entropy v2 test double. Records the requester and lets tests fulfill.
/// @dev Like Entropy, sequence numbers are PER PROVIDER, and the default provider can change.
///      Tracks the callback status the way Entropy does: 1 NOT_STARTED on request, cleared
///      (all zero) after a successful callback, 3 FAILED after a reverting one. Fulfilment calls
///      `_entropyCallback`, the selector the real Entropy calls. {fulfill} and {setStatus} act on
///      the current default provider; {fulfillFrom} names one.
contract MockEntropyV2 {
    uint128 public fee = 0.001 ether;
    address public defaultProvider;
    mapping(address => uint64) internal _nextSeq;
    mapping(address => mapping(uint64 => address)) internal _requester;
    mapping(address => mapping(uint64 => uint32)) internal _gasLimit;
    mapping(address => mapping(uint64 => uint8)) internal _status;
    /// @notice The caller seed each seeded request carried, and request counters (all overloads
    ///         vs the seeded one) so a test can prove which overload a contract uses.
    mapping(address => mapping(uint64 => bytes32)) public userRandomOf;
    uint256 public seededRequests;
    uint256 public totalRequests;
    /// @notice Gas tests switch the bookkeeping above off: it is the MOCK's cost, not the caller's.
    bool public recordSeeds = true;

    function setRecordSeeds(bool on) external {
        recordSeeds = on;
    }

    error Underpaid();

    constructor() {
        defaultProvider = address(this);
    }

    function setFee(uint128 v) external {
        fee = v;
    }

    function setDefaultProvider(address p) external {
        defaultProvider = p;
    }

    /// @notice Force a status, e.g. 3 to model a callback that failed and published its number.
    function setStatus(uint64 sequence, uint8 status) external {
        _status[defaultProvider][sequence] = status;
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
        return defaultProvider;
    }

    function requestV2() external payable returns (uint64) {
        return _request(defaultProvider, 0);
    }

    function requestV2(uint32 gasLimit) external payable returns (uint64) {
        return _request(defaultProvider, gasLimit);
    }

    function requestV2(address provider, uint32 gasLimit) external payable returns (uint64) {
        return _request(provider, gasLimit);
    }

    function requestV2(address provider, bytes32 userRandomNumber, uint32 gasLimit)
        external
        payable
        returns (uint64 seq)
    {
        seq = _request(provider, gasLimit);
        if (!recordSeeds) return seq;
        userRandomOf[provider][seq] = userRandomNumber;
        seededRequests++;
    }

    function getRequestV2(address provider, uint64 sequence) external view returns (IEntropyV2.RequestV2 memory r) {
        uint8 st = _status[provider][sequence];
        if (st == 0) return r; // cleared, or never requested: all zero, as on Entropy
        r.provider = provider;
        r.sequenceNumber = sequence;
        r.requester = _requester[provider][sequence];
        r.callbackStatus = st;
        r.gasLimit10k = uint16(_gasLimit[provider][sequence] / 10_000);
    }

    function fulfill(uint64 sequence, bytes32 randomNumber) external {
        fulfillFrom(defaultProvider, sequence, randomNumber);
    }

    function fulfillFrom(address provider, uint64 sequence, bytes32 randomNumber) public {
        address target = _requester[provider][sequence];
        try IEntropyCallback(target)._entropyCallback(sequence, provider, randomNumber) {
            _status[provider][sequence] = 0;
        } catch {
            _status[provider][sequence] = 3;
        }
    }

    function _request(address provider, uint32 gasLimit) internal returns (uint64 seq) {
        if (msg.value < fee) revert Underpaid();
        if (recordSeeds) totalRequests++;
        seq = _nextSeq[provider] + 1;
        _nextSeq[provider] = seq;
        _requester[provider][seq] = msg.sender;
        _gasLimit[provider][seq] = gasLimit;
        _status[provider][seq] = 1;
    }
}

interface IEntropyCallback {
    function _entropyCallback(uint64 sequence, address provider, bytes32 randomNumber) external;
}
