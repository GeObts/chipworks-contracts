// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {ChipBurner} from "../src/ChipBurner.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {StockRegistry} from "../src/StockRegistry.sol";
import {Pot} from "../src/Pot.sol";
import {ChipActivation} from "../src/activation/ChipActivation.sol";
import {ChipClaims} from "../src/ChipClaims.sol";
import {ChipRounds} from "../src/ChipRounds.sol";
import {POLTreasury} from "../src/POLTreasury.sol";
import {ClaimRouter} from "../src/ClaimRouter.sol";
import {Furnace} from "../src/furnace/Furnace.sol";
import {NounLoans} from "../src/loans/NounLoans.sol";
import {Anvil} from "../src/anvil/Anvil.sol";

/// @title Chipworks deploy scripts
/// @notice The twelve CREATE transactions, split into the four phases the calendar forces.
///
/// @dev ═══════════════════════════════════════════════════════════════════════════════════
///      READ THIS BEFORE RUNNING ANYTHING.
///      ═══════════════════════════════════════════════════════════════════════════════════
///
///      **THIS SCRIPT ONLY DEPLOYS. IT CANNOT CONFIGURE ANYTHING, AND THAT IS BY DESIGN.**
///
///      Every contract here takes `MULTISIG` as its `Ownable` owner *in the constructor*, so
///      it is owned by the Safe from the very first block of its life. The deploy wallet is
///      never an owner of anything and therefore **cannot call a single setter** —
///      `addStock`, `queueCosts`, `setRouters`, `setCustodian`, `setCollectionBaseBps` and
///      every other config call reverts `OwnableUnauthorizedAccount` if this wallet tries.
///
///      That is the safe arrangement — an EOA never holds control of live contracts, not even
///      transiently — and it is what DEPLOY.md and LAUNCH_CONFIG specify. The consequence is
///      that **the config half of the deploy runs from the Safe, not from forge.** Use
///      `script/SafeCalls.s.sol` to print every one of those calls as target + calldata for
///      the Safe Transaction Builder.
///
///      **WHY FOUR PHASES.** The sequence spans days, not minutes: $CHIP must launch, then
///      24–48h of price must be observed before the cost table exists, then a 48h timelock
///      runs. No single `forge script` invocation can span that. Each phase is run on a
///      different day and reads the previous phase's addresses from the environment.
///
///      **EVERY PHASE IS EXERCISED ON A FORK** by `test/fork/DeployScript.t.sol`, which runs
///      these exact functions and then asserts the same post-conditions the rehearsal does.
contract DeployPhase1PreChip is Script {
    /// @notice Day 0, before $CHIP exists. FeeSplitter, StockRegistry, Pot, POLTreasury, Anvil.
    ///
    /// @dev Reads: MULTISIG, OPS_WALLET.
    ///
    ///      **THE ANVIL IS HERE, NOT IN PHASE 4, AND THE REASON IS THE CLOCK.** Its
    ///      constructor is `(multisig, feeSplitter, premiumBps)` — no $CHIP anywhere — and its
    ///      queue price is denominated in ETH. So it can be deployed before the token exists,
    ///      which means `queueQueuePrice` can be called TODAY and its 48-hour timelock runs
    ///      during the launch and the price-observation window rather than after it.
    ///
    ///      Deploying it in phase 4 would have started that clock two days later for no
    ///      reason. Nothing else in the sequence has this property: every other timelocked
    ///      thing is denominated in $CHIP and genuinely cannot start until the token is live.
    function run()
        external
        returns (address splitter, address registry, address pot, address polTreasury, address anvil)
    {
        address multisig = vm.envAddress("MULTISIG");
        address ops = vm.envAddress("OPS_WALLET");

        require(multisig != address(0), "MULTISIG unset");
        require(ops != address(0), "OPS_WALLET unset");
        require(multisig.code.length > 0, "MULTISIG has no code - is it really the Safe?");

        vm.startBroadcast();

        // 1. FeeSplitter. The second argument is the multisig standing in as the Pot; the
        //    Safe corrects it with setPot() once step 3 exists.
        FeeSplitter s = new FeeSplitter(multisig, multisig, ops, 2_000, 2_000);

        // 2. StockRegistry.
        //    🔴 SLIPSTREAM FACTORY B IS IMMUTABLE AND CANNOT BE CORRECTED LATER.
        StockRegistry r = new StockRegistry(multisig, Addrs.USDC, Addrs.UNIV3_FACTORY, Addrs.SLIP_FACTORY_B);

        // 3. Pot.
        Pot p = new Pot(multisig, Addrs.USDC, Addrs.UNIV3_FACTORY);

        // 6. POLTreasury. Runs on Aerodrome factory A via the NPM - deliberately the other
        //    book from the registry's factory B. Not a mistake; see LAUNCH_CONFIG step 6.
        POLTreasury t =
            new POLTreasury(multisig, Addrs.USDC, Addrs.SLIP_NPM, address(s), Addrs.UNIV3_FACTORY, Addrs.AERO_VOTER);

        // 10. Anvil. Deployed EARLY on purpose - see the note above. Prices in ETH, needs
        //     no $CHIP, so its 48h price timelock can start today.
        Anvil an = new Anvil(multisig, address(s), 2_500);

        vm.stopBroadcast();

        // --- the immutables, read back off the deployed code -------------------------
        require(r.slipstreamFactory() == Addrs.SLIP_FACTORY_B, "REGISTRY ON THE WRONG SLIPSTREAM FACTORY");
        require(an.owner() == multisig, "anvil owner is not the multisig");
        require(!an.sellEnabled(), "anvil sell side must be off and has no setter");
        require(s.owner() == multisig && r.owner() == multisig, "owner is not the multisig");
        require(p.owner() == multisig && t.owner() == multisig, "owner is not the multisig");

        console2.log("");
        console2.log("=== PHASE 1 COMPLETE - export these ===");
        console2.log("export FEE_SPLITTER=%s", address(s));
        console2.log("export STOCK_REGISTRY=%s", address(r));
        console2.log("export POT=%s", address(p));
        console2.log("export POL_TREASURY=%s", address(t));
        console2.log("export ANVIL=%s", address(an));
        console2.log("");
        console2.log("NEXT: SafeCalls phase 1. QUEUE THE ANVIL PRICE TODAY - that starts");
        console2.log("      its 48h clock now instead of two days from now.");

        return (address(s), address(r), address(p), address(t), address(an));
    }
}

