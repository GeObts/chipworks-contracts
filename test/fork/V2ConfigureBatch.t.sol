// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ChipActivationV2} from "../../src/activation/ChipActivationV2.sol";
import {ChipBurner} from "../../src/ChipBurner.sol";

interface IPointer {
    function setActivationSource(address v) external;
    function activationSource() external view returns (address);
}

interface INoun {
    function ownerOf(uint256) external view returns (address);
}

/// @notice Dry-runs the EXACT 8-call Safe batch against a Base fork, in order, as the Safe,
///         then chips a real Noun through the result.
///
/// @dev This is the last check before signing. It executes the same calls the JSON contains,
///      against the REAL deployed V2, the REAL ChipRounds and NounLoans, and the REAL $CHIP —
///      so a wrong argument, a bad ordering, or a missing prerequisite fails HERE rather than
///      in a signed multisig transaction.
contract V2ConfigureBatchForkTest is Test {
    address constant V2 = 0x762984092Cb9404982835551970C73b5838d5411;
    address constant SAFE = 0xe1096B727499a3f70FaD8bc0267F5e69d01373C7;
    address constant ROUNDS = 0xa8192D4Ee3526CA8158cBE83b2FC05BdC205bed3;
    address constant LOANS = 0x123Bc476594A80B0d99Ca6510e87E249b1C5EC5f;
    address constant CHIP = 0x75Af968d2e58749FDA1b42C58186B76f5E511bA3;
    address constant BURNER = 0x7Bc1C03e843C37845d89B54667382b4577Ead5C0;

    address constant BASED = 0xBf57D0535E10E7033447174404b9bEd3D9eF4C88;
    address constant DARK = 0xd45E54B1A5e77d6E9469a4174d34f27D5D16270C;
    address constant LIL = 0xe3c5Ef27B80481518a2363406e354a9361415556;
    address constant CHIPLETS = 0xC7c114191aa3b2225F9bb053Bc55b3d6F145Bd33;

    ChipActivationV2 act = ChipActivationV2(payable(V2));

    uint256[5] LADDER = [
        uint256(1_000_000 ether), 2_200_000 ether, 4_500_000 ether, 9_000_000 ether, 24_000_000 ether
    ];
    uint256[5] FLAT = [uint256(390_000 ether), 390_000 ether, 390_000 ether, 390_000 ether, 390_000 ether];

    function _runBatch() internal {
        vm.startPrank(SAFE);
        act.setCustodian(LOANS, true);              // 1
        act.setFlatRateCollection(CHIPLETS);        // 2
        act.setInitialCosts(BASED, LADDER);         // 3
        act.setInitialCosts(DARK, LADDER);          // 4
        act.setInitialCosts(LIL, LADDER);           // 5
        act.setInitialCosts(CHIPLETS, FLAT);        // 6
        IPointer(ROUNDS).setActivationSource(V2);   // 7
        IPointer(LOANS).setActivationSource(V2);    // 8
        vm.stopPrank();
    }

    function test_theBatchExecutesInOrderAndConfiguresEverything() public {
        if (block.chainid != 8453) { console2.log("skipped: not forked"); return; }

        _runBatch();

        assertTrue(act.isCustodian(LOANS), "custodian not set");
        assertTrue(act.isFlatRate(CHIPLETS), "chiplets not flat-rate");

        assertTrue(act.collectionConfigured(BASED), "Based not configured");
        assertTrue(act.collectionConfigured(DARK), "Dark not configured");
        assertTrue(act.collectionConfigured(LIL), "Lil not configured");
        assertTrue(act.collectionConfigured(CHIPLETS), "Chiplets not configured");

        assertEq(act.costOf(BASED, 0), 1_000_000 ether, "Based tier1 != 1M");
        assertEq(act.costOf(BASED, 4), 24_000_000 ether, "Based tier5 != 24M");
        assertEq(act.costOf(CHIPLETS, 0), 390_000 ether, "Chiplets flat != 390k");

        assertEq(IPointer(ROUNDS).activationSource(), V2, "ChipRounds not re-pointed");
        assertEq(IPointer(LOANS).activationSource(), V2, "NounLoans not re-pointed");

        console2.log("all 8 calls executed, every assertion passed");
    }

    function test_afterTheBatch_aRealNounChipsWithA5050Split() public {
        if (block.chainid != 8453) return;
        _runBatch();

        // borrow a real Based Noun holder and fund them with real CHIP from the Safe
        address holder = INoun(BASED).ownerOf(1);
        vm.prank(SAFE);
        IERC20(CHIP).transfer(holder, 2_000_000 ether);
        vm.prank(holder);
        IERC20(CHIP).approve(V2, type(uint256).max);

        uint256 burnerBefore = IERC20(CHIP).balanceOf(BURNER);
        uint256 safeBefore = IERC20(CHIP).balanceOf(SAFE);
        uint256 supplyBefore = IERC20(CHIP).totalSupply();

        vm.prank(holder);
        act.activate(BASED, 1, 0);

        uint256 half = 500_000 ether;
        assertEq(IERC20(CHIP).balanceOf(BURNER) - burnerBefore, half, "burn leg wrong");
        assertEq(IERC20(CHIP).balanceOf(SAFE) - safeBefore, half, "collect leg wrong");
        assertEq(act.totalChipBurned(), half, "totalChipBurned wrong");
        assertEq(act.totalChipCollected(), half, "totalChipCollected wrong");
        assertEq(IERC20(CHIP).balanceOf(V2), 0, "V2 took custody");

        // and the burned half really leaves supply once swept
        ChipBurner(payable(BURNER)).burnAll();
        assertEq(supplyBefore - IERC20(CHIP).totalSupply(), burnerBefore + half, "supply did not fall");

        console2.log("chipped Based #1 for 1,000,000 CHIP");
        console2.log("  burned  (supply fell)", half / 1e18);
        console2.log("  collected to Safe    ", half / 1e18);
    }

    function test_afterTheBatch_pricesStillNeed48hToChange() public {
        if (block.chainid != 8453) return;
        _runBatch();

        uint256[5] memory cheaper = [uint256(1 ether), 2 ether, 3 ether, 4 ether, 5 ether];

        // the bootstrap door is shut
        vm.prank(SAFE);
        vm.expectRevert(abi.encodeWithSelector(ChipActivationV2.AlreadyInitialized.selector, BASED));
        act.setInitialCosts(BASED, cheaper);

        // and the only remaining path is the 48h one
        vm.prank(SAFE);
        act.queueCosts(BASED, cheaper);
        vm.prank(SAFE);
        vm.expectRevert();
        act.executeCosts(BASED);

        vm.warp(block.timestamp + 48 hours);
        vm.prank(SAFE);
        act.executeCosts(BASED);
        assertEq(act.costOf(BASED, 0), 1 ether, "timelocked change failed");
    }
}
