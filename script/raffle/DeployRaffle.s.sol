// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Raffle} from "../../src/raffle/Raffle.sol";

interface IDecimals {
    function decimals() external view returns (uint8);
}

interface IEntropyCheck {
    function getDefaultProvider() external view returns (address);
}

interface IRegistryCheck {
    function isEnabled(address token) external view returns (bool);
    function quoteToken() external view returns (address);
    function slipstreamFactory() external view returns (address);
}

interface IRouterCheck {
    function factory() external view returns (address);
}

/**
 * Deploy Raffle v2 (the system buys the prize stock).
 * DO NOT RUN AGAINST MAINNET until the SPEC-v2 §2.5 pre-deploy items have cleared AND a fresh
 * external audit of v2 has passed.
 *
 * -- THE LAUNCH CONFIG LIVES HERE, AND test/fork/RaffleLaunchConfig.t.sol PINS IT ------------
 *
 *   owner / house      the ChipWorks Safe
 *   router             Aerodrome Slipstream SwapRouter on factory B (the factory every stock
 *                      pool in the StockRegistry lives in; the constructor checks it)
 *   redrawTimeout      24 HOURS (owner decision 2026-10-09), snapshotted per raffle
 *   acquireTimeout     6 HOURS (owner decision 2026-10-09), snapshotted per raffle: after it,
 *                      anyone may switch a stuck raffle's prize to its USDC budget
 *   price guard        the contract's launch defaults: 30-min TWAP, 100-tick (~1%) spot-vs-TWAP
 *                      guard, 150 bps slippage floor, buy <= 1% of the pool's USDC
 *   fee / base range   the contract's launch defaults: 10% on top, $10-$1,000
 *   keeper             NOT set by this script (the deployer is not the owner). After deploy the
 *                      Safe calls setKeeper(0x6571E3412553Fada40C3D96e61E7Cfd20A0695B9), the
 *                      chipworks-keeper signer, so it can acquirePrize and retryDraw. Until then
 *                      only the Safe can (and anyone can fall back to USDC after 6 h).
 *
 * Every immutable argument is checked against the chain before broadcasting, so a wrong one
 * costs nothing:
 *   forge script script/raffle/DeployRaffle.s.sol:DeployRaffle \
 *     --rpc-url $BASE_RPC_URL --account <keystore> --broadcast --verify
 * Dry run first WITHOUT --broadcast.
 */
contract DeployRaffle is Script {
    address public constant SAFE = 0xe1096B727499a3f70FaD8bc0267F5e69d01373C7;
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant ENTROPY = 0x6E7D74FA7d5c90FEF9F0512987605a6d546181Bb;
    address public constant REGISTRY = 0x5e4b6CbAc2D9b581428eE7f22E7bd4bf03675458;
    address public constant POT = 0x3918a9B479Ce9B58238584c645079AB3bB49855B;
    /// @notice Slipstream SwapRouter whose factory() is the registry's slipstreamFactory (B).
    address public constant ROUTER = 0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F;
    /// @notice Owner decisions 2026-10-09.
    uint64 public constant REDRAW_TIMEOUT = 24 hours;
    uint64 public constant ACQUIRE_TIMEOUT = 6 hours;
    /// @dev Any enabled stock, to prove the registry argument is the live StockRegistry.
    address public constant NVDA = 0xb20000000000000000000078ee7ce2fE4908108C;

    error CheckFailed(string what);

    /// @notice The checks, separate from the broadcast so the launch-config test runs them too.
    function checkChain() public view {
        if (SAFE.code.length == 0) revert CheckFailed("SAFE has no code");
        if (POT.code.length == 0) revert CheckFailed("POT has no code");
        if (IDecimals(USDC).decimals() != 6) revert CheckFailed("USDC is not 6 decimals");
        if (IEntropyCheck(ENTROPY).getDefaultProvider() == address(0)) revert CheckFailed("Entropy has no provider");
        if (!IRegistryCheck(REGISTRY).isEnabled(NVDA)) revert CheckFailed("REGISTRY does not enable NVDAc");
        if (IRegistryCheck(REGISTRY).quoteToken() != USDC) revert CheckFailed("REGISTRY quote is not USDC");
        if (IRouterCheck(ROUTER).factory() != IRegistryCheck(REGISTRY).slipstreamFactory()) {
            revert CheckFailed("ROUTER does not swap in the registry's Slipstream factory");
        }
    }

    function deploy() public returns (Raffle raffle) {
        raffle = new Raffle(SAFE, USDC, ENTROPY, REGISTRY, POT, ROUTER, REDRAW_TIMEOUT, ACQUIRE_TIMEOUT);
    }

    function run() external returns (Raffle raffle) {
        checkChain();
        vm.startBroadcast();
        raffle = deploy();
        vm.stopBroadcast();
        console2.log("Raffle v2 deployed at", address(raffle));
        console2.log("redrawTimeout (s)", raffle.redrawTimeout());
        console2.log("acquireTimeout (s)", raffle.acquireTimeout());
    }
}