contract DeployPhase2Burner is Script {
    /// @notice The moment $CHIP exists. ChipBurner, and nothing else.
    ///
    /// @dev Reads: MULTISIG, CHIP.
    ///
    ///      🔴 THIS ADDRESS BECOMES `immutable` ON THREE LATER CONTRACTS — ChipActivation,
    ///      ChipRounds and the Furnace. If it is wrong, all four redeploy. It is the only
    ///      deploy in the sequence whose own dependency is a Bankr artifact rather than ours.
    ///
    ///      NO OWNERSHIP HAND-OFF. This contract was designed believing $CHIP's `burn` was
    ///      owner-gated, so it would have to become the token's owner first. It does not:
    ///      the Doppler factory owns $CHIP permanently and `burn(uint256)` is a standard
    ///      public burn of the caller's own balance. `burnAll()` calls exactly that, so it
    ///      works from the moment this deploys. Proven against the live pair in
    ///      `test/fork/LiveBurnerBurn.t.sol`.
    function run() external returns (address burner) {
        address multisig = vm.envAddress("MULTISIG");
        address chip = vm.envAddress("CHIP");

        require(chip != address(0), "CHIP unset");
        require(chip.code.length > 0, "CHIP has no code at that address");

        vm.startBroadcast();
        ChipBurner b = new ChipBurner(multisig, chip);
        vm.stopBroadcast();

        require(address(b.chipToken()) == chip, "burner bound to the wrong token");
        require(b.owner() == multisig, "burner owner is not the multisig");

        console2.log("");
        console2.log("=== PHASE 2 COMPLETE ===");
        console2.log("export CHIP_BURNER=%s", address(b));
        console2.log("");
        console2.log("NO OWNERSHIP HAND-OFF IS NEEDED OR POSSIBLE.");
        console2.log("  The Doppler factory owns $CHIP permanently; burn(uint256) is PUBLIC and");
        console2.log("  destroys the CALLER's own balance. burnAll() already does exactly that.");
        console2.log("  Proof: test/fork/LiveBurnerBurn.t.sol, against this deployed address.");
        console2.log("NEXT: transfer 1e18 CHIP here, call burnAll(), confirm totalSupply fell.");

        return address(b);
    }
}

