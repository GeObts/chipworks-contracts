// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Aerodrome Slipstream NonfungiblePositionManager.
/// @dev VERIFIED, not assumed. Every selector below was probed against the deployed
///      bytecode at 0x827922686190790b37229fd06084350E74485b72 on Base:
///        mint((address,address,int24,int24,int24,uint256,uint256,uint256,uint256,address,uint256,uint160))
///          -> 0xb5007d1f  PRESENT
///        the Uniswap-v3 shape (uint24 fee, no sqrtPriceX96) -> 0x88316456  ABSENT
///      So Slipstream keys by tickSpacing, not fee tier, and carries sqrtPriceX96 so a
///      mint can create the pool. See test/fork/PolTreasuryFork.t.sol.
interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
        uint160 sqrtPriceX96;
    }

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            int24 tickSpacing,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    function factory() external view returns (address);
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @notice Minimal Aerodrome gauge surface for staking a Slipstream position.
interface ISlipstreamGauge {
    function deposit(uint256 tokenId) external;
    function withdraw(uint256 tokenId) external;
    function getReward(uint256 tokenId) external;
    function rewardToken() external view returns (address);
}
