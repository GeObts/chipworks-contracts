// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Box} from "../../src/box/Box.sol";
import {PrizeVault} from "../../src/box/PrizeVault.sol";
import {ChipConverter} from "../../src/box/ChipConverter.sol";
import {IBox} from "../../src/interfaces/IBox.sol";
import {IEntropyV2} from "../../src/interfaces/IEntropyV2.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {IStockRegistry} from "../../src/interfaces/IStockRegistry.sol";
import {PoolKey} from "../../src/interfaces/IUniswapV4.sol";
import {EtchableERC20} from "../mocks/EtchableERC20.sol";

interface IStateView {
    function getSlot0(bytes32 poolId) external view returns (uint160 sqrtPriceX96, int24 tick, uint24, uint24);
}

interface IFeeSplitterLike {
    function distributeToken(IERC20 token) external returns (uint256, uint256, uint256);
}

/// @title BoxForkTest
/// @notice THE REAL PROOF for the rebuilt Box, on a Base mainnet fork: the live StockRegistry
///         and its Chainlink marks, the factory-B Slipstream router, the live $CHIP/WETH
///         Uniswap v4 pool behind the Doppler hook, the WETH/USDC v3 pool, Chainlink ETH/USD,
///         Pyth Entropy v2 (the request is real; the reveal is delivered as Entropy), and the
///         live FeeSplitter -> Pot.
///
/// @dev The one substitution is NVDA's token code. B20 stocks are node-native precompiles
///      that cannot execute in a forked EVM (ASSUMPTIONS A-15/A-17), so NVDA is etched with a
///      runnable ERC-20 carrying the pool's REAL balance, read over raw RPC — the same
///      technique test/fork/FactoryBRouter.t.sol uses. Pool maths, router, registry marks
///      and every other token are untouched.
///
///      Run: forge test --match-contract BoxForkTest -vv  (needs BASE_RPC_URL)
contract BoxForkTest is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant CHIP = 0x75Af968d2e58749FDA1b42C58186B76f5E511bA3;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant ENTROPY = 0x6E7D74FA7d5c90FEF9F0512987605a6d546181Bb;
    address constant FEE_SPLITTER = 0xb9b76e1835afE05e5A73065FE01A19B14869F8A3;
    address constant POT = 0x3918a9B479Ce9B58238584c645079AB3bB49855B;
    address constant REGISTRY = 0x5e4b6CbAc2D9b581428eE7f22E7bd4bf03675458;
    address constant UNI_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant SLIP_ROUTER_B = 0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F;
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant CHIP_HOOK = 0xBDF938149ac6a781F94FAa0ed45E6A0e984c6544;
    address constant ETH_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant STATE_VIEW = 0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71;
    bytes32 constant CHIP_POOL_ID = 0xbcdd8383e38069f626846b94e93ee4d2c00cadfcce4b9457b0b8b04289030345;
    address constant NVDA = 0xb20000000000000000000078ee7ce2fE4908108C;
    address constant NVDA_POOL = 0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9;

    Box boxes;
    PrizeVault vault;
    ChipConverter converter;

    address multisig = makeAddr("safe");
    address keeper = makeAddr("keeper");
    address alice = makeAddr("box-fork-buyer-usdc");
    address bob = makeAddr("box-fork-buyer-chip");

    uint256 chipPerUsd; // 18-dp CHIP per $1 at the live mark

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));

        // NVDA: runnable ERC-20 over the precompile, carrying the pool's real balance.
        uint256 poolNvda = _rpcBalanceOf(NVDA, NVDA_POOL);
        vm.etch(NVDA, address(new EtchableERC20()).code);
        EtchableERC20(NVDA).init("NVIDIA Corporation", "NVDAc", 8);
        EtchableERC20(NVDA).mint(NVDA_POOL, poolNvda);

        chipPerUsd = _liveChipPerUsd();

        vault = new PrizeVault(multisig, USDC, CHIP, REGISTRY, UNI_ROUTER, SLIP_ROUTER_B, 2_500);
        converter = new ChipConverter(
            multisig,
            CHIP,
            WETH,
            USDC,
            POOL_MANAGER,
            UNI_ROUTER,
            ETH_FEED,
            500,
            PoolKey({currency0: WETH, currency1: CHIP, fee: 0x800000, tickSpacing: 200, hooks: CHIP_HOOK})
        );
        boxes = new Box(
            multisig,
            USDC,
            CHIP,
            FEE_SPLITTER,
            address(vault),
            address(converter),
            ENTROPY,
            uint128(chipPerUsd),
            uint128(10 * chipPerUsd),
            uint128(25 * chipPerUsd)
        );

        vm.startPrank(multisig);
        vault.setBox(address(boxes));
        converter.setBox(address(boxes));
        vault.addStock(NVDA);
        vault.setKeeper(keeper);
        converter.setKeeper(keeper);
        vault.setRestockParams(1_000e6, 5_000e6, 200, 3_000);
        converter.setLimits(type(uint128).max, type(uint128).max);
        vm.stopPrank();

        // Seed: $4,000 USDC covers the $25 box's $900 jackpot ($3,600 pool needed).
        deal(USDC, address(vault), 4_000e6);
        deal(USDC, alice, 100e6);
        deal(CHIP, bob, 100 * chipPerUsd);
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        vm.prank(alice);
        IERC20(USDC).approve(address(boxes), type(uint256).max);
        vm.prank(bob);
        IERC20(CHIP).approve(address(boxes), type(uint256).max);
    }

    function test_fullCycle_onRealPools() public {
        assertTrue(IStockRegistry(REGISTRY).getStock(NVDA).enabled, "NVDA enabled in the live registry");
        console2.log("CHIP per $1 (whole):", chipPerUsd / 1e18);
        console2.log("vault inventory $   :", vault.inventoryUsd() / 1e6);

        // ---- 1. Buy: $10 with USDC (alice), $10 with CHIP (bob) --------------------
        uint256 split0 = IERC20(USDC).balanceOf(FEE_SPLITTER);
        vm.prank(alice);
        uint256 idUsdc = boxes.buyWithUsdc(1, alice);
        vm.prank(bob);
        uint256 idChip = boxes.buyWithChip(1, bob);
        assertEq(IERC20(USDC).balanceOf(FEE_SPLITTER) - split0, 500_000, "5% of the USDC box to FeeSplitter");
        assertEq(IERC20(CHIP).balanceOf(address(converter)), 10 * chipPerUsd, "CHIP box whole to converter");
        assertEq(IERC20(CHIP).balanceOf(address(vault)), 0, "vault never holds CHIP");

        // ---- 1b. The keeper stocks the pool from its own USDC, through the real Slipstream pool.
        vm.prank(keeper);
        uint256 stocked = vault.restock(NVDA, 1_000e6);
        console2.log("restock $1,000 -> NVDA (8dp):", stocked);

        // ---- 2. Open through the real Pyth Entropy, deliver the reveal as Entropy ------
        uint64 seqUsdc = _open(alice, idUsdc);
        uint64 seqChip = _open(bob, idChip);
        address provider = IEntropyV2(ENTROPY).getDefaultProvider();
        // Read before the prank: vm.prank binds to the NEXT call, and oddsTable() is one.
        bytes32 rollUncommon = _rollForTier(2);
        bytes32 rollDust = _rollForTier(0);

        uint256 nvda0 = IERC20(NVDA).balanceOf(alice);
        uint256 g0 = gasleft();
        vm.prank(ENTROPY);
        boxes.entropyCallback(seqUsdc, provider, rollUncommon); // Uncommon: $10 in stock
        uint256 gasStock = g0 - gasleft();
        uint256 nvdaWon = IERC20(NVDA).balanceOf(alice) - nvda0;
        assertGt(nvdaWon, 0, "stock prize paid in NVDA");

        // A CHIP-bought box wins a stock like any other: prizes are never paid in $CHIP.
        uint256 bobNvda0 = IERC20(NVDA).balanceOf(bob);
        uint256 bobChip0 = IERC20(CHIP).balanceOf(bob);
        vm.prank(ENTROPY);
        boxes.entropyCallback(seqChip, provider, rollDust); // Dust: $2 in stock
        assertGt(IERC20(NVDA).balanceOf(bob) - bobNvda0, 0, "the CHIP buyer's Dust prize is NVDA");
        assertEq(IERC20(CHIP).balanceOf(bob), bobChip0, "and never CHIP");

        console2.log("callback gas, stock tier:", gasStock);
        assertLt(gasStock, boxes.callbackGasLimit(), "fits Pyth's callback gas limit");
        (uint256 nvdaPx,) = IStockRegistry(REGISTRY).priceUsd(NVDA);
        console2.log("NVDA won (8dp)         :", nvdaWon, " value USD e-6:", nvdaWon * nvdaPx / 1e20);

        _stepSell();
        _stepRestockAndSweep();
    }

    function _stepSell() internal {
        // ---- 3. Keeper sells the box CHIP through the real v4 + v3 pools ------------
        uint256 split0 = IERC20(USDC).balanceOf(FEE_SPLITTER);
        uint256 vaultUsdc0 = IERC20(USDC).balanceOf(address(vault));
        vm.prank(keeper);
        uint256 usdcOut = converter.sellChip(10 * chipPerUsd, 9e6, block.timestamp + 600);
        uint256 fee = IERC20(USDC).balanceOf(FEE_SPLITTER) - split0;
        console2.log("sold $10 of CHIP for USDC e-6:", usdcOut);
        assertEq(fee, usdcOut * 500 / 10_000, "5% of the proceeds to FeeSplitter");
        assertEq(IERC20(USDC).balanceOf(address(vault)) - vaultUsdc0, usdcOut - fee, "95% to the vault");
        assertEq(IERC20(CHIP).balanceOf(address(converter)), 0, "no CHIP left on the converter");
        assertEq(IERC20(USDC).balanceOf(address(converter)), 0, "and no USDC either");
    }

    function _stepRestockAndSweep() internal {
        // ---- 5. Keeper restocks NVDA from pool USDC through the real Slipstream pool ---
        uint256 vN0 = IERC20(NVDA).balanceOf(address(vault));
        vm.prank(keeper);
        uint256 bought = vault.restock(NVDA, 500e6);
        assertEq(IERC20(NVDA).balanceOf(address(vault)) - vN0, bought, "stock landed in the vault");
        console2.log("restock $500 -> NVDA (8dp):", bought);

        // ---- 6. House take: sweep to FeeSplitter, then FeeSplitter -> Pot ------------
        uint256 sweepable = vault.sweepableUsdc();
        console2.log("sweepable USDC e-6:", sweepable);
        assertGt(sweepable, 0, "a $4k pool with no open boxes has surplus above the floors");
        uint256 split0 = IERC20(USDC).balanceOf(FEE_SPLITTER);
        vault.sweepSurplus();
        assertEq(IERC20(USDC).balanceOf(FEE_SPLITTER) - split0, sweepable);

        uint256 pot0 = IERC20(USDC).balanceOf(POT);
        uint256 splitterUsdc = IERC20(USDC).balanceOf(FEE_SPLITTER);
        IFeeSplitterLike(FEE_SPLITTER).distributeToken(IERC20(USDC));
        uint256 toPot = IERC20(USDC).balanceOf(POT) - pot0;
        // The Pot takes the remainder after ops, so it can be 1 wei over a straight 80%.
        assertApproxEqAbs(toPot, splitterUsdc * 8_000 / 10_000, 1, "80% of the Box USDC reaches the Pot");
        console2.log("reached the Pot, USDC e-6:", toPot);

        // ---- 7. The pool still covers every SKU after the sweep --------------------
        assertTrue(boxes.isSkuCovered(2), "sweep never takes the pool below the $25 jackpot");
        assertEq(boxes.outstandingLiabilityUsd(), 0);
    }

    /* ------------------------------------------------------------------ */

    function _open(address who, uint256 id) internal returns (uint64) {
        uint128 fee = boxes.quoteOpenFee();
        vm.prank(who);
        boxes.open{value: fee}(id);
        return boxes.boxInfo(id).sequence;
    }

    function _rollForTier(uint8 tierId) internal view returns (bytes32) {
        IBox.PrizeTier[] memory tiers = boxes.oddsTable();
        uint256 acc;
        for (uint256 i; i < tierId; ++i) {
            acc += tiers[i].weight;
        }
        return bytes32(acc);
    }

    /// @dev CHIP per $1 from the live v4 slot0 and Chainlink ETH/USD. currency0 is WETH,
    ///      so (sqrtP / 2^96)^2 is CHIP per WETH (both 18 dp).
    function _liveChipPerUsd() internal view returns (uint256) {
        (uint160 sqrtP,,,) = IStateView(STATE_VIEW).getSlot0(CHIP_POOL_ID);
        uint256 chipPerWeth1e18 = Math.mulDiv(uint256(sqrtP) * uint256(sqrtP), 1e18, 1 << 192);
        (, int256 eth,,,) = IAggregatorV3(ETH_FEED).latestRoundData();
        return chipPerWeth1e18 * 1e8 / uint256(eth);
    }

    function _rpcBalanceOf(address token, address who) internal returns (uint256) {
        bytes memory data = abi.encodeWithSignature("balanceOf(address)", who);
        string memory params =
            string.concat('[{"to":"', vm.toString(token), '","data":"', vm.toString(data), '"},"latest"]');
        return abi.decode(vm.rpc("eth_call", params), (uint256));
    }
}
