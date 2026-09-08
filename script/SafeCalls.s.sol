// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Addrs} from "./Deploy.s.sol";
import {StockRegistry} from "../src/StockRegistry.sol";
import {Venue} from "../src/interfaces/IStockRegistry.sol";

/// @title SafeCalls — every owner-only transaction, as ready-to-paste calldata
/// @notice The other half of the deploy. `Deploy.s.sol` does the twelve CREATEs; everything
///         else in LAUNCH_CONFIG is an `onlyOwner` call that must come from the Safe.
///
/// @dev WHY THIS EXISTS. There are roughly forty owner-only calls in the sequence, several of
///      them taking structs (`addStock`), fixed-size arrays (`queueCosts`) or values that must
///      be derived from the observed price. Hand-encoding those in the Safe UI forty times is
///      the single most error-prone part of launch day, and the mistakes it produces are
///      exactly the silent kind — a wrong `baseBps`, a missed `setCustodian`.
///
///      So this prints each call as `to` + `data`, in order, grouped by phase. Paste them
///      into the Safe Transaction Builder — it takes a `to`, a `value` (always 0 here) and a
///      hex `data` field — and batch each phase into one Safe transaction.
///
///      **THIS SCRIPT BROADCASTS NOTHING AND SIGNS NOTHING.** It is a pure `view` run. It
///      cannot deploy, cannot send and holds no key. Run it with plain `forge script`, no
///      `--broadcast` and no account.
contract SafeCallsPhase1 is Script {
    /// @notice Phase 1 config: thirteen stocks, the Pot, POL — and THE ANVIL PRICE QUEUE.
    /// @dev Reads: STOCK_REGISTRY, POT, POL_TREASURY, KEEPER, ANVIL, BASED_NOUNS,
    ///      ANVIL_QUEUE_PRICE_WEI.
    ///
    ///      **THE ANVIL QUEUE IS THE WHOLE POINT OF RUNNING THIS TODAY.** Its price is on a
    ///      48-hour timelock with no first-set exemption, and its price is denominated in ETH
    ///      rather than $CHIP — so the clock can run through the token launch and the
    ///      price-observation window instead of starting after them. Queue it now and the
    ///      Anvil is sellable two days from now. Queue it in phase 4 and it is sellable four.
    function run() external view {
        address registry = vm.envAddress("STOCK_REGISTRY");
        address pot = vm.envAddress("POT");
        address polTreasury = vm.envAddress("POL_TREASURY");
        address keeper = vm.envAddress("KEEPER");
        address anvil = vm.envAddress("ANVIL");
        address based = vm.envAddress("BASED_NOUNS");
        uint256 anvilPriceWei = vm.envUint("ANVIL_QUEUE_PRICE_WEI");

        require(anvilPriceWei > 0, "ANVIL_QUEUE_PRICE_WEI unset - see the number sheet, group A");

        console2.log("################ PHASE 1 SAFE CALLS ################");
        console2.log("Batch all of these into ONE Safe transaction if you can.");
        console2.log("");

        _stocks(registry);

        console2.log("--- Pot ---");
        _p(
            "pot.setConversionConfig(WETH ...)",
            pot,
            abi.encodeWithSignature(
                "setConversionConfig(address,address,address,uint24,uint32,uint128,uint128,uint64)",
                Addrs.WETH,
                Addrs.ETH_USD_FEED,
                Addrs.UNIV3_ROUTER,
                uint24(500),
                uint32(100),
                uint128(5 ether),
                uint128(0),
                uint64(1 hours)
            )
        );
        _p(
            "pot.setRoute(AERO ...)",
            pot,
            abi.encodeWithSignature(
                "setRoute(address,address,address,uint24,uint32,uint128,uint128,uint64)",
                Addrs.AERO,
                Addrs.AERO_USD_FEED,
                Addrs.UNIV3_ROUTER,
                uint24(500),
                uint32(300),
                uint128(50_000 ether),
                uint128(0),
                uint64(24 hours)
            )
        );
        _p(
            "pot.setSequencerFeed",
            pot,
            abi.encodeWithSignature("setSequencerFeed(address,uint64)", Addrs.SEQUENCER_FEED, uint64(1 hours))
        );

        console2.log("--- POLTreasury ---");
        _p("polTreasury.setWeth", polTreasury, abi.encodeWithSignature("setWeth(address)", Addrs.WETH));
        _p("polTreasury.setManager(KEEPER)", polTreasury, abi.encodeWithSignature("setManager(address)", keeper));
        _p(
            "polTreasury.setPolAsset(WETH, 5%, 1h)  <- 24/7 asset, so a REAL window",
            polTreasury,
            abi.encodeWithSignature(
                "setPolAsset(address,address,uint32,uint64)",
                Addrs.WETH,
                Addrs.ETH_USD_FEED,
                uint32(500),
                uint64(1 hours)
            )
        );
        console2.log("  NOTE: every EQUITY POL asset needs maxFeedAge = 0. The B20 feeds have");
        console2.log("        no off-hours heartbeat and a real window refuses every mint");
        console2.log("        outside market hours.");
        console2.log("");

        console2.log("################################################################");
        console2.log("### QUEUE THE ANVIL PRICE TODAY. THIS STARTS THE 48H CLOCK.  ###");
        console2.log("### It is ETH-denominated, so it does NOT wait on $CHIP.     ###");
        console2.log("################################################################");
        console2.log("  price (wei):", anvilPriceWei);
        _p(
            "anvil.queueQueuePrice(BASED_NOUNS, <wei>)",
            anvil,
            abi.encodeWithSignature("queueQueuePrice(address,uint256)", based, anvilPriceWei)
        );
        console2.log("  -> 48h from NOW, call executeQueuePrice(BASED_NOUNS) and the Anvil sells.");
        console2.log("  -> Shelving is separate and NOT timelocked: shelve whenever the Nouns");
        console2.log("     are in hand. The price clock does not wait for the shelf.");
        console2.log("  -> CONFIG_GRACE: a queued change expires 14 days after it matures.");
    }

    /// @dev The thirteen B20 stocks. Pools are re-derived from the LIVE factory B at run time
    ///      rather than pasted, so a moved or missing pool shows up here and not on chain.
    function _stocks(address registry) internal view {
        (address[13] memory t, address[13] memory f) = _b20();
        console2.log("--- StockRegistry: addStock x13, ALL DISABLED ---");
        uint256 withPool;
        for (uint256 i; i < 13; ++i) {
            address pool = _slipPool(t[i]);
            if (pool != address(0)) ++withPool;
            _p(
                pool == address(0) ? "addStock (Venue.None - no pool anywhere)" : "addStock (Slipstream, factory B)",
                registry,
                abi.encodeCall(
                    StockRegistry.addStock,
                    (StockRegistry.AddStockParams({
                            token: t[i],
                            feed: f[i],
                            venue: pool == address(0) ? Venue.None : Venue.Slipstream,
                            pool: pool,
                            fee: 0,
                            tickSpacing: pool == address(0) ? int24(0) : int24(10),
                            minLiquidityUsd: 25_000e18,
                            tokenDecimals: 8
                        }))
                )
            );
        }
        require(withPool == 10, "expected exactly ten factory-B pools - the venue set has moved, STOP");
        console2.log("  ten resolved a factory-B pool, three registered Venue.None. As expected.");
        console2.log("");
    }

    function _slipPool(address token) internal view returns (address p) {
        (bool ok, bytes memory ret) = Addrs.SLIP_FACTORY_B
            .staticcall(abi.encodeWithSignature("getPool(address,address,int24)", token, Addrs.USDC, int24(10)));
        if (ok && ret.length >= 32) p = abi.decode(ret, (address));
    }

    function _p(string memory label, address to, bytes memory data) internal pure {
        console2.log(label);
        console2.log("  to  :", to);
        console2.log("  data:", vm.toString(data));
        console2.log("");
    }

    function _b20() internal pure returns (address[13] memory t, address[13] memory f) {
        t[0] = 0xb20000000000000000000078ee7ce2fE4908108C;
        f[0] = 0x04689a41629776563E6822F76f2e57D148d28513;
        t[1] = 0xb2000000000000000000002D0BA3164cc74f58B7;
        f[1] = 0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2;
        t[2] = 0xb200000000000000000000C2e324d24d7eEcd1fb;
        f[2] = 0x787f13dEa48Db0897CbCDD985de77809D837F988;
        t[3] = 0xb2000000000000000000008bC8786B856E61707C;
        f[3] = 0x6526aE6797A76123638b863AeE4dD27Ba4E4b27D;
        t[4] = 0xb2000000000000000000001e800a7f5189430cD0;
        f[4] = 0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4;
        t[5] = 0xb200000000000000000000d9192b6B456483C2E8;
        f[5] = 0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295;
        t[6] = 0xB200000000000000000000Ab99cFa739E253872B;
        f[6] = 0xeB10A6c9aa7E537aEd766C08c35Dae35B321b18c;
        t[7] = 0xb2000000000000000000004884b426556b92883d;
        f[7] = 0xB3cE282CD188b35DA0E38D8Bc7d58e33173D202a;
        t[8] = 0xb200000000000000000000397293Cb8cda9a10c5;
        f[8] = 0x388b0dC46C0Fb05A74BeE0994fa5b02c6Fcca2eA;
        t[9] = 0xb2000000000000000000007b9fcbd005511aCBd5;
        f[9] = 0x6A634B235903C4ad6376892180d6fF8612e3Fa68;
        t[10] = 0xb200000000000000000000c85a31389D71F3ecfb;
        f[10] = 0x408e44f504A7371a345F03a73dDC96A4b48e8aa7;
        t[11] = 0xB20000000000000000000019f6E7C675b73C2e4D;
        f[11] = 0x0231cF2635D1E17bB5c2462cc7504Ba1fBd61f33;
        t[12] = 0xB2000000000000000000004AFF16039bA04bdFBc;
        f[12] = 0xAB657C39bac0D5886250D70849e2E3E008F2EECB;
    }
}

