// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChipRewardsBase} from "../ChipRewardsBase.t.sol";
import {ChipActivation} from "../../src/activation/ChipActivation.sol";
import {NounLoans} from "../../src/loans/NounLoans.sol";

/// @title NounLoansIntegrationTest
/// @notice THE PRODUCT RULE, END TO END: collateral keeps earning, for the borrower.
///
/// @dev The full stack — ChipRounds, ChipClaims, Pot, StockRegistry — with `ChipActivation`
///      as the activation source and `NounLoans` registered as a custodian. Neither
///      ChipRounds nor ChipClaims knows that lending exists; the entire mechanism is one
///      `beneficiaryOf` call inside `ChipActivation._effectiveOwner`.
///
///      The matrix, one test each: chip then borrow, borrow then chip, upgrade while
///      collateralised, repay, liquidate, liquidate mid-round, and re-picking a split from
///      inside the vault.
contract NounLoansIntegrationTest is ChipRewardsBase {
    ChipActivation internal activation;
    NounLoans internal loans;

    address internal loanTreasury = makeAddr("loanTreasury");
    address internal feeSplitterAddr = makeAddr("feeSplitter");

    uint32[5] internal TIER_TABLE = [uint32(10_000), 12_500, 16_000, 20_000, 33_300];
    uint256[5] internal COST_TABLE = [uint256(100 ether), 250 ether, 600 ether, 1_200 ether, 4_000 ether];

    uint256 internal constant CAP = 10_000 ether;

    function setUp() public override {
        super.setUp();

        activation = new ChipActivation(multisig, address(chip), TIER_TABLE);
        _price(address(basedNouns));
        _price(address(darkNouns));

        NounLoans.Terms memory t;
        t.length = [uint64(30 days), 90 days, 180 days];
        t.feeBps = [uint32(200), 500, 900];
        t.bountyBps = 200;
        loans = new NounLoans(multisig, address(chip), feeSplitterAddr, loanTreasury, t);

        vm.startPrank(multisig);
        rounds.setActivationSource(address(activation));
        activation.setCustodian(address(loans), true);
        loans.setMaxPrincipal(address(basedNouns), CAP);
        loans.setMaxPrincipal(address(darkNouns), CAP);
        vm.stopPrank();

        // Seed the lending pool.
        chip.mint(multisig, 500_000 ether);
        vm.startPrank(multisig);
        chip.approve(address(loans), 500_000 ether);
        loans.depositPool(500_000 ether);
        vm.stopPrank();

        address[3] memory who = [alice, bob, carol];
        for (uint256 i; i < who.length; ++i) {
            chip.mint(who[i], 1_000_000 ether);
            vm.startPrank(who[i]);
            chip.approve(address(activation), type(uint256).max);
            chip.approve(address(loans), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _price(address collection) internal {
        vm.prank(multisig);
        activation.queueCosts(collection, COST_TABLE);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        activation.executeCosts(collection);
    }

    function _mintAndChip(address owner, uint256 tokenId, uint8 tier) internal {
        basedNouns.mint(owner, tokenId);
        vm.prank(owner);
        activation.activate(address(basedNouns), tokenId, tier);
    }

    function _deposit(address owner, uint256 tokenId, uint8 term, uint256 principal) internal returns (uint256) {
        vm.startPrank(owner);
        basedNouns.approve(address(loans), tokenId);
        uint256 id = loans.borrow(address(basedNouns), tokenId, term, principal);
        vm.stopPrank();
        return id;
    }

    /* ------------------------------------------------------------------ */
    /*                        THE HEADLINE SCENARIO                         */
    /* ------------------------------------------------------------------ */

    /// @notice A full round paying a borrower whose Noun sits in the loan vault.
    function test_aFullRoundPaysTheBorrowerWhileTheNounIsCollateral() public {
        _mintAndChip(alice, 1, 2); // 1.60x
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));

        uint256 payoutBefore = chip.balanceOf(alice);
        _deposit(alice, 1, 0, 1_000 ether);

        assertEq(basedNouns.ownerOf(1), address(loans), "the Noun really is locked away");
        assertEq(chip.balanceOf(alice) - payoutBefore, 980 ether, "and she got the loan");

        _fundPot(1_000e6);
        uint256 id = _openAndAccumulate(_ids(1));
        assertEq(rounds.getRound(id).totalWeight, 16_000, "tier 2 survived the deposit");

        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);

        assertEq(claims.claimable(id, address(nvda), alice), 5e8, "the borrower earns");
        assertEq(claims.claimable(id, address(nvda), address(loans)), 0, "the vault does not");

        _openClaimWindow();
        vm.prank(alice);
        claims.claim(id, address(nvda));
        assertEq(nvda.balanceOf(alice), 5e8);
    }

    /// @notice And the other order: deposit first, chip from inside the vault.
    function test_aBorrowerCanChipFromInsideTheVault() public {
        basedNouns.mint(alice, 1);
        _deposit(alice, 1, 1, 2_000 ether);

        vm.startPrank(alice);
        activation.activate(address(basedNouns), 1, 3); // 2.00x, Noun is in the vault
        rounds.setSplit(address(basedNouns), 1, _one(address(nvda)), _one(uint8(100)));
        vm.stopPrank();

        _fundPot(1_000e6);
        uint256 id = _openAndAccumulate(_ids(1));
        assertEq(rounds.getRound(id).totalWeight, 20_000);

        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);
        assertEq(claims.claimable(id, address(nvda), alice), 5e8);
    }

    /// @notice Upgrading a tier while collateralised.
    function test_aBorrowerCanUpgradeWhileCollateralised() public {
        _mintAndChip(alice, 1, 0); // 1.00x
        _deposit(alice, 1, 0, 1_000 ether);

        vm.prank(alice);
        activation.upgrade(address(basedNouns), 1, 4); // 3.33x

        _fundPot(1_000e6);
        uint256 id = _openAndAccumulate(_ids(1));
        assertEq(rounds.getRound(id).totalWeight, 33_300, "upgraded from inside the vault");
    }

    /// @notice Re-picking a split from inside the vault. This is why `setSplit` authorises
    ///         against the effective owner rather than `ownerOf` — the loan vault holds the
    ///         Noun and could never use that right.
    function test_aBorrowerCanRepickTheirSplitWhileCollateralised() public {
        _mintAndChip(alice, 1, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        _deposit(alice, 1, 0, 1_000 ether);

        // Change of mind, from inside the vault. The first change costs $CHIP.
        vm.startPrank(alice);
        chip.approve(address(rounds), type(uint256).max);
        rounds.setSplit(address(basedNouns), 1, _one(address(googl)), _one(uint8(100)));
        vm.stopPrank();

        _fundPot(1_000e6);
        uint256 id = _openAndAccumulate(_ids(1));
        rounds.settleStock(id, address(googl));
        rounds.finalizeRound(id);

        assertEq(claims.claimable(id, address(googl), alice), 2.5e8, "$1,000 of GOOGL at $400");
        assertEq(claims.acquired(id, address(nvda)), 0, "nothing went to the old pick");
    }

    /// @notice The loan vault itself cannot re-pick a borrower's split.
    function test_theVaultCannotRepickABorrowersSplit() public {
        _mintAndChip(alice, 1, 0);
        _deposit(alice, 1, 0, 1_000 ether);

        vm.prank(address(loans));
        vm.expectRevert();
        rounds.setSplit(address(basedNouns), 1, _one(address(nvda)), _one(uint8(100)));
    }

    /* ------------------------------------------------------------------ */
    /*                         REPAY AND LIQUIDATE                          */
    /* ------------------------------------------------------------------ */

    function test_repayChangesNothingAboutTheActivation() public {
        _mintAndChip(alice, 1, 3);
        uint256 loanId = _deposit(alice, 1, 0, 1_000 ether);

        (bool activeIn, uint32 bpsIn, address ownerIn) = activation.activation(address(basedNouns), 1);
        vm.prank(alice);
        loans.repay(loanId);
        (bool activeOut, uint32 bpsOut, address ownerOut) = activation.activation(address(basedNouns), 1);

        assertTrue(activeIn);
        assertEq(activeIn, activeOut);
        assertEq(bpsIn, bpsOut);
        assertEq(ownerIn, ownerOut);
        assertEq(basedNouns.ownerOf(1), alice);

        _fundPot(1_000e6);
        uint256 id = _openAndAccumulate(_ids(1));
        assertEq(rounds.getRound(id).totalWeight, 20_000, "earning exactly as before");
    }

    function test_liquidationEndsTheActivation() public {
        _mintAndChip(alice, 1, 3);
        uint256 loanId = _deposit(alice, 1, 0, 1_000 ether);
        assertTrue(activation.isActive(address(basedNouns), 1));

        vm.warp(loans.deadlineOf(loanId) + 1);
        vm.prank(keeper);
        loans.liquidate(loanId);

        assertEq(basedNouns.ownerOf(1), loanTreasury);
        assertFalse(activation.isActive(address(basedNouns), 1), "the loan ended it, atomically");

        _fundPot(1_000e6);
        uint256 id = rounds.openRound();
        rounds.contributeWeights(id, address(basedNouns), _ids(1));
        assertEq(rounds.getRound(id).totalWeight, 0);
    }

    /// @notice Liquidation MID-ROUND. Weight booked while the loan was healthy stays with
    ///         the borrower; the round that has not opened yet sees nothing.
    function test_liquidationMidRound() public {
        _mintAndChip(alice, 1, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        uint256 loanId = _deposit(alice, 1, 0, 1_000 ether);

        _fundPot(1_000e6);
        uint256 id = rounds.openRound();
        rounds.contributeWeights(id, address(basedNouns), _ids(1));
        assertEq(rounds.getRound(id).totalWeight, 10_000, "booked while healthy");

        // Default and liquidation land between accumulation and settlement.
        vm.warp(loans.deadlineOf(loanId) + 1);
        vm.prank(keeper);
        loans.liquidate(loanId);

        rounds.closeAccumulation(id);
        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);

        assertEq(claims.claimable(id, address(nvda), alice), 5e8, "already earned, still hers");
        _openClaimWindow();
        vm.prank(alice);
        claims.claim(id, address(nvda));
        assertEq(nvda.balanceOf(alice), 5e8);

        // The treasury now holds the Noun and it is chipped to nobody.
        assertEq(basedNouns.ownerOf(1), loanTreasury);
        assertFalse(activation.isActive(address(basedNouns), 1));
    }

    /// @notice The new owner of liquidated collateral can chip it themselves, at full price.
    function test_theTreasuryCanReChipLiquidatedCollateral() public {
        _mintAndChip(alice, 1, 4);
        uint256 loanId = _deposit(alice, 1, 0, 1_000 ether);
        vm.warp(loans.deadlineOf(loanId) + 1);
        vm.prank(keeper);
        loans.liquidate(loanId);

        chip.mint(loanTreasury, 10_000 ether);
        vm.startPrank(loanTreasury);
        chip.approve(address(activation), type(uint256).max);
        activation.activate(address(basedNouns), 1, 1);
        vm.stopPrank();

        (bool active, uint32 bps, address owner) = activation.activation(address(basedNouns), 1);
        assertTrue(active);
        assertEq(bps, 12_500);
        assertEq(owner, loanTreasury);
    }

    /* ------------------------------------------------------------------ */
    /*                        THE CUSTODIAN SWITCH                          */
    /* ------------------------------------------------------------------ */

    /// @notice Before NounLoans is registered, a deposit is indistinguishable from a sale.
    ///         This is the exact behaviour the custodian registry exists to fix.
    function test_anUnregisteredLoanVaultLooksLikeASale() public {
        vm.prank(multisig);
        activation.setCustodian(address(loans), false);

        _mintAndChip(alice, 1, 3);
        _deposit(alice, 1, 0, 1_000 ether);

        assertFalse(activation.isActive(address(basedNouns), 1), "reads as sold");

        vm.prank(multisig);
        activation.setCustodian(address(loans), true);
        assertTrue(activation.isActive(address(basedNouns), 1), "and back, with no user action");
    }

    /// @notice Two borrowers, two Nouns, one vault: beneficiaries do not cross.
    function test_twoBorrowersDoNotCross() public {
        _mintAndChip(alice, 1, 0);
        basedNouns.mint(bob, 2);
        vm.prank(bob);
        activation.activate(address(basedNouns), 2, 4);

        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        _setSplit(address(basedNouns), 2, bob, _one(address(nvda)), _one(uint8(100)));

        _deposit(alice, 1, 0, 1_000 ether);
        _deposit(bob, 2, 0, 1_000 ether);

        _fundPot(4_330e6);
        uint256 id = _openAndAccumulate(_ids(1, 2));
        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);

        // 1.00x vs 3.33x out of 4.33 total.
        uint256 aliceOwed = claims.claimable(id, address(nvda), alice);
        uint256 bobOwed = claims.claimable(id, address(nvda), bob);
        assertGt(aliceOwed, 0);
        assertGt(bobOwed, 0);
        assertApproxEqRel(bobOwed, aliceOwed * 333 / 100, 1e15, "3.33x, to the right borrower");
        assertEq(claims.claimable(id, address(nvda), address(loans)), 0, "and none to the vault");
    }
}
