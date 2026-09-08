// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

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
import {Venue} from "../../src/interfaces/IStockRegistry.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

import {MockNoun} from "../mocks/MockNoun.sol";
import {DopplerLikeChip} from "../ChipBurner.t.sol";

/// @title DeployRehearsalTest
/// @notice THE FULL LAUNCH_CONFIG SEQUENCE, END TO END, ON A BASE MAINNET FORK.
///
/// @dev WHY THIS EXISTS. Every other suite proves a contract. Nothing proved the ORDER:
///      twelve deploys, four 48-hour timelocks, the $CHIP ownership hand-off, and one wire
///      that fails silently. This walks LAUNCH_CONFIG section 6 as written, in the order
///      written, running the verification read after each step, so a broken deploy costs a
///      test run rather than real gas.
///
///      WHAT IS REAL. USDC, WETH, AERO, the Uniswap v3 factory and router, both Aerodrome CL
///      factories and both their routers, the Chainlink feeds, the Aerodrome Voter and NPM,
///      the sequencer uptime feed, the thirteen B20 tokens with their real feeds and their
///      real factory-B pools, and the real CHIPLETS collection.
///
///      WHAT IS SUBSTITUTED, AND WHY.
///        - $CHIP does not exist yet. DopplerLikeChip stands in: an ERC-20 whose burn and
///          admin calls are owner-gated, which is the shape the hand-off depends on.
///        - Based Nouns and DarkNOUNs have no addresses yet, so they are MockNoun.
///        - THE FURNACE FORGE PATH CANNOT BE EXERCISED AT ALL. CHIPLETS is real and its
///          burn selector is asserted here against live bytecode, but totalSupply() is 0 --
///          the drop has not minted -- so there is no fuel and no way to make any. The
///          Furnace is deployed, stocked and paused exactly as it will be; the first real
///          forge is the one thing this rehearsal CANNOT cover.
///        - The thirteen B20 stocks register but cannot be ENABLED on a fork: they are
///          precompiles a forked EVM cannot execute, so measured depth reads zero and the
///          gate correctly refuses. WETH stands in as the tradeable stock for the round leg.
contract DeployRehearsalTest is Test {
    /* ------------------------- real Base mainnet ------------------------- */
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address internal constant UNIV3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address internal constant UNIV3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address internal constant SLIP_FACTORY_A = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
    address internal constant SLIP_FACTORY_B = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef;
    address internal constant SLIP_ROUTER_A = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;
    address internal constant SLIP_ROUTER_B = 0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F;
    address internal constant SLIP_NPM = 0x827922686190790b37229fd06084350E74485b72;
    address internal constant AERO_VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;
    address internal constant SEQUENCER_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    address internal constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant AERO_USD_FEED = 0x4EC5970fC728C5f65ba413992CD5fF6FD70fcfF0;
    address internal constant CHIPLETS = 0xC7c114191aa3b2225F9bb053Bc55b3d6F145Bd33;
    address internal constant LIL_NOUNS = 0xe3c5Ef27B80481518a2363406e354a9361415556;
    address internal constant WETH_USDC_UNI_500 = 0xd0b53D9277642d899DF5C87A3966A349A798F224;

    int24 internal constant B20_TICK_SPACING = 10;
    uint128 internal constant LAUNCH_MIN_USD = 25_000e18;

    /// @dev LAUNCH_CONFIG section 4 at the worked base unit. On the day this is recomputed
    ///      from the observed price; the SHAPE is what is rehearsed here.
    uint256 internal constant BASE_UNIT = 50_000e18;
    uint256 internal constant SPLIT_FEE = 5_000e18;

    /// @dev LAUNCH_CONFIG section 4 item 6: Chiplets activate at a FLAT 10% of the base unit,
    ///      which is 5,000 $CHIP at a 50,000 base. Five EQUAL entries -- `_validateFlatCosts`
    ///      refuses a ladder on a flat collection. Recomputed from the observed price on the
    ///      day, exactly like every other row in the table.
    uint256 internal constant CHIPLET_FLAT_COST = BASE_UNIT / 10;

    /* ------------------------------ ours --------------------------------- */
    ChipBurner internal burner;
    FeeSplitter internal splitter;
    StockRegistry internal registry;
    Pot internal pot;
    ChipActivation internal activation;
    ChipClaims internal claims;
    ChipRounds internal rounds;
    POLTreasury internal polTreasury;
    ClaimRouter internal claimRouter;
    Furnace internal furnace;
    NounLoans internal loans;
    Anvil internal anvil;

    DopplerLikeChip internal chip;
    MockNoun internal basedNouns;
    MockNoun internal darkNouns;

    address internal multisig = makeAddr("MULTISIG");
    address internal ops = makeAddr("OPS_WALLET");
    address internal loanTreasury = makeAddr("LOAN_TREASURY");
    address internal keeper = makeAddr("KEEPER");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    /* --------------------------- the gas ledger -------------------------- */
    string[] internal stepName;
    uint256[] internal stepGas;

    function _g(string memory n, uint256 g) internal {
        stepName.push(n);
        stepGas.push(g);
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
    }

    /* ------------------------------ helpers ------------------------------ */

    function _ids(uint256 a) internal pure returns (uint256[] memory o) {
        o = new uint256[](1);
        o[0] = a;
    }

    function _costs(uint256 unit) internal pure returns (uint256[5] memory c) {
        c[0] = unit;
        c[1] = (unit * 220) / 100;
        c[2] = (unit * 450) / 100;
        c[3] = (unit * 900) / 100;
        c[4] = (unit * 2400) / 100;
    }

    function _flat(uint256 unit) internal pure returns (uint256[5] memory c) {
        c[0] = unit;
        c[1] = unit;
        c[2] = unit;
        c[3] = unit;
        c[4] = unit;
    }

    /// @dev Re-stamp a live Chainlink feed as having just published.
    ///
    ///      THIS IS A FORK ARTIFACT, NOT A PROTOCOL CONCESSION. The sequence contains two
    ///      real 48-hour timelocks, so the rehearsal warps 96 hours forward. A forked feed's
    ///      `updatedAt` stays pinned at the fork block, so after the warp every feed looks
    ///      four days stale and `maxFeedAge` correctly refuses everything. On mainnet the
    ///      feed keeps publishing across those two days. This models that, and nothing else:
    ///      the ANSWER is passed through untouched, only the timestamp moves.
    function _refreshFeed(address feed) internal {
        (uint80 rid, int256 ans,,, uint80 air) = IAggregatorV3(feed).latestRoundData();
        vm.mockCall(
            feed,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(rid, ans, block.timestamp, block.timestamp, air)
        );
    }

    function _slipPool(address factory, address token, int24 ts) internal view returns (address p) {
        (bool ok, bytes memory ret) =
            factory.staticcall(abi.encodeWithSignature("getPool(address,address,int24)", token, USDC, ts));
        if (ok && ret.length >= 32) p = abi.decode(ret, (address));
    }

    /// @dev The thirteen B20 tokens and their live Chainlink feeds. Ten resolve a factory-B
    ///      pool; COIN, CRCL and INTC resolve none and register as Venue.None.
    function _b20() internal pure returns (address[13] memory t, address[13] memory f) {
        t[0] = 0xb20000000000000000000078ee7ce2fE4908108C;
        f[0] = 0x04689a41629776563E6822F76f2e57D148d28513; // NVDA
        t[1] = 0xb2000000000000000000002D0BA3164cc74f58B7;
        f[1] = 0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2; // GOOGL
        t[2] = 0xb200000000000000000000C2e324d24d7eEcd1fb;
        f[2] = 0x787f13dEa48Db0897CbCDD985de77809D837F988; // AAPL
        t[3] = 0xb2000000000000000000008bC8786B856E61707C;
        f[3] = 0x6526aE6797A76123638b863AeE4dD27Ba4E4b27D; // META
        t[4] = 0xb2000000000000000000001e800a7f5189430cD0;
        f[4] = 0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4; // TSLA
        t[5] = 0xb200000000000000000000d9192b6B456483C2E8;
        f[5] = 0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295; // AMZN
        t[6] = 0xB200000000000000000000Ab99cFa739E253872B;
        f[6] = 0xeB10A6c9aa7E537aEd766C08c35Dae35B321b18c; // MSFT
        t[7] = 0xb2000000000000000000004884b426556b92883d;
        f[7] = 0xB3cE282CD188b35DA0E38D8Bc7d58e33173D202a; // MSTR
        t[8] = 0xb200000000000000000000397293Cb8cda9a10c5;
        f[8] = 0x388b0dC46C0Fb05A74BeE0994fa5b02c6Fcca2eA; // SNDK
        t[9] = 0xb2000000000000000000007b9fcbd005511aCBd5;
        f[9] = 0x6A634B235903C4ad6376892180d6fF8612e3Fa68; // SPCX
        t[10] = 0xb200000000000000000000c85a31389D71F3ecfb;
        f[10] = 0x408e44f504A7371a345F03a73dDC96A4b48e8aa7; // COIN
        t[11] = 0xB20000000000000000000019f6E7C675b73C2e4D;
        f[11] = 0x0231cF2635D1E17bB5c2462cc7504Ba1fBd61f33; // CRCL
        t[12] = 0xB2000000000000000000004AFF16039bA04bdFBc;
        f[12] = 0xAB657C39bac0D5886250D70849e2E3E008F2EECB; // INTC
    }

    /* ==================================================================== */
    /*                           THE REHEARSAL                              */
    /* ==================================================================== */

    function test_theWholeDeploySequence() public {
        _phaseA_beforeChip();
        _phaseB_chipAndTheBurner();
        _phaseC_activationAndTimelocks();
        _phaseD_theRoundsStack();
        _phaseE_peripheryAndTheSilentWire();
        _phaseF_aRealRound();
        _report();
    }

    /* ---------------- section 6: before $CHIP, day 0 --------------------- */

    function _phaseA_beforeChip() internal {
        uint256 gs;

        // --- step 1. FeeSplitter, multisig as the placeholder pot ---
        gs = gasleft();
        splitter = new FeeSplitter(multisig, multisig, ops, 2_000, 2_000);
        _g("1  deploy FeeSplitter", gs - gasleft());

        assertEq(splitter.owner(), multisig, "1: owner");
        assertEq(splitter.opsBps(), 2_000, "1: opsBps");
        assertEq(splitter.potBps(), 8_000, "1: potBps");

        vm.deal(address(splitter), 0.001 ether);
        uint256 opsBefore = ops.balance;
        uint256 placeholderBefore = multisig.balance;
        vm.prank(keeper);
        splitter.distributeETH();
        assertEq(ops.balance - opsBefore, 0.0002 ether, "1: 20% to ops");
        assertEq(multisig.balance - placeholderBefore, 0.0008 ether, "1: 80% to the placeholder pot");

        // --- step 2. StockRegistry, on FACTORY B ---
        gs = gasleft();
        registry = new StockRegistry(multisig, USDC, UNIV3_FACTORY, SLIP_FACTORY_B);
        _g("2  deploy StockRegistry", gs - gasleft());

        assertEq(registry.slipstreamFactory(), SLIP_FACTORY_B, "2: the immutable that cannot be corrected later");

        (address[13] memory tok, address[13] memory feed) = _b20();
        uint256 gAdd;
        uint256 withPool;
        for (uint256 i; i < 13; ++i) {
            address pool = _slipPool(SLIP_FACTORY_B, tok[i], B20_TICK_SPACING);
            if (pool != address(0)) ++withPool;
            gs = gasleft();
            vm.prank(multisig);
            registry.addStock(
                StockRegistry.AddStockParams({
                    token: tok[i],
                    feed: feed[i],
                    venue: pool == address(0) ? Venue.None : Venue.Slipstream,
                    pool: pool,
                    fee: 0,
                    tickSpacing: pool == address(0) ? int24(0) : B20_TICK_SPACING,
                    minLiquidityUsd: LAUNCH_MIN_USD,
                    tokenDecimals: 8
                })
            );
            gAdd += gs - gasleft();
        }
        _g("2  addStock x13 (all disabled)", gAdd);

        assertEq(registry.stockCount(), 13, "2: thirteen registered");
        assertEq(registry.enabledTokens().length, 0, "2: none enabled");
        assertEq(withPool, 10, "2: ten resolve a factory-B pool");
        assertEq(uint8(registry.getStock(tok[0]).venue), uint8(Venue.Slipstream), "2: NVDA venue");
        assertEq(registry.getStock(tok[0]).tickSpacing, B20_TICK_SPACING, "2: NVDA tick spacing 10");

        // CRCL has a feed but no pool anywhere: it cannot be enabled by mistake.
        vm.prank(multisig);
        vm.expectRevert();
        registry.setEnabled(tok[11], true);

        // --- step 3. Pot ---
        gs = gasleft();
        pot = new Pot(multisig, USDC, UNIV3_FACTORY);
        _g("3  deploy Pot", gs - gasleft());

        vm.expectRevert(); // nobody can pull a budget yet: rewards is unset
        pot.pullBudget(1);

        vm.startPrank(multisig);
        gs = gasleft();
        pot.setConversionConfig(WETH, ETH_USD_FEED, UNIV3_ROUTER, 500, 100, 5 ether, 0, 1 hours);
        _g("3  pot.setConversionConfig", gs - gasleft());

        gs = gasleft();
        pot.setRoute(AERO, AERO_USD_FEED, UNIV3_ROUTER, 500, 300, 50_000 ether, 0, 24 hours);
        _g("3  pot.setRoute(AERO)", gs - gasleft());

        gs = gasleft();
        pot.setSequencerFeed(SEQUENCER_FEED, 1 hours);
        _g("3  pot.setSequencerFeed", gs - gasleft());
        vm.stopPrank();

        assertEq(pot.sequencerUptimeFeed(), SEQUENCER_FEED, "3: sequencer feed");

        // SEC-POT-006: an EOA cannot be the rewards target.
        // NOTE: the address must be proved codeless FIRST. `makeAddr("alice")` resolves to
        // 0x3288...dac6, which carries 23 bytes of code on live Base -- so the obvious
        // spelling of this check passes for the wrong reason on a fork.
        address eoa = address(uint160(uint256(keccak256("chipworks.rehearsal.eoa"))));
        assertEq(eoa.code.length, 0, "fixture: the EOA must genuinely have no code on Base");
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSignature("NotAContract(address)", eoa));
        pot.setRewards(eoa);

        // --- step 6. POLTreasury (day-0 deployable; it holds nothing yet) ---
        gs = gasleft();
        polTreasury = new POLTreasury(multisig, USDC, SLIP_NPM, address(splitter), UNIV3_FACTORY, AERO_VOTER);
        _g("6  deploy POLTreasury", gs - gasleft());

        assertEq(polTreasury.positionFactory(), SLIP_FACTORY_A, "6: POL is on Aerodrome factory A, not B");
        assertTrue(polTreasury.isProtected(USDC), "6: USDC protected");
        assertTrue(polTreasury.isProtected(SLIP_NPM), "6: position manager protected");

        vm.startPrank(multisig);
        polTreasury.setWeth(WETH);
        gs = gasleft();
        polTreasury.setPolAsset(WETH, ETH_USD_FEED, 500, 1 hours);
        _g("6  polTreasury.setPolAsset(WETH)", gs - gasleft());
        polTreasury.setManager(keeper);
        vm.stopPrank();

        assertTrue(polTreasury.isPolAsset(WETH), "6: WETH is a POL asset");
    }

    /* ------------- section 6.6: $CHIP, the Burner, the hand-off ---------- */

    function _phaseB_chipAndTheBurner() internal {
        uint256 gs;

        // $CHIP launches on Bankr. Ownership lands with the deployer.
        chip = new DopplerLikeChip(1_000_000_000e18);
        basedNouns = new MockNoun("Based Nouns", "BASED");
        darkNouns = new MockNoun("DarkNOUNs", "DARK");

        // --- step 0. ChipBurner, deployed BEFORE the three immutables need it ---
        gs = gasleft();
        burner = new ChipBurner(multisig, address(chip));
        _g("0  deploy ChipBurner", gs - gasleft());

        assertEq(burner.owner(), multisig, "0: admin owner");
        assertEq(address(burner.chipToken()), address(chip), "0: immutable token");

        // Until the hand-off lands, burnAll reverts: the token's burn is owner-gated.
        chip.transfer(address(burner), 1e18);
        vm.expectRevert();
        burner.burnAll();

        // --- THE STEP. section 6.6 ---
        gs = gasleft();
        chip.transferOwnership(address(burner));
        _g("6.6 chip.transferOwnership(ChipBurner)", gs - gasleft());

        assertEq(chip.owner(), address(burner), "6.6: THE verification read");

        // and prove it end to end, once, with a small amount
        uint256 supplyBefore = chip.totalSupply();
        gs = gasleft();
        uint256 burned = burner.burnAll();
        _g("6.6 burner.burnAll() (proof burn)", gs - gasleft());

        assertEq(burned, 1e18, "6.6: burned the whole balance");
        assertEq(chip.totalSupply(), supplyBefore - 1e18, "6.6: totalSupply ACTUALLY fell");
        assertEq(burner.totalBurned(), 1e18, "6.6: totalBurned");
        assertEq(burner.burnCount(), 1, "6.6: burnCount");

        // --- section 6.5 check one, against LIVE Chiplets bytecode ---
        assertGt(CHIPLETS.code.length, 0, "6.5: Chiplets has code on Base");
        (bool ok, bytes memory ret) = CHIPLETS.staticcall(abi.encodeWithSignature("totalSupply()"));
        assertTrue(ok, "6.5: Chiplets totalSupply readable");
        console2.log("CHIPLETS totalSupply at fork block:", abi.decode(ret, (uint256)));
    }

    /* --------- section 6 step 4: ChipActivation and the 48h timelock ------ */

    function _phaseC_activationAndTimelocks() internal {
        uint256 gs;

        gs = gasleft();
        activation = new ChipActivation(
            multisig, address(chip), address(burner), [uint32(10_000), 12_500, 16_000, 20_000, 33_300]
        );
        _g("4  deploy ChipActivation", gs - gasleft());

        assertEq(activation.chipBurnTarget(), address(burner), "4: immutable burn target is the Burner");

        // An unpriced collection cannot be activated, by anyone, at any tier.
        vm.expectRevert();
        activation.activate(address(basedNouns), 1, 0);

        vm.startPrank(multisig);

        // ORDERING TRAP: flat-rate must be set BEFORE the collection's first executeCosts.
        gs = gasleft();
        activation.setFlatRateCollection(CHIPLETS);
        _g("4  setFlatRateCollection(CHIPLETS)", gs - gasleft());
        assertTrue(activation.isFlatRate(CHIPLETS), "4: Chiplets is flat-rate");

        // All FOUR earning collections: the three tiered families plus flat-rate Chiplets.
        gs = gasleft();
        activation.queueCosts(LIL_NOUNS, _costs(BASE_UNIT));
        activation.queueCosts(address(basedNouns), _costs(BASE_UNIT));
        activation.queueCosts(address(darkNouns), _costs(BASE_UNIT));
        activation.queueCosts(CHIPLETS, _flat(CHIPLET_FLAT_COST));
        _g("4  queueCosts x4", gs - gasleft());
        vm.stopPrank();

        assertFalse(activation.isSupportedCollection(address(basedNouns)), "4: not configured before execute");

        // --- the 48-hour wait ---
        vm.warp(block.timestamp + 48 hours);

        vm.startPrank(multisig);
        gs = gasleft();
        activation.executeCosts(LIL_NOUNS);
        activation.executeCosts(address(basedNouns));
        activation.executeCosts(address(darkNouns));
        activation.executeCosts(CHIPLETS);
        _g("4  executeCosts x4", gs - gasleft());
        vm.stopPrank();

        assertTrue(activation.isSupportedCollection(address(basedNouns)), "4: configured after execute");
        assertEq(activation.costOf(address(basedNouns), 0), BASE_UNIT, "4: tier 0 cost");
        assertEq(activation.costOf(address(basedNouns), 4), (BASE_UNIT * 2400) / 100, "4: tier 4 cost");

        // flat-rate refuses a ladder
        vm.prank(multisig);
        vm.expectRevert();
        activation.queueCosts(CHIPLETS, _costs(BASE_UNIT));

        // and it is one-way: a live collection cannot be flipped to flat
        vm.prank(multisig);
        vm.expectRevert();
        activation.setFlatRateCollection(address(basedNouns));
    }

    /* ------------- section 6 steps 5a/5b: the rounds stack ---------------- */

    function _phaseD_theRoundsStack() internal {
        uint256 gs;

        gs = gasleft();
        claims = new ChipClaims(multisig, address(registry));
        _g("5a deploy ChipClaims", gs - gasleft());

        gs = gasleft();
        rounds = new ChipRounds(
            multisig, address(registry), address(pot), address(activation), address(claims), SPLIT_FEE, address(burner)
        );
        _g("5b deploy ChipRounds", gs - gasleft());

        assertEq(rounds.chipBurnTarget(), address(burner), "5b: immutable burn target");

        // BEFORE claims.setRounds: a round cannot book a single weight.
        vm.expectRevert();
        rounds.contributeWeights(1, address(basedNouns), _ids(1));

        vm.startPrank(multisig);

        gs = gasleft();
        claims.setRounds(address(rounds));
        _g("5a claims.setRounds", gs - gasleft());
        claims.setClaimSchedule(604800, 172800);
        claims.setCreditExpiry(2592000);
        claims.setPolTreasury(address(polTreasury));

        gs = gasleft();
        pot.setRewards(address(rounds));
        _g("3  pot.setRewards(ChipRounds)", gs - gasleft());

        gs = gasleft();
        splitter.setPot(address(pot));
        _g("1  splitter.setPot(Pot)", gs - gasleft());

        // NOTE: setRoundParams takes THREE arguments. maxBudget was removed at the
        // depth-aware impact trim; LAUNCH_CONFIG still documents a four-argument form.
        gs = gasleft();
        rounds.setRoundParams(86400, 7200, 100e6);
        _g("5b setRoundParams(duration,window,minPot)", gs - gasleft());

        gs = gasleft();
        rounds.setCollectionBaseBps(LIL_NOUNS, 5_000);
        rounds.setCollectionBaseBps(address(basedNouns), 10_000);
        rounds.setCollectionBaseBps(address(darkNouns), 20_000);
        rounds.setCollectionBaseBps(CHIPLETS, 1_000);
        _g("5b setCollectionBaseBps x4", gs - gasleft());

        rounds.setHoldbackBps(1_500);
        rounds.setDefaultMaxSlippageBps(200);
        rounds.setMaxFeedAge(432000);
        rounds.setChip(address(chip));
        rounds.setPolTreasury(address(polTreasury));

        gs = gasleft();
        rounds.setRouters(UNIV3_ROUTER, SLIP_ROUTER_B);
        _g("5b setRouters (uni + slipstream B)", gs - gasleft());

        polTreasury.setRewards(address(claims));
        vm.stopPrank();

        // 🔴 ALL FOUR COLLECTIONS MUST HAVE A NON-ZERO baseBps. A collection left at the
        //    default of 0 earns nothing, for ever, with no revert and no event -- the same
        //    silent shape as the custodian wire. CHIPLETS is the one that gets forgotten.
        _assertEveryCollectionEarns();

        assertEq(address(rounds.slipstreamRouter()), SLIP_ROUTER_B, "5b: the factory-B router");
        assertEq(claims.rounds(), address(rounds), "5b: wiring check claims.rounds");
        assertEq(address(rounds.claims()), address(claims), "5b: wiring check rounds.claims");
        assertEq(pot.rewards(), address(rounds), "5b: wiring check pot.rewards");

        // The wrong Slipstream router is now refused AT SET TIME.
        vm.prank(multisig);
        vm.expectRevert();
        rounds.setRouters(UNIV3_ROUTER, SLIP_ROUTER_A);
    }

    /// @notice Every earning collection has a non-zero, exact multiplier.
    /// @dev THIS IS THE FAILS-LOUD REPLACEMENT FOR A CHECK THE CONTRACT CANNOT MAKE.
    ///      `collectionBaseBps` is a plain mapping with no "config complete" gate, so nothing
    ///      on chain can refuse a deploy that forgot one. Adding such a gate would be a
    ///      contract change, and `launch-candidate-22` is the reviewed package -- so the
    ///      assertion lives here and in the checklist's verification reads instead.
    function _assertEveryCollectionEarns() internal view {
        address[4] memory cols = [LIL_NOUNS, address(basedNouns), address(darkNouns), CHIPLETS];
        uint32[4] memory want = [uint32(5_000), 10_000, 20_000, 1_000];
        string[4] memory names = ["LIL_NOUNS", "BASED_NOUNS", "DARK_NOUNS", "CHIPLETS"];

        for (uint256 i; i < 4; ++i) {
            uint32 got = rounds.collectionBaseBps(cols[i]);
            assertTrue(got != 0, string.concat("baseBps IS ZERO -- this collection earns nothing: ", names[i]));
            assertEq(got, want[i], string.concat("baseBps wrong for ", names[i]));
        }
    }

    /* --- steps 7-10 plus the one wire with no safety net ------------------ */

    function _phaseE_peripheryAndTheSilentWire() internal {
        uint256 gs;

        // --- step 7. ClaimRouter, pointed at the LEDGER not the engine ---
        gs = gasleft();
        claimRouter = new ClaimRouter(multisig, address(claims), 1_000_000);
        _g("7  deploy ClaimRouter", gs - gasleft());
        assertEq(address(claimRouter.rewards()), address(claims), "7: points at ChipClaims, not ChipRounds");

        // --- step 8. Furnace. Fuel is the REAL Chiplets collection. ---
        Furnace.Recipe memory based = Furnace.Recipe({
            exists: true, paused: false, outputCollection: address(basedNouns), fuelCost: 25, chipCost: BASE_UNIT / 2
        });
        Furnace.Recipe memory dark = Furnace.Recipe({
            exists: true,
            paused: false,
            outputCollection: address(darkNouns),
            fuelCost: 50,
            chipCost: (BASE_UNIT * 12) / 10
        });

        gs = gasleft();
        furnace = new Furnace(multisig, address(chip), address(burner), CHIPLETS, based, dark);
        _g("8  deploy Furnace", gs - gasleft());

        assertEq(address(furnace.fuelCollection()), CHIPLETS, "8: fuel is the real Chiplets");
        assertEq(furnace.recipe(0).fuelCost, 25, "8: Based recipe 25 Chiplets");
        assertEq(furnace.recipe(1).fuelCost, 50, "8: Dark recipe 50 Chiplets");

        // stock the Based recipe, then switch BOTH off (placeholder prices)
        basedNouns.mint(multisig, 101);
        vm.startPrank(multisig);
        basedNouns.setApprovalForAll(address(furnace), true);
        gs = gasleft();
        furnace.depositStock(address(basedNouns), _ids(101));
        _g("8  furnace.depositStock (one)", gs - gasleft());

        gs = gasleft();
        furnace.setPaused(0, true);
        furnace.setPaused(1, true);
        _g("8  furnace.setPaused x2 (both off)", gs - gasleft());
        vm.stopPrank();

        assertEq(furnace.stockRemaining(0), 1, "8: one Based Noun in stock");
        vm.expectRevert();
        furnace.forge(0, new uint256[](25));

        // --- step 9. NounLoans ---
        NounLoans.Terms memory terms = NounLoans.Terms({
            length: [uint64(7 days), 14 days, 30 days, 90 days, 180 days],
            feeBps: [uint32(50), 100, 200, 500, 900],
            bountyBps: 200,
            lateFeeBps: 100
        });

        gs = gasleft();
        loans = new NounLoans(multisig, address(chip), address(splitter), loanTreasury, address(activation), terms);
        _g("9  deploy NounLoans", gs - gasleft());

        // borrow refuses before a cap and before a pool
        vm.expectRevert();
        loans.borrow(address(basedNouns), 1, 0, 100e18);

        vm.startPrank(multisig);
        gs = gasleft();
        loans.setMaxPrincipal(LIL_NOUNS, 50_000e18);
        loans.setMaxPrincipal(address(basedNouns), 100_000e18);
        loans.setMaxPrincipal(address(darkNouns), 200_000e18);
        _g("9  setMaxPrincipal x3", gs - gasleft());
        vm.stopPrank();

        // seed the pool from the initial buy
        chip.transfer(multisig, 5_000_000e18);
        vm.startPrank(multisig);
        chip.approve(address(loans), type(uint256).max);
        gs = gasleft();
        loans.depositPool(5_000_000e18);
        _g("9  depositPool (seed)", gs - gasleft());
        vm.stopPrank();

        assertEq(loans.poolBalance(), chip.balanceOf(address(loans)), "9: pool balance matches");

        // --- 🔴 section 7. THE ONE THAT FAILS SILENTLY ---
        vm.prank(multisig);
        gs = gasleft();
        activation.setCustodian(address(loans), true);
        _g("7! setCustodian(NounLoans) THE SILENT WIRE", gs - gasleft());

        assertTrue(activation.isCustodian(address(loans)), "SECTION 7: isCustodian MUST be true");

        // --- step 10. Anvil ---
        gs = gasleft();
        anvil = new Anvil(multisig, address(splitter), 2_500);
        _g("10 deploy Anvil", gs - gasleft());

        assertFalse(anvil.sellEnabled(), "10: sell side is off and has no setter");

        basedNouns.mint(multisig, 201);
        vm.startPrank(multisig);
        basedNouns.setApprovalForAll(address(anvil), true);
        gs = gasleft();
        anvil.shelve(address(basedNouns), _ids(201));
        _g("10 anvil.shelve (one)", gs - gasleft());

        gs = gasleft();
        anvil.queueQueuePrice(address(basedNouns), 0.25 ether);
        _g("10 queueQueuePrice", gs - gasleft());
        vm.stopPrank();

        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        gs = gasleft();
        anvil.executeQueuePrice(address(basedNouns));
        _g("10 executeQueuePrice", gs - gasleft());

        (uint256 qp,) = anvil.prices(address(basedNouns));
        assertEq(qp, 0.25 ether, "10: queue price landed");
        (bool avail, uint256 head) = anvil.nextOnShelf(address(basedNouns));
        assertTrue(avail, "10: the shelf has a head");
        assertEq(head, 201, "10: the head is readable before anyone buys");
    }

    /* ---- the end-to-end reads, and a real round on real infrastructure --- */

    function _phaseF_aRealRound() internal {
        uint256 gs;

        // 96 hours of timelock have passed. On mainnet the feeds kept publishing.
        _refreshFeed(ETH_USD_FEED);
        _refreshFeed(AERO_USD_FEED);

        // --- a real round. WETH stands in for a B20 stock. ---
        vm.startPrank(multisig);
        registry.addStock(
            StockRegistry.AddStockParams({
                token: WETH,
                feed: ETH_USD_FEED,
                venue: Venue.UniswapV3,
                pool: WETH_USDC_UNI_500,
                fee: 500,
                tickSpacing: 0,
                minLiquidityUsd: 50_000e18,
                tokenDecimals: 18
            })
        );
        registry.setEnabled(WETH, true);
        vm.stopPrank();

        assertEq(registry.enabledTokens().length, 1, "round: one tradeable stock");

        // --- SECTION 7's end-to-end read: activate, borrow, still earning ---
        basedNouns.mint(alice, 1);
        chip.transfer(alice, 10_000_000e18);

        vm.startPrank(alice);
        chip.approve(address(activation), type(uint256).max);
        gs = gasleft();
        activation.activate(address(basedNouns), 1, 0);
        _g("--  a holder activates at tier 0", gs - gasleft());

        basedNouns.setApprovalForAll(address(loans), true);
        loans.borrow(address(basedNouns), 1, 0, 50_000e18);
        vm.stopPrank();

        // The holder picks what her slice buys. Without a split it routes to the quote
        // token, and `settleStock(WETH)` would then correctly revert NoWeight.
        {
            address[] memory picks = new address[](1);
            picks[0] = WETH;
            uint8[] memory pcts = new uint8[](1);
            pcts[0] = 100;
            vm.startPrank(alice);
            chip.approve(address(rounds), type(uint256).max);
            rounds.setSplit(address(basedNouns), 1, picks, pcts);
            vm.stopPrank();
        }

        assertTrue(activation.isActive(address(basedNouns), 1), "SECTION 7: STILL ACTIVE while collateralised");
        assertEq(activation.effectiveOwner(address(basedNouns), 1), alice, "SECTION 7: effectiveOwner is the BORROWER");

        // fund the pot the way launch day will: fees in, converted
        vm.deal(address(splitter), 3 ether);
        vm.prank(keeper);
        splitter.distributeETH();
        vm.prank(keeper);
        (, uint256 usdcOut) = pot.convert();
        assertGt(usdcOut, 0, "round: pot converted to USDC");

        vm.prank(keeper);
        gs = gasleft();
        uint256 roundId = rounds.openRound();
        _g("op openRound", gs - gasleft());

        gs = gasleft();
        rounds.contributeWeights(roundId, address(basedNouns), _ids(1));
        _g("op contributeWeights (one id)", gs - gasleft());

        assertGt(rounds.getRound(roundId).totalWeight, 0, "round: weight booked for a COLLATERALISED Noun");

        vm.warp(block.timestamp + 2 hours);
        gs = gasleft();
        rounds.closeAccumulation(roundId);
        _g("op closeAccumulation", gs - gasleft());

        gs = gasleft();
        rounds.settleStock(roundId, WETH);
        _g("op settleStock (real swap)", gs - gasleft());

        gs = gasleft();
        rounds.finalizeRound(roundId);
        _g("op finalizeRound", gs - gasleft());

        assertFalse(rounds.stockSkipped(roundId, WETH), "round: the real swap executed");
        assertGt(claims.acquired(roundId, WETH), 0, "round: WETH credited to holders");
        console2.log("round bought WETH (wei):", claims.acquired(roundId, WETH));
    }

    /* ------------------------------ the ledger --------------------------- */

    function _report() internal view {
        uint256 total;
        console2.log("");
        console2.log("=========== DEPLOY REHEARSAL GAS LEDGER ===========");
        for (uint256 i; i < stepName.length; ++i) {
            console2.log(stepName[i], stepGas[i]);
            total += stepGas[i];
        }
        console2.log("---------------------------------------------------");
        console2.log("TOTAL execution gas (excl. per-tx intrinsic):", total);
        console2.log("transactions counted:", stepName.length);
        console2.log("===================================================");
    }
}
