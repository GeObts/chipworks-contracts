// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ChipActivationV2} from "../src/activation/ChipActivationV2.sol";

/// @notice Deploys ChipActivationV2 ONLY. It configures nothing.
///
/// @dev OWNERSHIP IS THE SAFE FROM BLOCK ONE. There is deliberately no
///      "deploy as EOA, configure, then hand over" phase: that would leave a hot key owning
///      the contract that prices every activation, however briefly. Every setup call is a
///      Safe transaction, batched into one atomic import (see the accompanying JSON).
///
///      WHAT THIS SCRIPT DOES NOT DO, ON PURPOSE:
///        - setCustodian(NounLoans, true)      <- the live V1 has this; borrowers need it
///        - setFlatRateCollection(Chiplets)    <- must precede its setInitialCosts
///        - setInitialCosts(...) x4
///        - ChipRounds/NounLoans setActivationSource
///      All of those are owner-gated and belong in the Safe batch, in that order.
///
///      Run:
///        forge script script/DeployChipActivationV2.s.sol:DeployChipActivationV2 \
///          --rpc-url $BASE_RPC_URL --broadcast --verify -vvvv
contract DeployChipActivationV2 is Script {
    // ── live mainnet inputs, read off chain 2026-09-11 ───────────────────────
    address constant SAFE = 0xe1096B727499a3f70FaD8bc0267F5e69d01373C7;
    address constant CHIP = 0x75Af968d2e58749FDA1b42C58186B76f5E511bA3;
    address constant BURNER = 0x7Bc1C03e843C37845d89B54667382b4577Ead5C0;

    /// @dev Replicated EXACTLY from the deployed V1 (`tierBps` 0..4). Changing any entry
    ///      silently reprices every holder's earning weight.
    uint32[5] TIERS = [uint32(10_000), 12_500, 16_000, 20_000, 33_300];

    /// @dev 50% burned / 50% collected. feeCollector is the Safe.
    uint32 constant BURN_BPS = 5_000;

    function run() external returns (ChipActivationV2 act) {
        vm.startBroadcast();
        act = new ChipActivationV2(SAFE, CHIP, BURNER, TIERS, BURN_BPS, SAFE);
        vm.stopBroadcast();

        console2.log("ChipActivationV2 :", address(act));
        console2.log("owner            :", act.owner());
        console2.log("chipToken        :", address(act.chipToken()));
        console2.log("chipBurnTarget   :", act.chipBurnTarget());
        console2.log("burnBps          :", act.burnBps());
        console2.log("feeCollector     :", act.feeCollector());

        // fail loudly rather than leave a misconfigured contract to be found later
        require(act.owner() == SAFE, "owner != Safe");
        require(act.chipBurnTarget() == BURNER, "burn target wrong");
        require(act.feeCollector() == SAFE, "collector wrong");
        require(act.burnBps() == BURN_BPS, "split wrong");
        require(address(act.chipToken()) == CHIP, "chip wrong");
        for (uint256 i; i < 5; ++i) {
            require(act.tierBps(i) == TIERS[i], "tierBps mismatch vs V1");
        }
        console2.log("post-deploy checks: OK");
        console2.log("NEXT: run the Safe batch (custodian -> flatRate -> costs -> re-point)");
    }
}
