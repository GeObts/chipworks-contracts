// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {POLTreasury} from "../../src/POLTreasury.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/INonfungiblePositionManager.sol";
import {EtchableERC20} from "../mocks/EtchableERC20.sol";
import {ISlipstreamFactory, IAerodromeVoter} from "../../src/interfaces/IAmmFactories.sol";

/// @notice POLTreasury against the real Aerodrome Slipstream position manager on Base.
/// @dev The point of this suite is to prove our INonfungiblePositionManager interface
///      matches the deployed contract, which is otherwise pure assumption.
contract PolTreasuryForkTest is Test {
    address internal constant NPM = 0x827922686190790b37229fd06084350E74485b72;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant NVDA = 0xb20000000000000000000078ee7ce2fE4908108C;
    address internal constant SLIPSTREAM_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
    address internal constant AERO_VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;
    address internal constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    int24 internal constant SPACING = 100;

    POLTreasury internal pol;
    address internal multisig = makeAddr("multisig");
    address internal manager = makeAddr("bankrOptimizer");
    address internal splitter = makeAddr("feeSplitter");

    address internal constant UNIV3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        pol = new POLTreasury(multisig, USDC, NPM, splitter, UNIV3_FACTORY, AERO_VOTER);
        vm.prank(multisig);
        pol.setManager(manager);
    }

    /// @notice Register WETH the way the multisig will at launch.
    /// @dev The band is set to the 10% maximum here rather than the 5% we would run in
    ///      production. This suite forks the LATEST block, so the live WETH/USDC Slipstream
    ///      pool and the live ETH/USD feed are whatever they are on the day; a wide band keeps
    ///      the suite honest about the mechanism without making it a bet on how tightly the
    ///      pool tracked Chainlink at that particular block.
    ///
    ///      NVDA is deliberately NOT registered in `setUp`. It is a node-native precompile
    ///      (ASSUMPTIONS A-15/A-17) and `setPolAsset` probes `decimals()`, which a precompile
    ///      cannot answer in a forked EVM — registering it would fail before any test ran.
    function _listWeth() internal {
        vm.prank(multisig);
        pol.setPolAsset(WETH, ETH_USD_FEED, 1_000, 1 hours);
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

        _listWeth();

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
                amount0Min: 1,
                amount1Min: 1,
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
        _listWeth();

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
                amount0Min: 1,
                amount1Min: 1,
                recipient: address(pol),
                deadline: block.timestamp + 1,
                sqrtPriceX96: 0
            })
        );

        vm.prank(makeAddr("stranger"));
        pol.collectFees(tokenId); // no fees accrued yet, but the call path must work
    }

    /// @notice The pool and gauge checks that close H-01 and H-02 must work against the real
    ///         Aerodrome deployment, not just against our mocks.
    /// @dev This is the load-bearing fork assertion of the batch-6 fix. It proves three
    ///      things about live Base: the Slipstream factory resolves the WETH/USDC pool our
    ///      `_requireCanonicalPool` derives, the real Voter names a gauge for that pool so
    ///      `stakePosition` has something canonical to accept, and the live pool price sits
    ///      inside the band around the live Chainlink mark so the check does not simply refuse
    ///      everything.
    function test_realAerodromeAnswersThePoolAndGaugeChecks() public {
        _listWeth();

        address pool = ISlipstreamFactory(SLIPSTREAM_FACTORY).getPool(WETH, USDC, SPACING);
        assertTrue(pool != address(0), "the WETH/USDC Slipstream pool resolves");

        address gauge = IAerodromeVoter(AERO_VOTER).gauges(pool);
        assertTrue(gauge != address(0), "and the real voter names a gauge for it");
        assertTrue(gauge != address(this), "which is not just any address");

        (uint256 mark, uint256 poolPrice) = pol.markAndPoolPrice(WETH, pool);
        assertGt(mark, 0, "Chainlink prices WETH");
        assertGt(poolPrice, 0, "so does the pool");

        uint256 delta = poolPrice > mark ? poolPrice - mark : mark - poolPrice;
        assertLt(delta * 10_000 / mark, 1_000, "and they agree inside the band");

        console2.log("WETH mark (USDC)", mark);
        console2.log("WETH pool (USDC)", poolPrice);
        console2.log("canonical gauge", gauge);
    }

    /// @notice A gauge the real voter does not name is refused, on real infrastructure.
    function test_realVoterRefusesANonCanonicalGauge() public {
        _listWeth();
        deal(WETH, address(pol), 2 ether);
        deal(USDC, address(pol), 5_000e6);

        (address token0, address token1) = WETH < USDC ? (WETH, USDC) : (USDC, WETH);
        (uint256 amt0, uint256 amt1) =
            WETH < USDC ? (uint256(2 ether), uint256(5_000e6)) : (uint256(5_000e6), uint256(2 ether));

        vm.prank(manager);
        (uint256 tokenId,,,) = pol.mintPosition(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                tickSpacing: SPACING,
                tickLower: -887200,
                tickUpper: 887200,
                amount0Desired: amt0,
                amount1Desired: amt1,
                amount0Min: 1,
                amount1Min: 1,
                recipient: address(pol),
                deadline: block.timestamp + 1,
                sqrtPriceX96: 0
            })
        );

        address impostor = makeAddr("impostorGauge");
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(POLTreasury.GaugeNotCanonical.selector, impostor));
        pol.stakePosition(tokenId, impostor);

        // ...while the gauge the voter actually names is accepted by the check.
        address pool = ISlipstreamFactory(SLIPSTREAM_FACTORY).getPool(WETH, USDC, SPACING);
        assertEq(pol.canonicalGaugeOf(tokenId), IAerodromeVoter(AERO_VOTER).gauges(pool));
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
