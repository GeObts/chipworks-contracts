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
///      by moving the feed. This contract exists for the OTHER half: a corporate action that
///      rebases holders' balances instead.
///
///      **Base's own docs say that does not happen.** `B20_DOCS.md`, filed in this repo,
///      states that corporate actions are reflected *"without changing their balance of the
///      B20 token"* — `balanceOf` returns raw units a dividend or split does not move, and
///      `scaledBalanceOf` is the adjusted view. So this is a hedge against documentation
///      being wrong, not against an open question.
///
///      It is kept anyway, for a reason worth stating: **the failure shape is not unique to
///      a rebase.** Anything that reduces the ledger's balance below `totalOwed` produces it.
///      These tests describe that boundary — where the suite stops saying "cannot happen" and
///      starts saying "degrades safely" — and they are the tripwire if the documentation
///      turns out to be wrong. B20 tokens are precompiles with no readable implementation
///      (A-15), so a sentence is all anyone has.
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