contract DeployPhase3Activation is Script {
    /// @notice Day 2, after 24–48h of observed price. ChipActivation only.
    ///
    /// @dev Reads: MULTISIG, CHIP, CHIP_BURNER.
    ///
    ///      Deployed alone and early because everything it gates is timelocked: the Safe must
    ///      call `setFlatRateCollection(CHIPLETS)` and then `queueCosts` x4 immediately after
    ///      this, and those need 48 hours before `executeCosts`.
    function run() external returns (address activation) {
        address multisig = vm.envAddress("MULTISIG");
        address chip = vm.envAddress("CHIP");
        address burner = vm.envAddress("CHIP_BURNER");

        require(burner.code.length > 0, "CHIP_BURNER has no code");
        require(address(ChipBurner(burner).chipToken()) == chip, "CHIP_BURNER is bound to a different token");

        vm.startBroadcast();
        ChipActivation a = new ChipActivation(multisig, chip, burner, [uint32(10_000), 12_500, 16_000, 20_000, 33_300]);
        vm.stopBroadcast();

        require(a.chipBurnTarget() == burner, "IMMUTABLE BURN TARGET IS WRONG - REDEPLOY");
        require(address(a.chipToken()) == chip, "wrong chip token");

        console2.log("");
        console2.log("=== PHASE 3 COMPLETE ===");
        console2.log("export CHIP_ACTIVATION=%s", address(a));
        console2.log("");
        console2.log("NEXT, FROM THE SAFE, AND THE ORDER MATTERS:");
        console2.log("  1. setFlatRateCollection(CHIPLETS)   <- BEFORE any executeCosts, one-way");
        console2.log("  2. queueCosts x4  (LIL, BASED, DARK tiered; CHIPLETS five EQUAL entries)");
        console2.log("  3. wait 48 hours, then executeCosts x4");

        return address(a);
    }
}

