// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {NounLoans} from "../../src/loans/NounLoans.sol";
import {ChipActivation} from "../../src/activation/ChipActivation.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockNoun} from "../mocks/MockNoun.sol";
import {LyingToken, PausableToken} from "../mocks/HostileTokens.sol";

/// @notice Unit suite for the loan vault.
contract NounLoansTest is Test {
    address internal multisig = makeAddr("multisig");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal liquidator = makeAddr("liquidator");
    address internal splitter = makeAddr("feeSplitter");
    address internal treasury = makeAddr("treasury");

    NounLoans internal loans;
    ChipActivation internal activation;
    MockERC20 internal chip;
    MockNoun internal based;
    MockNoun internal dark;

    uint256 internal constant CAP = 10_000 ether;

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        chip = new MockERC20("Chipworks", "CHIP", 18);
        based = new MockNoun("Based Nouns", "BASED");
        dark = new MockNoun("DarkNOUNs", "DARK");

        // The chip gate reads a real ChipActivation. Costs are all zero here so chipping is
        // free and cannot perturb the $CHIP balances these tests assert on; the gate is
        // about the activation EXISTING, not about what it cost.
        activation = new ChipActivation(multisig, address(chip), [uint32(10_000), 12_500, 16_000, 20_000, 33_300]);
        _priceFree(address(based));
        _priceFree(address(dark));

        loans = new NounLoans(multisig, address(chip), splitter, treasury, address(activation), _defaultTerms());

        vm.startPrank(multisig);
        loans.setMaxPrincipal(address(based), CAP);
        loans.setMaxPrincipal(address(dark), CAP);
        activation.setCustodian(address(loans), true);
        vm.stopPrank();

        _seedPool(500_000 ether);

        chip.mint(alice, 100_000 ether);
        chip.mint(bob, 100_000 ether);
        vm.prank(alice);
        chip.approve(address(loans), type(uint256).max);
        vm.prank(bob);
        chip.approve(address(loans), type(uint256).max);
    }

    /* -------------------------------- helpers -------------------------------- */

    /// @dev 30 / 90 / 180 days at 2% / 5% / 9%, 2% liquidation bounty.
    function _defaultTerms() internal pure returns (NounLoans.Terms memory t) {
        t.length = [uint64(30 days), 90 days, 180 days];
        t.feeBps = [uint32(200), 500, 900];
        t.bountyBps = 200;
    }

    function _priceFree(address collection) internal {
        vm.prank(multisig);
        activation.queueCosts(collection, [uint256(0), 0, 0, 0, 0]);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        activation.executeCosts(collection);
    }

    /// @dev Mint and chip, which every borrow now requires.
    function _mintAndChip(address who, uint256 tokenId) internal {
        based.mint(who, tokenId);
        vm.prank(who);
        activation.activate(address(based), tokenId, 0);
    }

    /// @dev A fresh NounLoans on a different $CHIP, with its own ChipActivation priced free
    ///      so the chip gate can be satisfied without the hostile token being involved in it.
    function _pairOn(address token) internal returns (NounLoans l2, ChipActivation a2) {
        a2 = new ChipActivation(multisig, token, [uint32(10_000), 12_500, 16_000, 20_000, 33_300]);
        vm.prank(multisig);
        a2.queueCosts(address(based), [uint256(0), 0, 0, 0, 0]);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        a2.executeCosts(address(based));

        l2 = new NounLoans(multisig, token, splitter, treasury, address(a2), _defaultTerms());
        vm.startPrank(multisig);
        l2.setMaxPrincipal(address(based), CAP);
        a2.setCustodian(address(l2), true);
        vm.stopPrank();
    }

    function _seedPool(uint256 amount) internal {
        chip.mint(multisig, amount);
        vm.startPrank(multisig);
        chip.approve(address(loans), amount);
        loans.depositPool(amount);
        vm.stopPrank();
    }

    function _borrow(address who, uint256 tokenId, uint8 term, uint256 principal) internal returns (uint256 loanId) {
        _mintAndChip(who, tokenId);
        vm.startPrank(who);
        based.approve(address(loans), tokenId);
        loanId = loans.borrow(address(based), tokenId, term, principal);
        vm.stopPrank();
    }

    /* ------------------------------- borrowing ------------------------------- */

    function test_borrowLocksTheNounAndPaysPrincipalMinusFee() public {
        uint256 before = chip.balanceOf(alice);
        uint256 poolBefore = loans.poolBalance();

        uint256 id = _borrow(alice, 1, 0, 1_000 ether); // 30d @ 2%

        assertEq(based.ownerOf(1), address(loans), "collateral held");
        assertEq(chip.balanceOf(alice) - before, 980 ether, "principal minus the fee");
        assertEq(chip.balanceOf(splitter), 20 ether, "fee routed to the FeeSplitter");
        assertEq(loans.poolBalance(), poolBefore - 1_000 ether, "the whole principal left the pool");

        NounLoans.Loan memory l = loans.getLoan(id);
        assertEq(l.borrower, alice);
        assertEq(l.principal, 1_000 ether);
        assertEq(l.feePaid, 20 ether);
        assertEq(l.dueAt, uint64(block.timestamp) + 30 days);
        assertFalse(l.closed);
        assertTrue(loans.isCollateral(address(based), 1));
    }

    function test_longerTermsCostMore() public {
        _borrow(alice, 1, 0, 1_000 ether);
        _borrow(alice, 2, 1, 1_000 ether);
        _borrow(alice, 3, 2, 1_000 ether);
        assertEq(chip.balanceOf(splitter), 20 ether + 50 ether + 90 ether);
    }

    function test_quoteMatchesWhatBorrowDoes() public {
        (uint256 fee, uint256 payout, uint64 dueAt) = loans.quote(1, 4_000 ether);
        assertEq(fee, 200 ether);
        assertEq(payout, 3_800 ether);

        uint256 before = chip.balanceOf(alice);
        uint256 id = _borrow(alice, 1, 1, 4_000 ether);
        assertEq(chip.balanceOf(alice) - before, payout);
        assertEq(loans.getLoan(id).dueAt, dueAt);
    }

    function test_repaymentIsPrincipalOnly() public {
        uint256 id = _borrow(alice, 1, 2, 1_000 ether); // 9% fee up front
        uint256 before = chip.balanceOf(alice);

        vm.prank(alice);
        loans.repay(id);

        assertEq(before - chip.balanceOf(alice), 1_000 ether, "principal, not principal plus fee");
        assertEq(based.ownerOf(1), alice, "Noun returned");
        assertTrue(loans.getLoan(id).closed);
        assertFalse(loans.isCollateral(address(based), 1));
    }

    /// @notice Net cost of a loan is exactly the fee, no matter the term.
    function test_theRoundTripCostsExactlyTheFee() public {
        uint256 before = chip.balanceOf(alice);
        uint256 id = _borrow(alice, 1, 1, 2_000 ether);
        vm.prank(alice);
        loans.repay(id);
        assertEq(before - chip.balanceOf(alice), 100 ether, "5% of 2,000, and nothing else");
    }

    function test_theCapIsEnforcedPerCollection() public {
        _mintAndChip(alice, 1);
        vm.startPrank(alice);
        based.approve(address(loans), 1);
        vm.expectRevert(abi.encodeWithSelector(NounLoans.PrincipalTooLarge.selector, CAP + 1, CAP));
        loans.borrow(address(based), 1, 0, CAP + 1);
        vm.stopPrank();
    }

    function test_anUnlendableCollectionIsRefused() public {
        MockNoun other = new MockNoun("Other", "OTH");
        other.mint(alice, 1);
        vm.startPrank(alice);
        other.approve(address(loans), 1);
        vm.expectRevert(abi.encodeWithSelector(NounLoans.CollectionNotLendable.selector, address(other)));
        loans.borrow(address(other), 1, 0, 100 ether);
        vm.stopPrank();
    }

    function test_cannotBorrowAgainstSomebodyElsesNoun() public {
        _mintAndChip(alice, 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(NounLoans.NotNounOwner.selector, address(based), 1, bob));
        loans.borrow(address(based), 1, 0, 100 ether);
    }

    /// @dev The open-loan guard fires before the ownership check, so the error names the
    ///      actual reason rather than the consequence of the Noun having moved.
    function test_cannotDoubleBorrowAgainstOneNoun() public {
        _borrow(alice, 1, 0, 100 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NounLoans.AlreadyCollateral.selector, address(based), 1));
        loans.borrow(address(based), 1, 0, 100 ether);
    }

    function test_borrowingBeyondThePoolIsRefused() public {
        uint256 drain = loans.poolBalance() - 500 ether;
        vm.prank(multisig);
        loans.withdrawPool(drain, multisig);

        _mintAndChip(alice, 1);
        vm.startPrank(alice);
        based.approve(address(loans), 1);
        vm.expectRevert(abi.encodeWithSelector(NounLoans.PoolTooSmall.selector, 1_000 ether, 500 ether));
        loans.borrow(address(based), 1, 0, 1_000 ether);
        vm.stopPrank();
    }

    function test_badTermAndZeroPrincipalAreRefused() public {
        _mintAndChip(alice, 1);
        vm.startPrank(alice);
        based.approve(address(loans), 1);
        vm.expectRevert(abi.encodeWithSelector(NounLoans.BadTerm.selector, 3));
        loans.borrow(address(based), 1, 3, 100 ether);
        vm.expectRevert(NounLoans.ZeroPrincipal.selector);
        loans.borrow(address(based), 1, 0, 0);
        vm.stopPrank();
    }

    /* ------------------------------- the chip gate --------------------------- */

    /// @notice Lending is a holder benefit. An unchipped Noun is refused, by name.
    function test_anUnchippedNounIsRefused() public {
        based.mint(alice, 1); // minted, never chipped

        vm.startPrank(alice);
        based.approve(address(loans), 1);
        vm.expectRevert(abi.encodeWithSelector(NounLoans.NotChipped.selector, address(based), 1));
        loans.borrow(address(based), 1, 0, 1_000 ether);
        vm.stopPrank();

        assertEq(based.ownerOf(1), alice, "nothing was taken");
        assertEq(loans.openLoanCount(), 0);
        assertFalse(loans.isChippedFor(address(based), 1, alice));
    }

    /// @notice A Noun chipped by someone ELSE does not let this caller borrow. Belt and
    ///         braces: `ownerOf` already gates it, but the two checks must agree.
    function test_aNounChippedByAnotherOwnerDoesNotLetYouBorrow() public {
        _mintAndChip(alice, 1);
        vm.prank(alice);
        based.transferFrom(alice, bob, 1); // sold; the chip is now void

        vm.startPrank(bob);
        based.approve(address(loans), 1);
        vm.expectRevert(abi.encodeWithSelector(NounLoans.NotChipped.selector, address(based), 1));
        loans.borrow(address(based), 1, 0, 1_000 ether);
        vm.stopPrank();
    }

    /// @notice A LAPSED chip is refused too — the gate reads live effective state, not a
    ///         "was once chipped" flag.
    function test_aLapsedChipIsRefused() public {
        _mintAndChip(alice, 1);
        assertTrue(loans.isChippedFor(address(based), 1, alice));

        // Sold and bought back by bob: the record still names alice, so it is void for him.
        vm.prank(alice);
        based.transferFrom(alice, bob, 1);
        assertFalse(loans.isChippedFor(address(based), 1, bob));

        vm.startPrank(bob);
        based.approve(address(loans), 1);
        vm.expectRevert(abi.encodeWithSelector(NounLoans.NotChipped.selector, address(based), 1));
        loans.borrow(address(based), 1, 0, 1_000 ether);
        vm.stopPrank();
    }

    function test_aChippedNounBorrowsNormally() public {
        _mintAndChip(alice, 1);
        assertTrue(loans.isChippedFor(address(based), 1, alice), "the site can see it will work");

        vm.startPrank(alice);
        based.approve(address(loans), 1);
        uint256 id = loans.borrow(address(based), 1, 0, 1_000 ether);
        vm.stopPrank();

        assertEq(loans.getLoan(id).borrower, alice);
        assertEq(based.ownerOf(1), address(loans));
    }

    /// @notice The gate is checked at borrow time and NEVER re-checked. A borrower cannot
    ///         lose their Noun over their chip, which would be a wildly disproportionate
    ///         penalty and would hand a liquidation trigger to whoever controls the vault.
    function test_theGateIsBorrowTimeOnlyAndCannotTriggerALiquidation() public {
        _mintAndChip(alice, 1);
        uint256 id = _borrowChipped(alice, 1, 0, 1_000 ether);

        // De-register the custodian: the chip reads inactive from ChipActivation's side.
        vm.prank(multisig);
        activation.setCustodian(address(loans), false);
        assertFalse(activation.isActive(address(based), 1), "the chip is now dark");

        // The loan is untouched: not liquidatable, and repayable exactly as before.
        assertFalse(loans.isLiquidatable(id));
        vm.prank(alice);
        loans.repay(id);
        assertEq(based.ownerOf(1), alice, "she gets her Noun back regardless");
    }

    /// @dev Borrow a Noun already minted and chipped by `who`.
    function _borrowChipped(address who, uint256 tokenId, uint8 term, uint256 principal)
        internal
        returns (uint256 loanId)
    {
        vm.startPrank(who);
        based.approve(address(loans), tokenId);
        loanId = loans.borrow(address(based), tokenId, term, principal);
        vm.stopPrank();
    }

    /* -------------------------- repay window & grace ------------------------- */

    function test_repayWorksThroughTheGracePeriod() public {
        uint256 id = _borrow(alice, 1, 0, 1_000 ether);
        vm.warp(block.timestamp + 30 days + 7 days); // exactly the deadline
        vm.prank(alice);
        loans.repay(id);
        assertEq(based.ownerOf(1), alice);
    }

    function test_repayIsRefusedOneSecondAfterGrace() public {
        uint256 id = _borrow(alice, 1, 0, 1_000 ether);
        uint64 deadline = loans.deadlineOf(id);
        vm.warp(deadline + 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NounLoans.RepayWindowOver.selector, id, deadline));
        loans.repay(id);
    }

    /// @notice Anyone may repay, and the Noun always goes back to the BORROWER.
    function test_anyoneCanRepayAndTheNounGoesToTheBorrower() public {
        uint256 id = _borrow(alice, 1, 0, 1_000 ether);

        vm.prank(bob); // a friend clears it
        loans.repay(id);

        assertEq(based.ownerOf(1), alice, "the borrower, not the payer");
        assertEq(chip.balanceOf(bob), 100_000 ether - 1_000 ether, "bob paid");
    }

    function test_cannotRepayTwice() public {
        uint256 id = _borrow(alice, 1, 0, 1_000 ether);
        vm.prank(alice);
        loans.repay(id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NounLoans.LoanClosed.selector, id));
        loans.repay(id);
    }

    /* ------------------------------ liquidation ------------------------------ */

    function test_liquidationIsPermissionlessAndPaysABounty() public {
        uint256 id = _borrow(alice, 1, 0, 1_000 ether);
        vm.warp(loans.deadlineOf(id) + 1);

        assertTrue(loans.isLiquidatable(id));

        vm.prank(liquidator);
        uint256 bounty = loans.liquidate(id);

        assertEq(bounty, 20 ether, "2% of principal");
        assertEq(chip.balanceOf(liquidator), 20 ether);
        assertEq(based.ownerOf(1), treasury, "collateral to the treasury");
        assertTrue(loans.getLoan(id).liquidated);
        assertFalse(loans.isCollateral(address(based), 1));
    }

    function test_liquidationBeforeTheDeadlineIsRefused() public {
        uint256 id = _borrow(alice, 1, 0, 1_000 ether);
        uint64 at = loans.deadlineOf(id);
        vm.warp(at); // exactly on it: still repayable, not yet liquidatable
        assertFalse(loans.isLiquidatable(id));

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(NounLoans.NotYetLiquidatable.selector, id, at));
        loans.liquidate(id);
    }

    function test_cannotLiquidateARepaidLoan() public {
        uint256 id = _borrow(alice, 1, 0, 1_000 ether);
        vm.prank(alice);
        loans.repay(id);
        vm.warp(block.timestamp + 400 days);

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(NounLoans.LoanClosed.selector, id));
        loans.liquidate(id);
    }

    /// @notice Collateral must be recoverable even when the pool cannot pay a bounty.
    function test_anEmptyPoolStillLiquidates() public {
        uint256 id = _borrow(alice, 1, 0, 1_000 ether);
        uint256 all = loans.poolBalance();
        vm.prank(multisig);
        loans.withdrawPool(all, multisig);

        vm.warp(loans.deadlineOf(id) + 1);
        vm.prank(liquidator);
        uint256 bounty = loans.liquidate(id);

        assertEq(bounty, 0, "no money for a bounty");
        assertEq(based.ownerOf(1), treasury, "but the collateral still moves");
    }

    /* ------------------------------ the pool --------------------------------- */

    function test_poolAccountingSurvivesAFullCycle() public {
        uint256 start = loans.poolBalance();
        uint256 id = _borrow(alice, 1, 1, 2_000 ether);
        assertEq(loans.poolBalance(), start - 2_000 ether);

        vm.prank(alice);
        loans.repay(id);
        assertEq(loans.poolBalance(), start, "principal back; the fee was never the pool's");
        assertEq(chip.balanceOf(address(loans)), loans.poolBalance(), "held equals accounted");
    }

    function test_poolIsMultisigOnly() public {
        vm.prank(alice);
        vm.expectRevert();
        loans.depositPool(1 ether);
        vm.prank(alice);
        vm.expectRevert();
        loans.withdrawPool(1 ether, alice);
    }

    function test_cannotWithdrawMoreThanThePoolHolds() public {
        uint256 bal = loans.poolBalance();
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(NounLoans.PoolTooSmall.selector, bal + 1, bal));
        loans.withdrawPool(bal + 1, multisig);
    }

    /// @notice Principal out on loan is not in the pool and cannot be withdrawn.
    function test_outstandingPrincipalIsNotWithdrawable() public {
        uint256 start = loans.poolBalance();
        _borrow(alice, 1, 0, 5_000 ether);

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(NounLoans.PoolTooSmall.selector, start, start - 5_000 ether));
        loans.withdrawPool(start, multisig);
    }

    /* --------------------------------- pause --------------------------------- */

    function test_pauseStopsNewBorrowingOnly() public {
        uint256 id = _borrow(alice, 1, 0, 1_000 ether);

        vm.prank(multisig);
        loans.setBorrowingPaused(true);

        _mintAndChip(bob, 2);
        vm.startPrank(bob);
        based.approve(address(loans), 2);
        vm.expectRevert(NounLoans.BorrowingIsPaused.selector);
        loans.borrow(address(based), 2, 0, 100 ether);
        vm.stopPrank();

        // Repay still works, always.
        vm.prank(alice);
        loans.repay(id);
        assertEq(based.ownerOf(1), alice);
    }

    function test_pauseDoesNotBlockLiquidation() public {
        uint256 id = _borrow(alice, 1, 0, 1_000 ether);
        vm.prank(multisig);
        loans.setBorrowingPaused(true);
        vm.warp(loans.deadlineOf(id) + 1);

        vm.prank(liquidator);
        loans.liquidate(id);
        assertEq(based.ownerOf(1), treasury);
    }

    /* ------------------------------ terms config ----------------------------- */

    function test_termsRequireTheFullFortyEightHours() public {
        NounLoans.Terms memory t = _defaultTerms();
        t.feeBps = [uint32(300), 600, 1_000];

        vm.prank(multisig);
        loans.queueTerms(t);

        vm.warp(block.timestamp + 48 hours - 1);
        vm.prank(multisig);
        vm.expectRevert();
        loans.executeTerms();

        vm.warp(block.timestamp + 1);
        vm.prank(multisig);
        loans.executeTerms();
        (uint256 fee,,) = loans.quote(0, 1_000 ether);
        assertEq(fee, 30 ether);
    }

    /// @notice A live loan is a constant. Re-pricing never reaches it.
    function test_aTermsChangeDoesNotTouchALiveLoan() public {
        uint256 id = _borrow(alice, 1, 0, 1_000 ether);
        uint64 dueBefore = loans.getLoan(id).dueAt;

        NounLoans.Terms memory t = _defaultTerms();
        t.length = [uint64(1 days), 2 days, 3 days];
        t.feeBps = [uint32(5_000), 5_000, 5_000];
        vm.prank(multisig);
        loans.queueTerms(t);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        loans.executeTerms();

        NounLoans.Loan memory l = loans.getLoan(id);
        assertEq(l.principal, 1_000 ether, "unchanged");
        assertEq(l.feePaid, 20 ether, "unchanged");
        assertEq(l.dueAt, dueBefore, "unchanged");

        uint256 before = chip.balanceOf(alice);
        vm.prank(alice);
        loans.repay(id);
        assertEq(before - chip.balanceOf(alice), 1_000 ether, "still principal only");
    }

    function test_termsCeilingsAreEnforced() public {
        NounLoans.Terms memory t = _defaultTerms();
        t.feeBps = [uint32(200), 500, 5_001]; // over MAX_FEE_BPS
        vm.prank(multisig);
        vm.expectRevert(NounLoans.BadConfig.selector);
        loans.queueTerms(t);

        t = _defaultTerms();
        t.bountyBps = 1_001; // over MAX_BOUNTY_BPS
        vm.prank(multisig);
        vm.expectRevert(NounLoans.BadConfig.selector);
        loans.queueTerms(t);

        t = _defaultTerms();
        t.length = [uint64(90 days), 30 days, 180 days]; // not increasing
        vm.prank(multisig);
        vm.expectRevert(NounLoans.BadConfig.selector);
        loans.queueTerms(t);

        t = _defaultTerms();
        t.feeBps = [uint32(900), 500, 200]; // inverted fee curve
        vm.prank(multisig);
        vm.expectRevert(NounLoans.BadConfig.selector);
        loans.queueTerms(t);
    }

    function test_queuedTermsCanBeCancelled() public {
        vm.prank(multisig);
        loans.queueTerms(_defaultTerms());
        vm.prank(multisig);
        loans.cancelTerms();
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        vm.expectRevert(NounLoans.NothingQueued.selector);
        loans.executeTerms();
    }

    function test_configIsMultisigOnly() public {
        vm.startPrank(alice);
        vm.expectRevert();
        loans.setMaxPrincipal(address(based), 1);
        vm.expectRevert();
        loans.setBorrowingPaused(true);
        vm.expectRevert();
        loans.setTreasury(alice);
        vm.expectRevert();
        loans.setFeeSplitter(alice);
        vm.expectRevert();
        loans.queueTerms(_defaultTerms());
        vm.stopPrank();
    }

    /* ------------------------------ beneficiaryOf ---------------------------- */

    function test_beneficiaryIsTheBorrowerWhileOpenAndNobodyAfter() public {
        assertEq(loans.beneficiaryOf(address(based), 1), address(0), "before");

        uint256 id = _borrow(alice, 1, 0, 1_000 ether);
        assertEq(loans.beneficiaryOf(address(based), 1), alice, "while open");

        vm.prank(alice);
        loans.repay(id);
        assertEq(loans.beneficiaryOf(address(based), 1), address(0), "after repay");
    }

    function test_beneficiaryEndsAtLiquidation() public {
        uint256 id = _borrow(alice, 1, 0, 1_000 ether);
        vm.warp(loans.deadlineOf(id) + 1);
        vm.prank(liquidator);
        loans.liquidate(id);
        assertEq(loans.beneficiaryOf(address(based), 1), address(0));
    }

    /// @notice It never speaks for a token it is not holding under an open loan.
    function test_beneficiaryIsZeroForTokensItDoesNotHold() public {
        _borrow(alice, 1, 0, 1_000 ether);
        assertEq(loans.beneficiaryOf(address(based), 2), address(0), "another token");
        assertEq(loans.beneficiaryOf(address(dark), 1), address(0), "another collection");
        assertEq(loans.beneficiaryOf(makeAddr("random"), 1), address(0), "an unrelated address");
    }

    /* -------------------------------- rescue --------------------------------- */

    /// @notice The rescue can never reach the lending pool.
    function test_recoverExcessCannotTouchThePool() public {
        uint256 pool = loans.poolBalance();
        chip.mint(address(loans), 7 ether); // a stray donation on top

        vm.prank(multisig);
        loans.recoverExcess(address(chip), multisig);

        assertEq(chip.balanceOf(multisig), 7 ether, "only the surplus moved");
        assertEq(loans.poolBalance(), pool, "pool untouched");
        assertEq(chip.balanceOf(address(loans)), pool, "and still fully backed");
    }

    function test_recoverExcessMovesNothingWhenThereIsNoSurplus() public {
        uint256 pool = loans.poolBalance();
        vm.prank(multisig);
        loans.recoverExcess(address(chip), multisig);
        assertEq(chip.balanceOf(multisig), 0);
        assertEq(chip.balanceOf(address(loans)), pool);
    }

    function test_recoverExcessSweepsAnUnrelatedTokenWhole() public {
        MockERC20 junk = new MockERC20("Junk", "JNK", 18);
        junk.mint(address(loans), 42 ether);
        vm.prank(multisig);
        loans.recoverExcess(address(junk), multisig);
        assertEq(junk.balanceOf(multisig), 42 ether);
    }

    /// @notice The multisig has no third path to a borrower's Noun.
    function test_recoverNFTCannotTakeLiveCollateral() public {
        _borrow(alice, 1, 0, 1_000 ether);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(NounLoans.IsLiveCollateral.selector, address(based), 1));
        loans.recoverNFT(address(based), 1, multisig);
        assertEq(based.ownerOf(1), address(loans));
    }

    function test_recoverNFTReturnsAStrayNoun() public {
        based.mint(bob, 9);
        vm.prank(bob);
        based.transferFrom(bob, address(loans), 9); // pushed in, no loan

        assertEq(loans.beneficiaryOf(address(based), 9), address(0), "collateral for nothing");

        vm.prank(multisig);
        loans.recoverNFT(address(based), 9, bob);
        assertEq(based.ownerOf(9), bob);
    }

    function test_rescueIsMultisigOnly() public {
        vm.startPrank(alice);
        vm.expectRevert();
        loans.recoverExcess(address(chip), alice);
        vm.expectRevert();
        loans.recoverNFT(address(based), 1, alice);
        vm.stopPrank();
    }

    /* --------------------------- hostile $CHIP ------------------------------- */

    /// @notice A $CHIP that reports a repayment it did not make must not free the Noun.
    function test_aLyingChipCannotFreeANoun() public {
        LyingToken liar = new LyingToken("Chipworks", "CHIP", 18);
        (NounLoans l2, ChipActivation a2) = _pairOn(address(liar));

        liar.mint(multisig, 50_000 ether);
        vm.startPrank(multisig);
        liar.approve(address(l2), 50_000 ether);
        l2.depositPool(50_000 ether);
        vm.stopPrank();

        based.mint(alice, 1);
        vm.startPrank(alice);
        a2.activate(address(based), 1, 0);
        based.approve(address(l2), 1);
        liar.approve(address(l2), type(uint256).max);
        uint256 id = l2.borrow(address(based), 1, 0, 1_000 ether);
        vm.stopPrank();

        liar.setLying(true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NounLoans.ChipShortfall.selector, 0, 1_000 ether));
        l2.repay(id);

        assertEq(based.ownerOf(1), address(l2), "the Noun stayed put");
        assertFalse(l2.getLoan(id).closed);
    }

    /// @notice And it cannot inflate the pool either.
    function test_aLyingChipCannotInflateThePool() public {
        LyingToken liar = new LyingToken("Chipworks", "CHIP", 18);
        (NounLoans l2,) = _pairOn(address(liar));

        liar.mint(multisig, 1_000 ether);
        vm.startPrank(multisig);
        liar.approve(address(l2), type(uint256).max);
        liar.setLying(true);
        vm.expectRevert(abi.encodeWithSelector(NounLoans.ChipShortfall.selector, 0, 1_000 ether));
        l2.depositPool(1_000 ether);
        vm.stopPrank();

        assertEq(l2.poolBalance(), 0);
    }

    function test_aPausedChipBlocksBorrowingWithoutLosingTheNoun() public {
        PausableToken pt = new PausableToken("Chipworks", "CHIP", 18);
        (NounLoans l2, ChipActivation a2) = _pairOn(address(pt));

        pt.mint(multisig, 50_000 ether);
        vm.startPrank(multisig);
        pt.approve(address(l2), 50_000 ether);
        l2.depositPool(50_000 ether);
        vm.stopPrank();

        based.mint(alice, 1);
        vm.prank(alice);
        a2.activate(address(based), 1, 0); // free, so the pause does not block chipping

        pt.setPaused(true);
        vm.startPrank(alice);
        based.approve(address(l2), 1);
        vm.expectRevert();
        l2.borrow(address(based), 1, 0, 1_000 ether);
        vm.stopPrank();

        assertEq(based.ownerOf(1), alice, "nothing was taken");
        assertFalse(l2.isCollateral(address(based), 1));
    }

    /* ---------------------------------- fuzz --------------------------------- */

    /// @notice Whatever the principal and term, the borrower nets exactly the fee and the
    ///         pool ends a full cycle exactly where it started.
    function testFuzz_aFullCycleIsFeeOnlyAndPoolNeutral(uint256 principalSeed, uint8 termSeed) public {
        uint256 principal = bound(principalSeed, 1, CAP);
        uint8 term = uint8(bound(termSeed, 0, 2));

        uint256 poolStart = loans.poolBalance();
        uint256 aliceStart = chip.balanceOf(alice);
        (uint256 fee,,) = loans.quote(term, principal);

        uint256 id = _borrow(alice, 1, term, principal);
        vm.prank(alice);
        loans.repay(id);

        assertEq(aliceStart - chip.balanceOf(alice), fee, "net cost is exactly the fee");
        assertEq(loans.poolBalance(), poolStart, "pool neutral");
        assertEq(chip.balanceOf(address(loans)), loans.poolBalance(), "held equals accounted");
        assertEq(based.ownerOf(1), alice);
    }

    /// @notice The pool's accounted balance is never more than the $CHIP it actually holds.
    function testFuzz_thePoolIsAlwaysFullyBacked(uint256 principalSeed, uint8 termSeed, bool liquidateIt) public {
        uint256 principal = bound(principalSeed, 1, CAP);
        uint8 term = uint8(bound(termSeed, 0, 2));

        uint256 id = _borrow(alice, 1, term, principal);
        assertLe(loans.poolBalance(), chip.balanceOf(address(loans)));

        if (liquidateIt) {
            vm.warp(loans.deadlineOf(id) + 1);
            vm.prank(liquidator);
            loans.liquidate(id);
        } else {
            vm.prank(alice);
            loans.repay(id);
        }
        assertLe(loans.poolBalance(), chip.balanceOf(address(loans)), "never over-counted");
    }
}
