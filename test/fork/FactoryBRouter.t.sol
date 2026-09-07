// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ISlipstreamSwapRouter} from "../../src/interfaces/ISwapRouters.sol";
import {EtchableERC20} from "../mocks/EtchableERC20.sol";

/// @title FactoryBRouterTest
/// @notice The router that actually reaches the B20 pools, found on chain rather than in a doc.
///
/// @dev HOW IT WAS FOUND. The B20 stock pools live on Aerodrome CL factory
///      `0xf8f2eB…061Ef` (ASSUMPTIONS A-22), but the Slipstream SwapRouter we already knew
///      about, `0xBE6D8f…18a5`, reports `factory() == 0x5e7BB1…809A` — factory A — so it
///      cannot derive a factory-B pool address and every buy would revert.
///
///      Rather than trust a deployment list, the answer was derived from the chain: read the
///      `Swap` events on the NVDA/USDC pool, tally the senders, and probe each one for
///      `factory()`. Exactly one answered with factory B, and its code is 19,819 bytes — the
///      same size as the factory-A router. Same contract, different constructor argument.
///
///      **This suite is what turns that inference into a fact.** It runs a real
///      `exactInputSingle` through the candidate router, in the Slipstream 8-field shape that
///      `ChipRounds._buy` encodes, against the deepest live B20 pool.
contract FactoryBRouterTest is Test {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant NVDA = 0xb20000000000000000000078ee7ce2fE4908108C;

    address internal constant FACTORY_A = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
    address internal constant FACTORY_B = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef;

    address internal constant ROUTER_A = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;
    address internal constant ROUTER_B = 0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F;

    address internal constant NVDA_USDC_POOL = 0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9;
    int24 internal constant TS = 10;

    address internal buyer = makeAddr("buyer");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
    }

    /// @notice The two routers, side by side. Only one can reach factory-B pools.
    function test_routerBIsBoundToFactoryB() public view {
        assertEq(_factoryOf(ROUTER_A), FACTORY_A, "the router we had serves factory A");
        assertEq(_factoryOf(ROUTER_B), FACTORY_B, "and this one serves factory B");

        // Same contract, different constructor argument.
        assertEq(ROUTER_A.code.length, ROUTER_B.code.length, "identical bytecode size");
        console2.log("router A code bytes", ROUTER_A.code.length);
        console2.log("router B code bytes", ROUTER_B.code.length);
    }

    /// @notice THE PROOF. A real buy of NVDA with USDC, through router B, using exactly the
    ///         calldata `ChipRounds._buy` builds for `Venue.Slipstream`.
    ///
    /// @dev NVDA is a node-native B20 precompile and cannot execute inside a forked EVM
    ///      (ASSUMPTIONS A-15/A-17), so it is etched with a runnable ERC-20 carrying the pool's
    ///      REAL balance, read over raw RPC. That substitution is on the token's transfer only.
    ///      Everything under test is untouched and real: the router's pool derivation from
    ///      factory B, the 8-field Slipstream calldata shape, the pool's own swap maths, and
    ///      the callback that pulls the USDC.
    function test_aRealBuyThroughRouterB() public {
        uint256 poolNvda = _rpcBalanceOf(NVDA, NVDA_USDC_POOL);
        assertGt(poolNvda, 0, "the pool holds NVDA on chain");

        vm.etch(NVDA, address(new EtchableERC20()).code);
        EtchableERC20(NVDA).init("NVIDIA Corporation", "NVDAc", 8);
        EtchableERC20(NVDA).mint(NVDA_USDC_POOL, poolNvda);

        uint256 spend = 10_000e6; // $10k, a realistic round slice for this pool
        deal(USDC, buyer, spend);

        vm.startPrank(buyer);
        IERC20(USDC).approve(ROUTER_B, spend);
        uint256 out = ISlipstreamSwapRouter(ROUTER_B)
            .exactInputSingle(
                ISlipstreamSwapRouter.ExactInputSingleParams({
                tokenIn: USDC,
                tokenOut: NVDA,
                tickSpacing: TS,
                recipient: buyer,
                deadline: block.timestamp,
                amountIn: spend,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
            );
        vm.stopPrank();

        assertGt(out, 0, "the swap filled");
        assertEq(IERC20(NVDA).balanceOf(buyer), out, "and the stock arrived");
        assertEq(IERC20(USDC).balanceOf(buyer), 0, "the USDC was spent");

        // Sanity: $10k of NVDA at roughly the mark, 8 decimals.
        console2.log("spent USDC:", spend / 1e6);
        console2.log("received NVDA (8dp):", out);
        console2.log("implied price, USD:", (spend * 1e2) / out);
    }

    /// @notice And the router we HAD cannot do it — which is why this mattered.
    function test_routerACannotReachTheFactoryBPool() public {
        uint256 poolNvda = _rpcBalanceOf(NVDA, NVDA_USDC_POOL);
        vm.etch(NVDA, address(new EtchableERC20()).code);
        EtchableERC20(NVDA).init("NVIDIA Corporation", "NVDAc", 8);
        EtchableERC20(NVDA).mint(NVDA_USDC_POOL, poolNvda);

        deal(USDC, buyer, 10_000e6);
        vm.startPrank(buyer);
        IERC20(USDC).approve(ROUTER_A, 10_000e6);
        vm.expectRevert();
        ISlipstreamSwapRouter(ROUTER_A)
            .exactInputSingle(
                ISlipstreamSwapRouter.ExactInputSingleParams({
                tokenIn: USDC,
                tokenOut: NVDA,
                tickSpacing: TS,
                recipient: buyer,
                deadline: block.timestamp,
                amountIn: 10_000e6,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
            );
        vm.stopPrank();
    }

    function _factoryOf(address r) internal view returns (address) {
        (bool ok, bytes memory ret) = r.staticcall(abi.encodeWithSignature("factory()"));
        if (!ok || ret.length < 32) return address(0);
        return abi.decode(ret, (address));
    }

    function _rpcBalanceOf(address token, address who) internal returns (uint256) {
        bytes memory data = abi.encodeWithSignature("balanceOf(address)", who);
        string memory params =
            string.concat('[{"to":"', vm.toString(token), '","data":"', vm.toString(data), '"},"latest"]');
        return abi.decode(vm.rpc("eth_call", params), (uint256));
    }
}
