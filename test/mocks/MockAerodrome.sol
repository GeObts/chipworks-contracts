// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice A concentrated-liquidity pool, as far as POLTreasury is concerned: an address the
///         factory vouches for that will state a price.
/// @dev Returns the six-field Slipstream `slot0` tuple. POLTreasury reads only the first
///      word, which is the field Uniswap v3 and Slipstream agree on.
contract MockCLPool {
    address public immutable token0;
    address public immutable token1;
    int24 public immutable tickSpacing;
    uint160 public sqrtPriceX96;

    constructor(address token0_, address token1_, int24 tickSpacing_, uint160 sqrtPriceX96_) {
        token0 = token0_;
        token1 = token1_;
        tickSpacing = tickSpacing_;
        sqrtPriceX96 = sqrtPriceX96_;
    }

    /// @notice Move the pool. This is the manipulation POLTreasury's Chainlink band exists
    ///         to refuse.
    function setSqrtPriceX96(uint160 v) external {
        sqrtPriceX96 = v;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool) {
        return (sqrtPriceX96, 0, 0, 1, 1, true);
    }
}

/// @notice Slipstream CL factory test double. Pools exist only when created, which is the
///         property H-02(b) turns on.
contract MockSlipstreamFactoryReal {
    mapping(bytes32 => address) internal _pools;

    function _key(address a, address b, int24 spacing) internal pure returns (bytes32) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return keccak256(abi.encode(t0, t1, spacing));
    }

    function createPool(address a, address b, int24 spacing, uint160 sqrtPriceX96) external returns (address pool) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        pool = address(new MockCLPool(t0, t1, spacing, sqrtPriceX96));
        _pools[_key(a, b, spacing)] = pool;
    }

    function getPool(address a, address b, int24 spacing) external view returns (address) {
        return _pools[_key(a, b, spacing)];
    }
}

/// @notice Aerodrome Voter test double. `gauges(pool)` is the whole of the H-01 fix, so the
///         mock does exactly that and nothing else.
contract MockAerodromeVoter {
    mapping(address pool => address) public gauges;

    function setGauge(address pool, address gauge) external {
        gauges[pool] = gauge;
    }
}

/// @notice Turns a human price into the `sqrtPriceX96` a pool must hold to show it.
/// @dev Tests state prices the way an operator would — "NVDA is 100 USDC" — and this works
///      out the Q96 square root in whichever direction the pair's address ordering demands.
///      Keeping the arithmetic here rather than in each test means the suites cannot quietly
///      disagree with each other about what a correctly-priced pool looks like.
library PoolMath {
    /// @param asset The POL asset.
    /// @param quote The quote token.
    /// @param assetDecimals Decimals of `asset`.
    /// @param quotePerWholeAsset Raw quote units one whole `asset` should cost.
    function sqrtPriceX96For(address asset, address quote, uint8 assetDecimals, uint256 quotePerWholeAsset)
        internal
        pure
        returns (uint160)
    {
        uint256 q96 = 1 << 96;
        uint256 whole = 10 ** assetDecimals;

        // priceX96 is always token1-per-token0, so which way up depends on address order.
        uint256 priceX96 =
            asset < quote ? Math.mulDiv(quotePerWholeAsset, q96, whole) : Math.mulDiv(whole, q96, quotePerWholeAsset);

        return uint160(Math.sqrt(Math.mulDiv(priceX96, q96, 1)));
    }
}
