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
///        BOX_USDC          default Base USDC (`Box.DEFAULT_USDC`)
///        BOX_ENTROPY       default Pyth Entropy v2 on Base
///        BOX_TREASURY      5% recipient; **defaults to Goyabean's Safe**
///                          (`Box.DEFAULT_FEE_RECIPIENT`)
///        CHIP              $CHIP token; **defaults to `Box.DEFAULT_CHIP`** (live on Base).
///                          Set CHIP=0x0000…0 to disable CHIP buys. PrizeVault and Box
///                          both receive this address so {rescue}/{addStock}/surplus
///                          cannot treat CHIP as inventory (H-01).
///        BOX_CHIP_PRICE_1 / BOX_CHIP_PRICE_10 / BOX_CHIP_PRICE_25
///                          18-decimal CHIP prices. Default is the locked implied CHIP/USD
///                          from the loan seed (467e6 CHIP = $700), rounded up: 667_143
///                          CHIP per $1. 0 = CHIP path off for that SKU.
///        BOX_MAX_PRIZE_BPS default 2500 (25% of vault inventory)
///
///      After CREATE, the Safe must call `PrizeVault.setBox(box)` once. This script cannot
///      — same reason as Deploy.s.sol: the deploy wallet is never the owner.
contract DeployBox is Script {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant ENTROPY = 0x6E7D74FA7d5c90FEF9F0512987605a6d546181Bb;
    address internal constant CHIP_TOKEN = 0x75Af968d2e58749FDA1b42C58186B76f5E511bA3;
    address internal constant FEE_RECIPIENT = 0xe1096B727499a3f70FaD8bc0267F5e69d01373C7;
    /// @dev 467_000_000 CHIP / $700, rounded up. Same high-bias as activation costs.
    uint256 internal constant CHIP_PER_USD = 667_143 ether;

    function run() external returns (address vault, address boxes) {
        address multisig = vm.envAddress("MULTISIG");
        address usdc = vm.envOr("BOX_USDC", USDC);
        address entropy = vm.envOr("BOX_ENTROPY", ENTROPY);
        address treasury = vm.envOr("BOX_TREASURY", FEE_RECIPIENT);
        address chip = vm.envOr("CHIP", CHIP_TOKEN);
        uint128 chipPrice1 = uint128(vm.envOr("BOX_CHIP_PRICE_1", CHIP_PER_USD));
        uint128 chipPrice10 = uint128(vm.envOr("BOX_CHIP_PRICE_10", 10 * CHIP_PER_USD));
        uint128 chipPrice25 = uint128(vm.envOr("BOX_CHIP_PRICE_25", 25 * CHIP_PER_USD));
        uint32 maxPrizeBps = uint32(vm.envOr("BOX_MAX_PRIZE_BPS", uint256(2_500)));

        require(multisig != address(0), "MULTISIG unset");
        require(treasury != address(0), "BOX_TREASURY unset");

        vm.startBroadcast();
        PrizeVault v = new PrizeVault(multisig, usdc, chip, maxPrizeBps);
        Box b = new Box(multisig, usdc, chip, treasury, address(v), entropy, chipPrice1, chipPrice10, chipPrice25);
        vm.stopBroadcast();

        console2.log("PrizeVault     ", address(v));
        console2.log("Box            ", address(b));
        console2.log("feeRecipient 5%", treasury);
        console2.log("chip           ", chip);
        console2.log("NEXT: Safe calls PrizeVault.setBox(box) once.");
        return (address(v), address(b));
    }
}
