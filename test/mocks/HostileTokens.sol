// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title HostileTokens
/// @notice Badly-behaved ERC-20s, ported from the BasedPacks test suite and adapted to
///         OpenZeppelin v5 (which replaced the before/after hooks with `_update`).
///
/// @dev These are not hypotheticals for Chipworks. Base's own B20 docs state that onchain
///      policies can block specific addresses and that a blocked transfer reverts, and that
///      the standard includes pause mechanisms. {BlacklistToken} and {PausableToken} are
///      therefore direct models of documented B20 behaviour, not paranoia.
///      See ASSUMPTIONS.md A-15.
contract HostileBase is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Owner can freeze addresses; any transfer touching one reverts.
///         Models a B20 policy block, a USDT-style freeze, or a post-hoc honeypot.
contract BlacklistToken is HostileBase {
    mapping(address => bool) public blacklisted;

    constructor(string memory n, string memory s, uint8 d) HostileBase(n, s, d) {}

    function setBlacklisted(address account, bool b) external {
        blacklisted[account] = b;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blacklisted[from] && !blacklisted[to], "BLACKLISTED");
        super._update(from, to, value);
    }
}

/// @notice Globally pausable. Models a token team pausing mid-round.
contract PausableToken is HostileBase {
    bool public paused;

    constructor(string memory n, string memory s, uint8 d) HostileBase(n, s, d) {}

    function setPaused(bool p) external {
        paused = p;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) require(!paused, "PAUSED");
        super._update(from, to, value);
    }
}

/// @notice Reports success but silently moves nothing. Only balance-delta checks catch it;
///         a return-value check such as SafeERC20 does not.
contract LyingToken is HostileBase {
    bool public lying;

    constructor(string memory n, string memory s, uint8 d) HostileBase(n, s, d) {}

    function setLying(bool l) external {
        lying = l;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (lying) return true;
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (lying) return true;
        return super.transferFrom(from, to, amount);
    }
}

/// @notice Charges a transfer tax, so the recipient receives less than `amount`.
contract FeeOnTransferToken is HostileBase {
    uint256 public immutable feeBps;

    constructor(string memory n, string memory s, uint8 d, uint256 feeBps_) HostileBase(n, s, d) {
        feeBps = feeBps_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * feeBps) / 10_000;
        super._update(from, address(0xdead), fee);
        super._update(from, to, value - fee);
    }
}

/// @notice Returns false instead of reverting.
contract FalseReturnToken is HostileBase {
    constructor() HostileBase("False", "FALSE", 18) {}

    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }
}
