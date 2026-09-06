// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ISlipstreamFactory, IUniswapV3Factory} from "../../src/interfaces/IAmmFactories.sol";

interface IBal {
    function balanceOf(address) external view returns (uint256);
}

interface IAeroBasicFactory {
    function getPool(address tokenA, address tokenB, bool stable) external view returns (address);
    function allPoolsLength() external view returns (uint256);
}

/// @notice Discovery sweep: where does each B20 stock's on-chain depth actually live?
/// @dev Not an assertion suite. It prints the table the registry config is built from, so the
///      addresses used in `StockRegistryFork.t.sol` are derived from the chain rather than
///      pasted from a message. Kept in the repo because "which venue" is a question that will
///      be asked again every time a ticker is added.
contract B20PoolDiscoveryTest is Test {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant UNIV3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address internal constant SLIPSTREAM_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
    address internal constant AERO_BASIC_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

    string[13] internal names =
        ["AAPL", "AMZN", "COIN", "CRCL", "GOOGL", "INTC", "META", "MSFT", "MSTR", "NVDA", "SNDK", "SPCX", "TSLA"];

    address[13] internal tokens = [
        0xb200000000000000000000C2e324d24d7eEcd1fb,
        0xb200000000000000000000d9192b6B456483C2E8,
        0xb200000000000000000000c85a31389D71F3ecfb,
        0xB20000000000000000000019f6E7C675b73C2e4D,
        0xb2000000000000000000002D0BA3164cc74f58B7,
        0xB2000000000000000000004AFF16039bA04bdFBc,
        0xb2000000000000000000008bC8786B856E61707C,
        0xB200000000000000000000Ab99cFa739E253872B,
        0xb2000000000000000000004884b426556b92883d,
        0xb20000000000000000000078ee7ce2fE4908108C,
        0xb200000000000000000000397293Cb8cda9a10c5,
        0xb2000000000000000000007b9fcbd005511aCBd5,
        0xb2000000000000000000001e800a7f5189430cD0
    ];

    // Every tick spacing Slipstream has ever been configured with, plus the Uniswap ones.
    int24[10] internal spacings = [int24(1), 2, 5, 10, 25, 50, 100, 200, 500, 2000];
    uint24[5] internal fees = [uint24(100), 500, 2500, 3000, 10000];

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
    }

    /// @notice Prove the factories we are probing are the real ones before trusting a "no".
    function test_theFactoriesAreLive() public view {
        assertGt(SLIPSTREAM_FACTORY.code.length, 0, "slipstream CL factory");
        assertGt(AERO_BASIC_FACTORY.code.length, 0, "aerodrome basic factory");
        assertGt(UNIV3_FACTORY.code.length, 0, "uniswap v3 factory");

        // A known-good Slipstream pool, so a zero answer below means "no pool", not "wrong ABI".
        address wethUsdc = ISlipstreamFactory(SLIPSTREAM_FACTORY).getPool(WETH, USDC, 100);
        assertTrue(wethUsdc != address(0), "control: WETH/USDC ts=100 resolves");
        console2.log("control WETH/USDC slipstream ts=100:", wethUsdc);
        console2.log("aerodrome basic pools deployed:", IAeroBasicFactory(AERO_BASIC_FACTORY).allPoolsLength());
    }

    function test_discoverB20Venues() public view {
        console2.log("### SLIPSTREAM CL, vs USDC and vs WETH");
        for (uint256 i; i < 13; ++i) {
            for (uint256 j; j < 10; ++j) {
                _slip(names[i], tokens[i], USDC, spacings[j], "USDC");
                _slip(names[i], tokens[i], WETH, spacings[j], "WETH");
            }
        }

        console2.log("### AERODROME BASIC AMM (v/sAMM), vs USDC and vs WETH");
        for (uint256 i; i < 13; ++i) {
            _basic(names[i], tokens[i], USDC, false, "USDC vAMM");
            _basic(names[i], tokens[i], USDC, true, "USDC sAMM");
            _basic(names[i], tokens[i], WETH, false, "WETH vAMM");
        }

        console2.log("### UNISWAP V3, vs USDC");
        for (uint256 i; i < 13; ++i) {
            for (uint256 j; j < 5; ++j) {
                address pool = IUniswapV3Factory(UNIV3_FACTORY).getPool(tokens[i], USDC, fees[j]);
                if (pool == address(0)) continue;
                console2.log(
                    string.concat(names[i], " uniV3 fee=", vm.toString(uint256(fees[j]))),
                    pool,
                    IBal(USDC).balanceOf(pool) / 1e6
                );
            }
        }
    }

    function _slip(string memory name, address token, address other, int24 spacing, string memory label) internal view {
        address pool = ISlipstreamFactory(SLIPSTREAM_FACTORY).getPool(token, other, spacing);
        if (pool == address(0)) return;
        console2.log(
            string.concat(name, " slipstream ", label, " ts=", vm.toString(int256(spacing))),
            pool,
            IBal(other).balanceOf(pool)
        );
    }

    function _basic(string memory name, address token, address other, bool stable, string memory label) internal view {
        (bool ok, bytes memory ret) = AERO_BASIC_FACTORY.staticcall(
            abi.encodeWithSignature("getPool(address,address,bool)", token, other, stable)
        );
        if (!ok || ret.length < 32) return;
        address pool = abi.decode(ret, (address));
        if (pool == address(0)) return;
        console2.log(string.concat(name, " aeroBasic ", label), pool, IBal(other).balanceOf(pool));
    }
}
