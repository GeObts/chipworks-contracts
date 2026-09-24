// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Box} from "../../src/box/Box.sol";
import {PrizeVault} from "../../src/box/PrizeVault.sol";
import {ChipConverter} from "../../src/box/ChipConverter.sol";
import {PoolKey} from "../../src/interfaces/IUniswapV4.sol";

/// @title DeployBox
/// @notice Deploys PrizeVault, ChipConverter and Box on Base mainnet. Wiring is the Safe's.
///
/// @dev UNAUDITED. Requires the owner's explicit written OK, recorded as the env flag
///      `BOX_MAINNET_WRITTEN_OK=true`, and a completed Bankr + Grok audit. Base (8453) only.
///
///      Env:
///        MULTISIG          owner of all three (required; the Safe)
///        BOX_TREASURY      fee recipient, default the FeeSplitter (80% Pot / 20% ops)
///        BOX_MAX_PRIZE_BPS default 2500 (25% of inventory)
///
///      After CREATE the Safe must, in one batch:
///        vault.setBox(box); converter.setBox(box);
///        vault.addStock(...) for each prize stock; vault.setKeeper;
///        vault.setRestockParams(...)
///        and seed the vault. Until the vault can cover a SKU's top prize, that SKU cannot sell.
contract DeployBox is Script {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant CHIP = 0x75Af968d2e58749FDA1b42C58186B76f5E511bA3;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant ENTROPY = 0x6E7D74FA7d5c90FEF9F0512987605a6d546181Bb;
    address internal constant FEE_SPLITTER = 0xb9b76e1835afE05e5A73065FE01A19B14869F8A3;
    address internal constant STOCK_REGISTRY = 0x5e4b6CbAc2D9b581428eE7f22E7bd4bf03675458;
    address internal constant UNISWAP_V3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address internal constant SLIPSTREAM_ROUTER_B = 0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F;
    address internal constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant CHIP_HOOK = 0xBDF938149ac6a781F94FAa0ed45E6A0e984c6544;
    uint24 internal constant WETH_USDC_FEE = 500;

    function run() external returns (address vault, address converter, address boxes) {
        require(block.chainid == 8453, "DeployBox: Base mainnet only");
        require(vm.envOr("BOX_MAINNET_WRITTEN_OK", false), "DeployBox: needs the owner's written OK");
        address multisig = vm.envAddress("MULTISIG");
        address treasury = vm.envOr("BOX_TREASURY", FEE_SPLITTER);
        uint32 maxPrizeBps = uint32(vm.envOr("BOX_MAX_PRIZE_BPS", uint256(2_500)));
        require(multisig != address(0) && treasury != address(0), "unset address");

        PoolKey memory key =
            PoolKey({currency0: WETH, currency1: CHIP, fee: 0x800000, tickSpacing: 200, hooks: CHIP_HOOK});

        vm.startBroadcast();
        PrizeVault v = new PrizeVault(
            multisig, USDC, CHIP, STOCK_REGISTRY, UNISWAP_V3_ROUTER, SLIPSTREAM_ROUTER_B, maxPrizeBps
        );
        ChipConverter c = new ChipConverter(
            multisig, CHIP, WETH, USDC, POOL_MANAGER, UNISWAP_V3_ROUTER, WETH_USDC_FEE, key
        );
        Box b = new Box(
            multisig,
            USDC,
            CHIP,
            treasury,
            address(v),
            address(c),
            ENTROPY
        );
        vm.stopBroadcast();

        console2.log("PrizeVault    ", address(v));
        console2.log("ChipConverter ", address(c));
        console2.log("Box           ", address(b));
        console2.log("fee recipient ", treasury);
        return (address(v), address(c), address(b));
    }
}