contract DeployPhase4Core is Script {
    /// @notice The remaining five, in dependency order. The Anvil is not here - it went out
    ///         in phase 1 so its price timelock could start on day zero.
    ///
    /// @dev Reads: MULTISIG, LOAN_TREASURY, CHIP, CHIP_BURNER, STOCK_REGISTRY, POT,
    ///      CHIP_ACTIVATION, FEE_SPLITTER, BASED_NOUNS, DARK_NOUNS,
    ///      SPLIT_FEE_CHIP, FURNACE_BASED_CHIP_COST, FURNACE_DARK_CHIP_COST.
    ///
    ///      🔴 `ChipClaims`' DEPLOY TIMESTAMP PERMANENTLY FIXES THE CLAIM WINDOW'S DAY OF THE
    ///      WEEK. There is no setter for the anchor. Run this phase at a time you have chosen
    ///      on purpose.
    /// @dev Grouped into a struct because reading thirteen environment values as separate
    ///      locals overflows the stack on the non-via-ir profile this repo builds with.
    struct Cfg {
        address multisig;
        address loanTreasury;
        address chip;
        address burner;
        address registry;
        address pot;
        address activation;
        address splitter;
        address basedNouns;
        address darkNouns;
        uint256 splitFee;
        uint256 basedCost;
        uint256 darkCost;
    }

    function _cfg() internal view returns (Cfg memory c) {
        c.multisig = vm.envAddress("MULTISIG");
        c.loanTreasury = vm.envAddress("LOAN_TREASURY");
        c.chip = vm.envAddress("CHIP");
        c.burner = vm.envAddress("CHIP_BURNER");
        c.registry = vm.envAddress("STOCK_REGISTRY");
        c.pot = vm.envAddress("POT");
        c.activation = vm.envAddress("CHIP_ACTIVATION");
        c.splitter = vm.envAddress("FEE_SPLITTER");
        c.basedNouns = vm.envAddress("BASED_NOUNS");
        c.darkNouns = vm.envAddress("DARK_NOUNS");
        c.splitFee = vm.envUint("SPLIT_FEE_CHIP");
        c.basedCost = vm.envUint("FURNACE_BASED_CHIP_COST");
        c.darkCost = vm.envUint("FURNACE_DARK_CHIP_COST");

        require(c.loanTreasury != address(0), "LOAN_TREASURY unset");
        require(c.basedNouns.code.length > 0, "BASED_NOUNS has no code");
        require(c.darkNouns.code.length > 0, "DARK_NOUNS has no code");
        require(c.splitFee > 0, "SPLIT_FEE_CHIP must be non-zero");
        require(c.basedCost > 0 && c.darkCost > 0, "Furnace chipCost cannot be zero");
        require(ChipActivation(c.activation).chipBurnTarget() == c.burner, "activation/burner mismatch");
    }

    function run()
        external
        returns (address claims, address rounds, address claimRouter, address furnace, address loans)
    {
        Cfg memory c = _cfg();

        vm.startBroadcast();

        // 5a. ChipClaims - the ledger.
        claims = address(new ChipClaims(c.multisig, c.registry));

        // 5b. ChipRounds - the engine.
        rounds = address(new ChipRounds(c.multisig, c.registry, c.pot, c.activation, claims, c.splitFee, c.burner));

        // 7. ClaimRouter - points at the LEDGER, not the engine.
        claimRouter = address(new ClaimRouter(c.multisig, claims, 1_000_000));

        // 8. Furnace. Fuel is CHIPLETS and it is immutable. Both recipes deploy unpaused and
        //    are switched OFF by the Safe immediately - see SafeCalls.
        furnace = address(
            new Furnace(
                c.multisig,
                c.chip,
                c.burner,
                Addrs.CHIPLETS,
                Furnace.Recipe({
                    exists: true, paused: false, outputCollection: c.basedNouns, fuelCost: 25, chipCost: c.basedCost
                }),
                Furnace.Recipe({
                    exists: true, paused: false, outputCollection: c.darkNouns, fuelCost: 50, chipCost: c.darkCost
                })
            )
        );

        // 9. NounLoans.
        loans = address(
            new NounLoans(
                c.multisig,
                c.chip,
                c.splitter,
                c.loanTreasury,
                c.activation,
                NounLoans.Terms({
                    length: [uint64(7 days), 14 days, 30 days, 90 days, 180 days],
                    feeBps: [uint32(50), 100, 200, 500, 900],
                    bountyBps: 200,
                    lateFeeBps: 100
                })
            )
        );

        vm.stopBroadcast();

        _assertImmutables(c, claims, rounds, claimRouter, furnace);
        _report(claims, rounds, claimRouter, furnace, loans);
    }

    function _assertImmutables(Cfg memory c, address claims, address rounds, address claimRouter, address furnace)
        internal
        view
    {
        require(ChipRounds(rounds).chipBurnTarget() == c.burner, "ROUNDS BURN TARGET WRONG - REDEPLOY");
        require(Furnace(furnace).chipBurnTarget() == c.burner, "FURNACE BURN TARGET WRONG - REDEPLOY");
        require(address(Furnace(furnace).fuelCollection()) == Addrs.CHIPLETS, "FURNACE FUEL WRONG - REDEPLOY");
        require(address(ClaimRouter(claimRouter).rewards()) == claims, "ClaimRouter must point at ChipClaims");
        require(address(ChipRounds(rounds).registry()) == c.registry, "rounds registry mismatch");
    }

    function _report(address claims, address rounds, address claimRouter, address furnace, address loans)
        internal
        pure
    {
        console2.log("");
        console2.log("=== PHASE 4 COMPLETE ===");
        console2.log("export CHIP_CLAIMS=%s", claims);
        console2.log("export CHIP_ROUNDS=%s", rounds);
        console2.log("export CLAIM_ROUTER=%s", claimRouter);
        console2.log("export FURNACE=%s", furnace);
        console2.log("export NOUN_LOANS=%s", loans);
        console2.log("");
        console2.log("ALL TWELVE DEPLOYED (the Anvil went out in phase 1). Nothing is wired");
        console2.log("yet and nothing can take money.");
        console2.log("NEXT: SafeCalls phase 4, and DO NOT MISS setCustodian OR the four baseBps.");
    }
}

/// @notice Base mainnet addresses, every one verified on chain.
library Addrs {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address internal constant UNIV3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address internal constant UNIV3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;

    /// @dev 🔴 FACTORY B. Every B20 stock pool is here. Factory A resolves none of them and
    ///      `slipstreamFactory` is immutable on the registry.
    address internal constant SLIP_FACTORY_B = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef;
    address internal constant SLIP_ROUTER_B = 0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F;

    /// @dev The Aerodrome NPM, which is on factory A. POL runs on the other book on purpose.
    address internal constant SLIP_NPM = 0x827922686190790b37229fd06084350E74485b72;
    address internal constant AERO_VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;

    address internal constant SEQUENCER_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    address internal constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant AERO_USD_FEED = 0x4EC5970fC728C5f65ba413992CD5fF6FD70fcfF0;

    address internal constant LIL_NOUNS = 0xe3c5Ef27B80481518a2363406e354a9361415556;
    address internal constant CHIPLETS = 0xC7c114191aa3b2225F9bb053Bc55b3d6F145Bd33;
}
