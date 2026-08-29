// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @notice Chainlink feed test double, including the off-hours "held last close" shape.
contract MockAggregatorV3 is IAggregatorV3 {
    uint8 public immutable override decimals;
    string public override description;

    uint80 internal _roundId = 1;
    int256 internal _answer;
    uint256 internal _updatedAt;
    bool internal _revertOnRead;

    constructor(uint8 decimals_, int256 answer_, string memory description_) {
        decimals = decimals_;
        _answer = answer_;
        _updatedAt = block.timestamp;
        description = description_;
    }

    function setAnswer(int256 answer_) external {
        _answer = answer_;
        _updatedAt = block.timestamp;
        ++_roundId;
    }

    /// @notice Set the answer while leaving `updatedAt` in the past, as happens when
    ///         equity markets are closed and the feed holds the last close.
    function setStaleAnswer(int256 answer_, uint256 updatedAt_) external {
        _answer = answer_;
        _updatedAt = updatedAt_;
        ++_roundId;
    }

    function setRevertOnRead(bool v) external {
        _revertOnRead = v;
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        require(!_revertOnRead, "feed down");
        return (_roundId, _answer, _updatedAt, _updatedAt, _roundId);
    }
}
