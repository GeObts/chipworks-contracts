// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Box} from "../../src/box/Box.sol";

/// @title BoxSepoliaCycle
/// @notice Buy one box with mock USDC and one with mock CHIP, then open both. Pyth
///         Entropy delivers the callback later, in its own transaction; read the result
///         from `BoxOpened` / `PrizePaid`, or from the boxes being burned.
/// @dev Base Sepolia only. Env: BOX (address), BOX_SKU (default 1 = $10).
contract BoxSepoliaCycle is Script {
    function run() external {
        require(block.chainid == 84_532, "BoxSepoliaCycle: Base Sepolia (84532) only");
        Box box = Box(vm.envAddress("BOX"));
        uint8 skuId = uint8(vm.envOr("BOX_SKU", uint256(1)));
        IERC20 usdc = IERC20(box.usdc());
        IERC20 chip = IERC20(box.chip());

        vm.startBroadcast();
        usdc.approve(address(box), box.sku(skuId).usdcPrice);
        chip.approve(address(box), box.sku(skuId).chipPrice);
        uint256 idUsdc = box.buyWithUsdc(skuId, msg.sender);
        uint256 idChip = box.buyWithChip(skuId, msg.sender);
        uint128 fee = box.quoteOpenFee();
        box.open{value: fee}(idUsdc);
        box.open{value: fee}(idChip);
        vm.stopBroadcast();

        console2.log("usdc box id  ", idUsdc, " sequence", box.boxInfo(idUsdc).sequence);
        console2.log("chip box id  ", idChip, " sequence", box.boxInfo(idChip).sequence);
        console2.log("entropy fee each (wei)", fee);
    }
}
