// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ChipActivationV2} from "../../src/activation/ChipActivationV2.sol";
import {ChipBurner} from "../../src/ChipBurner.sol";
import {MockNoun} from "../mocks/MockNoun.sol";

/// @title ChipActivationV2LiveForkTest
/// @notice Proves the burn-split against the REAL $CHIP token and the REAL deployed
///         ChipBurner on Base mainnet — not a mock.
///
/// @dev WHAT A MOCK CANNOT PROVE. The unit suite burns to `0xdead`, where "burned" only ever
///      means "unreachable" — `totalSupply` never moves. The whole point of the split is that
///      half of every mandatory fee genuinely LEAVES SUPPLY. That claim can only be settled
///      against the live pair, because it depends on $CHIP's own `burn` actually working when
///      the Burner calls it.
///
///      So this test asserts the thing the site will publish:
///        1. half the fee reaches the Burner,
///        2. `ChipBurner.burnAll()` then drops `$CHIP.totalSupply()` by exactly that half,
///        3. the other half arrives at the collector, untouched and spendable.
///
///      Run: forge test --match-path test/fork/ChipActivationV2Live.t.sol --fork-url $BASE_RPC_URL
contract ChipActivationV2LiveForkTest is Test {
    address internal constant CHIP = 0x75Af968d2e58749FDA1b42C58186B76f5E511bA3;
    address internal constant BURNER = 0x7Bc1C03e843C37845d89B54667382b4577Ead5C0;
    /// @dev The Chipworks Safe — the real CHIP whale we fund the actor from.
    address internal constant WHALE = 0xe1096B727499a3f70FaD8bc0267F5e69d01373C7;

    address internal multisig = makeAddr("multisig");
    address internal collector = makeAddr("collector"); // stands in for the Safe
    address internal alice = makeAddr("alice");

    ChipActivationV2 internal act;
    MockNoun internal based;

    uint32[5] internal TIERS = [uint32(10_000), 12_500, 16_000, 20_000, 33_300];
    uint256[5] internal LADDER =
        [uint256(1_000_000 ether), 2_200_000 ether, 4_500_000 ether, 9_000_000 ether, 24_000_000 ether];

    function setUp() public {
        // self-skip when no fork is configured, so CI stays green
        if (block.chainid != 8453) return;

        based = new MockNoun("Based Nouns", "BASED");
        act = new ChipActivationV2(multisig, CHIP, BURNER, TIERS, 5_000, collector);

        vm.prank(multisig);
        act.setInitialCosts(address(based), LADDER);

        // fund the actor from the real whale
        vm.prank(WHALE);
        IERC20(CHIP).transfer(alice, 5_000_000 ether);
        vm.prank(alice);
        IERC20(CHIP).approve(address(act), type(uint256).max);
    }

    function test_live_halfBurnsAndActuallyDropsSupply_halfLandsAtCollector() public {
        if (block.chainid != 8453) {
            console2.log("skipped: not forked on Base");
            return;
        }

        uint256 cost = LADDER[0];
        uint256 half = cost / 2;

        uint256 supply0 = IERC20(CHIP).totalSupply();
        uint256 burnerBal0 = IERC20(CHIP).balanceOf(BURNER);
        uint256 collector0 = IERC20(CHIP).balanceOf(collector);

        based.mint(alice, 1);
        vm.prank(alice);
        act.activate(address(based), 1, 0);

        // --- leg 1: half reached the Burner, half reached the collector ---
        assertEq(IERC20(CHIP).balanceOf(BURNER) - burnerBal0, half, "burn leg did not reach the Burner");
        assertEq(IERC20(CHIP).balanceOf(collector) - collector0, half, "collect leg did not reach the collector");
        assertEq(IERC20(CHIP).balanceOf(address(act)), 0, "activation contract took custody");

        // supply has NOT moved yet - the Burner holds, it does not auto-burn
        assertEq(IERC20(CHIP).totalSupply(), supply0, "supply moved before burnAll");

        // --- leg 2: burnAll actually destroys it ---
        uint256 burned = ChipBurner(payable(BURNER)).burnAll();
        uint256 supply1 = IERC20(CHIP).totalSupply();

        assertEq(supply0 - supply1, burnerBal0 + half, "totalSupply did not fall by the burned amount");
        assertGe(burned, half, "burnAll under-reported");
        assertEq(IERC20(CHIP).balanceOf(BURNER), 0, "Burner still holds CHIP after burnAll");

        // --- leg 3: the collected half is untouched and spendable ---
        assertEq(IERC20(CHIP).balanceOf(collector), collector0 + half, "collected half was disturbed");

        console2.log("cost paid (CHIP)      ", cost / 1e18);
        console2.log("burned, supply fell by", (supply0 - supply1) / 1e18);
        console2.log("collected to Safe     ", half / 1e18);
    }

    function test_live_countersMatchReality() public {
        if (block.chainid != 8453) return;
        based.mint(alice, 2);
        vm.prank(alice);
        act.activate(address(based), 2, 0);

        assertEq(act.totalChipBurned(), LADDER[0] / 2, "totalChipBurned must count only the destroyed half");
        assertEq(act.totalChipCollected(), LADDER[0] / 2, "totalChipCollected wrong");
    }

    function test_live_executeHatchCanMoveTheCollectedChip() public {
        if (block.chainid != 8453) return;
        // the hatch exists so this contract can never be trapped holding a role it cannot use.
        // Prove it can act: send it CHIP directly, then have the multisig sweep it out.
        vm.prank(WHALE);
        IERC20(CHIP).transfer(address(act), 1_000 ether);

        bytes memory data = abi.encodeWithSignature("transfer(address,uint256)", collector, uint256(1_000 ether));
        uint256 before = IERC20(CHIP).balanceOf(collector);

        vm.prank(multisig);
        act.execute(CHIP, 0, data);

        assertEq(IERC20(CHIP).balanceOf(collector) - before, 1_000 ether, "execute could not move CHIP");
        assertEq(IERC20(CHIP).balanceOf(address(act)), 0, "stray CHIP stranded");
    }
}
