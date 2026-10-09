// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Raffle} from "../../src/raffle/Raffle.sol";
import {DeployRaffle} from "../../script/raffle/DeployRaffle.s.sol";

/// @notice Pins the launch configuration the deploy script produces, on a Base fork.
contract RaffleLaunchConfigTest is Test {
    function test_launchConfig_v2_andChainChecks() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        DeployRaffle script = new DeployRaffle();
        script.checkChain(); // every immutable argument verified against the live chain
        Raffle raffle = script.deploy();

        assertEq(raffle.owner(), script.SAFE(), "the Safe is the house");
        assertEq(raffle.redrawTimeout(), 24 hours, "launch redraw timeout is 24 hours");
        assertEq(raffle.acquireTimeout(), 6 hours, "launch acquire timeout is 6 hours");
        assertEq(raffle.pot(), script.POT());
        assertEq(address(raffle.usdc()), script.USDC());
        assertEq(raffle.entropy(), script.ENTROPY());
        assertEq(address(raffle.registry()), script.REGISTRY());
        assertEq(address(raffle.router()), script.ROUTER());
        assertEq(raffle.factory(), 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef, "Slipstream factory B");
        assertEq(raffle.feeBps(), 1_000, "10% on top");
        assertEq(raffle.minBase(), 10);
        assertEq(raffle.maxBase(), 1_000);
        (uint32 w, uint16 dev, uint16 slip, uint16 share) = raffle.priceGuard();
        assertEq(w, 30 minutes);
        assertEq(dev, 100);
        assertEq(slip, 150);
        assertEq(share, 100);
        // acquirePrize / retryDraw are owner / keeper only. The deployer is not the owner, so
        // the keeper is set AFTER deploy by a Safe call (see DeployRaffle.s.sol) - unset here.
        assertEq(raffle.keeper(), address(0), "keeper is a post-deploy Safe call");

        // Still owner-adjustable within the hard bounds.
        vm.startPrank(script.SAFE());
        raffle.setRedrawTimeout(1 hours);
        vm.expectRevert(Raffle.BadConfig.selector);
        raffle.setRedrawTimeout(30 days + 1);
        raffle.setAcquireTimeout(1 hours);
        vm.expectRevert(Raffle.BadConfig.selector);
        raffle.setAcquireTimeout(7 days + 1);
        vm.stopPrank();
    }
}
