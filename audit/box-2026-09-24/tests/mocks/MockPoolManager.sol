// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUnlockCallback, PoolKey, SwapParams} from "../../src/interfaces/IUniswapV4.sol";

/// @notice Uniswap v4 PoolManager test double for exact-input and exact-output swaps on one pair.
/// @dev Enforces the same accounting shape the real one does: work happens inside
///      {unlock}, the input is paid by sync -> transfer -> settle, the output is {take}n,
///      and the lock reverts if either side is left unbalanced. Must hold output inventory.
contract MockPoolManager {
    using SafeERC20 for IERC20;

    /// @dev out = in * num / den, keyed by (tokenIn, tokenOut).
    mapping(address => mapping(address => uint256)) public rateNum;
    mapping(address => mapping(address => uint256)) public rateDen;

    bool internal _unlocked;
    address internal _synced;
    uint256 internal _syncedBal;
    // Outstanding deltas for the current lock: owedIn must reach 0 via settle, owedOut via take.
    address internal _inToken;
    uint256 internal _owedIn;
    address internal _outToken;
    uint256 internal _owedOut;

    function setRate(address tokenIn, address tokenOut, uint256 num, uint256 den) external {
        rateNum[tokenIn][tokenOut] = num;
        rateDen[tokenIn][tokenOut] = den;
    }

    function unlock(bytes calldata data) external returns (bytes memory out) {
        require(!_unlocked, "locked");
        _unlocked = true;
        out = IUnlockCallback(msg.sender).unlockCallback(data);
        require(_owedIn == 0 && _owedOut == 0, "CurrencyNotSettled");
        _unlocked = false;
    }

    function swap(PoolKey memory key, SwapParams memory p, bytes calldata) external returns (int256) {
        require(_unlocked, "not unlocked");
        address tokenIn = p.zeroForOne ? key.currency0 : key.currency1;
        address tokenOut = p.zeroForOne ? key.currency1 : key.currency0;
        uint256 den = rateDen[tokenIn][tokenOut];
        uint256 num = rateNum[tokenIn][tokenOut];
        require(den != 0, "no rate");
        uint256 amountIn;
        uint256 amountOut;
        if (p.amountSpecified < 0) {
            // Exact input.
            amountIn = uint256(-p.amountSpecified);
            amountOut = amountIn * num / den;
        } else {
            // Exact output: charge the input that buys it, rounded up, as a pool would.
            amountOut = uint256(p.amountSpecified);
            amountIn = (amountOut * den + num - 1) / num;
        }
        _inToken = tokenIn;
        _owedIn = amountIn;
        _outToken = tokenOut;
        _owedOut = amountOut;
        int128 inDelta = -int128(int256(amountIn));
        int128 outDelta = int128(int256(amountOut));
        (int128 a0, int128 a1) = p.zeroForOne ? (inDelta, outDelta) : (outDelta, inDelta);
        return (int256(a0) << 128) | int256(uint256(uint128(a1)));
    }

    function sync(address currency) external {
        _synced = currency;
        _syncedBal = IERC20(currency).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        paid = IERC20(_synced).balanceOf(address(this)) - _syncedBal;
        if (_synced == _inToken) _owedIn = paid >= _owedIn ? 0 : _owedIn - paid;
    }

    function take(address currency, address to, uint256 amount) external {
        require(currency == _outToken && amount <= _owedOut, "take too much");
        _owedOut -= amount;
        IERC20(currency).safeTransfer(to, amount);
    }
}
