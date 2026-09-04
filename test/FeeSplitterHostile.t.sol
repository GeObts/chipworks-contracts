// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";

import {FeeSplitter} from "../src/FeeSplitter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {BlacklistToken, PausableToken, LyingToken} from "./mocks/HostileTokens.sol";
import {FeeOnTransferToken} from "./mocks/HostileTokens.sol";
import {RejectingReceiver} from "./mocks/MockReceivers.sol";

/// @notice Gaps found by diffing this suite against the BasedPacks FeeSplitter tests,
///         plus the hostile-token cases their HostileTokens mocks exist for.
contract FeeSplitterHostileTest is Test {
    FeeSplitter internal splitter;

    address internal multisig = makeAddr("multisig");
    address internal pot = makeAddr("pot");
    address internal ops = makeAddr("ops");

    uint32 internal constant OPS_BPS = 2_000;
    uint32 internal constant MAX_OPS_BPS = 2_000;

    MockERC20 internal usdc;

    function setUp() public {
        splitter = new FeeSplitter(multisig, pot, ops, OPS_BPS, MAX_OPS_BPS);
        usdc = new MockERC20("USD Coin", "USDC", 6);
    }

    /* ------------------------------------------------------------------ */
    /*                    PARITY WITH THE BasedPacks SUITE                  */
    /* ------------------------------------------------------------------ */

    /// @notice BasedPacks uses Solady's forceSafeTransferETH, so a rejecting recipient can
    ///         never wedge their splitter. Ours reverts instead. That is a deliberate
    ///         trade — no self-destruct trick, no silently burnt ETH — but it is only
    ///         acceptable if the wedge is RECOVERABLE. Prove that it is.
    /// @notice Retargeting still recovers a bad recipient — but it is no longer the ONLY
    ///         recovery, and the flush it follows no longer reverts.
    ///
    /// @dev Rewritten for SEC-FEE-001. The old version asserted that `distributeETH` reverted
    ///      while ops was broken, and that retargeting was what unstuck it. Now the flush
    ///      succeeds immediately, the pot is paid on time, and the broken leg is escrowed.
    ///      Retargeting changes where FUTURE shares go; it deliberately does NOT move ETH
    ///      already escrowed to the old address, because that ETH was allocated to whoever
    ///      was ops at the time and reassigning it would be a governance power over money
    ///      already earmarked. The old address claims it with `withdrawEth`.
    function test_retargetingRedirectsFutureSharesAndEscrowKeepsThePast() public {
        RejectingReceiver badOps = new RejectingReceiver();
        FeeSplitter s = new FeeSplitter(multisig, pot, address(badOps), OPS_BPS, MAX_OPS_BPS);
        vm.deal(address(s), 10 ether);

        s.distributeETH(); // no revert: the pot is paid, ops is escrowed
        assertEq(pot.balance, 8 ether, "the pot never waited");
        assertEq(s.owedEth(address(badOps)), 2 ether);

        address goodOps = makeAddr("goodOps");
        vm.prank(multisig);
        s.setOps(goodOps);

        vm.deal(address(s), address(s).balance + 10 ether);
        s.distributeETH();

        assertEq(pot.balance, 16 ether);
        assertEq(goodOps.balance, 2 ether, "the new ops gets the new tranche");
        assertEq(s.owedEth(address(badOps)), 2 ether, "the old escrow is untouched by a retarget");

        // And the old address can still claim what it was allocated.
        badOps.setAccepting(true);
        s.withdrawEth(address(badOps));
        assertEq(address(badOps).balance, 2 ether);
        assertEq(address(s).balance, 0, "nothing stranded either way");
    }

    /// @notice BasedPacks: flush, retarget, flush again. Ours must do the same on BOTH
    ///         legs, with fees accruing BETWEEN the retargets rather than only after.
    function test_retargetMidStreamSplitsEachTrancheToThenCurrentTargets() public {
        vm.deal(address(splitter), 10 ether);
        splitter.distributeETH();
        assertEq(pot.balance, 8 ether);
        assertEq(ops.balance, 2 ether);

        vm.deal(address(splitter), 5 ether); // accrues BEFORE the retarget
        address newPot = makeAddr("newPot");
        address newOps = makeAddr("newOps");
        vm.startPrank(multisig);
        splitter.setPot(newPot);
        splitter.setOps(newOps);
        vm.stopPrank();

        splitter.distributeETH();

        assertEq(newPot.balance, 4 ether, "accrued tranche follows the new target");
        assertEq(newOps.balance, 1 ether);
        assertEq(pot.balance, 8 ether, "old targets keep only what they already had");
        assertEq(ops.balance, 2 ether);
    }

    function test_retargetMidStreamWorksForTokensToo() public {
        usdc.mint(address(splitter), 1_000e6);
        splitter.distributeToken(IERC20(address(usdc)));

        usdc.mint(address(splitter), 500e6);
        address newPot = makeAddr("newPot");
        vm.prank(multisig);
        splitter.setPot(newPot);
        splitter.distributeToken(IERC20(address(usdc)));

        assertEq(usdc.balanceOf(pot), 800e6);
        assertEq(usdc.balanceOf(newPot), 400e6);
        assertEq(usdc.balanceOf(address(splitter)), 0);
    }

    /// @notice Anyone at all can trigger the split. No keeper, no permission, no owner.
    function test_everyDistributionEntryPointIsPermissionless() public {
        address stranger = makeAddr("stranger");
        MockERC20 chip = new MockERC20("Chipworks", "CHIP", 18);
        vm.deal(address(splitter), 4 ether);
        usdc.mint(address(splitter), 100e6);
        chip.mint(address(splitter), 100 ether);

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(usdc));
        tokens[1] = IERC20(address(chip));

        vm.prank(stranger);
        splitter.distributeAll(tokens);

        assertEq(pot.balance, 3.2 ether);
        assertEq(usdc.balanceOf(pot), 80e6);
        assertEq(chip.balanceOf(pot), 80 ether);
    }

    /* ------------------------------------------------------------------ */
    /*                          HOSTILE TOKENS                              */
    /* ------------------------------------------------------------------ */

    /// @notice A frozen fee token must not stop ETH or any other token from flushing.
    ///         This is the FeeSplitter half of the isolation property that matters far
    ///         more in ChipRounds.
    function test_frozenTokenDoesNotBlockOtherAssets() public {
        BlacklistToken frozen = new BlacklistToken("Freezer", "FRZ", 18);
        frozen.mint(address(splitter), 1_000 ether);
        frozen.setBlacklisted(address(splitter), true);
        vm.deal(address(splitter), 10 ether);
        usdc.mint(address(splitter), 1_000e6);

        vm.expectRevert(bytes("BLACKLISTED"));
        splitter.distributeToken(IERC20(address(frozen)));

        // Everything else still flushes normally.
        splitter.distributeETH();
        splitter.distributeToken(IERC20(address(usdc)));
        assertEq(pot.balance, 8 ether);
        assertEq(usdc.balanceOf(pot), 800e6);

        // ...and once unfrozen it flushes too, with nothing lost meanwhile.
        frozen.setBlacklisted(address(splitter), false);
        splitter.distributeToken(IERC20(address(frozen)));
        assertEq(frozen.balanceOf(pot), 800 ether);
    }

    /// @notice A batch containing one frozen token reverts wholesale. Documented because
    ///         the keeper must fall back to per-token calls rather than retrying the batch.
    function test_batchRevertsIfAnyTokenIsFrozen() public {
        BlacklistToken frozen = new BlacklistToken("Freezer", "FRZ", 18);
        frozen.mint(address(splitter), 1_000 ether);
        frozen.setBlacklisted(address(splitter), true);
        usdc.mint(address(splitter), 1_000e6);

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(usdc));
        tokens[1] = IERC20(address(frozen));

        vm.expectRevert(bytes("BLACKLISTED"));
        splitter.distributeTokens(tokens);
        assertEq(usdc.balanceOf(pot), 0, "whole batch rolled back");
    }

    function test_pausedTokenBlocksOnlyItselfAndRecovers() public {
        PausableToken p = new PausableToken("Pauser", "PAUSE", 18);
        p.mint(address(splitter), 1_000 ether);
        p.setPaused(true);
        vm.deal(address(splitter), 10 ether);

        vm.expectRevert(bytes("PAUSED"));
        splitter.distributeToken(IERC20(address(p)));

        splitter.distributeETH();
        assertEq(pot.balance, 8 ether);

        p.setPaused(false);
        splitter.distributeToken(IERC20(address(p)));
        assertEq(p.balanceOf(pot), 800 ether);
    }

    /// @notice Reports success, moves nothing. SafeERC20 cannot catch it because the
    ///         return value is `true`. Documented so nobody trusts the Distributed event
    ///         as proof of settlement for an arbitrary token.
    function test_lyingTokenIsNotCaughtByReturnValueChecks() public {
        LyingToken liar = new LyingToken("Liar", "LIE", 18);
        liar.mint(address(splitter), 1_000 ether);
        liar.setLying(true);

        splitter.distributeToken(IERC20(address(liar))); // succeeds

        assertEq(liar.balanceOf(pot), 0, "nothing actually moved");
        assertEq(liar.balanceOf(address(splitter)), 1_000 ether, "funds still here, recoverable");
    }

    /* ------------------------------------------------------------------ */
    /*        SEC-FEE-003 — A TOKEN THAT TAKES A CUT IN TRANSIT             */
    /* ------------------------------------------------------------------ */

    /// @notice A fee-on-transfer token must not be able to revert its own split.
    ///
    /// @dev The old ordering paid the pot first from a precomputed share, so by the third
    ///      transfer the balance was short and `safeTransfer` reverted — freezing that
    ///      token's fees in the splitter permanently. The pot is now paid LAST from the
    ///      measured remaining balance, which cannot overdraw by construction.
    ///
    ///      No fee token Chipworks routes today behaves this way. This is the same
    ///      "measure, never assume" discipline `ChipRounds._deliver` already applies.
    function test_aFeeOnTransferTokenSplitsWithoutReverting() public {
        FeeOnTransferToken fot = new FeeOnTransferToken("Taxed", "TAX", 18, 100); // 1%
        fot.mint(address(splitter), 1_000 ether);

        splitter.distributeToken(fot); // must not revert

        // Ops took its exact share (less the token's own tax in transit).
        assertGt(fot.balanceOf(ops), 0, "ops was paid");
        assertGt(fot.balanceOf(pot), 0, "and so was the pot");
        assertEq(fot.balanceOf(address(splitter)), 0, "nothing frozen in the splitter");
    }

    /// @notice And the pot is the residual claimant: with a well-behaved token it still gets
    ///         its exact share plus every wei of rounding dust.
    function test_thePotStillTakesTheDustOnAWellBehavedToken() public {
        MockERC20 odd = new MockERC20("Odd", "ODD", 18);
        odd.mint(address(splitter), 10_001); // deliberately indivisible by the bps split

        (uint256 potAmount, uint256 opsAmount,) = splitter.previewSplit(10_001);
        splitter.distributeToken(odd);

        assertEq(odd.balanceOf(ops), opsAmount);
        assertEq(odd.balanceOf(pot), potAmount, "dust still lands on holders");
        assertEq(odd.balanceOf(ops) + odd.balanceOf(pot), 10_001, "value conserved");
    }
}
