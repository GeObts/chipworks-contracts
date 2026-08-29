// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUniswapV3Factory, ISlipstreamFactory} from "../../src/interfaces/IAmmFactories.sol";

/// @dev Both factories sort the token pair before keying, exactly as the real ones do,
///      so tests cannot accidentally depend on argument order.
contract MockUniswapV3Factory is IUniswapV3Factory {
    mapping(bytes32 => address) internal _pools;

    function setPool(address a, address b, uint24 fee, address pool) external {
        _pools[_key(a, b, uint256(fee))] = pool;
    }

    function getPool(address a, address b, uint24 fee) external view override returns (address) {
        return _pools[_key(a, b, uint256(fee))];
    }

    function _key(address a, address b, uint256 p) internal pure returns (bytes32) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return keccak256(abi.encode(t0, t1, p));
    }
}

contract MockSlipstreamFactory is ISlipstreamFactory {
    mapping(bytes32 => address) internal _pools;

    function setPool(address a, address b, int24 tickSpacing, address pool) external {
        _pools[_key(a, b, tickSpacing)] = pool;
    }

    function getPool(address a, address b, int24 tickSpacing) external view override returns (address) {
        return _pools[_key(a, b, tickSpacing)];
    }

    function _key(address a, address b, int24 p) internal pure returns (bytes32) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return keccak256(abi.encode(t0, t1, p));
    }
}
