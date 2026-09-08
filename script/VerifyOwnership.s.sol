// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

interface IOwned {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
}

interface IChipOwner {
    function owner() external view returns (address);
}

interface ISplitter {
    function ops() external view returns (address);
    function pot() external view returns (address);
}

interface ILoans {
    function treasury() external view returns (address);
}

interface IBurner {
    function chipToken() external view returns (address);
}

/// @title VerifyOwnership — prove the deploy wallet kept nothing
/// @notice Post-deploy audit. Reads `owner()` and `pendingOwner()` off all twelve contracts
///         and fails if any of them is not the Safe, or if any ownership transfer is left
///         dangling half-done.
///
/// @dev WHY `pendingOwner()` MATTERS AS MUCH AS `owner()`. Every contract here is
///      `Ownable2Step`. A two-step transfer that was started and never accepted leaves
///      `owner()` looking correct while a *second* address can seize control at any moment by
///      calling `acceptOwnership()`. Checking `owner()` alone would not see it. Every one of
///      these must read `address(0)`.
///
///      **THE ONE DELIBERATE EXCEPTION IS $CHIP ITSELF.** Its owner is the **ChipBurner**, not
///      the Safe — that is what makes burns real, and the Safe governs it indirectly by owning
///      the Burner. This script asserts that shape explicitly rather than letting it look like
///      a contract somebody forgot to hand over.
///
///      Read-only. No key, no broadcast:
///        forge script script/VerifyOwnership.s.sol:VerifyOwnership --rpc-url $BASE_RPC_URL
contract VerifyOwnership is Script {
    uint256 internal failures;

    function run() external {
        address multisig = vm.envAddress("MULTISIG");
        address deployWallet = vm.envAddress("DEPLOY_WALLET");
        address ops = vm.envAddress("OPS_WALLET");
        address loanTreasury = vm.envAddress("LOAN_TREASURY");

        console2.log("=========================================================");
        console2.log("  OWNERSHIP AUDIT");
        console2.log("  Safe          :", multisig);
        console2.log("  Deploy wallet :", deployWallet);
        console2.log("=========================================================");
        console2.log("");

        _check("FeeSplitter", vm.envAddress("FEE_SPLITTER"), multisig, deployWallet);
        _check("StockRegistry", vm.envAddress("STOCK_REGISTRY"), multisig, deployWallet);
        _check("Pot", vm.envAddress("POT"), multisig, deployWallet);
        _check("POLTreasury", vm.envAddress("POL_TREASURY"), multisig, deployWallet);
        _check("ChipBurner", vm.envAddress("CHIP_BURNER"), multisig, deployWallet);
        _check("ChipActivation", vm.envAddress("CHIP_ACTIVATION"), multisig, deployWallet);
        _check("ChipClaims", vm.envAddress("CHIP_CLAIMS"), multisig, deployWallet);
        _check("ChipRounds", vm.envAddress("CHIP_ROUNDS"), multisig, deployWallet);
        _check("ClaimRouter", vm.envAddress("CLAIM_ROUTER"), multisig, deployWallet);
        _check("Furnace", vm.envAddress("FURNACE"), multisig, deployWallet);
        _check("NounLoans", vm.envAddress("NOUN_LOANS"), multisig, deployWallet);
        _check("Anvil", vm.envAddress("ANVIL"), multisig, deployWallet);

        console2.log("");
        console2.log("--- the deliberate exception ---");
        _checkChip();

        console2.log("");
        console2.log("--- money goes where you said ---");
        _checkPayees(ops, loanTreasury);

        console2.log("");
        console2.log("=========================================================");
        if (failures == 0) {
            console2.log("  PASS. Twelve contracts, all owned by the Safe, no");
            console2.log("  pending transfers, deploy wallet holds nothing.");
        } else {
            console2.log("  FAILURES:", failures);
        }
        console2.log("=========================================================");

        require(failures == 0, "OWNERSHIP AUDIT FAILED - see the log above");
    }

    function _check(string memory name, address target, address multisig, address deployWallet) internal {
        require(target != address(0), string.concat(name, ": address not set in the environment"));
        require(target.code.length > 0, string.concat(name, ": no code at that address"));

        address o = IOwned(target).owner();
        address p = IOwned(target).pendingOwner();

        bool ok = true;
        if (o != multisig) {
            console2.log("  [FAIL] %s owner() is NOT the Safe: %s", name, o);
            ok = false;
            ++failures;
        }
        if (o == deployWallet) {
            console2.log("  [FAIL] %s IS STILL OWNED BY THE DEPLOY WALLET", name);
        }
        if (p != address(0)) {
            console2.log("  [FAIL] %s has a DANGLING pendingOwner: %s", name, p);
            console2.log("         that address can seize this contract with acceptOwnership()");
            ok = false;
            ++failures;
        }
        if (ok) console2.log("  [ok]   %s  owner == Safe, no pending transfer  (%s)", name, target);
    }

    /// @dev $CHIP is owned by the ChipBurner, on purpose. If it is still owned by the deploy
    ///      wallet, LAUNCH_CONFIG section 6.6 never happened and every burn is silently
    ///      accumulating at the Burner instead of reducing supply.
    function _checkChip() internal {
        address chip = vm.envAddress("CHIP");
        address burner = vm.envAddress("CHIP_BURNER");
        address deployWallet = vm.envAddress("DEPLOY_WALLET");

        address chipOwner = IChipOwner(chip).owner();

        if (chipOwner == burner) {
            console2.log("  [ok]   $CHIP owner == ChipBurner. Burns are REAL.");
        } else if (chipOwner == deployWallet) {
            console2.log("  [FAIL] $CHIP IS STILL OWNED BY THE DEPLOY WALLET.");
            console2.log("         Section 6.6 has not been done. burnAll() reverts and every");
            console2.log("         burned $CHIP is piling up at the Burner untouched.");
            ++failures;
        } else {
            console2.log("  [FAIL] $CHIP owner is neither the Burner nor the deploy wallet: %s", chipOwner);
            ++failures;
        }

        if (address(IBurner(burner).chipToken()) != chip) {
            console2.log("  [FAIL] ChipBurner is bound to a DIFFERENT token than $CHIP");
            ++failures;
        }
    }

    function _checkPayees(address ops, address loanTreasury) internal {
        address splitter = vm.envAddress("FEE_SPLITTER");
        address loans = vm.envAddress("NOUN_LOANS");
        address pot = vm.envAddress("POT");

        if (ISplitter(splitter).ops() != ops) {
            console2.log("  [FAIL] FeeSplitter.ops() != OPS_WALLET");
            ++failures;
        } else {
            console2.log("  [ok]   FeeSplitter.ops() == OPS_WALLET");
        }

        if (ISplitter(splitter).pot() != pot) {
            console2.log("  [FAIL] FeeSplitter.pot() is not the Pot - setPot was never called");
            ++failures;
        } else {
            console2.log("  [ok]   FeeSplitter.pot() == Pot (the day-0 placeholder was replaced)");
        }

        if (ILoans(loans).treasury() != loanTreasury) {
            console2.log("  [FAIL] NounLoans.treasury() != LOAN_TREASURY");
            ++failures;
        } else {
            console2.log("  [ok]   NounLoans.treasury() == LOAN_TREASURY");
        }
    }
}
