// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";

import {FeeSplitter} from "../src/FeeSplitter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {BlacklistToken} from "./mocks/HostileTokens.sol";
import {RejectingReceiver} from "./mocks/MockReceivers.sol";

/// @notice The optional third leg: a slice of every inflow routed to POL, so protocol-owned
///         liquidity can pair its stock holdback with quote token of its own instead of
///         depending on expired credits or manual ops transfers. OPEN_ITEMS.md item 2.
contract FeeSplitterPolTest is Test {
    FeeSplitter internal splitter;

    address internal multisig = makeAddr("multisig");
    address internal pot = makeAddr("pot");
    address internal ops = makeAddr("ops");
    address internal polTreasury = makeAddr("polTreasury");
    address internal stranger = makeAddr("stranger");

    MockERC20 internal usdc;

    uint32 internal constant OPS_BPS = 2_000;
    uint32 internal constant MAX_OPS_BPS = 2_000;

    event Distributed(
        address indexed asset, uint256 potAmount, uint256 opsAmount, uint256 polAmount, address indexed caller
    );

    function setUp() public {
        splitter = new FeeSplitter(multisig, pot, ops, OPS_BPS, MAX_OPS_BPS);
        usdc = new MockERC20("USD Coin", "USDC", 6);
    }

    function _enablePol(uint32 bps) internal {
        vm.startPrank(multisig);
        splitter.setPolTreasury(polTreasury);
        splitter.setPolShareBps(bps);
        vm.stopPrank();
    }

    /* ------------------------------------------------------------------ */
    /*                        OFF BY DEFAULT                                */
    /* ------------------------------------------------------------------ */

    function test_defaultsToTwoWaySplit() public view {
        assertEq(splitter.polShareBps(), 0);
        assertEq(splitter.polTreasury(), address(0));
        assertEq(splitter.potBps(), 8_000);
    }

    function test_untouchedBehaviourWhenPolIsOff() public {
        vm.deal(address(splitter), 10 ether);
        (uint256 potAmount, uint256 opsAmount, uint256 polAmount) = splitter.distributeETH();
        assertEq(potAmount, 8 ether);
        assertEq(opsAmount, 2 ether);
        assertEq(polAmount, 0);
        assertEq(polTreasury.balance, 0);
    }

    /* ------------------------------------------------------------------ */
    /*                          THREE-WAY SPLIT                             */
    /* ------------------------------------------------------------------ */

    function test_threeWaySplitEth() public {
        _enablePol(1_000); // 10% to POL
        assertEq(splitter.potBps(), 7_000, "pot takes what is left");

        vm.deal(address(splitter), 10 ether);
        vm.prank(stranger); // still permissionless
        (uint256 potAmount, uint256 opsAmount, uint256 polAmount) = splitter.distributeETH();

        assertEq(potAmount, 7 ether);
        assertEq(opsAmount, 2 ether);
        assertEq(polAmount, 1 ether);
        assertEq(pot.balance, 7 ether);
        assertEq(ops.balance, 2 ether);
        assertEq(polTreasury.balance, 1 ether);
        assertEq(address(splitter).balance, 0, "fully drained");
    }

    function test_threeWaySplitToken() public {
        _enablePol(1_500);
        usdc.mint(address(splitter), 1_000e6);

        splitter.distributeToken(IERC20(address(usdc)));

        assertEq(usdc.balanceOf(pot), 650e6);
        assertEq(usdc.balanceOf(ops), 200e6);
        assertEq(usdc.balanceOf(polTreasury), 150e6);
        assertEq(usdc.balanceOf(address(splitter)), 0);
    }

    function test_emitsThePolLeg() public {
        _enablePol(1_000);
        vm.deal(address(splitter), 10 ether);
        vm.expectEmit(true, true, true, true, address(splitter));
        emit Distributed(address(0), 7 ether, 2 ether, 1 ether, stranger);
        vm.prank(stranger);
        splitter.distributeETH();
    }

    function test_dustStillFavoursThePot() public {
        _enablePol(1_000);
        vm.deal(address(splitter), 7); // ops = 1, pol = 0, pot = 6
        (uint256 potAmount, uint256 opsAmount, uint256 polAmount) = splitter.distributeETH();
        assertEq(opsAmount, 1);
        assertEq(polAmount, 0);
        assertEq(potAmount, 6, "dust to holders");
        assertEq(address(splitter).balance, 0, "nothing stranded");
    }

    function test_batchPathsAlsoSplitThreeWays() public {
        _enablePol(1_000);
        vm.deal(address(splitter), 10 ether);
        usdc.mint(address(splitter), 1_000e6);

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(usdc));
        vm.prank(stranger);
        splitter.distributeAll(tokens);

        assertEq(polTreasury.balance, 1 ether);
        assertEq(usdc.balanceOf(polTreasury), 100e6);
        assertEq(pot.balance, 7 ether);
        assertEq(usdc.balanceOf(pot), 700e6);
    }

    /* ------------------------------------------------------------------ */
    /*                        RETARGET MID-STREAM                           */
    /* ------------------------------------------------------------------ */

    /// @notice Fees accrue, then all three targets move, then we flush. Each tranche must
    ///         follow the targets that were current when it was flushed.
    function test_retargetAllThreeMidStream() public {
        _enablePol(1_000);

        vm.deal(address(splitter), 10 ether);
        splitter.distributeETH();
        assertEq(pot.balance, 7 ether);
        assertEq(ops.balance, 2 ether);
        assertEq(polTreasury.balance, 1 ether);

        // A second tranche accrues BEFORE the retarget.
        vm.deal(address(splitter), 10 ether);
        address newPot = makeAddr("newPot");
        address newOps = makeAddr("newOps");
        address newPol = makeAddr("newPol");
        vm.startPrank(multisig);
        splitter.setPot(newPot);
        splitter.setOps(newOps);
        splitter.setPolTreasury(newPol);
        vm.stopPrank();

        splitter.distributeETH();

        assertEq(newPot.balance, 7 ether, "accrued tranche follows the new targets");
        assertEq(newOps.balance, 2 ether);
        assertEq(newPol.balance, 1 ether);
        assertEq(pot.balance, 7 ether, "old targets keep only what they had");
        assertEq(ops.balance, 2 ether);
        assertEq(polTreasury.balance, 1 ether);
    }

    function test_retargetPolOnlyMidStreamForTokens() public {
        _enablePol(1_000);
        usdc.mint(address(splitter), 1_000e6);
        splitter.distributeToken(IERC20(address(usdc)));
        assertEq(usdc.balanceOf(polTreasury), 100e6);

        usdc.mint(address(splitter), 500e6);
        address newPol = makeAddr("newPol");
        vm.prank(multisig);
        splitter.setPolTreasury(newPol);
        splitter.distributeToken(IERC20(address(usdc)));

        assertEq(usdc.balanceOf(newPol), 50e6);
        assertEq(usdc.balanceOf(polTreasury), 100e6, "old treasury untouched");
        assertEq(usdc.balanceOf(address(splitter)), 0);
    }

    /// @notice Changing the share mid-stream applies to the next flush, not retroactively.
    function test_changingTheShareAppliesToTheNextFlush() public {
        _enablePol(1_000);
        vm.deal(address(splitter), 10 ether);
        splitter.distributeETH();

        vm.prank(multisig);
        splitter.setPolShareBps(2_000);

        vm.deal(address(splitter), 10 ether);
        splitter.distributeETH();

        assertEq(polTreasury.balance, 1 ether + 2 ether);
        assertEq(pot.balance, 7 ether + 6 ether);
    }

    /// @notice Turning POL back off returns the splitter to a clean two-way split.
    function test_polCanBeTurnedBackOff() public {
        _enablePol(1_000);
        vm.prank(multisig);
        splitter.setPolShareBps(0);

        vm.deal(address(splitter), 10 ether);
        splitter.distributeETH();
        assertEq(pot.balance, 8 ether);
        assertEq(polTreasury.balance, 0);
    }

    /* ------------------------------------------------------------------ */
    /*                              LIMITS                                  */
    /* ------------------------------------------------------------------ */

    function test_polShareIsCappedAtTwentyPercent() public {
        vm.startPrank(multisig);
        splitter.setPolTreasury(polTreasury);
        splitter.setPolShareBps(2_000); // allowed

        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.PolShareTooHigh.selector, uint32(2_001), uint32(2_000)));
        splitter.setPolShareBps(2_001);
        vm.stopPrank();
    }

    /// @notice A non-zero share can never be configured with nowhere to send it.
    function test_cannotEnableAShareWithoutATreasury() public {
        vm.prank(multisig);
        vm.expectRevert(FeeSplitter.PolTreasuryNotSet.selector);
        splitter.setPolShareBps(1_000);
    }

    function test_opsAndPolCannotExceedEverything() public {
        FeeSplitter s = new FeeSplitter(multisig, pot, ops, 9_000, 9_000);
        vm.startPrank(multisig);
        s.setPolTreasury(polTreasury);
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.SharesExceedTotal.selector, uint32(9_000), uint32(2_000)));
        s.setPolShareBps(2_000);
        vm.stopPrank();
    }

    function test_polConfigOnlyMultisig() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        splitter.setPolTreasury(polTreasury);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        splitter.setPolShareBps(1_000);
        vm.stopPrank();
    }

    function test_setPolTreasuryRejectsZero() public {
        vm.prank(multisig);
        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        splitter.setPolTreasury(address(0));
    }

    /* ------------------------------------------------------------------ */
    /*                            FAILURE MODES                             */
    /* ------------------------------------------------------------------ */

    /// @notice A POL treasury that rejects ETH wedges the flush, exactly as a bad ops
    ///         address does. Recoverable the same way: retarget and flush again.
    function test_rejectingPolTreasuryIsRecoverable() public {
        RejectingReceiver badPol = new RejectingReceiver();
        vm.startPrank(multisig);
        splitter.setPolTreasury(address(badPol));
        splitter.setPolShareBps(1_000);
        vm.stopPrank();

        vm.deal(address(splitter), 10 ether);
        vm.expectRevert(Errors.FailedCall.selector);
        splitter.distributeETH();

        vm.prank(multisig);
        splitter.setPolTreasury(polTreasury);
        splitter.distributeETH();
        assertEq(polTreasury.balance, 1 ether, "nothing lost while wedged");
        assertEq(pot.balance, 7 ether);
    }

    /// @notice A frozen token blocks only its own flush, POL leg included.
    function test_frozenTokenDoesNotBlockOtherAssets() public {
        _enablePol(1_000);
        BlacklistToken frozen = new BlacklistToken("Freezer", "FRZ", 18);
        frozen.mint(address(splitter), 1_000 ether);
        frozen.setBlacklisted(polTreasury, true); // POL specifically cannot receive it
        vm.deal(address(splitter), 10 ether);

        vm.expectRevert(bytes("BLACKLISTED"));
        splitter.distributeToken(IERC20(address(frozen)));

        splitter.distributeETH(); // unaffected
        assertEq(pot.balance, 7 ether);
        assertEq(polTreasury.balance, 1 ether);

        frozen.setBlacklisted(polTreasury, false);
        splitter.distributeToken(IERC20(address(frozen)));
        assertEq(frozen.balanceOf(polTreasury), 100 ether, "recovers, nothing lost");
    }

    /* ------------------------------------------------------------------ */
    /*                               FUZZ                                   */
    /* ------------------------------------------------------------------ */

    function testFuzz_threeWaySplitConservesValue(uint96 amount, uint32 polBps) public {
        polBps = uint32(bound(polBps, 0, 2_000));
        vm.assume(amount > 0);

        vm.startPrank(multisig);
        splitter.setPolTreasury(polTreasury);
        splitter.setPolShareBps(polBps);
        vm.stopPrank();

        vm.deal(address(splitter), amount);
        (uint256 potAmount, uint256 opsAmount, uint256 polAmount) = splitter.distributeETH();

        assertEq(potAmount + opsAmount + polAmount, amount, "value conserved");
        assertEq(address(splitter).balance, 0, "nothing stranded");
        assertLe(opsAmount, (uint256(amount) * OPS_BPS) / 10_000, "ops never rounded up");
        assertLe(polAmount, (uint256(amount) * polBps) / 10_000, "pol never rounded up");
    }
}
