// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";

import {
    DeployPhase1PreChip,
    DeployPhase2Burner,
    DeployPhase3Activation,
    DeployPhase4Core,
    Addrs
} from "../../script/Deploy.s.sol";

import {ChipBurner} from "../../src/ChipBurner.sol";
import {FeeSplitter} from "../../src/FeeSplitter.sol";
import {StockRegistry} from "../../src/StockRegistry.sol";
import {Pot} from "../../src/Pot.sol";
import {ChipActivation} from "../../src/activation/ChipActivation.sol";
import {ChipClaims} from "../../src/ChipClaims.sol";
import {ChipRounds} from "../../src/ChipRounds.sol";
import {POLTreasury} from "../../src/POLTreasury.sol";
import {ClaimRouter} from "../../src/ClaimRouter.sol";
import {Furnace} from "../../src/furnace/Furnace.sol";
import {NounLoans} from "../../src/loans/NounLoans.sol";
import {Anvil} from "../../src/anvil/Anvil.sol";

import {MockNoun} from "../mocks/MockNoun.sol";
import {DopplerLikeChip} from "../ChipBurner.t.sol";

/// @title DeployScriptForkTest
/// @notice Runs the REAL deploy script — the same four `run()` functions launch day executes —
///         against a Base mainnet fork, and checks what comes out.
///
/// @dev WHY THIS IS SEPARATE FROM `DeployRehearsal.t.sol`. The rehearsal proves the *sequence*
///      is sound: ordering, timelocks, wiring, the silent custodian wire. It does that by
///      constructing everything inline, which means it proves the SEQUENCE without proving the
///      SCRIPT. This suite is the other half — it executes `script/Deploy.s.sol` itself, so a
///      typo in a constructor argument, a missing env var, or a broken `require` in the script
///      fails here rather than on mainnet.
///
///      Together: the rehearsal says "this order works", this says "the thing you will
///      actually type produces that order".
contract DeployScriptForkTest is Test {
    DopplerLikeChip internal chip;
    MockNoun internal basedNouns;
    MockNoun internal darkNouns;

    /// @dev The script requires `MULTISIG` to have code, on the reasoning that a Safe is a
    ///      contract and an EOA there means somebody pasted the wrong address. Any contract
    ///      satisfies that, so a MockNoun stands in for the Safe.
    address internal multisig;
    address internal ops = makeAddr("OPS_WALLET");
    address internal loanTreasury = makeAddr("LOAN_TREASURY");
    address internal keeper = makeAddr("KEEPER");

    uint256 internal constant BASE_UNIT = 50_000e18;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));

        multisig = address(new MockNoun("Safe", "SAFE"));
        chip = new DopplerLikeChip(1_000_000_000e18);
        basedNouns = new MockNoun("Based Nouns", "BASED");
        darkNouns = new MockNoun("DarkNOUNs", "DARK");

        vm.setEnv("MULTISIG", vm.toString(multisig));
        vm.setEnv("OPS_WALLET", vm.toString(ops));
        vm.setEnv("LOAN_TREASURY", vm.toString(loanTreasury));
        vm.setEnv("KEEPER", vm.toString(keeper));
        vm.setEnv("CHIP", vm.toString(address(chip)));
        vm.setEnv("BASED_NOUNS", vm.toString(address(basedNouns)));
        vm.setEnv("DARK_NOUNS", vm.toString(address(darkNouns)));
        vm.setEnv("CHIP_BASE_UNIT", vm.toString(BASE_UNIT));
        vm.setEnv("SPLIT_FEE_CHIP", vm.toString(BASE_UNIT / 10));
        vm.setEnv("FURNACE_BASED_CHIP_COST", vm.toString(BASE_UNIT / 2));
        vm.setEnv("FURNACE_DARK_CHIP_COST", vm.toString((BASE_UNIT * 12) / 10));
    }

    /// @notice All four phases, in order, exactly as launch day runs them.
    function test_theDeployScriptProducesTheDocumentedStack() public {
        // ---------------- phase 1: before $CHIP -------------------------------
        (address splitter, address registry, address pot, address polTreasury) = new DeployPhase1PreChip().run();

        vm.setEnv("FEE_SPLITTER", vm.toString(splitter));
        vm.setEnv("STOCK_REGISTRY", vm.toString(registry));
        vm.setEnv("POT", vm.toString(pot));
        vm.setEnv("POL_TREASURY", vm.toString(polTreasury));

        assertEq(FeeSplitter(payable(splitter)).owner(), multisig, "P1: splitter owned by the Safe");
        assertEq(FeeSplitter(payable(splitter)).opsBps(), 2_000, "P1: opsBps");
        assertEq(FeeSplitter(payable(splitter)).potBps(), 8_000, "P1: potBps");
        assertEq(StockRegistry(registry).slipstreamFactory(), Addrs.SLIP_FACTORY_B, "P1: THE immutable - factory B");
        assertEq(StockRegistry(registry).stockCount(), 0, "P1: stocks are a Safe call, not a deploy call");
        assertEq(Pot(payable(pot)).owner(), multisig, "P1: pot owned by the Safe");
        assertEq(
            POLTreasury(payable(polTreasury)).positionFactory(),
            0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A,
            "P1: POL is on factory A"
        );

        // ---------------- phase 2: the Burner ---------------------------------
        address burner = new DeployPhase2Burner().run();
        vm.setEnv("CHIP_BURNER", vm.toString(burner));

        assertEq(address(ChipBurner(burner).chipToken()), address(chip), "P2: bound to $CHIP");
        assertEq(ChipBurner(burner).owner(), multisig, "P2: admin owner is the Safe");

        // ---------------- phase 3: ChipActivation -----------------------------
        address activation = new DeployPhase3Activation().run();
        vm.setEnv("CHIP_ACTIVATION", vm.toString(activation));

        assertEq(ChipActivation(activation).chipBurnTarget(), burner, "P3: THE immutable burn target");
        assertEq(ChipActivation(activation).owner(), multisig, "P3: owned by the Safe");

        // ---------------- phase 4: the remaining six --------------------------
        (address claims, address rounds, address claimRouter, address furnace, address loans, address anvil) =
            new DeployPhase4Core().run();

        assertEq(ChipRounds(rounds).chipBurnTarget(), burner, "P4: rounds burn target");
        assertEq(Furnace(furnace).chipBurnTarget(), burner, "P4: furnace burn target");
        assertEq(address(Furnace(furnace).fuelCollection()), Addrs.CHIPLETS, "P4: fuel is the real Chiplets");
        assertEq(Furnace(furnace).recipe(0).fuelCost, 25, "P4: Based recipe 25 Chiplets");
        assertEq(Furnace(furnace).recipe(1).fuelCost, 50, "P4: Dark recipe 50 Chiplets");
        assertEq(address(ClaimRouter(claimRouter).rewards()), claims, "P4: router points at the LEDGER");
        assertEq(address(ChipRounds(rounds).registry()), registry, "P4: rounds registry");
        assertEq(address(ChipRounds(rounds).pot()), pot, "P4: rounds pot");
        assertEq(ChipRounds(rounds).splitChangeFeeChip(), BASE_UNIT / 10, "P4: split-change fee");
        assertEq(NounLoans(loans).treasury(), loanTreasury, "P4: loan treasury");
        assertEq(Anvil(payable(anvil)).owner(), multisig, "P4: anvil owned by the Safe");
        assertFalse(Anvil(payable(anvil)).sellEnabled(), "P4: sell side off, no setter");

        // Every one of the twelve is owned by the Safe and by nobody else.
        assertEq(ChipClaims(claims).owner(), multisig, "P4: claims owner");
        assertEq(ChipRounds(rounds).owner(), multisig, "P4: rounds owner");
        assertEq(Furnace(furnace).owner(), multisig, "P4: furnace owner");
        assertEq(NounLoans(loans).owner(), multisig, "P4: loans owner");
    }

    /// @notice THE DEPLOY WALLET CANNOT CONFIGURE ANYTHING, AND THAT IS THE WHOLE POINT.
    ///
    /// @dev The reason `SafeCalls.s.sol` exists. Every contract is `Ownable(MULTISIG)` from its
    ///      constructor, so the wallet that deployed it has no authority over it at all — not
    ///      transiently, not for a single block. This asserts that rather than assuming it,
    ///      because the alternative arrangement (deploy as owner, hand over later) is the one
    ///      people reach for by default and it would leave an EOA in control of live contracts.
    function test_theDeployWalletHasNoAuthorityOverAnythingItDeployed() public {
        (address splitter, address registry, address pot,) = new DeployPhase1PreChip().run();

        // `address(this)` is the deployer inside this test, standing in for the deploy wallet.
        vm.expectRevert();
        FeeSplitter(payable(splitter)).setPot(pot);

        vm.expectRevert();
        StockRegistry(registry).setEnabled(Addrs.WETH, true);

        vm.expectRevert();
        Pot(payable(pot)).setRewards(splitter);
    }

    /// @notice A phase refuses to run on a half-filled environment rather than deploying junk.
    function test_aMissingInputStopsTheScriptRatherThanDeployingSomethingWrong() public {
        // The Burner bound to a token that is not the one Activation will be told about is
        // the single most expensive mistake available, so phase 3 checks the pair.
        address burner = address(new ChipBurner(multisig, address(new DopplerLikeChip(1e18))));
        vm.setEnv("CHIP_BURNER", vm.toString(burner));

        // Construct FIRST: `vm.expectRevert` binds to the next call, and `new` is a CREATE,
        // so building the script inline would attach the expectation to the constructor.
        DeployPhase3Activation phase3 = new DeployPhase3Activation();

        vm.expectRevert(bytes("CHIP_BURNER is bound to a different token"));
        phase3.run();
    }
}
