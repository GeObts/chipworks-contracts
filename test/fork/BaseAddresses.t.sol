// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {EtchableERC20} from "../mocks/EtchableERC20.sol";

interface IUniV3Factory {
    function getPool(address a, address b, uint24 fee) external view returns (address);
}

interface ICLFactory {
    function getPool(address a, address b, int24 tickSpacing) external view returns (address);
}

/// @notice Pins down every third-party Base mainnet fact Chipworks depends on.
/// @dev    forge test --match-path "test/fork/*" -vv   (needs BASE_RPC_URL)
///
///         These tests are documentation that executes. When any of them starts
///         failing, a assumption in ASSUMPTIONS.md has changed on mainnet.
contract BaseAddressesForkTest is Test {
    address internal constant NVDA = 0xb20000000000000000000078ee7ce2fE4908108C;
    address internal constant GOOGL = 0xb2000000000000000000002D0BA3164cc74f58B7;
    address internal constant AAPL = 0xb200000000000000000000C2e324d24d7eEcd1fb;
    address internal constant META = 0xb2000000000000000000008bC8786B856E61707C;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    address internal constant SLIPSTREAM_NPM = 0x827922686190790b37229fd06084350E74485b72;
    address internal constant SLIPSTREAM_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
    address internal constant UNIV3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address internal constant AERO_V2_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
    }

    function test_chainIsBaseMainnet() public view {
        assertEq(block.chainid, 8453, "must be Base mainnet");
    }

    function test_usdcIsUsable() public view {
        assertEq(IERC20Metadata(USDC).symbol(), "USDC");
        assertEq(IERC20Metadata(USDC).decimals(), 6);
    }

    function test_slipstreamPositionManagerIsReal() public view {
        assertGt(SLIPSTREAM_NPM.code.length, 0, "position manager has code");
        assertEq(IERC20Metadata(SLIPSTREAM_NPM).symbol(), "AERO-CL-POS");
    }

    /* ------------------------------------------------------------------ */
    /*      FINDING 1: B20 tokens are node-native, not EVM contracts        */
    /* ------------------------------------------------------------------ */

    /// @notice The B20 stock tokens carry exactly one byte of code (0xef), which is
    ///         not executable EVM, and their storage slots read as zero. Live RPC
    ///         calls still answer correctly, so the node special-cases them.
    function test_b20TokensHaveOneByteOfNonExecutableCode() public view {
        address[4] memory stocks = [NVDA, GOOGL, AAPL, META];
        for (uint256 i; i < stocks.length; ++i) {
            assertEq(stocks[i].code.length, 1, "one byte of code");
            assertEq(vm.load(stocks[i], bytes32(uint256(0))), bytes32(0), "no EVM storage");
        }
    }

    /// @notice CONSEQUENCE: a forked EVM cannot execute them. Any fork test or
    ///         `forge script` simulation that touches a B20 token reverts.
    ///         This is why Chipworks fork tests must etch a stand-in (below).
    function test_b20TokensRevertWhenCalledInAFork() public {
        vm.expectRevert();
        IERC20Metadata(NVDA).symbol();
    }

    /// @notice The supported workaround for every future fork test: replace the
    ///         node-native token with a real ERC-20 at the same address, then
    ///         initialise it. `vm.etch` copies runtime code only, never storage,
    ///         so metadata must be written after the etch, not in a constructor.
    function test_b20TokenCanBeEtchedForTesting() public {
        _etchStock(NVDA, "NVIDIA Corporation", "NVDAc", 8);

        assertEq(IERC20Metadata(NVDA).symbol(), "NVDAc");
        assertEq(IERC20Metadata(NVDA).decimals(), 8);

        EtchableERC20(NVDA).mint(address(this), 100e8);
        assertEq(IERC20Metadata(NVDA).balanceOf(address(this)), 100e8);

        address bob = makeAddr("bob");
        IERC20Metadata(NVDA).transfer(bob, 40e8);
        assertEq(IERC20Metadata(NVDA).balanceOf(bob), 40e8, "etched token fully usable");
        assertEq(IERC20Metadata(NVDA).balanceOf(address(this)), 60e8);
    }

    /// @notice Installs a usable stand-in over a node-native B20 address.
    function _etchStock(address stock, string memory n, string memory s, uint8 d) internal {
        vm.etch(stock, address(new EtchableERC20()).code);
        EtchableERC20(stock).init(n, s, d);
    }

    /* ------------------------------------------------------------------ */
    /*        FINDING 2: the liquidity is not where the spec says          */
    /* ------------------------------------------------------------------ */

    /// @notice Spec section 5 buys on Aerodrome Slipstream. No Slipstream pool
    ///         exists for any launch stock, against USDC or WETH, at any tick spacing.
    function test_noSlipstreamPoolsExistForAnyLaunchStock() public view {
        address[4] memory stocks = [NVDA, GOOGL, AAPL, META];
        int24[5] memory spacings = [int24(1), int24(50), int24(100), int24(200), int24(2000)];
        for (uint256 i; i < stocks.length; ++i) {
            for (uint256 j; j < spacings.length; ++j) {
                assertEq(
                    ICLFactory(SLIPSTREAM_FACTORY).getPool(stocks[i], USDC, spacings[j]),
                    address(0),
                    "unexpected: a Slipstream pool now exists"
                );
                assertEq(ICLFactory(SLIPSTREAM_FACTORY).getPool(stocks[i], WETH, spacings[j]), address(0));
            }
        }
    }

    /// @notice Control: the Slipstream factory does work, it just has no stock pools.
    function test_slipstreamFactoryWorksForNormalPairs() public view {
        assertTrue(ICLFactory(SLIPSTREAM_FACTORY).getPool(WETH, USDC, 100) != address(0), "WETH/USDC exists");
    }

    /* ------------------------------------------------------------------ */
    /*   FINDING 3: reading real B20 balances despite the fork limitation   */
    /* ------------------------------------------------------------------ */

    /// @notice The local EVM cannot execute a B20 precompile, but the NODE can. `vm.rpc`
    ///         forwards a raw eth_call to the real endpoint, so any tool that must read
    ///         TRUE stock balances (the launch depth check) has to go through it.
    ///         Reading these values through the forked EVM instead silently yields zero,
    ///         which would read as "no liquidity" and is the trap this guards against.
    function test_realB20BalanceIsReadableViaRawRpc() public {
        address pool = IUniV3Factory(UNIV3_FACTORY).getPool(NVDA, USDC, 3000);
        assertTrue(pool != address(0), "NVDA/USDC 0.3% pool exists");

        uint256 viaRpc = _rpcBalanceOf(NVDA, pool);
        assertGt(viaRpc, 0, "real node reports a real balance");

        // And the same read through the forked EVM fails outright.
        vm.expectRevert();
        IERC20Metadata(NVDA).balanceOf(pool);
    }

    /// @notice Reads `token.balanceOf(who)` through the fork's RPC endpoint rather than
    ///         the local EVM. Required for B20 precompiles.
    function _rpcBalanceOf(address token, address who) internal returns (uint256) {
        bytes memory data = abi.encodeWithSignature("balanceOf(address)", who);
        string memory params =
            string.concat('[{"to":"', vm.toString(token), '","data":"', vm.toString(data), '"},"latest"]');
        return abi.decode(vm.rpc("eth_call", params), (uint256));
    }

    /// @notice Where the liquidity actually is: Uniswap v3.
    function test_uniswapV3PoolsExistAndReportDepth() public view {
        address[4] memory stocks = [NVDA, GOOGL, AAPL, META];
        string[4] memory names = ["NVDA ", "GOOGL", "AAPL ", "META "];
        uint24[4] memory fees = [uint24(100), 500, 3000, 10000];

        for (uint256 i; i < stocks.length; ++i) {
            uint256 bestUsdc;
            for (uint256 j; j < fees.length; ++j) {
                address pool = IUniV3Factory(UNIV3_FACTORY).getPool(stocks[i], USDC, fees[j]);
                if (pool == address(0)) continue;
                uint256 usdcBal = IERC20Metadata(USDC).balanceOf(pool);
                if (usdcBal > bestUsdc) bestUsdc = usdcBal;
                console2.log(names[i], fees[j], usdcBal / 1e6);
            }
            assertGt(bestUsdc, 0, "at least one Uniswap v3 pool holds USDC");
        }
    }
}
