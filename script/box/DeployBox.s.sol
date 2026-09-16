// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {Box} from "../../src/box/Box.sol";
import {PrizeVault} from "../../src/box/PrizeVault.sol";

/// @title DeployBox
/// @notice Isolated ChipWorks Box deploy. Not part of the Anvil / rounds phase script.
///
/// @dev UNAUDITED. Do not `--broadcast` on Base mainnet from this PR.
///
///      Reads:
///        MULTISIG          owner (required)
///        BOX_USDC          default Base USDC
///        BOX_ENTROPY       default Pyth Entropy v2 on Base
///        BOX_TREASURY      5% recipient; **defaults to Goyabean's Safe**
///                          (`Box.DEFAULT_FEE_RECIPIENT`)
///        CHIP              $CHIP token; default `address(0)` disables CHIP buys
///        BOX_CHIP_PRICE_1 / BOX_CHIP_PRICE_5   18-decimal CHIP prices; 0 = CHIP path off
///        BOX_MAX_PRIZE_BPS default 2500 (25% of vault inventory)
///
///      After CREATE, the Safe must call `PrizeVault.setBox(box)` once. This script cannot
///      — same reason as Deploy.s.sol: the deploy wallet is never the owner.
contract DeployBox is Script {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant ENTROPY = 0x6E7D74FA7d5c90FEF9F0512987605a6d546181Bb;

    function run() external returns (address vault, address boxes) {
        address multisig = vm.envAddress("MULTISIG");
        address usdc = vm.envOr("BOX_USDC", USDC);
        address entropy = vm.envOr("BOX_ENTROPY", ENTROPY);
        address treasury = vm.envOr("BOX_TREASURY", address(0xe1096B727499a3f70FaD8bc0267F5e69d01373C7));
        address chip = vm.envOr("CHIP", address(0));
        uint128 chipPrice1 = uint128(vm.envOr("BOX_CHIP_PRICE_1", uint256(0)));
        uint128 chipPrice5 = uint128(vm.envOr("BOX_CHIP_PRICE_5", uint256(0)));
        uint32 maxPrizeBps = uint32(vm.envOr("BOX_MAX_PRIZE_BPS", uint256(2_500)));

        require(multisig != address(0), "MULTISIG unset");
        require(treasury != address(0), "BOX_TREASURY unset");

        vm.startBroadcast();
        PrizeVault v = new PrizeVault(multisig, usdc, maxPrizeBps);
        Box b = new Box(multisig, usdc, chip, treasury, address(v), entropy, chipPrice1, chipPrice5);
        vm.stopBroadcast();

        console2.log("PrizeVault     ", address(v));
        console2.log("Box            ", address(b));
        console2.log("feeRecipient 5%", treasury);
        console2.log("NEXT: Safe calls PrizeVault.setBox(box) once.");
        return (address(v), address(b));
    }
}
