// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Accepts ETH but burns a lot of gas doing it.
contract GreedyReceiver {
    uint256[] private junk;

    receive() external payable {
        for (uint256 i; i < 5; ++i) {
            junk.push(block.number + i);
        }
    }
}

/// @notice Rejects ETH until told otherwise.
/// @dev Toggleable so a test can escrow a payment and then show it becoming claimable once
///      the recipient is fixed — which is the whole point of the escrow.
contract RejectingReceiver {
    bool public accepting;

    function setAccepting(bool v) external {
        accepting = v;
    }

    receive() external payable {
        if (!accepting) revert("no eth");
    }
}

/// @notice Calls back into the splitter while receiving ETH.
/// @dev Target is settable so the receiver can be deployed BEFORE the splitter
///      that names it as a recipient, breaking the constructor cycle.
///      The re-entrant call result is RECORDED rather than bubbled, so a test can
///      assert that the outer call still succeeded while the inner one was rejected.
contract ReentrantReceiver {
    address public target;
    bytes public payload;
    bool public armed;

    bool public reentryAttempted;
    bool public reentrySucceeded;
    bytes public reentryReturnData;

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        armed = true;
    }

    receive() external payable {
        if (armed) {
            armed = false;
            reentryAttempted = true;
            (bool ok, bytes memory ret) = target.call(payload);
            reentrySucceeded = ok;
            reentryReturnData = ret;
        }
    }
}
