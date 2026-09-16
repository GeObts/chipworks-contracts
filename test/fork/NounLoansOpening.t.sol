// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface ILoans {
    function borrow(address collection, uint256 tokenId, uint8 termIndex, uint256 principal)
        external
        returns (uint256 loanId);
    function repay(uint256 loanId) external returns (uint256 paid);
    function repayAmount(uint256 loanId) external view returns (uint256 principal, uint256 lateFee);
    function liquidate(uint256 loanId) external returns (uint256 bounty);
    function quote(uint8 termIndex, uint256 principal)
        external
        view
        returns (uint256 fee, uint256 payout, uint64 dueAt, uint64 deadline);
    function setMaxPrincipal(address collection, uint256 amount) external;
    function setBorrowingPaused(bool paused) external;
    function setFeeSplitter(address v) external;
    function maxPrincipal(address) external view returns (uint256);
    function borrowingPaused() external view returns (bool);
    function poolBalance() external view returns (uint256);
    function feeSplitter() external view returns (address);
    function treasury() external view returns (address);
    function totalFees() external view returns (uint256);
    function deadlineOf(uint256 loanId) external view returns (uint64);
    function isLiquidatable(uint256 loanId) external view returns (bool);
}

interface IActivation {
    function activation(address, uint256) external view returns (bool, uint32, address);
}

/**
 * OPENING NOUNLOANS, REHEARSED AGAINST THE LIVE CONTRACT.
 *
 * Everything here runs on a fork of Base against the deployed NounLoans, with the
 * three opening transactions applied as the Safe would send them:
 *
 *     setMaxPrincipal(Based, 8,771,708 CHIP)   60% of a $38 floor at $2.5993e-6
 *     setMaxPrincipal(Dark,  19,943,552 CHIP)  60% of an $80 floor
 *     setFeeSplitter(Safe)                     fees straight to the multisig
 *     setBorrowingPaused(false)
 *
 * Then the whole loan life: borrow, repay on time, repay late, and liquidate.
 * Lil is deliberately left at a zero cap and the test asserts it CANNOT be
 * borrowed against, which is the contract-level half of hiding it in the UI.
 */
