// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ChipActivationV2} from "../../src/activation/ChipActivationV2.sol";
import {ChipBurner} from "../../src/ChipBurner.sol";

interface INoun {
    function ownerOf(uint256) external view returns (address);
}

/// @notice Settles one question against the LIVE, ALREADY-CONFIGURED deployment:
///         when someone chips a Noun, does $CHIP `totalSupply` ACTUALLY FALL?
///
/// @dev No setup, no mocks, no fixtures. It chips a real Noun through the deployed
///      ChipActivationV2 at its mainnet address and watches the real token's supply.
///      If the burn were parked at 0xdead, `totalSupply` would not move and this fails.
contract V2LiveSupplyDropForkTest is Test {
    address constant V2 = 0x762984092Cb9404982835551970C73b5838d5411;
    address constant SAFE = 0xe1096B727499a3f70FaD8bc0267F5e69d01373C7;
    address constant CHIP = 0x75Af968d2e58749FDA1b42C58186B76f5E511bA3;
    address constant BURNER = 0x7Bc1C03e843C37845d89B54667382b4577Ead5C0;
    address constant BASED = 0xBf57D0535E10E7033447174404b9bEd3D9eF4C88;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    ChipActivationV2 act = ChipActivationV2(payable(V2));

    function test_live_chippingActuallyReducesTotalSupply() public {
        if (block.chainid != 8453) { console2.log("skipped: not forked"); return; }

        // the deployed contract points at the Burner, not the dead address
        assertEq(act.chipBurnTarget(), BURNER, "burn target is not the ChipBurner");
        assertTrue(act.chipBurnTarget() != DEAD, "burn target is the dead address");
        assertEq(act.burnBps(), 5000, "not a 50/50 split");

        address holder = INoun(BASED).ownerOf(1);
        vm.prank(SAFE);
        IERC20(CHIP).transfer(holder, 2_000_000 ether);
        vm.prank(holder);
        IERC20(CHIP).approve(V2, type(uint256).max);

        uint256 supply0 = IERC20(CHIP).totalSupply();
        uint256 dead0 = IERC20(CHIP).balanceOf(DEAD);
        uint256 safe0 = IERC20(CHIP).balanceOf(SAFE);
        uint256 burner0 = IERC20(CHIP).balanceOf(BURNER);

        vm.prank(holder);
        act.activate(BASED, 1, 0); // 1,000,000 CHIP, tier 1

        uint256 half = 500_000 ether;

        // half routed to the Burner, half to the Safe, NOTHING to the dead address
        assertEq(IERC20(CHIP).balanceOf(BURNER) - burner0, half, "burn leg did not reach the Burner");
        assertEq(IERC20(CHIP).balanceOf(SAFE) - safe0, half, "collect leg did not reach the Safe");
        assertEq(IERC20(CHIP).balanceOf(DEAD), dead0, "CHIP was parked at 0xdEaD");

        // supply has not moved YET - the Burner holds until swept
        assertEq(IERC20(CHIP).totalSupply(), supply0, "supply moved before burnAll");

        // the sweep is what destroys it
        ChipBurner(payable(BURNER)).burnAll();
        uint256 supply1 = IERC20(CHIP).totalSupply();

        assertEq(supply0 - supply1, burner0 + half, "TOTAL SUPPLY DID NOT FALL");
        assertLt(supply1, supply0, "supply did not decrease");
        assertEq(IERC20(CHIP).balanceOf(DEAD), dead0, "dead-address balance changed");

        console2.log("chipped Based #1 for 1,000,000 CHIP through the LIVE V2");
        console2.log("  totalSupply before :", supply0 / 1e18);
        console2.log("  totalSupply after  :", supply1 / 1e18);
        console2.log("  SUPPLY FELL BY     :", (supply0 - supply1) / 1e18);
        console2.log("  collected to Safe  :", half / 1e18);
        console2.log("  parked at 0xdEaD   :", (IERC20(CHIP).balanceOf(DEAD) - dead0) / 1e18);
    }
}
