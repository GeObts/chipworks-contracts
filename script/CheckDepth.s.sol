// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

/// @title CheckDepth
/// @notice Prints every registered stock's measured pool depth, its threshold, and whether
///         it clears — so the launch enable decision is one command instead of a manual check.
///
/// @dev    Run:
///           STOCK_REGISTRY=0x... forge script script/CheckDepth.s.sol --rpc-url $BASE_RPC_URL
///
///         WHY THIS USES RAW RPC INSTEAD OF JUST CALLING THE REGISTRY:
///         B20 stock tokens are native precompiles on Base. A forked EVM cannot execute
///         them, so calling `registry.liquidityReport()` through the local fork would hit
///         the try/catch inside that function and report every stock as $0 of depth — a
///         silent, plausible-looking wrong answer that would tell you to enable nothing.
///         `vm.rpc` sends the call to the real node, where the precompiles work, so the
///         numbers printed here are the true on-chain ones. See ASSUMPTIONS.md A-15.
contract CheckDepth is Script {
    function run() external {
        address registry = vm.envAddress("STOCK_REGISTRY");

        console2.log("=== Chipworks stock depth check ===");
        console2.log("registry:", registry);
        console2.log("");

        (address[] memory tokens, uint256[] memory measured, uint256[] memory required, bool[] memory ok) =
            _liquidityReport(registry);

        if (tokens.length == 0) {
            console2.log("No stocks registered.");
            return;
        }

        uint256 clearing;
        for (uint256 i; i < tokens.length; ++i) {
            string memory sym = _symbol(tokens[i]);
            console2.log("-------------------------------------------");
            console2.log(string.concat(sym, "  ", vm.toString(tokens[i])));
            console2.log("   measured depth : $", measured[i] / 1e18);
            console2.log("   required       : $", required[i] / 1e18);
            console2.log(ok[i] ? "   CLEARS -> safe to enable" : "   BELOW THRESHOLD -> leave disabled");
            if (ok[i]) ++clearing;
        }

        console2.log("===========================================");
        console2.log("clearing threshold:", clearing, "of", tokens.length);
        console2.log("");
        console2.log("Enable list (pass to the enable script):");
        for (uint256 i; i < tokens.length; ++i) {
            if (ok[i]) console2.log(string.concat("   ", _symbol(tokens[i]), "  ", vm.toString(tokens[i])));
        }
    }

    /* ------------------------------------------------------------------ */
    /*                        raw RPC read helpers                          */
    /* ------------------------------------------------------------------ */

    function _liquidityReport(address registry)
        internal
        returns (address[] memory tokens, uint256[] memory measured, uint256[] memory required, bool[] memory ok)
    {
        bytes memory ret = _ethCall(registry, abi.encodeWithSignature("liquidityReport()"));
        (tokens, measured, required, ok) = abi.decode(ret, (address[], uint256[], uint256[], bool[]));
    }

    function _symbol(address token) internal returns (string memory) {
        bytes memory ret = _ethCall(token, abi.encodeWithSignature("symbol()"));
        if (ret.length == 0) return "???";
        return abi.decode(ret, (string));
    }

    /// @dev Sends the call to the real node rather than executing it in the local fork.
    function _ethCall(address to, bytes memory data) internal returns (bytes memory) {
        string memory params =
            string.concat('[{"to":"', vm.toString(to), '","data":"', vm.toString(data), '"},"latest"]');
        return vm.rpc("eth_call", params);
    }
}