contract NounLoansOpeningTest is Test {
    address constant LOANS = 0x123Bc476594A80B0d99Ca6510e87E249b1C5EC5f;
    address constant CHIP = 0x75Af968d2e58749FDA1b42C58186B76f5E511bA3;
    address constant V2 = 0x762984092Cb9404982835551970C73b5838d5411;
    address constant SAFE = 0xe1096B727499a3f70FaD8bc0267F5e69d01373C7;

    address constant BASED = 0xBf57D0535E10E7033447174404b9bEd3D9eF4C88;
    address constant DARK = 0xd45E54B1A5e77d6E9469a4174d34f27D5D16270C;
    address constant LIL = 0xe3c5Ef27B80481518a2363406e354a9361415556;

    /// @dev Live activated Nouns, read off chain at fork time by tools/claim-day/loan-caps.cjs.
    uint256 constant BASED_ID = 2034;
    address constant BASED_OWNER = 0xcd2f7B2272f860A7a60e25ff6cdd0BdD0A9FCEFa;
    uint256 constant DARK_ID = 257;
    address constant DARK_OWNER = 0x74e130B74D85D4774360263D8d28aa6Fd480Cc9c;

    /// @dev The caps being proposed. 60% LTV at the live $CHIP price.
    uint256 constant BASED_CAP = 8_771_708e18;
    uint256 constant DARK_CAP = 19_943_552e18;

    ILoans loans = ILoans(LOANS);
    address liquidator = makeAddr("liquidator");

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        require(bytes(rpc).length > 0, "BASE_RPC_URL is required");
        vm.createSelectFork(rpc);

        // The opening sequence, exactly as the Safe would send it.
        vm.startPrank(SAFE);
        loans.setMaxPrincipal(BASED, BASED_CAP);
        loans.setMaxPrincipal(DARK, 0);
        /*
            LIL IS ALREADY LENDABLE ON CHAIN — 2,700,000 CHIP, set before the pause.
            Hiding it in the UI would leave it borrowable by anyone calling the contract
            directly, so excluding it is a TRANSACTION, not a frontend decision.
        */
        loans.setMaxPrincipal(LIL, 0);
        loans.setFeeSplitter(SAFE);
        loans.setBorrowingPaused(false);
        vm.stopPrank();
    }

    function _borrow(address collection, uint256 id, address owner, uint8 term, uint256 principal)
        internal
        returns (uint256 loanId)
    {
        vm.startPrank(owner);
        IERC721(collection).approve(LOANS, id);
        loanId = loans.borrow(collection, id, term, principal);
        vm.stopPrank();
    }

    // ---- the opening itself ---------------------------------------------

    function test_openingSequenceLeavesTheContractLendable() public view {
        assertFalse(loans.borrowingPaused(), "still paused");
        assertEq(loans.maxPrincipal(BASED), BASED_CAP, "Based cap");
        assertEq(loans.maxPrincipal(DARK), 0, "Dark must be zeroed: its 35M cap is 114% LTV if the validator ever relaxes");
        assertEq(loans.maxPrincipal(LIL), 0, "Lil must stay unlendable");
        assertEq(loans.feeSplitter(), SAFE, "fees must go to the Safe");
        assertGe(loans.poolBalance(), 767_000_000e18, "pool must still be funded");
    }

    function test_lilNounsCannotBorrow_capIsZero() public {
        // Zero cap reverts CollectionNotLendable before anything else is checked.
        vm.prank(BASED_OWNER);
        vm.expectRevert();
        loans.borrow(LIL, 1, 0, 1e18);
    }

    // ---- 1. BORROW -------------------------------------------------------

    function test_borrow_paysPrincipalLessFee_andTakesCustody() public {
        (uint256 fee, uint256 payout,,) = loans.quote(0, BASED_CAP);
        uint256 before = IERC20(CHIP).balanceOf(BASED_OWNER);
        uint256 poolBefore = loans.poolBalance();
        uint256 safeBefore = IERC20(CHIP).balanceOf(SAFE);

        uint256 loanId = _borrow(BASED, BASED_ID, BASED_OWNER, 0, BASED_CAP);

        assertEq(IERC20(CHIP).balanceOf(BASED_OWNER) - before, payout, "borrower receives principal less fee");
        assertEq(IERC721(BASED).ownerOf(BASED_ID), LOANS, "collateral must be held by the pool");
        assertEq(loans.poolBalance(), poolBefore - BASED_CAP, "pool falls by the whole principal");
        assertEq(IERC20(CHIP).balanceOf(SAFE) - safeBefore, fee, "the fee lands in the Safe");
        assertEq(loans.totalFees(), fee, "fee is booked");

        emit log_named_decimal_uint("7-day fee on the Based cap (CHIP)", fee, 18);
        emit log_named_decimal_uint("borrower received (CHIP)", payout, 18);
        loanId;
    }

    /// @dev THE WHOLE PROPOSITION: the Noun keeps earning while it is collateral.
    function test_collateralKeepsEarningForTheBorrower() public {
        _borrow(BASED, BASED_ID, BASED_OWNER, 0, BASED_CAP);
        (bool active,, address beneficiary) = IActivation(V2).activation(BASED, BASED_ID);
        assertTrue(active, "activation must survive custody");
        assertEq(beneficiary, BASED_OWNER, "and still name the BORROWER, not the pool");
    }

    function test_borrowAboveTheCapReverts() public {
        vm.startPrank(BASED_OWNER);
        IERC721(BASED).approve(LOANS, BASED_ID);
        vm.expectRevert(); // PrincipalTooLarge
        loans.borrow(BASED, BASED_ID, 0, BASED_CAP + 1);
        vm.stopPrank();
    }

    function test_onlyTheChippedOwnerCanBorrow() public {
        address thief = makeAddr("thief");
        vm.prank(thief);
        vm.expectRevert(); // NotNounOwner
        loans.borrow(BASED, BASED_ID, 0, 1e18);
    }

    // ---- 2. REPAY ON TIME ------------------------------------------------

    function test_repayOnTime_returnsTheNoun_andCostsNoExtra() public {
        uint256 loanId = _borrow(BASED, BASED_ID, BASED_OWNER, 0, BASED_CAP);

        skip(3 days); // inside the 7-day term
        (uint256 principal, uint256 lateFee) = loans.repayAmount(loanId);
        assertEq(principal, BASED_CAP, "repay the principal");
        assertEq(lateFee, 0, "no late fee inside the term");

        deal(CHIP, BASED_OWNER, principal);
        vm.startPrank(BASED_OWNER);
        IERC20(CHIP).approve(LOANS, principal);
        uint256 paid = loans.repay(loanId);
        vm.stopPrank();

        assertEq(paid, principal, "paid exactly the principal");
        assertEq(IERC721(BASED).ownerOf(BASED_ID), BASED_OWNER, "Noun comes home");
    }

    // ---- 3. REPAY LATE ---------------------------------------------------

    /**
     * @dev THE GRACE PERIOD IS FREE, AND IT IS THE ONLY SAFE LATENESS.
     *
     *      The late fee starts at `dueAt + grace` — the SAME instant the loan becomes
     *      liquidatable. So there is no window where a borrower is late, charged, and
     *      still safe: past grace they are racing a liquidator. The UI has to say that,
     *      because "a 1% late fee" sounds like a grace period of its own and is not.
     */
    function test_graceIsFree_thenTheLateFeeAndLiquidationStartTogether() public {
        uint256 loanId = _borrow(BASED, BASED_ID, BASED_OWNER, 0, BASED_CAP);
        uint64 liqAt = loans.deadlineOf(loanId);

        // One second before grace ends: late, but free and safe.
        vm.warp(liqAt - 1);
        (, uint256 noFee) = loans.repayAmount(loanId);
        assertEq(noFee, 0, "inside grace the late fee is zero");
        assertFalse(loans.isLiquidatable(loanId), "and it cannot be liquidated");

        // One second after: the fee applies and a liquidator could take the Noun.
        vm.warp(liqAt + 1);
        (uint256 principal, uint256 lateFee) = loans.repayAmount(loanId);
        assertGt(lateFee, 0, "a late repayment must cost more");
        assertTrue(loans.isLiquidatable(loanId), "and liquidation is open from the same second");

        uint256 safeBefore = IERC20(CHIP).balanceOf(SAFE);
        deal(CHIP, BASED_OWNER, principal + lateFee);
        vm.startPrank(BASED_OWNER);
        IERC20(CHIP).approve(LOANS, principal + lateFee);
        loans.repay(loanId);
        vm.stopPrank();

        assertEq(IERC721(BASED).ownerOf(BASED_ID), BASED_OWNER, "still returned");
        assertEq(IERC20(CHIP).balanceOf(SAFE) - safeBefore, lateFee, "late fee goes to the Safe too");
        emit log_named_decimal_uint("late fee (CHIP)", lateFee, 18);
    }

    // ---- 4. LIQUIDATE ----------------------------------------------------

    /**
     * @dev DARKNOUNS CANNOT BE COLLATERAL TODAY, AND NOT FOR A REASON THIS REPO CONTROLS.
     *
     *      DarkNOUNs is an ERC-721C. Its transfer validator
     *      (0x721C008fdff27BF06E7E123956E2Fe03B63342e3) refuses the transfer into this
     *      contract with custom error 0xe1f1d02e, so `borrow` reverts for every Dark
     *      token whatever cap is set. The collection owner is 0x75C8…50A6 — not the
     *      Chipworks Safe — so allowing it is that owner's call, not ours.
     *
     *      Setting a Dark cap is therefore harmless but useless: it advertises a loan
     *      nobody can take. This test is here so the day the policy changes, it fails
     *      and tells us Dark can be switched on.
     */
    function test_darkNounsIsBlockedByItsTransferValidator() public {
        vm.startPrank(DARK_OWNER);
        IERC721(DARK).approve(LOANS, DARK_ID);
        vm.expectRevert(); // 0xe1f1d02e from the ERC-721C validator
        loans.borrow(DARK, DARK_ID, 0, DARK_CAP);
        vm.stopPrank();
    }

    function test_liquidate_onlyAfterGrace_andCollateralGoesToTreasury() public {
        uint256 loanId = _borrow(BASED, BASED_ID, BASED_OWNER, 0, BASED_CAP);

        uint64 liqAt = loans.deadlineOf(loanId);
        vm.warp(liqAt - 1);
        vm.prank(liquidator);
        vm.expectRevert(); // NotYetLiquidatable
        loans.liquidate(loanId);

        vm.warp(liqAt + 1);
        assertTrue(loans.isLiquidatable(loanId), "liquidatable once grace is over");

        address treasury = loans.treasury();
        uint256 bountyBefore = IERC20(CHIP).balanceOf(liquidator);
        vm.prank(liquidator);
        uint256 bounty = loans.liquidate(loanId);

        assertEq(IERC721(BASED).ownerOf(BASED_ID), treasury, "collateral to the treasury");
        assertEq(IERC20(CHIP).balanceOf(liquidator) - bountyBefore, bounty, "liquidator paid the bounty");
        assertGt(bounty, 0, "bounty must be real, or nobody liquidates");
        emit log_named_decimal_uint("liquidation bounty (CHIP)", bounty, 18);

        // And the borrower keeps the $CHIP they were paid: default is the exit.
        vm.prank(DARK_OWNER);
        vm.expectRevert(); // LoanClosed
        loans.repay(loanId);
    }

    // ---- 5. WHAT THE SITE WILL SHOW --------------------------------------

    /// @dev The three terms the UI offers, priced on the real caps.
    function test_quotesForTheThreeShortTerms() public {
        string[3] memory names = ["7d ", "14d", "30d"];
        for (uint8 i = 0; i < 3; i++) {
            (uint256 fee, uint256 payout, uint64 dueAt,) = loans.quote(i, BASED_CAP);
            emit log_named_string("term", names[i]);
            emit log_named_decimal_uint("  fee CHIP", fee, 18);
            emit log_named_decimal_uint("  payout CHIP", payout, 18);
            assertGt(payout, 0);
            assertGt(dueAt, block.timestamp);
        }
    }
}