/// @notice Phase 3 config: the flat-rate flag and the cost table, then the 48h execute.
/// @dev Reads: CHIP_ACTIVATION, BASED_NOUNS, DARK_NOUNS, CHIP_BASE_UNIT (in wei).
contract SafeCallsPhase3Costs is Script {
    function run() external view {
        address a = vm.envAddress("CHIP_ACTIVATION");
        address based = vm.envAddress("BASED_NOUNS");
        address dark = vm.envAddress("DARK_NOUNS");
        uint256 unit = vm.envUint("CHIP_BASE_UNIT");

        require(unit > 0, "CHIP_BASE_UNIT unset - compute it from 24-48h of observed price");

        uint256[5] memory tiered =
            [unit, (unit * 220) / 100, (unit * 450) / 100, (unit * 900) / 100, (unit * 2400) / 100];

        // Read EXPLICITLY rather than derived. Deriving it would silently emit
        // LAUNCH_CONFIG's 10%-of-base default even when a different number was chosen on
        // purpose, and that difference is invisible once it is hex calldata.
        uint256 flat = vm.envUint("CHIPLET_FLAT_CHIP");
        require(flat > 0, "CHIPLET_FLAT_CHIP unset - state it, do not let it be derived");
        uint256[5] memory chiplet = [flat, flat, flat, flat, flat];

        console2.log("################ PHASE 3 SAFE CALLS - PART A (queue) ################");
        console2.log("Base unit :", unit);
        console2.log("Tier table:", tiered[0], tiered[1]);
        console2.log("           ", tiered[2], tiered[3]);
        console2.log("           ", tiered[4]);
        console2.log("Chiplets flat (x5):", flat);
        if (flat != unit / 10) {
            console2.log("  NOTE: this is NOT 10% of the base unit.");
            console2.log("        LAUNCH_CONFIG s4 item 6 default would be:", unit / 10);
            console2.log("        10% is what puts a Chiplet at PARITY with a Based Noun on");
            console2.log("        cost-per-unit-of-earning, because Chiplets earn 0.1x.");
            console2.log("        Higher means activating a Chiplet is worse value than a Noun.");
            console2.log("        Deliberate is fine. Accidental is not. Confirm which.");
        }
        console2.log("");

        console2.log("*** THIS ONE MUST GO FIRST AND IS ONE-WAY ***");
        _p(
            "activation.setFlatRateCollection(CHIPLETS)",
            a,
            abi.encodeWithSignature("setFlatRateCollection(address)", Addrs.CHIPLETS)
        );

        _p(
            "queueCosts(LIL_NOUNS)",
            a,
            abi.encodeWithSignature("queueCosts(address,uint256[5])", Addrs.LIL_NOUNS, tiered)
        );
        _p("queueCosts(BASED_NOUNS)", a, abi.encodeWithSignature("queueCosts(address,uint256[5])", based, tiered));
        _p("queueCosts(DARK_NOUNS)", a, abi.encodeWithSignature("queueCosts(address,uint256[5])", dark, tiered));
        _p(
            "queueCosts(CHIPLETS) - five EQUAL entries",
            a,
            abi.encodeWithSignature("queueCosts(address,uint256[5])", Addrs.CHIPLETS, chiplet)
        );

        console2.log("################ PART B - AFTER 48 HOURS ################");
        _p("executeCosts(LIL_NOUNS)", a, abi.encodeWithSignature("executeCosts(address)", Addrs.LIL_NOUNS));
        _p("executeCosts(BASED_NOUNS)", a, abi.encodeWithSignature("executeCosts(address)", based));
        _p("executeCosts(DARK_NOUNS)", a, abi.encodeWithSignature("executeCosts(address)", dark));
        _p("executeCosts(CHIPLETS)", a, abi.encodeWithSignature("executeCosts(address)", Addrs.CHIPLETS));
    }

    function _p(string memory label, address to, bytes memory data) internal pure {
        console2.log(label);
        console2.log("  to  :", to);
        console2.log("  data:", vm.toString(data));
        console2.log("");
    }
}

