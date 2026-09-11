// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChipActivationV2} from "../../src/activation/ChipActivationV2.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockNoun} from "../mocks/MockNoun.sol";

/// @notice Tests ONLY the V2 diff against the audited ChipActivation:
///         burn-split, feeCollector, setInitialCosts (zero-notice bootstrap),
///         the 48h path still governing every later change, and execute().
///
/// @dev The 922-line ChipActivation.t.sol suite is the regression net for everything
///      unchanged. This file deliberately does not re-test activation mechanics except
///      where the diff touches them (i.e. wherever _burnChip is called).
contract ChipActivationV2DiffTest is Test {
    address internal multisig = makeAddr("multisig");
    address internal collector = makeAddr("collector"); // stands in for the Safe
    address internal alice = makeAddr("alice");
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    ChipActivationV2 internal act;
    MockERC20 internal chip;
    MockNoun internal based;
    MockNoun internal chiplets;

    uint32[5] internal TIERS = [uint32(10_000), 12_500, 16_000, 20_000, 33_300];
    // the real launch ladder, in whole CHIP
    uint256[5] internal LADDER =
        [uint256(1_000_000 ether), 2_200_000 ether, 4_500_000 ether, 9_000_000 ether, 24_000_000 ether];
    uint256[5] internal FLAT =
        [uint256(390_000 ether), 390_000 ether, 390_000 ether, 390_000 ether, 390_000 ether];

    function setUp() public {
        vm.warp(1_700_000_000);
        chip = new MockERC20("Chipworks", "CHIP", 18);
        based = new MockNoun("Based Nouns", "BASED");
        chiplets = new MockNoun("Chiplets", "CHIPP");

        // 50/50 split, burn target is the dead address in unit tests
        act = new ChipActivationV2(multisig, address(chip), DEAD, TIERS, 5_000, collector);

        chip.mint(alice, 500_000_000 ether);
        vm.prank(alice);
        chip.approve(address(act), type(uint256).max);
    }

    function _bootstrap() internal {
        vm.prank(multisig);
        act.setInitialCosts(address(based), LADDER);
    }

    function _activate(uint256 tokenId, uint8 tier) internal {
        based.mint(alice, tokenId);
        vm.prank(alice);
        act.activate(address(based), tokenId, tier);
    }

    /* ---------------------------- 1. BURN SPLIT ---------------------------- */

    function test_burnSplit_sendsHalfToBurnTargetAndHalfToCollector() public {
        _bootstrap();
        uint256 cost = LADDER[0]; // 1,000,000 CHIP

        uint256 deadBefore = chip.balanceOf(DEAD);
        uint256 colBefore = chip.balanceOf(collector);
        uint256 aliceBefore = chip.balanceOf(alice);

        _activate(1, 0);

        assertEq(chip.balanceOf(DEAD) - deadBefore, cost / 2, "burn leg != 50%");
        assertEq(chip.balanceOf(collector) - colBefore, cost / 2, "collect leg != 50%");
        assertEq(aliceBefore - chip.balanceOf(alice), cost, "user paid != full cost");
    }

    function test_burnSplit_countersAreSeparate() public {
        _bootstrap();
        _activate(1, 0);
        assertEq(act.totalChipBurned(), LADDER[0] / 2, "totalChipBurned must count ONLY the burned half");
        assertEq(act.totalChipCollected(), LADDER[0] / 2, "totalChipCollected wrong");
    }

    function test_burnSplit_contractNeverHoldsChip() public {
        _bootstrap();
        _activate(1, 0);
        assertEq(chip.balanceOf(address(act)), 0, "contract took custody");
    }

    function test_burnSplit_dustFavoursTheBurn() public {
        // odd cost -> the extra wei must go to the BURN, never the collector
        uint256[5] memory odd = [uint256(1_000_001), 2_000_001, 3_000_001, 4_000_001, 5_000_001];
        vm.prank(multisig);
        act.setInitialCosts(address(based), odd);

        uint256 d0 = chip.balanceOf(DEAD);
        uint256 c0 = chip.balanceOf(collector);
        _activate(1, 0);
        uint256 burned = chip.balanceOf(DEAD) - d0;
        uint256 collected = chip.balanceOf(collector) - c0;

        assertEq(burned + collected, 1_000_001, "split lost value");
        assertEq(burned, 500_001, "dust did not favour the burn");
        assertEq(collected, 500_000, "collector got the dust");
    }

    function test_burnSplit_100pctBurn_behavesLikeV1() public {
        vm.prank(multisig);
        act.setBurnSplit(10_000, collector);
        _bootstrap();

        uint256 c0 = chip.balanceOf(collector);
        uint256 d0 = chip.balanceOf(DEAD);
        _activate(1, 0);
        assertEq(chip.balanceOf(collector), c0, "collector got paid at 100% burn");
        assertEq(chip.balanceOf(DEAD) - d0, LADDER[0], "full amount not burned");
        assertEq(act.totalChipCollected(), 0);
    }

    function test_burnSplit_zeroBurn_allCollected() public {
        vm.prank(multisig);
        act.setBurnSplit(0, collector);
        _bootstrap();
        uint256 d0 = chip.balanceOf(DEAD);
        _activate(1, 0);
        assertEq(chip.balanceOf(DEAD), d0, "something burned at 0 bps");
        assertEq(act.totalChipBurned(), 0);
        assertEq(act.totalChipCollected(), LADDER[0]);
    }

    function test_burnSplit_rejectsOver100AndZeroCollector() public {
        vm.prank(multisig);
        vm.expectRevert(ChipActivationV2.BadSplit.selector);
        act.setBurnSplit(10_001, collector);

        vm.prank(multisig);
        vm.expectRevert(); // ZeroAddress
        act.setBurnSplit(5_000, address(0));

        // 100% burn with no collector is legitimate: nothing is collected
        vm.prank(multisig);
        act.setBurnSplit(10_000, address(0));
        assertEq(act.burnBps(), 10_000);
    }

    function test_burnSplit_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        act.setBurnSplit(0, alice);
    }

    /* ------------------- 2. TIER UPGRADES USE THE SPLIT ------------------- */

    function test_upgradePath_alsoSplits() public {
        _bootstrap();
        _activate(1, 0);
        uint256 d0 = chip.balanceOf(DEAD);
        uint256 c0 = chip.balanceOf(collector);

        vm.prank(alice);
        act.upgrade(address(based), 1, 1);

        uint256 delta = LADDER[1] - LADDER[0];
        assertEq(chip.balanceOf(DEAD) - d0, delta / 2, "upgrade burn leg wrong");
        assertEq(chip.balanceOf(collector) - c0, delta / 2, "upgrade collect leg wrong");
    }

    /* --------------- 3. BOOTSTRAP vs 48h TIMELOCK BEHAVIOUR --------------- */

    function test_setInitialCosts_isImmediateAndOpensChipping() public {
        assertFalse(act.collectionConfigured(address(based)));
        vm.prank(multisig);
        act.setInitialCosts(address(based), LADDER);
        assertTrue(act.collectionConfigured(address(based)), "not configured");
        assertTrue(act.costsInitialized(address(based)), "flag not set");
        assertEq(act.costOf(address(based), 0), LADDER[0]);
        _activate(1, 0); // works with zero wait
    }

    function test_setInitialCosts_cannotBeReplayed() public {
        _bootstrap();
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(ChipActivationV2.AlreadyInitialized.selector, address(based)));
        act.setInitialCosts(address(based), FLAT);
    }

    function test_afterBootstrap_priceChangeStillNeeds48h() public {
        _bootstrap();
        uint256[5] memory cheaper =
            [uint256(1 ether), 2 ether, 3 ether, 4 ether, 5 ether];

        vm.prank(multisig);
        act.queueCosts(address(based), cheaper);

        vm.prank(multisig);
        vm.expectRevert(); // TimelockNotElapsed
        act.executeCosts(address(based));

        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        act.executeCosts(address(based));
        assertEq(act.costOf(address(based), 0), 1 ether, "timelocked change did not apply");
    }

    function test_timelockedExecute_alsoClosesTheBootstrapDoor() public {
        // a collection priced via the 48h path can never then use the zero-notice path
        vm.prank(multisig);
        act.queueCosts(address(based), LADDER);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        act.executeCosts(address(based));

        assertTrue(act.costsInitialized(address(based)));
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(ChipActivationV2.AlreadyInitialized.selector, address(based)));
        act.setInitialCosts(address(based), FLAT);
    }

    function test_setInitialCosts_onlyOwnerAndValidates() public {
        vm.prank(alice);
        vm.expectRevert();
        act.setInitialCosts(address(based), LADDER);

        // descending ladder must be rejected by _validateCosts
        uint256[5] memory bad = [uint256(5 ether), 4 ether, 3 ether, 2 ether, 1 ether];
        vm.prank(multisig);
        vm.expectRevert();
        act.setInitialCosts(address(based), bad);
    }

    function test_setInitialCosts_flatCollectionMustBeFlat() public {
        vm.prank(multisig);
        act.setFlatRateCollection(address(chiplets));

        vm.prank(multisig);
        vm.expectRevert(); // ladder on a flat collection
        act.setInitialCosts(address(chiplets), LADDER);

        vm.prank(multisig);
        act.setInitialCosts(address(chiplets), FLAT);
        assertEq(act.costOf(address(chiplets), 0), 390_000 ether);
    }

    /* -------------------------- 4. EXECUTE HATCH -------------------------- */

    function test_execute_canCallAnotherContract() public {
        // the whole point: this contract can INITIATE a call, unlike the trapped FeeSplitter
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        other.mint(address(act), 1_000 ether);

        bytes memory data = abi.encodeWithSignature("transfer(address,uint256)", collector, 1_000 ether);
        vm.prank(multisig);
        act.execute(address(other), 0, data);

        assertEq(other.balanceOf(collector), 1_000 ether, "execute did not move the token");
        assertEq(other.balanceOf(address(act)), 0);
    }

    function test_execute_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        act.execute(address(chip), 0, "");
    }

    function test_execute_revertsOnZeroTargetAndBubblesFailure() public {
        vm.prank(multisig);
        vm.expectRevert();
        act.execute(address(0), 0, "");

        // calling a function that reverts must revert the whole thing, not swallow it
        bytes memory bad = abi.encodeWithSignature("transfer(address,uint256)", collector, type(uint256).max);
        vm.prank(multisig);
        vm.expectRevert(ChipActivationV2.ExecuteFailed.selector);
        act.execute(address(chip), 0, bad);
    }

    function test_execute_cannotReachUserFundsBecauseThereAreNone() public {
        _bootstrap();
        _activate(1, 0);
        // invariant carried from V1: the contract never holds CHIP, so the hatch has
        // nothing of a user's to reach
        assertEq(chip.balanceOf(address(act)), 0);
    }
}
