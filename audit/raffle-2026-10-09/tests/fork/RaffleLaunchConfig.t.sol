// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Raffle} from "../../src/raffle/Raffle.sol";
import {DeployRaffle} from "../../script/raffle/DeployRaffle.s.sol";

/// @notice Pins the launch configuration the deploy script produces, on a Base fork.
contract RaffleLaunchConfigTest is Test {
    function test_launchConfig_24hRedraw_andChainChecks() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        DeployRaffle script = new DeployRaffle();
        script.checkChain(); // every immutable argument verified against the live chain
        Raffle raffle = script.deploy();

        assertEq(raffle.redrawTimeout(), 24 hours, "launch redraw timeout is 24 hours");
        assertEq(raffle.owner(), script.SAFE(), "the Safe is the house");
        assertEq(raffle.pot(), script.POT());
        assertEq(address(raffle.usdc()), script.USDC());
        assertEq(raffle.entropy(), script.ENTROPY());
        assertEq(address(raffle.registry()), script.REGISTRY());
        assertEq(raffle.feeBps(), 1_000);
        assertEq(raffle.minBase(), 10);
        assertEq(raffle.maxBase(), 1_000);
        assertFalse(raffle.nftPrizesEnabled(), "NFT prizes off at launch");

        // Still owner-adjustable within the hard bounds.
        vm.startPrank(script.SAFE());
        raffle.setRedrawTimeout(1 hours);
        vm.expectRevert(Raffle.BadConfig.selector);
        raffle.setRedrawTimeout(30 days + 1);
        vm.stopPrank();
    }
}
