// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";

interface IBal {
    function balanceOf(address) external view returns (uint256);
}

/// @notice Settle which factory the B20 stock pools actually live on, and how deep they are.
/// @dev ASSUMPTIONS A-22 claimed there are no Aerodrome CL pools for any B20 stock. That claim
///      was made against factory 0x5e7BB1…809A. A second factory address has been supplied,
///      0xf8f2eB…061Ef, with live depth figures. Both are probed here, side by side, at every
///      tick spacing either might use, against USDC and WETH. Whatever this prints is the
///      answer.
contract AerodromeFactoryCheckTest is Test {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    address internal constant FACTORY_A = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A; // used by A-22
    address internal constant FACTORY_B = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef; // newly supplied
    address internal constant SLIPSTREAM_NPM = 0x827922686190790b37229fd06084350E74485b72;

    string[14] internal names = [
        "AAPL", "AMZN", "COIN", "CRCL", "GOOGL", "INTC", "META", "MSFT", "MSTR", "NVDA", "SNDK", "SPCX", "TSLA", "MAG7"
    ];

    address[14] internal tokens = [
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
        0xb2000000000000000000001e800a7f5189430cD0,
        0xCEF8Db49E456f872E288E1C042F916E9ceD7c781
    ];

    int24[6] internal spacings = [int24(1), 10, 50, 100, 200, 2000];

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
    }

    function test_whichFactoryIsWhich() public view {
        console2.log("FACTORY_A code bytes:", FACTORY_A.code.length);
        console2.log("FACTORY_B code bytes:", FACTORY_B.code.length);

        (bool okOwner, bytes memory ret) = SLIPSTREAM_NPM.staticcall(abi.encodeWithSignature("factory()"));
        if (okOwner && ret.length >= 32) {
            console2.log("Slipstream NPM reports factory:", abi.decode(ret, (address)));
        }

        // Control on both: the WETH/USDC pair, which certainly exists somewhere.
        for (uint256 j; j < 6; ++j) {
            address a = _getPool(FACTORY_A, WETH, USDC, spacings[j]);
            address b = _getPool(FACTORY_B, WETH, USDC, spacings[j]);
            if (a != address(0)) console2.log("A WETH/USDC ts", vm.toString(int256(spacings[j])), vm.toString(a));
            if (b != address(0)) console2.log("B WETH/USDC ts", vm.toString(int256(spacings[j])), vm.toString(b));
        }
    }

    function test_probeEveryB20OnBothFactories() public view {
        console2.log("=== FACTORY A 0x5e7BB1...809A ===");
        _sweep(FACTORY_A);
        console2.log("=== FACTORY B 0xf8f2eB...061Ef ===");
        _sweep(FACTORY_B);
    }

    function _sweep(address factory) internal view {
        for (uint256 i; i < 14; ++i) {
            for (uint256 j; j < 6; ++j) {
                _report(factory, names[i], tokens[i], USDC, spacings[j], "USDC");
                _report(factory, names[i], tokens[i], WETH, spacings[j], "WETH");
            }
        }
    }

    function _report(address factory, string memory name, address token, address other, int24 ts, string memory label)
        internal
        view
    {
        address pool = _getPool(factory, token, other, ts);
        if (pool == address(0)) return;
        uint256 bal = IBal(other).balanceOf(pool);
        console2.log(
            string.concat(name, "/", label, " ts=", vm.toString(int256(ts))), pool, bal / (other == USDC ? 1e6 : 1e18)
        );
    }

    function _getPool(address factory, address a, address b, int24 ts) internal view returns (address) {
        (bool ok, bytes memory ret) =
            factory.staticcall(abi.encodeWithSignature("getPool(address,address,int24)", a, b, ts));
        if (!ok || ret.length < 32) return address(0);
        return abi.decode(ret, (address));
    }

    /// @notice What IS factory B? Probe the identifying surface of both.
    function test_identifyFactoryB() public view {
        string[6] memory sigs = [
            "voter()", "owner()", "poolImplementation()", "factoryRegistry()", "swapFeeModule()", "unstakedFeeModule()"
        ];
        for (uint256 i; i < 6; ++i) {
            _probe(FACTORY_A, "A", sigs[i]);
            _probe(FACTORY_B, "B", sigs[i]);
        }
        // What does a factory-B pool say its own factory is?
        address p = _getPool(FACTORY_B, 0xb20000000000000000000078ee7ce2fE4908108C, USDC, 10);
        (bool ok, bytes memory ret) = p.staticcall(abi.encodeWithSignature("factory()"));
        if (ok && ret.length >= 32) console2.log("NVDA/USDC ts10 pool.factory() =", abi.decode(ret, (address)));
        (ok, ret) = p.staticcall(abi.encodeWithSignature("tickSpacing()"));
        if (ok && ret.length >= 32) console2.log("  tickSpacing =", vm.toString(abi.decode(ret, (int256))));
        (ok, ret) = p.staticcall(abi.encodeWithSignature("fee()"));
        if (ok && ret.length >= 32) console2.log("  fee =", abi.decode(ret, (uint256)));
    }

    function _probe(address who, string memory tag, string memory sig) internal view {
        (bool ok, bytes memory ret) = who.staticcall(abi.encodeWithSignature(sig));
        if (ok && ret.length >= 32) console2.log(string.concat(tag, " ", sig), abi.decode(ret, (address)));
    }

    /// @notice Both sides of every factory-B pool, in USD, the way `poolLiquidityUsd` computes it.
    function test_realDepthOnFactoryB() public {
        address[10] memory feeds = [
            0x787f13dEa48Db0897CbCDD985de77809D837F988, // AAPL
            0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295, // AMZN
            0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2, // GOOGL
            0x6526aE6797A76123638b863AeE4dD27Ba4E4b27D, // META
            0xeB10A6c9aa7E537aEd766C08c35Dae35B321b18c, // MSFT
            0xB3cE282CD188b35DA0E38D8Bc7d58e33173D202a, // MSTR
            0x04689a41629776563E6822F76f2e57D148d28513, // NVDA
            0x388b0dC46C0Fb05A74BeE0994fa5b02c6Fcca2eA, // SNDK
            0x6A634B235903C4ad6376892180d6fF8612e3Fa68, // SPCX
            0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4 // TSLA
        ];
        address[10] memory toks = [
            0xb200000000000000000000C2e324d24d7eEcd1fb,
            0xb200000000000000000000d9192b6B456483C2E8,
            0xb2000000000000000000002D0BA3164cc74f58B7,
            0xb2000000000000000000008bC8786B856E61707C,
            0xB200000000000000000000Ab99cFa739E253872B,
            0xb2000000000000000000004884b426556b92883d,
            0xb20000000000000000000078ee7ce2fE4908108C,
            0xb200000000000000000000397293Cb8cda9a10c5,
            0xb2000000000000000000007b9fcbd005511aCBd5,
            0xb2000000000000000000001e800a7f5189430cD0
        ];
        string[10] memory nm = ["AAPL", "AMZN", "GOOGL", "META", "MSFT", "MSTR", "NVDA", "SNDK", "SPCX", "TSLA"];

        console2.log("=== factory B, USDC pairs at ts=10, TVL in USD (both sides) ===");
        for (uint256 i; i < 10; ++i) {
            address pool = _getPool(FACTORY_B, toks[i], USDC, 10);
            if (pool == address(0)) {
                console2.log(string.concat(nm[i], ": no pool"));
                continue;
            }
            uint256 usdcSide = IBal(USDC).balanceOf(pool);
            uint256 stockRaw = _rpcBalanceOf(toks[i], pool);
            (, int256 answer,,,) = IFeed(feeds[i]).latestRoundData();
            uint256 stockUsd = (stockRaw * uint256(answer)) / 1e8 / 1e8; // 8dp token, 8dp feed
            console2.log(string.concat(nm[i], "  usdc$ / stock$ / TVL$"), usdcSide / 1e6, stockUsd);
            console2.log("      TVL:", usdcSide / 1e6 + stockUsd);
        }
    }

    function _rpcBalanceOf(address token, address who) internal returns (uint256) {
        bytes memory data = abi.encodeWithSignature("balanceOf(address)", who);
        string memory params =
            string.concat('[{"to":"', vm.toString(token), '","data":"', vm.toString(data), '"},"latest"]');
        return abi.decode(vm.rpc("eth_call", params), (uint256));
    }
}

interface IFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}
