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
}

/**
 * Deploy the Raffle. DO NOT RUN AGAINST MAINNET UNTIL THE EXTERNAL AUDIT HAS PASSED.
 *
 * -- THE LAUNCH CONFIG LIVES HERE, AND test/fork/RaffleLaunchConfig.t.sol PINS IT ------------
 *
 *   owner / house      the ChipWorks Safe
 *   redrawTimeout      24 HOURS (owner decision 2026-10-09). The keeper completes a late draw
 *                      with Pyth's revealWithCallback long before this, so fresh randomness is
 *                      only ever for a provider that is truly gone. Snapshotted into each
 *                      raffle at creation; setRedrawTimeout (hard bounds [1 h, 30 d]) only
 *                      affects raffles created afterwards.
 *   keeper             NOT set by this script (the deployer is not the owner). After deploy the
 *                      Safe calls setKeeper(0x6571E3412553Fada40C3D96e61E7Cfd20A0695B9), the
 *                      chipworks-keeper signer, so it can retryDraw a draw Entropy never revealed.
 *                      Until then only the Safe and each raffle's payee can.
 *   fee / base range   the contract's own launch defaults: 10%, $10-$1,000
 *   NFT prizes         OFF (contract default)
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
    /// @notice Owner decision 2026-10-09: 24 hours at launch.
    uint64 public constant REDRAW_TIMEOUT = 24 hours;
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
    }

    function deploy() public returns (Raffle raffle) {
        raffle = new Raffle(SAFE, USDC, ENTROPY, REGISTRY, POT, REDRAW_TIMEOUT);
    }

    function run() external returns (Raffle raffle) {
        checkChain();
        vm.startBroadcast();
        raffle = deploy();
        vm.stopBroadcast();
        console2.log("Raffle deployed at", address(raffle));
        console2.log("redrawTimeout (s)", raffle.redrawTimeout());
    }
}
