// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {POLTreasury} from "../../src/POLTreasury.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/INonfungiblePositionManager.sol";
import {EtchableERC20} from "../mocks/EtchableERC20.sol";

/// @notice POLTreasury against the real Aerodrome Slipstream position manager on Base.
/// @dev The point of this suite is to prove our INonfungiblePositionManager interface
///      matches the deployed contract, which is otherwise pure assumption.
contract PolTreasuryForkTest is Test {
    address internal constant NPM = 0x827922686190790b37229fd06084350E74485b72;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant NVDA = 0xb20000000000000000000078ee7ce2fE4908108C;
    address internal constant SLIPSTREAM_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;

    POLTreasury internal pol;
    address internal multisig = makeAddr("multisig");
    address internal manager = makeAddr("bankrOptimizer");
    address internal splitter = makeAddr("feeSplitter");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        pol = new POLTreasury(multisig, USDC, NPM, splitter);
        vm.startPrank(multisig);
        pol.setManager(manager);
        pol.setPolAsset(NVDA, true);
        vm.stopPrank();
    }

    /// @notice Our interface must match the deployed bytecode. Selector probes: the
    ///         Slipstream mint (tickSpacing + sqrtPriceX96) is present, the Uniswap-v3
    ///         shape (uint24 fee) is absent.
    function test_positionManagerInterfaceMatchesTheDeployedContract() public view {
        assertGt(NPM.code.length, 0);
        assertEq(INonfungiblePositionManager(NPM).factory(), SLIPSTREAM_FACTORY, "factory matches");

        bytes4 slipstreamMint = bytes4(
            keccak256(
                "mint((address,address,int24,int24,int24,uint256,uint256,uint256,uint256,address,uint256,uint160))"
            )
        );
        bytes4 uniswapMint = bytes4(
            keccak256("mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))")
        );

        assertTrue(_codeContains(NPM, slipstreamMint), "Slipstream mint present");
        assertFalse(_codeContains(NPM, uniswapMint), "Uniswap-v3 mint absent");
        assertTrue(_codeContains(NPM, INonfungiblePositionManager.increaseLiquidity.selector), "increaseLiquidity");
        assertTrue(_codeContains(NPM, INonfungiblePositionManager.decreaseLiquidity.selector), "decreaseLiquidity");
        assertTrue(_codeContains(NPM, INonfungiblePositionManager.collect.selector), "collect");
        assertTrue(_codeContains(NPM, INonfungiblePositionManager.positions.selector), "positions");
    }

    /// @notice Mint a real WETH/USDC Slipstream position from the treasury.
    function test_mintsARealSlipstreamPosition() public {
        deal(WETH, address(pol), 2 ether);
        deal(USDC, address(pol), 5_000e6);

        vm.prank(multisig);
        pol.setPolAsset(WETH, true);

        (address token0, address token1) = WETH < USDC ? (WETH, USDC) : (USDC, WETH);
        (uint256 amt0, uint256 amt1) =
            WETH < USDC ? (uint256(2 ether), uint256(5_000e6)) : (uint256(5_000e6), uint256(2 ether));

        vm.prank(manager);
        (uint256 tokenId, uint128 liquidity,,) = pol.mintPosition(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                tickSpacing: 100,
                tickLower: -887200,
                tickUpper: 887200,
                amount0Desired: amt0,
                amount1Desired: amt1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(pol),
                deadline: block.timestamp + 1,
                sqrtPriceX96: 0
            })
        );

        assertGt(tokenId, 0);
        assertGt(liquidity, 0, "real liquidity minted");
        assertEq(INonfungiblePositionManager(NPM).ownerOf(tokenId), address(pol), "position held by the treasury");
        assertTrue(pol.holdsPosition(tokenId));
        assertEq(pol.positionCount(), 1);

        console2.log("minted Slipstream position", tokenId, "liquidity", liquidity);
    }

    /// @notice Collecting from a real position is permissionless and lands here.
    function test_collectOnARealPositionIsPermissionless() public {
        deal(WETH, address(pol), 2 ether);
        deal(USDC, address(pol), 5_000e6);
        vm.prank(multisig);
        pol.setPolAsset(WETH, true);

        (address token0, address token1) = WETH < USDC ? (WETH, USDC) : (USDC, WETH);
        (uint256 amt0, uint256 amt1) =
            WETH < USDC ? (uint256(2 ether), uint256(5_000e6)) : (uint256(5_000e6), uint256(2 ether));

        vm.prank(manager);
        (uint256 tokenId,,,) = pol.mintPosition(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                tickSpacing: 100,
                tickLower: -887200,
                tickUpper: 887200,
                amount0Desired: amt0,
                amount1Desired: amt1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(pol),
                deadline: block.timestamp + 1,
                sqrtPriceX96: 0
            })
        );

        vm.prank(makeAddr("stranger"));
        pol.collectFees(tokenId); // no fees accrued yet, but the call path must work
    }

    /// @notice B20 stock is a precompile, so a POL position paired with it cannot be
    ///         exercised in a fork without etching. Documented so nobody assumes the
    ///         NVDA/USDC POL path is fork-testable as-is. See ASSUMPTIONS.md A-15.
    function test_b20PolPairNeedsEtchingInAFork() public {
        vm.expectRevert();
        IERC20(NVDA).balanceOf(address(pol));

        vm.etch(NVDA, address(new EtchableERC20()).code);
        EtchableERC20(NVDA).init("NVIDIA Corporation", "NVDAc", 8);
        EtchableERC20(NVDA).mint(address(pol), 10e8);
        assertEq(IERC20(NVDA).balanceOf(address(pol)), 10e8);
    }

    function _codeContains(address target, bytes4 selector) internal view returns (bool) {
        bytes memory code = target.code;
        for (uint256 i; i + 4 <= code.length; ++i) {
            if (
                code[i] == selector[0] && code[i + 1] == selector[1] && code[i + 2] == selector[2]
                    && code[i + 3] == selector[3]
            ) return true;
        }
        return false;
    }
}
