// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Box} from "../../src/box/Box.sol";
import {PrizeVault} from "../../src/box/PrizeVault.sol";
import {ChipConverter} from "../../src/box/ChipConverter.sol";
import {IBox} from "../../src/interfaces/IBox.sol";
import {Venue} from "../../src/interfaces/IStockRegistry.sol";
import {PoolKey} from "../../src/interfaces/IUniswapV4.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockEntropyV2} from "../mocks/MockEntropyV2.sol";
import {MockStockRegistry} from "../mocks/MockStockRegistry.sol";
import {MockSwapRouter} from "../mocks/MockSwapRouter.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";

/// @notice The whole Box system on mocks. Prices are round numbers so every expected
///         amount in a test can be worked out by hand:
///           NVDA $100 (8 dp, Slipstream)   TSLA $200 (8 dp, Uniswap v3)
///           ETH  $2,000                    CHIP $0.00005 (20,000 CHIP = $1)
contract BoxTestBase is Test {
    Box internal boxes;
    PrizeVault internal vault;
    ChipConverter internal converter;
    MockEntropyV2 internal entropy;
    MockStockRegistry internal registry;
    MockSwapRouter internal router; // plays both the Slipstream and the Uniswap v3 stock routers
    MockSwapRouter internal v3; // the WETH/USDC leg of the converter
    MockPoolManager internal pm; // the $CHIP/WETH v4 pool
    MockAggregatorV3 internal ethFeed;

    MockERC20 internal usdc;
    MockERC20 internal chip;
    MockERC20 internal weth;
    MockERC20 internal nvda;
    MockERC20 internal tsla;

    address internal multisig = makeAddr("multisig");
    address internal keeper = makeAddr("keeper");
    /// @dev Stands in for the FeeSplitter: the Box's fee recipient.
    address internal treasury = makeAddr("feeSplitter");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint8 internal constant SKU1 = 0;
    uint8 internal constant SKU10 = 1;
    uint8 internal constant SKU25 = 2;

    uint256 internal constant USD1 = 1_000_000;
    uint256 internal constant USD10 = 10_000_000;
    uint256 internal constant USD25 = 25_000_000;

    uint128 internal constant CHIP_PER_USD = 20_000 ether;
    uint128 internal constant CHIP1 = CHIP_PER_USD;
    uint128 internal constant CHIP10 = 10 * CHIP_PER_USD;
    uint128 internal constant CHIP25 = 25 * CHIP_PER_USD;

    uint256 internal constant NVDA_PRICE = 100e18;
    uint256 internal constant TSLA_PRICE = 200e18;

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        chip = new MockERC20("Chipworks", "CHIP", 18);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        nvda = new MockERC20("NVIDIA", "NVDAc", 8);
        tsla = new MockERC20("Tesla", "TSLAc", 8);

        registry = new MockStockRegistry(address(usdc));
        registry.setStock(address(nvda), Venue.Slipstream, 0, 10, 8, true);
        registry.setStock(address(tsla), Venue.UniswapV3, 3000, 0, 8, true);
        registry.setPrice(address(nvda), NVDA_PRICE);
        registry.setPrice(address(tsla), TSLA_PRICE);

        router = new MockSwapRouter();
        router.setRate(address(usdc), address(nvda), 1, 1); // $1 (1e6) -> 0.01 NVDA (1e6)
        router.setRate(address(usdc), address(tsla), 1, 2); // $1 -> 0.005 TSLA
        nvda.mint(address(router), 1_000_000e8);
        tsla.mint(address(router), 1_000_000e8);

        v3 = new MockSwapRouter();
        v3.setRate(address(weth), address(usdc), 2_000e6, 1e18);
        v3.setRate(address(usdc), address(weth), 1e18, 2_000e6);
        usdc.mint(address(v3), 10_000_000e6);
        weth.mint(address(v3), 10_000 ether);
        ethFeed = new MockAggregatorV3(8, 2_000e8, "ETH / USD");

        pm = new MockPoolManager();
        // 1 CHIP = $0.00005 = 2.5e-8 ETH
        pm.setRate(address(chip), address(weth), 25, 1e9);
        pm.setRate(address(weth), address(chip), 1e9, 25);
        weth.mint(address(pm), 10_000 ether);
        chip.mint(address(pm), 1e33);

        entropy = new MockEntropyV2();
        vault = new PrizeVault(multisig, address(usdc), address(chip), address(registry), address(router), address(router), 2_500);
        converter = new ChipConverter(
            multisig, address(chip), address(weth), address(usdc), address(pm), address(v3), 500, _key()
        );
        boxes = _newBox(address(vault), address(chip), address(converter));

        vm.startPrank(multisig);
        vault.setBox(address(boxes));
        converter.setBox(address(boxes));
        vault.addStock(address(nvda));
        vault.addStock(address(tsla));
        vault.setKeeper(keeper);
        vault.setRestockParams(5_000e6, 20_000e6, 200, 5_000);
        vm.stopPrank();

        _fundVault();
        _fundBuyer(alice);
        _fundBuyer(bob);
    }

    function _key() internal view returns (PoolKey memory) {
        (address c0, address c1) = address(chip) < address(weth) ? (address(chip), address(weth)) : (address(weth), address(chip));
        return PoolKey({currency0: c0, currency1: c1, fee: 0x800000, tickSpacing: 200, hooks: address(0)});
    }

    function _newBox(address vault_, address chip_, address converter_) internal returns (Box) {
        return new Box(
            multisig, address(usdc), chip_, treasury, vault_, converter_, address(entropy)
        );
    }

    /// @dev $10,000 USDC + 100 NVDA ($10,000) + 50 TSLA ($10,000) = $30,000 inventory,
    ///      so the 25% cap is $7,500 and every SKU's top prize ($900 at most) is covered.
    function _fundVault() internal {
        usdc.mint(address(vault), 10_000e6);
        nvda.mint(address(this), 100e8);
        tsla.mint(address(this), 50e8);
        nvda.approve(address(vault), type(uint256).max);
        tsla.approve(address(vault), type(uint256).max);
        vault.deposit(address(nvda), 100e8);
        vault.deposit(address(tsla), 50e8);
    }

    function _fundBuyer(address who) internal {
        usdc.mint(who, 1_000e6);
        chip.mint(who, 100 * uint256(CHIP_PER_USD) * 100);
        vm.deal(who, 10 ether);
        vm.startPrank(who);
        usdc.approve(address(boxes), type(uint256).max);
        chip.approve(address(boxes), type(uint256).max);
        vm.stopPrank();
    }

    function _buy1(address who) internal returns (uint256 id) {
        vm.prank(who);
        id = boxes.buyWithUsdc(SKU1, who);
    }

    function _open(address who, uint256 id) internal returns (uint64 seq) {
        uint128 fee = boxes.quoteOpenFee();
        vm.prank(who);
        boxes.open{value: fee}(id);
        seq = boxes.boxInfo(id).sequence;
    }

    function _openAndFulfill(address who, uint256 id, bytes32 rand) internal {
        uint64 seq = _open(who, id);
        entropy.fulfill(seq, rand);
    }

    /// @dev A random number that lands exactly on the first roll of `tierId`.
    function _rollForTier(uint8 tierId) internal view returns (bytes32) {
        IBox.PrizeTier[] memory tiers = boxes.oddsTable();
        uint256 acc;
        for (uint256 i; i < tierId; ++i) {
            acc += tiers[i].weight;
        }
        return bytes32(acc);
    }

    /// @dev A second, UNWIRED vault on the same mocks, plus (for a CHIP box) a second converter.
    function _freshVaultAndConverter(address chip_) internal returns (PrizeVault v, ChipConverter c) {
        v = new PrizeVault(multisig, address(usdc), chip_, address(registry), address(router), address(router), 2_500);
        if (chip_ != address(0)) {
            c = new ChipConverter(
                multisig, address(chip), address(weth), address(usdc), address(pm), address(v3), 500, _key()
            );
        }
    }

    /// @dev A second fully wired Box/vault/converter (CHIP enabled), vault seeded with `seedUsdc`,
    ///      alice and bob approved. No stocks listed.
    function _newWiredPair(uint256 seedUsdc) internal returns (Box b, PrizeVault v, ChipConverter c) {
        (v, c) = _freshVaultAndConverter(address(chip));
        b = _newBox(address(v), address(chip), address(c));
        vm.startPrank(multisig);
        v.setBox(address(b));
        c.setBox(address(b));
        vm.stopPrank();
        if (seedUsdc != 0) usdc.mint(address(v), seedUsdc);
        address[2] memory who = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(who[i]);
            usdc.approve(address(b), type(uint256).max);
            chip.approve(address(b), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// @dev What a $CHIP buy of `usdcOut` costs at the mock pools' CURRENT rates, rounded up the
    ///      way the mocks charge: the WETH the USDC leg needs, and the $CHIP that buys that WETH.
    function _chipQuote(uint256 usdcOut) internal view returns (uint256 wethNeeded, uint256 chipCost) {
        uint256 n1 = v3.rateNum(address(weth), address(usdc));
        uint256 d1 = v3.rateDen(address(weth), address(usdc));
        wethNeeded = (usdcOut * d1 + n1 - 1) / n1;
        uint256 n0 = pm.rateNum(address(chip), address(weth));
        uint256 d0 = pm.rateDen(address(chip), address(weth));
        chipCost = (wethNeeded * d0 + n0 - 1) / n0;
    }

    /// @dev Buy one box of `skuId` with $CHIP on `b`, allowing 1% over the quoted cost.
    function _buyChipOn(Box b, address who, uint8 skuId) internal returns (uint256 id) {
        (uint256 wethNeeded, uint256 chipCost) = _chipQuote(b.sku(skuId).usdcPrice);
        vm.prank(who);
        id = b.buyWithChip(skuId, who, wethNeeded, chipCost * 101 / 100, block.timestamp + 600);
    }

    function _buyChip(address who, uint8 skuId) internal returns (uint256 id) {
        id = _buyChipOn(boxes, who, skuId);
    }

    function _skuUsd(uint8 skuId) internal pure returns (uint256) {
        if (skuId == SKU1) return USD1;
        if (skuId == SKU10) return USD10;
        if (skuId == SKU25) return USD25;
        revert("unknown sku");
    }

    function _skuChip(uint8 skuId) internal pure returns (uint128) {
        if (skuId == SKU1) return CHIP1;
        if (skuId == SKU10) return CHIP10;
        if (skuId == SKU25) return CHIP25;
        revert("unknown sku");
    }
}
