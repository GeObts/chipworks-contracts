// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Raffle} from "../../src/raffle/Raffle.sol";
import {DeployRaffle} from "../../script/raffle/DeployRaffle.s.sol";

/// @notice The post-deploy Safe steps in specs/raffle/LAUNCH-CHECKLIST.md, on a Base fork,
///         against exactly what the deploy script produces (owner decisions 2026-10-09).
contract RaffleLaunchStepsTest is Test {
    address constant KEEPER = 0x6571E3412553Fada40C3D96e61E7Cfd20A0695B9;
    address constant NVDA = 0xb20000000000000000000078ee7ce2fE4908108C;

    function test_postDeploySafeSteps_keeperAnd125bpsGuard() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        DeployRaffle script = new DeployRaffle();
        Raffle raffle = script.deploy();
        address safe = script.SAFE();

        // Step: setKeeper(chipworks-keeper signer).
        vm.prank(safe);
        raffle.setKeeper(KEEPER);
        assertEq(raffle.keeper(), KEEPER);

        // Step: slippage floor 150 -> 125 bps, the other three values unchanged.
        vm.prank(safe);
        raffle.setPriceGuard(Raffle.PriceGuard({twapWindow: 1800, maxDeviationTicks: 100, maxSlippageBps: 125, maxPoolShareBps: 100}));
        (uint32 w, uint16 dev, uint16 slip, uint16 share) = raffle.priceGuard();
        assertEq(w, 1800);
        assertEq(dev, 100);
        assertEq(slip, 125);
        assertEq(share, 100);

        // Raffles created AFTER the step snapshot 125 bps.
        vm.deal(safe, 1 ether);
        uint256 reserve = raffle.requiredReserve();
        vm.prank(safe);
        uint256 id = raffle.createRaffle{value: reserve}(NVDA, 100);
        Raffle.RaffleData memory r = raffle.getRaffle(id);
        assertEq(r.guard.maxSlippageBps, 125, "new raffles take the 1.25% floor");
        assertEq(r.guard.twapWindow, 1800);
        assertEq(r.guard.maxDeviationTicks, 100);
        assertEq(r.guard.maxPoolShareBps, 100);

        // Only the Safe can make these calls.
        vm.expectRevert();
        raffle.setPriceGuard(Raffle.PriceGuard({twapWindow: 1800, maxDeviationTicks: 100, maxSlippageBps: 500, maxPoolShareBps: 500}));
        vm.expectRevert();
        raffle.setKeeper(address(this));
    }
}
