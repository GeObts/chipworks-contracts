// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MultiplierToken
/// @notice A token whose balances rebase with a multiplier, used to prove Chipworks is
///         indifferent to one.
///
/// @dev READ THIS BEFORE ASSUMING IT MODELS B20. It deliberately does NOT.
///
///      ASSUMPTIONS A-13 describes the Coinbase multiplier as living in the **valuation**:
///      the feed reports underlying price x multiplier, so a cash dividend converts to
///      shares and raises the multiplier, and a 10:1 split raises it from 1.0 to 10.0 so the
///      token's quoted price stays continuous. On that reading **balances never change** —
///      one B20 token stays one B20 token, it is just not permanently one share.
///
///      `test/b20/MultiplierIndifference.t.sol` tests that documented mechanism directly,
///      by moving the feed. This contract exists for the OTHER half: the mechanism we have
///      NOT been able to rule out, where a corporate action rebases holders' balances
///      instead. B20 tokens are node-native precompiles (A-15) with no readable
///      implementation, so "balances never rebase" is an inference from a valuation
///      sentence, not something anyone has verified.
///
///      So this is a hedge, and it is worth having because a rebase is historically where
///      accounting built on remembered amounts goes wrong: **a holder's balance changes with
///      nobody calling transfer.** If the inference is right, these tests are free. If it is
///      wrong, they are the ones that matter.
///
///      Internally it stores SHARES and reports `shares * multiplier / 1e18`, which is how a
///      real rebasing token behaves. Transfers move shares. Rounding is left as plain
///      integer division rather than smoothed, because that is where the dust lives.
contract MultiplierToken {
    string public name;
    string public symbol;
    uint8 public immutable decimals;

    /// @notice 1e18 = 1.0x. Raised by dividends and forward splits.
    uint256 public multiplier = 1e18;

    mapping(address => uint256) public sharesOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalShares;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event MultiplierSet(uint256 previous, uint256 current);

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    /* ------------------------------ corporate actions ----------------------------- */

    /// @notice Apply a dividend or a split. `newMultiplier` is 1e18-scaled.
    function setMultiplier(uint256 newMultiplier) external {
        require(newMultiplier != 0, "zero multiplier");
        emit MultiplierSet(multiplier, newMultiplier);
        multiplier = newMultiplier;
    }

    /// @notice A cash dividend converted to shares: +`bps` basis points of value.
    function applyDividend(uint256 bps) external {
        multiplier = (multiplier * (10_000 + bps)) / 10_000;
    }

    /// @notice A forward split, e.g. `ratio = 10` for 10:1.
    function applySplit(uint256 ratio) external {
        multiplier = multiplier * ratio;
    }

    /* ---------------------------------- ERC-20 ------------------------------------ */

    function totalSupply() external view returns (uint256) {
        return (totalShares * multiplier) / 1e18;
    }

    function balanceOf(address who) public view returns (uint256) {
        return (sharesOf[who] * multiplier) / 1e18;
    }

    function mint(address to, uint256 amount) external {
        uint256 shares = (amount * 1e18) / multiplier;
        sharesOf[to] += shares;
        totalShares += shares;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amount, "allowance");
            allowance[from][msg.sender] = a - amount;
        }
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        uint256 shares = (amount * 1e18) / multiplier;
        require(sharesOf[from] >= shares, "balance");
        sharesOf[from] -= shares;
        sharesOf[to] += shares;
        emit Transfer(from, to, amount);
    }
}
