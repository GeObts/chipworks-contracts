// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title EtchableERC20
/// @notice A self-contained ERC-20 designed to be installed over an existing address
///         with `vm.etch`, then initialised.
/// @dev    Why this exists: the Coinbase B20 stock tokens on Base are node-native
///         addresses holding a single 0xef byte of code. A forked EVM cannot execute
///         them, so every Chipworks fork test that moves stock must install a real
///         ERC-20 in their place.
///
///         Everything lives in explicit storage slots and nothing is set in the
///         constructor, because `vm.etch` copies runtime code only, never storage.
///         Usage:
///             vm.etch(NVDA, address(new EtchableERC20()).code);
///             EtchableERC20(NVDA).init("NVIDIA Corporation", "NVDAc", 8);
contract EtchableERC20 {
    string private _name;
    string private _symbol;
    uint8 private _decimals;
    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function init(string memory n, string memory s, uint8 d) external {
        _name = n;
        _symbol = s;
        _decimals = d;
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address a) external view returns (uint256) {
        return _balances[a];
    }

    function allowance(address o, address s) external view returns (uint256) {
        return _allowances[o][s];
    }

    function mint(address to, uint256 amt) external {
        _totalSupply += amt;
        _balances[to] += amt;
        emit Transfer(address(0), to, amt);
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        _allowances[msg.sender][spender] = amt;
        emit Approval(msg.sender, spender, amt);
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _transfer(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        require(allowed >= amt, "allowance");
        if (allowed != type(uint256).max) _allowances[from][msg.sender] = allowed - amt;
        _transfer(from, to, amt);
        return true;
    }

    function _transfer(address from, address to, uint256 amt) internal {
        require(_balances[from] >= amt, "balance");
        unchecked {
            _balances[from] -= amt;
            _balances[to] += amt;
        }
        emit Transfer(from, to, amt);
    }
}
