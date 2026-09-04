// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {FeeSplitter} from "../src/FeeSplitter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FeeOnTransferToken, FalseReturnToken} from "./mocks/HostileTokens.sol";
import {GreedyReceiver, RejectingReceiver, ReentrantReceiver} from "./mocks/MockReceivers.sol";

contract FeeSplitterTest is Test {
    FeeSplitter internal splitter;

    address internal multisig = makeAddr("multisig");
    address internal pot = makeAddr("pot");
    address internal ops = makeAddr("ops");
    address internal randomer = makeAddr("randomer");

    uint32 internal constant OPS_BPS = 2_000; // 20 percent
    uint32 internal constant MAX_OPS_BPS = 2_000;

    MockERC20 internal usdc;
    MockERC20 internal chip;

    event Distributed(
        address indexed asset, uint256 potAmount, uint256 opsAmount, uint256 polAmount, address indexed caller
    );
    event OpsUpdated(address indexed previousOps, address indexed newOps);
    event PotUpdated(address indexed previousPot, address indexed newPot);
    event OpsBpsUpdated(uint32 previousOpsBps, uint32 newOpsBps);

    function setUp() public {
        splitter = new FeeSplitter(multisig, pot, ops, OPS_BPS, MAX_OPS_BPS);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        chip = new MockERC20("Chipworks", "CHIP", 18);
    }

    /* ------------------------------------------------------------------ */
    /*                          CONSTRUCTOR                                 */
    /* ------------------------------------------------------------------ */

    function test_constructor_setsState() public view {
        assertEq(splitter.owner(), multisig, "owner");
        assertEq(splitter.pot(), pot, "pot");
        assertEq(splitter.ops(), ops, "ops");
        assertEq(splitter.opsBps(), OPS_BPS, "opsBps");
        assertEq(splitter.potBps(), 8_000, "potBps");
        assertEq(splitter.maxOpsBps(), MAX_OPS_BPS, "maxOpsBps");
        assertEq(splitter.BPS_DENOMINATOR(), 10_000, "denominator");
    }

    function test_constructor_revertsOnZeroMultisig() public {
        // Ownable runs first, so the zero owner is caught there rather than by ZeroAddress.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new FeeSplitter(address(0), pot, ops, OPS_BPS, MAX_OPS_BPS);
    }

    function test_constructor_revertsOnZeroPot() public {
        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        new FeeSplitter(multisig, address(0), ops, OPS_BPS, MAX_OPS_BPS);
    }

    function test_constructor_revertsOnZeroOps() public {
        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        new FeeSplitter(multisig, pot, address(0), OPS_BPS, MAX_OPS_BPS);
    }

    function test_constructor_revertsWhenOpsBpsAboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.OpsBpsTooHigh.selector, uint32(2_001), MAX_OPS_BPS));
        new FeeSplitter(multisig, pot, ops, 2_001, MAX_OPS_BPS);
    }

    function test_constructor_revertsWhenMaxAboveDenominator() public {
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.MaxOpsBpsTooHigh.selector, uint32(10_001), uint32(10_000)));
        new FeeSplitter(multisig, pot, ops, 0, 10_001);
    }

    function test_constructor_allowsZeroOpsShare() public {
        FeeSplitter s = new FeeSplitter(multisig, pot, ops, 0, 0);
        assertEq(s.opsBps(), 0);
        assertEq(s.potBps(), 10_000);
    }

    /* ------------------------------------------------------------------ */
    /*                             ETH SPLIT                                */
    /* ------------------------------------------------------------------ */

    function test_receive_acceptsEthWithoutSplitting() public {
        vm.deal(randomer, 1 ether);
        vm.prank(randomer);
        (bool ok,) = address(splitter).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(splitter).balance, 1 ether, "held, not forwarded");
        assertEq(pot.balance, 0);
        assertEq(ops.balance, 0);
    }

    function test_receive_worksWithOnly2300Gas() public {
        // Some LP lockers and older royalty contracts still use .transfer().
        vm.deal(randomer, 1 ether);
        vm.prank(randomer);
        (bool ok,) = address(splitter).call{value: 1 ether, gas: 2_300}("");
        assertTrue(ok, "must accept a 2300 gas send");
    }

    function test_distributeETH_splits80_20() public {
        vm.deal(address(splitter), 10 ether);

        vm.prank(randomer); // permissionless
        (uint256 potAmount, uint256 opsAmount,) = splitter.distributeETH();

        assertEq(potAmount, 8 ether, "pot 80 percent");
        assertEq(opsAmount, 2 ether, "ops 20 percent");
        assertEq(pot.balance, 8 ether);
        assertEq(ops.balance, 2 ether);
        assertEq(address(splitter).balance, 0, "fully drained");
    }

    function test_distributeETH_emitsEvent() public {
        vm.deal(address(splitter), 10 ether);
        vm.expectEmit(true, true, true, true, address(splitter));
        emit Distributed(address(0), 8 ether, 2 ether, 0, randomer);
        vm.prank(randomer);
        splitter.distributeETH();
    }

    function test_distributeETH_revertsWhenEmpty() public {
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.NothingToDistribute.selector, address(0)));
        splitter.distributeETH();
    }

    function test_distributeETH_dustGoesToPot() public {
        // 3 wei: ops = 3 * 2000 / 10000 = 0, pot = 3.
        vm.deal(address(splitter), 3);
        (uint256 potAmount, uint256 opsAmount,) = splitter.distributeETH();
        assertEq(opsAmount, 0);
        assertEq(potAmount, 3);
        assertEq(pot.balance, 3);
        assertEq(address(splitter).balance, 0, "no wei stranded");
    }

    function test_distributeETH_repeatedAccumulation() public {
        vm.deal(address(splitter), 5 ether);
        splitter.distributeETH();
        vm.deal(address(splitter), 5 ether);
        splitter.distributeETH();
        assertEq(pot.balance, 8 ether);
        assertEq(ops.balance, 2 ether);
    }

    function test_distributeETH_worksWithGasHungryRecipient() public {
        GreedyReceiver greedyPot = new GreedyReceiver();
        FeeSplitter s = new FeeSplitter(multisig, address(greedyPot), ops, OPS_BPS, MAX_OPS_BPS);
        vm.deal(address(s), 10 ether);
        s.distributeETH();
        assertEq(address(greedyPot).balance, 8 ether, "full gas forwarded, not 2300");
    }

    /// @notice SEC-FEE-001. A recipient that refuses ETH is ESCROWED, not allowed to revert
    ///         the batch — so the other two legs are paid in full and on time.
    ///
    /// @dev This replaces `test_distributeETH_revertsWhenRecipientRejects`, which asserted the
    ///      old behaviour: the whole distribution reverted and every recipient waited on the
    ///      broken one. Nothing was lost then either, but everything was stuck.
    function test_aRejectingRecipientIsEscrowedAndTheOthersArePaid() public {
        RejectingReceiver badOps = new RejectingReceiver();
        FeeSplitter s = new FeeSplitter(multisig, pot, address(badOps), OPS_BPS, MAX_OPS_BPS);
        vm.deal(address(s), 10 ether);

        s.distributeETH(); // must NOT revert

        assertEq(pot.balance, 8 ether, "the pot was paid in full");
        assertEq(address(badOps).balance, 0, "ops could not accept");
        assertEq(s.owedEth(address(badOps)), 2 ether, "and is owed it instead");
        assertEq(s.totalOwedEth(), 2 ether);
        assertEq(address(s).balance, 2 ether, "exactly the escrow is held");
    }

    /// @notice Escrowed ETH is never re-split, however many times distribute is called.
    function test_escrowedEthIsHeldBackFromEverySubsequentSplit() public {
        RejectingReceiver badOps = new RejectingReceiver();
        FeeSplitter s = new FeeSplitter(multisig, pot, address(badOps), OPS_BPS, MAX_OPS_BPS);

        vm.deal(address(s), 10 ether);
        s.distributeETH();
        assertEq(s.owedEth(address(badOps)), 2 ether);
        assertEq(s.distributableEth(), 0, "nothing left to split");

        // A fresh 10 ETH arrives. Only the new money is split.
        vm.deal(address(s), address(s).balance + 10 ether);
        assertEq(s.distributableEth(), 10 ether, "the escrow is not double-counted");
        s.distributeETH();

        assertEq(pot.balance, 16 ether, "the pot got both rounds in full");
        assertEq(s.owedEth(address(badOps)), 4 ether, "escrow accumulated, not re-split");
        assertEq(address(s).balance, 4 ether);
    }

    /// @notice And the escrow is claimable once the recipient can accept again.
    function test_escrowIsWithdrawableAndPermissionless() public {
        RejectingReceiver badOps = new RejectingReceiver();
        FeeSplitter s = new FeeSplitter(multisig, pot, address(badOps), OPS_BPS, MAX_OPS_BPS);
        vm.deal(address(s), 10 ether);
        s.distributeETH();

        // The recipient starts accepting ETH.
        badOps.setAccepting(true);

        // Anyone may push it, and it goes to the RECIPIENT, never to the caller.
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        uint256 paid = s.withdrawEth(address(badOps));

        assertEq(paid, 2 ether);
        assertEq(address(badOps).balance, 2 ether, "paid the recipient");
        assertEq(stranger.balance, 0, "not the caller");
        assertEq(s.owedEth(address(badOps)), 0);
        assertEq(s.totalOwedEth(), 0);
        assertEq(address(s).balance, 0);
    }

    function test_withdrawingNothingReverts() public {
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.NothingOwed.selector, ops));
        splitter.withdrawEth(ops);
    }

    /// @notice A withdrawal that still cannot land reverts and leaves the escrow intact —
    ///         it is never consumed by a payment that did not arrive.
    function test_aFailedWithdrawalLeavesTheEscrowIntact() public {
        RejectingReceiver badOps = new RejectingReceiver();
        FeeSplitter s = new FeeSplitter(multisig, pot, address(badOps), OPS_BPS, MAX_OPS_BPS);
        vm.deal(address(s), 10 ether);
        s.distributeETH();

        vm.expectRevert();
        s.withdrawEth(address(badOps)); // still rejecting

        assertEq(s.owedEth(address(badOps)), 2 ether, "still owed");
        assertEq(s.totalOwedEth(), 2 ether);
        assertEq(address(s).balance, 2 ether);
    }

    /// @notice SEC-FEE-004. The batch entry points are permissionless, so the array is capped.
    function test_anOversizedBatchIsRefused() public {
        IERC20[] memory many = new IERC20[](33);
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.BatchTooLarge.selector, uint256(33), uint256(32)));
        splitter.distributeTokens(many);

        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.BatchTooLarge.selector, uint256(33), uint256(32)));
        splitter.distributeAll(many);
    }

    function test_distributeETH_reentrancyIsBlocked() public {
        ReentrantReceiver attacker = new ReentrantReceiver();
        FeeSplitter s = new FeeSplitter(multisig, address(attacker), ops, OPS_BPS, MAX_OPS_BPS);
        attacker.arm(address(s), abi.encodeCall(FeeSplitter.distributeETH, ()));

        vm.deal(address(s), 10 ether);
        s.distributeETH();

        assertTrue(attacker.reentryAttempted(), "attacker did try to re-enter");
        assertFalse(attacker.reentrySucceeded(), "re-entrant call must fail");
        assertEq(
            bytes4(attacker.reentryReturnData()),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector,
            "blocked by the reentrancy guard"
        );
        // The honest distribution still completed exactly once.
        assertEq(address(attacker).balance, 8 ether);
        assertEq(ops.balance, 2 ether);
        assertEq(address(s).balance, 0);
    }

    function test_distributeETH_reentrancyViaTokenPathIsBlocked() public {
        ReentrantReceiver attacker = new ReentrantReceiver();
        FeeSplitter s = new FeeSplitter(multisig, address(attacker), ops, OPS_BPS, MAX_OPS_BPS);
        usdc.mint(address(s), 1_000e6);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(usdc));
        attacker.arm(address(s), abi.encodeCall(FeeSplitter.distributeTokens, (tokens)));

        vm.deal(address(s), 10 ether);
        s.distributeETH();

        assertFalse(attacker.reentrySucceeded(), "cross-function re-entry must fail too");
        assertEq(bytes4(attacker.reentryReturnData()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(usdc.balanceOf(address(s)), 1_000e6, "tokens untouched by the re-entrant path");
    }

    /* ------------------------------------------------------------------ */
    /*                           TOKEN SPLIT                                */
    /* ------------------------------------------------------------------ */

    function test_distributeToken_splits80_20() public {
        usdc.mint(address(splitter), 1_000e6);

        vm.prank(randomer);
        (uint256 potAmount, uint256 opsAmount,) = splitter.distributeToken(IERC20(address(usdc)));

        assertEq(potAmount, 800e6);
        assertEq(opsAmount, 200e6);
        assertEq(usdc.balanceOf(pot), 800e6);
        assertEq(usdc.balanceOf(ops), 200e6);
        assertEq(usdc.balanceOf(address(splitter)), 0);
    }

    function test_distributeToken_handles18Decimals() public {
        chip.mint(address(splitter), 1_000 ether);
        splitter.distributeToken(IERC20(address(chip)));
        assertEq(chip.balanceOf(pot), 800 ether);
        assertEq(chip.balanceOf(ops), 200 ether);
    }

    function test_distributeToken_revertsWhenEmpty() public {
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.NothingToDistribute.selector, address(usdc)));
        splitter.distributeToken(IERC20(address(usdc)));
    }

    function test_distributeToken_revertsOnZeroAddress() public {
        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        splitter.distributeToken(IERC20(address(0)));
    }

    function test_distributeToken_dustGoesToPot() public {
        usdc.mint(address(splitter), 3);
        splitter.distributeToken(IERC20(address(usdc)));
        assertEq(usdc.balanceOf(pot), 3);
        assertEq(usdc.balanceOf(ops), 0);
        assertEq(usdc.balanceOf(address(splitter)), 0);
    }

    function test_distributeToken_feeOnTransferLeavesNothingStranded() public {
        FeeOnTransferToken fot = new FeeOnTransferToken("Taxed", "TAX", 18, 100); // 1 percent
        fot.mint(address(splitter), 1_000 ether);

        splitter.distributeToken(IERC20(address(fot)));

        // Recipients get less than the nominal split because the token taxes transfers,
        // but the splitter must not retain a balance.
        assertEq(fot.balanceOf(address(splitter)), 0, "splitter drained");
        assertEq(fot.balanceOf(pot), 792 ether, "800 minus 1 percent");
        assertEq(fot.balanceOf(ops), 198 ether, "200 minus 1 percent");
    }

    function test_distributeToken_revertsOnFalseReturningToken() public {
        FalseReturnToken bad = new FalseReturnToken();
        bad.mint(address(splitter), 1_000 ether);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad)));
        splitter.distributeToken(IERC20(address(bad)));
    }

    function test_distributeTokens_batch() public {
        usdc.mint(address(splitter), 1_000e6);
        chip.mint(address(splitter), 500 ether);

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(usdc));
        tokens[1] = IERC20(address(chip));
        splitter.distributeTokens(tokens);

        assertEq(usdc.balanceOf(pot), 800e6);
        assertEq(chip.balanceOf(pot), 400 ether);
        assertEq(usdc.balanceOf(ops), 200e6);
        assertEq(chip.balanceOf(ops), 100 ether);
    }

    function test_distributeTokens_skipsEmptyAndZeroEntries() public {
        usdc.mint(address(splitter), 1_000e6);

        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(usdc));
        tokens[1] = IERC20(address(chip)); // zero balance
        tokens[2] = IERC20(address(0)); // zero address
        splitter.distributeTokens(tokens); // must not revert

        assertEq(usdc.balanceOf(pot), 800e6);
    }

    function test_distributeTokens_emptyArrayIsANoop() public {
        IERC20[] memory tokens = new IERC20[](0);
        splitter.distributeTokens(tokens);
    }

    function test_distributeAll_handlesEthAndTokens() public {
        vm.deal(address(splitter), 10 ether);
        usdc.mint(address(splitter), 1_000e6);

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(usdc));
        vm.prank(randomer);
        splitter.distributeAll(tokens);

        assertEq(pot.balance, 8 ether);
        assertEq(ops.balance, 2 ether);
        assertEq(usdc.balanceOf(pot), 800e6);
        assertEq(usdc.balanceOf(ops), 200e6);
    }

    function test_distributeAll_noEthIsFine() public {
        usdc.mint(address(splitter), 1_000e6);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(usdc));
        splitter.distributeAll(tokens);
        assertEq(usdc.balanceOf(pot), 800e6);
        assertEq(pot.balance, 0);
    }

    /* ------------------------------------------------------------------ */
    /*                           GOVERNANCE                                 */
    /* ------------------------------------------------------------------ */

    function test_setOps_onlyMultisig() public {
        address newOps = makeAddr("newOps");

        vm.prank(randomer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, randomer));
        splitter.setOps(newOps);

        vm.prank(ops); // even the current ops wallet cannot move itself
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ops));
        splitter.setOps(newOps);

        vm.expectEmit(true, true, false, false, address(splitter));
        emit OpsUpdated(ops, newOps);
        vm.prank(multisig);
        splitter.setOps(newOps);
        assertEq(splitter.ops(), newOps);
    }

    function test_setOps_revertsOnZero() public {
        vm.prank(multisig);
        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        splitter.setOps(address(0));
    }

    function test_setOps_routesFutureDistributions() public {
        address newOps = makeAddr("newOps");
        vm.prank(multisig);
        splitter.setOps(newOps);

        vm.deal(address(splitter), 10 ether);
        splitter.distributeETH();

        assertEq(newOps.balance, 2 ether);
        assertEq(ops.balance, 0, "old ops gets nothing");
    }

    function test_setPot_onlyMultisig() public {
        address newPot = makeAddr("newPot");
        vm.prank(randomer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, randomer));
        splitter.setPot(newPot);

        vm.prank(multisig);
        splitter.setPot(newPot);
        assertEq(splitter.pot(), newPot);
    }

    function test_setPot_revertsOnZero() public {
        vm.prank(multisig);
        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        splitter.setPot(address(0));
    }

    function test_setOpsBps_onlyMultisigAndCapped() public {
        vm.prank(randomer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, randomer));
        splitter.setOpsBps(1_000);

        // Cannot exceed the immutable ceiling, even as the multisig.
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.OpsBpsTooHigh.selector, uint32(2_001), MAX_OPS_BPS));
        splitter.setOpsBps(2_001);

        vm.prank(multisig);
        splitter.setOpsBps(1_000);
        assertEq(splitter.opsBps(), 1_000);
        assertEq(splitter.potBps(), 9_000);
    }

    function test_setOpsBps_cannotBeRaisedEvenByCompromisedMultisig() public {
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.OpsBpsTooHigh.selector, uint32(10_000), MAX_OPS_BPS));
        splitter.setOpsBps(10_000);
    }

    function test_setOpsBps_appliesToNextDistribution() public {
        vm.prank(multisig);
        splitter.setOpsBps(500); // 5 percent

        vm.deal(address(splitter), 10 ether);
        splitter.distributeETH();
        assertEq(pot.balance, 9.5 ether);
        assertEq(ops.balance, 0.5 ether);
    }

    function test_ownershipTransferIsTwoStep() public {
        address newMultisig = makeAddr("newMultisig");

        vm.prank(multisig);
        splitter.transferOwnership(newMultisig);
        assertEq(splitter.owner(), multisig, "not yet");
        assertEq(splitter.pendingOwner(), newMultisig);

        vm.prank(newMultisig);
        splitter.acceptOwnership();
        assertEq(splitter.owner(), newMultisig);
    }

    function test_ownershipTransferToWrongAddressIsRecoverable() public {
        address typo = makeAddr("typo");
        vm.prank(multisig);
        splitter.transferOwnership(typo);
        // The typo address never accepts, so the multisig simply overrides it.
        vm.prank(multisig);
        splitter.transferOwnership(multisig);
        assertEq(splitter.owner(), multisig);
    }

    /* ------------------------------------------------------------------ */
    /*                              FUZZ                                    */
    /* ------------------------------------------------------------------ */

    function testFuzz_ethSplitConservesValueAndFavoursPot(uint96 amount, uint32 opsBps_) public {
        opsBps_ = uint32(bound(opsBps_, 0, MAX_OPS_BPS));
        vm.assume(amount > 0);

        vm.prank(multisig);
        splitter.setOpsBps(opsBps_);
        vm.deal(address(splitter), amount);

        (uint256 potAmount, uint256 opsAmount,) = splitter.distributeETH();

        assertEq(potAmount + opsAmount, amount, "value conserved");
        assertEq(address(splitter).balance, 0, "nothing stranded");
        assertEq(pot.balance, potAmount);
        assertEq(ops.balance, opsAmount);
        assertLe(opsAmount, (uint256(amount) * opsBps_) / 10_000, "ops never rounded up");
    }

    function testFuzz_tokenSplitConservesValue(uint128 amount, uint32 opsBps_) public {
        opsBps_ = uint32(bound(opsBps_, 0, MAX_OPS_BPS));
        vm.assume(amount > 0);

        vm.prank(multisig);
        splitter.setOpsBps(opsBps_);
        usdc.mint(address(splitter), amount);

        (uint256 potAmount, uint256 opsAmount,) = splitter.distributeToken(IERC20(address(usdc)));

        assertEq(potAmount + opsAmount, amount, "value conserved");
        assertEq(usdc.balanceOf(address(splitter)), 0, "nothing stranded");
        assertEq(usdc.balanceOf(pot), potAmount);
        assertEq(usdc.balanceOf(ops), opsAmount);
    }

    function testFuzz_previewMatchesActual(uint128 amount) public {
        vm.assume(amount > 0);
        (uint256 previewPot, uint256 previewOps,) = splitter.previewSplit(amount);
        usdc.mint(address(splitter), amount);
        (uint256 potAmount, uint256 opsAmount,) = splitter.distributeToken(IERC20(address(usdc)));
        assertEq(previewPot, potAmount);
        assertEq(previewOps, opsAmount);
    }
}
