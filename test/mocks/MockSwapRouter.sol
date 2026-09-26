// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3SwapRouter, ISlipstreamSwapRouter} from "../../src/interfaces/ISwapRouters.sol";
import {IUniswapV3ExactOutput} from "../../src/interfaces/IUniswapV4.sol";

/// @notice Swap router test double. Pulls tokenIn, pays tokenOut at a configured rate from
///         its own inventory, and enforces amountOutMinimum the way a real router does.
/// @dev    Must be pre-funded with tokenOut. Rate is expressed as out = in * num / den, so
///         a test can model any price and any decimal pair exactly.
contract MockSwapRouter {
    using SafeERC20 for IERC20;

    mapping(address tokenIn => mapping(address tokenOut => uint256)) public rateNum;
    mapping(address tokenIn => mapping(address tokenOut => uint256)) public rateDen;
    bool public failNext;
    bool public failAlways;

    /// @notice The Uniswap v3 factory this router claims to belong to.
    /// @dev ConversionRoutes refuses any router whose `factory()` is not the expected one
    ///      (SEC-POT-001), so a test double has to answer it.
    address public factory;

    function setFactory(address f) external {
        factory = f;
    }

    error TooLittleReceived();
    error TooMuchRequested();
    error RouterDown();

    function setRate(address tokenIn, address tokenOut, uint256 num, uint256 den) external {
        rateNum[tokenIn][tokenOut] = num;
        rateDen[tokenIn][tokenOut] = den;
    }

    /// @notice A lying router (audit round 2, mutants M4/M8): ignores the minimum and delivers
    ///         half on exact input, and one unit short on exact output, without reverting.
    bool public lie;

    function setLie(bool v) external {
        lie = v;
    }

    function setFailNext(bool v) external {
        failNext = v;
    }

    function setFailAlways(bool v) external {
        failAlways = v;
    }

    function exactInputSingle(IUniswapV3SwapRouter.ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256)
    {
        return _swap(p.tokenIn, p.tokenOut, p.recipient, p.amountIn, p.amountOutMinimum);
    }

    function exactInputSingle(ISlipstreamSwapRouter.ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256)
    {
        return _swap(p.tokenIn, p.tokenOut, p.recipient, p.amountIn, p.amountOutMinimum);
    }

    /// @notice Uniswap v3 SwapRouter02 exact-output-single: charges the input that buys exactly
    ///         `amountOut` at the configured rate, rounded up, and enforces `amountInMaximum`.
    function exactOutputSingle(IUniswapV3ExactOutput.ExactOutputSingleParams calldata p)
        external
        payable
        returns (uint256 amountIn)
    {
        if (failAlways) revert RouterDown();
        uint256 num = rateNum[p.tokenIn][p.tokenOut];
        uint256 den = rateDen[p.tokenIn][p.tokenOut];
        require(den != 0, "no rate");
        amountIn = (p.amountOut * den + num - 1) / num;
        if (amountIn > p.amountInMaximum) revert TooMuchRequested();
        IERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(p.tokenOut).safeTransfer(p.recipient, lie ? p.amountOut - 1 : p.amountOut);
    }

    function _swap(address tokenIn, address tokenOut, address to, uint256 amountIn, uint256 minOut)
        internal
        returns (uint256 out)
    {
        if (failAlways) revert RouterDown();
        if (failNext) {
            failNext = false;
            revert RouterDown();
        }
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 den = rateDen[tokenIn][tokenOut];
        require(den != 0, "no rate");
        out = (amountIn * rateNum[tokenIn][tokenOut]) / den;
        if (lie) out /= 2;
        else if (out < minOut) revert TooLittleReceived();
        IERC20(tokenOut).safeTransfer(to, out);
    }
}