/// @notice Phase 4 config: the wiring, the four multipliers, and the silent custodian wire.
/// @dev Reads: FEE_SPLITTER, POT, POL_TREASURY, CHIP_CLAIMS, CHIP_ROUNDS, CHIP_ACTIVATION,
///      NOUN_LOANS, FURNACE, CHIP, BASED_NOUNS, DARK_NOUNS.
contract SafeCallsPhase4Wiring is Script {
    struct A {
        address splitter;
        address pot;
        address polTreasury;
        address claims;
        address rounds;
        address activation;
        address loans;
        address furnace;
        address chip;
        address based;
        address dark;
    }

    function run() external view {
        A memory x = A({
            splitter: vm.envAddress("FEE_SPLITTER"),
            pot: vm.envAddress("POT"),
            polTreasury: vm.envAddress("POL_TREASURY"),
            claims: vm.envAddress("CHIP_CLAIMS"),
            rounds: vm.envAddress("CHIP_ROUNDS"),
            activation: vm.envAddress("CHIP_ACTIVATION"),
            loans: vm.envAddress("NOUN_LOANS"),
            furnace: vm.envAddress("FURNACE"),
            chip: vm.envAddress("CHIP"),
            based: vm.envAddress("BASED_NOUNS"),
            dark: vm.envAddress("DARK_NOUNS")
        });

        console2.log("################ PHASE 4 SAFE CALLS ################");
        console2.log("");

        console2.log("--- ChipClaims (both setters are one-shot while unset) ---");
        _p("claims.setRounds", x.claims, abi.encodeWithSignature("setRounds(address)", x.rounds));
        _p("claims.setPolTreasury", x.claims, abi.encodeWithSignature("setPolTreasury(address)", x.polTreasury));
        _p(
            "claims.setClaimSchedule(7d, 2d)",
            x.claims,
            abi.encodeWithSignature("setClaimSchedule(uint32,uint32)", uint32(604800), uint32(172800))
        );
        _p("claims.setCreditExpiry(30d)", x.claims, abi.encodeWithSignature("setCreditExpiry(uint64)", uint64(2592000)));

        console2.log("--- ChipRounds ---");
        _p(
            "rounds.setRoundParams(86400, 7200, 100e6)  <- THREE args, no maxBudget",
            x.rounds,
            abi.encodeWithSignature(
                "setRoundParams(uint64,uint64,uint128)", uint64(86400), uint64(7200), uint128(100e6)
            )
        );

        console2.log("*** ALL FOUR OF THESE. A MISSING ONE ZEROES THAT COLLECTION SILENTLY ***");
        _bps(x.rounds, Addrs.LIL_NOUNS, 5_000, "LIL_NOUNS 0.5x");
        _bps(x.rounds, x.based, 10_000, "BASED_NOUNS 1.0x");
        _bps(x.rounds, x.dark, 20_000, "DARK_NOUNS 2.0x");
        _bps(x.rounds, Addrs.CHIPLETS, 1_000, "CHIPLETS 0.1x  <- THE ONE THAT GETS MISSED");

        _p("rounds.setHoldbackBps(1500)", x.rounds, abi.encodeWithSignature("setHoldbackBps(uint32)", uint32(1500)));
        _p(
            "rounds.setDefaultMaxSlippageBps(200)",
            x.rounds,
            abi.encodeWithSignature("setDefaultMaxSlippageBps(uint32)", uint32(200))
        );
        _p("rounds.setMaxFeedAge(432000)", x.rounds, abi.encodeWithSignature("setMaxFeedAge(uint64)", uint64(432000)));
        _p("rounds.setChip", x.rounds, abi.encodeWithSignature("setChip(address)", x.chip));
        _p("rounds.setPolTreasury", x.rounds, abi.encodeWithSignature("setPolTreasury(address)", x.polTreasury));
        _p(
            "rounds.setRouters(uniV3, slipstreamB)  <- factory-B router or it reverts",
            x.rounds,
            abi.encodeWithSignature("setRouters(address,address)", Addrs.UNIV3_ROUTER, Addrs.SLIP_ROUTER_B)
        );

        console2.log("--- cross-wiring ---");
        _p("pot.setRewards(ChipRounds)", x.pot, abi.encodeWithSignature("setRewards(address)", x.rounds));
        _p("splitter.setPot(Pot)", x.splitter, abi.encodeWithSignature("setPot(address)", x.pot));
        _p(
            "polTreasury.setRewards(ChipClaims)  <- the LEDGER, not the engine",
            x.polTreasury,
            abi.encodeWithSignature("setRewards(address)", x.claims)
        );

        console2.log("--- Furnace: switch BOTH recipes off at launch ---");
        _p("furnace.setPaused(0, true)", x.furnace, abi.encodeWithSignature("setPaused(uint8,bool)", uint8(0), true));
        _p("furnace.setPaused(1, true)", x.furnace, abi.encodeWithSignature("setPaused(uint8,bool)", uint8(1), true));

        console2.log("################################################################");
        console2.log("### THE ONE THAT FAILS SILENTLY. DO NOT SIGN OFF WITHOUT IT. ###");
        console2.log("################################################################");
        _p(
            "activation.setCustodian(NOUN_LOANS, true)",
            x.activation,
            abi.encodeWithSignature("setCustodian(address,bool)", x.loans, true)
        );
        console2.log("VERIFY: isCustodian(NOUN_LOANS) == true, then the end-to-end read");
        console2.log("        (activate -> borrow -> isActive still TRUE, effectiveOwner == borrower)");
        console2.log("");
        console2.log("STILL TO DO BY HAND (they need amounts or token ids you choose):");
        console2.log("  loans.setMaxPrincipal(collection, amount)  x3");
        console2.log("  loans.depositPool(amount)                  after approve");
        console2.log("  furnace.depositStock(BASED_NOUNS, ids)     after setApprovalForAll");
        console2.log("  anvil.shelve(collection, ids)              after setApprovalForAll");
        console2.log("  anvil.queueQueuePrice(collection, wei)     x3, then 48h, then execute");
    }

    function _bps(address rounds, address collection, uint32 bps, string memory label) internal pure {
        _p(
            string.concat("rounds.setCollectionBaseBps - ", label),
            rounds,
            abi.encodeWithSignature("setCollectionBaseBps(address,uint32)", collection, bps)
        );
    }

    function _p(string memory label, address to, bytes memory data) internal pure {
        console2.log(label);
        console2.log("  to  :", to);
        console2.log("  data:", vm.toString(data));
        console2.log("");
    }
}
