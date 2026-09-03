// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ChipActivation} from "../../src/activation/ChipActivation.sol";
import {IActivationSource} from "../../src/interfaces/IActivationSource.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockNoun, GasBombNoun} from "../mocks/MockNoun.sol";
import {LyingToken, PausableToken} from "../mocks/HostileTokens.sol";
import {MockCustodian, LyingCustodian, GasBombCustodian, SilentCustodian} from "../mocks/MockCustodian.sol";

/// @notice Unit suite for Chipworks' own soft-staking vault.
contract ChipActivationTest is Test {
    address internal multisig = makeAddr("multisig");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    ChipActivation internal act;
    MockERC20 internal chip;
    MockNoun internal based;
    MockNoun internal dark;

    uint32[5] internal TIERS = [uint32(10_000), 12_500, 16_000, 20_000, 33_300];
    uint256[5] internal COSTS = [uint256(100 ether), 250 ether, 600 ether, 1_200 ether, 4_000 ether];

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        chip = new MockERC20("Chipworks", "CHIP", 18);
        based = new MockNoun("Based Nouns", "BASED");
        dark = new MockNoun("DarkNOUNs", "DARK");

        act = new ChipActivation(multisig, address(chip), TIERS);
        _configure(address(based), COSTS);

        chip.mint(alice, 100_000 ether);
        chip.mint(bob, 100_000 ether);
        vm.prank(alice);
        chip.approve(address(act), type(uint256).max);
        vm.prank(bob);
        chip.approve(address(act), type(uint256).max);
    }

    /* -------------------------------- helpers -------------------------------- */

    function _configure(address collection, uint256[5] memory costs) internal {
        vm.prank(multisig);
        act.queueCosts(collection, costs);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        act.executeCosts(collection);
    }

    function _mintAndActivate(address owner, uint256 tokenId, uint8 tier) internal {
        based.mint(owner, tokenId);
        vm.prank(owner);
        act.activate(address(based), tokenId, tier);
    }

    function _assertNoChipHeld() internal view {
        assertEq(chip.balanceOf(address(act)), 0, "ChipActivation is holding $CHIP");
    }

    /* ------------------------------- activation ------------------------------ */

    function test_activateBurnsTheTierCostAndRecordsTheOwner() public {
        based.mint(alice, 1);
        uint256 deadBefore = chip.balanceOf(DEAD);

        vm.prank(alice);
        act.activate(address(based), 1, 2);

        (bool active, uint32 bps, address owner) = act.activation(address(based), 1);
        assertTrue(active);
        assertEq(bps, 16_000);
        assertEq(owner, alice);
        assertEq(chip.balanceOf(DEAD) - deadBefore, 600 ether, "100% of the cost burned");
        assertEq(act.totalChipBurned(), 600 ether);
        _assertNoChipHeld();
    }

    /// @notice Clutch took 5% of every activation. Nothing is skimmed here.
    function test_oneHundredPercentOfTheCostBurns() public {
        based.mint(alice, 1);
        uint256 aliceBefore = chip.balanceOf(alice);
        uint256 deadBefore = chip.balanceOf(DEAD);

        vm.prank(alice);
        act.activate(address(based), 1, 4);

        uint256 paid = aliceBefore - chip.balanceOf(alice);
        assertEq(paid, 4_000 ether);
        assertEq(chip.balanceOf(DEAD) - deadBefore, paid, "every token paid reached 0xdead");
        _assertNoChipHeld();
    }

    function test_theContractNeverHoldsChip() public {
        based.mint(alice, 1);
        _assertNoChipHeld();

        vm.prank(alice);
        act.activate(address(based), 1, 0);
        _assertNoChipHeld();

        vm.prank(alice);
        act.upgrade(address(based), 1, 3);
        _assertNoChipHeld();

        vm.prank(alice);
        based.transferFrom(alice, bob, 1);
        _assertNoChipHeld();

        vm.prank(bob);
        act.activate(address(based), 1, 1);
        _assertNoChipHeld();
    }

    function test_aFreeTierBurnsNothingAndStillActivates() public {
        uint256[5] memory free = [uint256(0), 0, 0, 0, 0];
        _configure(address(dark), free);
        dark.mint(alice, 7);

        vm.prank(alice);
        act.activate(address(dark), 7, 3);

        (bool active, uint32 bps,) = act.activation(address(dark), 7);
        assertTrue(active);
        assertEq(bps, 20_000);
        assertEq(act.totalChipBurned(), 0);
    }

    function test_onlyTheEffectiveOwnerCanActivate() public {
        based.mint(alice, 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ChipActivation.NotEffectiveOwner.selector, address(based), 1, bob));
        act.activate(address(based), 1, 0);
    }

    function test_anUnconfiguredCollectionCannotBeActivated() public {
        dark.mint(alice, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ChipActivation.CollectionNotConfigured.selector, address(dark)));
        act.activate(address(dark), 1, 0);
        assertFalse(act.isSupportedCollection(address(dark)));
    }

    function test_aBadTierIndexIsRejected() public {
        based.mint(alice, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ChipActivation.BadTier.selector, 5));
        act.activate(address(based), 1, 5);
    }

    function test_reActivatingALiveActivationReverts() public {
        _mintAndActivate(alice, 1, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ChipActivation.AlreadyActive.selector, address(based), 1));
        act.activate(address(based), 1, 3);
    }

    function test_aNonexistentTokenCannotBeActivated() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ChipActivation.NotEffectiveOwner.selector, address(based), 99, alice));
        act.activate(address(based), 99, 0);
    }

    /* -------------------------------- upgrades ------------------------------- */

    function test_upgradePaysOnlyTheDifference() public {
        _mintAndActivate(alice, 1, 1); // 250
        uint256 deadBefore = chip.balanceOf(DEAD);

        assertEq(act.upgradeCost(address(based), 1, 3), 1_200 ether - 250 ether);

        vm.prank(alice);
        act.upgrade(address(based), 1, 3);

        assertEq(chip.balanceOf(DEAD) - deadBefore, 950 ether, "difference only");
        (, uint32 bps,) = act.activation(address(based), 1);
        assertEq(bps, 20_000);
        assertEq(act.totalUpgrades(), 1);
    }

    /// @notice Upgrading step by step costs exactly the same as buying the top tier outright.
    function test_upgradingStepwiseCostsTheSameAsBuyingTheTopTier() public {
        _mintAndActivate(alice, 1, 0);
        vm.startPrank(alice);
        act.upgrade(address(based), 1, 1);
        act.upgrade(address(based), 1, 2);
        act.upgrade(address(based), 1, 3);
        act.upgrade(address(based), 1, 4);
        vm.stopPrank();

        _mintAndActivate(bob, 2, 4);

        assertEq(act.totalChipBurned(), COSTS[4] * 2, "stepwise and outright cost the same");
    }

    function test_downgradeAndSideStepBothRevert() public {
        _mintAndActivate(alice, 1, 2);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ChipActivation.NotAnUpgrade.selector, 2, 1));
        act.upgrade(address(based), 1, 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ChipActivation.NotAnUpgrade.selector, 2, 2));
        act.upgrade(address(based), 1, 2);
    }

    function test_upgradingAnInactiveTokenReverts() public {
        based.mint(alice, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ChipActivation.NotActive.selector, address(based), 1));
        act.upgrade(address(based), 1, 2);
    }

    function test_aBuyerCannotUpgradeTheSellersActivation() public {
        _mintAndActivate(alice, 1, 1);
        vm.prank(alice);
        based.transferFrom(alice, bob, 1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ChipActivation.NotActive.selector, address(based), 1));
        act.upgrade(address(based), 1, 3);
    }

    /* ------------------------- lazy, atomic reset ---------------------------- */

    /// @notice THE HEADLINE PROPERTY. No kick, no keeper, no window of wrongness.
    function test_aSoldNounIsInactiveInTheSameTransaction() public {
        _mintAndActivate(alice, 1, 4);
        (bool activeBefore,,) = act.activation(address(based), 1);
        assertTrue(activeBefore);

        vm.prank(alice);
        based.transferFrom(alice, bob, 1);

        (bool active, uint32 bps, address owner) = act.activation(address(based), 1);
        assertFalse(active, "sold Nouns stop earning immediately");
        assertEq(bps, 0);
        assertEq(owner, address(0));
        assertEq(act.tierBpsOf(address(based), 1), 0);
        assertFalse(act.isActive(address(based), 1));
    }

    /// @notice A reset is not a wipe: the record survives so the site can explain it, but it
    ///         is never treated as live.
    function test_theStoredRecordSurvivesAResetButScoresNothing() public {
        _mintAndActivate(alice, 1, 4);
        vm.prank(alice);
        based.transferFrom(alice, bob, 1);

        ChipActivation.Activation memory raw = act.activationOf(address(based), 1);
        assertEq(raw.ownerAtActivation, alice, "the record is still readable");
        assertEq(raw.tier, 4);
        assertFalse(act.isActive(address(based), 1));
    }

    /// @notice A Noun sold and bought back reads active again, for the ORIGINAL owner. This
    ///         is the "resurrection" behaviour Clutch's V3 notes call a hole; here it is
    ///         harmless, because the record only ever pays the address that bought it and
    ///         that address is the live owner again.
    function test_aNounSoldAndBoughtBackByTheSameOwnerReadsActiveAgain() public {
        _mintAndActivate(alice, 1, 2);
        vm.prank(alice);
        based.transferFrom(alice, bob, 1);
        assertFalse(act.isActive(address(based), 1));

        vm.prank(bob);
        based.transferFrom(bob, alice, 1);

        (bool active,, address owner) = act.activation(address(based), 1);
        assertTrue(active);
        assertEq(owner, alice, "pays the address that actually paid for the tier");
    }

    function test_aBuyerActivatesAfreshAtFullPrice() public {
        _mintAndActivate(alice, 1, 3);
        vm.prank(alice);
        based.transferFrom(alice, bob, 1);

        uint256 deadBefore = chip.balanceOf(DEAD);
        vm.prank(bob);
        act.activate(address(based), 1, 1);

        assertEq(chip.balanceOf(DEAD) - deadBefore, 250 ether, "full price, not a difference");
        (bool active, uint32 bps, address owner) = act.activation(address(based), 1);
        assertTrue(active);
        assertEq(bps, 12_500);
        assertEq(owner, bob);
    }

    function test_aBurnedNounGoesInactive() public {
        _mintAndActivate(alice, 1, 2);
        vm.prank(alice);
        based.transferFrom(alice, DEAD, 1);
        assertFalse(act.isActive(address(based), 1));
    }

    /* ----------------------------- custodians -------------------------------- */

    function test_chipWhileCollateralised() public {
        MockCustodian vault = new MockCustodian();
        vm.prank(multisig);
        act.setCustodian(address(vault), true);

        based.mint(alice, 1);
        vm.startPrank(alice);
        based.approve(address(vault), 1);
        vault.deposit(address(based), 1);
        // Never activated before the deposit, and the Noun is not in alice's wallet.
        act.activate(address(based), 1, 2);
        vm.stopPrank();

        (bool active, uint32 bps, address owner) = act.activation(address(based), 1);
        assertTrue(active, "a collateralised Noun can still be chipped");
        assertEq(bps, 16_000);
        assertEq(owner, alice);
    }

    function test_borrowWhileChippedKeepsEarningForTheBorrower() public {
        MockCustodian vault = new MockCustodian();
        vm.prank(multisig);
        act.setCustodian(address(vault), true);

        _mintAndActivate(alice, 1, 3);

        vm.startPrank(alice);
        based.approve(address(vault), 1);
        vault.deposit(address(based), 1);
        vm.stopPrank();

        (bool active, uint32 bps, address owner) = act.activation(address(based), 1);
        assertTrue(active, "depositing collateral is not a sale");
        assertEq(bps, 20_000, "tier survives the deposit");
        assertEq(owner, alice, "rewards still book to the borrower");
    }

    function test_upgradesStillWorkWhileCollateralised() public {
        MockCustodian vault = new MockCustodian();
        vm.prank(multisig);
        act.setCustodian(address(vault), true);

        _mintAndActivate(alice, 1, 1);
        vm.startPrank(alice);
        based.approve(address(vault), 1);
        vault.deposit(address(based), 1);
        act.upgrade(address(based), 1, 4);
        vm.stopPrank();

        (, uint32 bps,) = act.activation(address(based), 1);
        assertEq(bps, 33_300);
    }

    function test_repayChangesNothing() public {
        MockCustodian vault = new MockCustodian();
        vm.prank(multisig);
        act.setCustodian(address(vault), true);

        _mintAndActivate(alice, 1, 2);
        vm.startPrank(alice);
        based.approve(address(vault), 1);
        vault.deposit(address(based), 1);
        vault.withdraw(address(based), 1, alice);
        vm.stopPrank();

        (bool active, uint32 bps, address owner) = act.activation(address(based), 1);
        assertTrue(active);
        assertEq(bps, 16_000);
        assertEq(owner, alice, "unchanged across deposit and repay");
    }

    function test_liquidationResets() public {
        MockCustodian vault = new MockCustodian();
        vm.prank(multisig);
        act.setCustodian(address(vault), true);

        _mintAndActivate(alice, 1, 3);
        vm.startPrank(alice);
        based.approve(address(vault), 1);
        vault.deposit(address(based), 1);
        vm.stopPrank();
        assertTrue(act.isActive(address(based), 1));

        // The beneficiary changes without the token moving: alice was liquidated.
        vault.setBeneficiary(address(based), 1, carol);
        assertFalse(act.isActive(address(based), 1), "liquidation ends the activation");

        // And a liquidation that ships the token out to a buyer resets too.
        vault.setBeneficiary(address(based), 1, carol);
        vm.prank(carol);
        vault.withdraw(address(based), 1, bob);
        assertFalse(act.isActive(address(based), 1));
    }

    /// @notice A custodian that stops naming a beneficiary reads as no owner, not as itself.
    function test_aCustodianNamingNobodyResets() public {
        MockCustodian vault = new MockCustodian();
        vm.prank(multisig);
        act.setCustodian(address(vault), true);

        _mintAndActivate(alice, 1, 2);
        vm.startPrank(alice);
        based.approve(address(vault), 1);
        vault.deposit(address(based), 1);
        vm.stopPrank();

        vault.setBeneficiary(address(based), 1, address(0));
        assertEq(act.effectiveOwner(address(based), 1), address(0));
        assertFalse(act.isActive(address(based), 1));
    }

    function test_anUnregisteredCustodianIsJustAnotherOwnerAndResets() public {
        MockCustodian vault = new MockCustodian();
        // deliberately NOT registered

        _mintAndActivate(alice, 1, 3);
        vm.startPrank(alice);
        based.approve(address(vault), 1);
        vault.deposit(address(based), 1);
        vm.stopPrank();

        assertEq(act.effectiveOwner(address(based), 1), address(vault), "no beneficiary lookup");
        assertFalse(act.isActive(address(based), 1), "depositing into an unknown vault is a transfer");
    }

    /// @notice The trust bound: a lying custodian can only speak for what it actually holds.
    function test_aLyingCustodianOnlyAffectsTokensItHolds() public {
        LyingCustodian liar = new LyingCustodian(carol);
        vm.prank(multisig);
        act.setCustodian(address(liar), true);

        // alice keeps her Noun in her own wallet and activates it.
        _mintAndActivate(alice, 1, 2);

        // The liar claims carol is the beneficiary of everything, including token 1.
        assertEq(liar.beneficiaryOf(address(based), 1), carol);

        // ChipActivation never asks, because ownerOf(1) is alice, not the liar.
        (bool active,, address owner) = act.activation(address(based), 1);
        assertTrue(active);
        assertEq(owner, alice, "the liar cannot reach a Noun it does not hold");

        // It also cannot reach another collection's token of the same id.
        _configure(address(dark), COSTS);
        dark.mint(bob, 1);
        vm.prank(bob);
        act.activate(address(dark), 1, 0);
        (,, address darkOwner) = act.activation(address(dark), 1);
        assertEq(darkOwner, bob);
    }

    /// @notice And over a token it DOES hold, the worst it can do is misdirect that token —
    ///         which it could achieve anyway by simply refusing to give the Noun back.
    function test_aLyingCustodianOverItsOwnCustodyIsBoundedToThatToken() public {
        LyingCustodian liar = new LyingCustodian(carol);
        vm.prank(multisig);
        act.setCustodian(address(liar), true);

        _mintAndActivate(alice, 1, 2);
        vm.prank(alice);
        based.approve(address(liar), 1);
        liar.pull(address(based), 1, alice);

        // alice's activation is void: the named beneficiary is not who activated.
        assertFalse(act.isActive(address(based), 1));
        assertEq(act.effectiveOwner(address(based), 1), carol);
    }

    function test_registeringACustodianMidActivationRevivesTheDeposit() public {
        MockCustodian vault = new MockCustodian();
        _mintAndActivate(alice, 1, 2);
        vm.startPrank(alice);
        based.approve(address(vault), 1);
        vault.deposit(address(based), 1);
        vm.stopPrank();
        assertFalse(act.isActive(address(based), 1), "unregistered while deposited");

        vm.prank(multisig);
        act.setCustodian(address(vault), true);
        assertTrue(act.isActive(address(based), 1), "registering restores it with no user action");
    }

    function test_deregisteringACustodianMidActivationResetsEverythingItHolds() public {
        MockCustodian vault = new MockCustodian();
        vm.prank(multisig);
        act.setCustodian(address(vault), true);

        _mintAndActivate(alice, 1, 2);
        based.mint(bob, 2);
        vm.prank(bob);
        act.activate(address(based), 2, 1);

        vm.startPrank(alice);
        based.approve(address(vault), 1);
        vault.deposit(address(based), 1);
        vm.stopPrank();
        vm.startPrank(bob);
        based.approve(address(vault), 2);
        vault.deposit(address(based), 2);
        vm.stopPrank();
        assertTrue(act.isActive(address(based), 1));
        assertTrue(act.isActive(address(based), 2));

        vm.prank(multisig);
        act.setCustodian(address(vault), false);

        assertFalse(act.isActive(address(based), 1), "the emergency stop is immediate");
        assertFalse(act.isActive(address(based), 2));
    }

    function test_onlyTheMultisigCanRegisterACustodian() public {
        MockCustodian vault = new MockCustodian();
        vm.prank(alice);
        vm.expectRevert();
        act.setCustodian(address(vault), true);
    }

    /* --------------------------- hostile foreign code ------------------------ */

    function test_aGasBombCustodianCannotWedgeAread() public {
        GasBombCustodian bomb = new GasBombCustodian();
        vm.prank(multisig);
        act.setCustodian(address(bomb), true);

        _mintAndActivate(alice, 1, 2);
        vm.prank(alice);
        based.approve(address(bomb), 1);
        bomb.pull(address(based), 1, alice);

        // Reads still answer, cheaply, and fail closed.
        uint256 gasBefore = gasleft();
        (bool active,,) = act.activation(address(based), 1);
        uint256 used = gasBefore - gasleft();
        assertFalse(active);
        assertLt(used, 400_000, "the probe is gas-capped");
    }

    function test_aSilentCustodianFailsClosed() public {
        SilentCustodian silent = new SilentCustodian();
        vm.prank(multisig);
        act.setCustodian(address(silent), true);

        _mintAndActivate(alice, 1, 2);
        vm.prank(alice);
        based.approve(address(silent), 1);
        silent.pull(address(based), 1, alice);

        assertEq(act.effectiveOwner(address(based), 1), address(0));
        assertFalse(act.isActive(address(based), 1));
    }

    function test_aGasBombCollectionCannotWedgeAread() public {
        GasBombNoun bomb = new GasBombNoun();
        _configure(address(bomb), COSTS);

        (bool active, uint32 bps, address owner) = act.activation(address(bomb), 1);
        assertFalse(active);
        assertEq(bps, 0);
        assertEq(owner, address(0));
    }

    /// @notice THE MEASURED BURN, doing its job. A $CHIP that reports a successful transfer
    ///         and moves nothing would otherwise buy an activation for free. `_burnChip`
    ///         reads `balanceOf(0xdead)` either side and refuses the shortfall, so the whole
    ///         call reverts and no activation is recorded.
    /// @dev SafeERC20 alone does NOT catch this: the token returns true.
    function test_aLyingChipCannotBuyAnActivationForFree() public {
        LyingToken liar = new LyingToken("Chipworks", "CHIP", 18);
        ChipActivation a2 = new ChipActivation(multisig, address(liar), TIERS);
        vm.prank(multisig);
        a2.queueCosts(address(based), COSTS);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        a2.executeCosts(address(based));

        liar.mint(alice, 10_000 ether);
        vm.prank(alice);
        liar.approve(address(a2), type(uint256).max);
        based.mint(alice, 1);

        // Honest first: the same call works when the token behaves.
        vm.prank(alice);
        a2.activate(address(based), 1, 2);
        (bool honest,,) = a2.activation(address(based), 1);
        assertTrue(honest);

        liar.setLying(true);
        based.mint(alice, 2);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ChipActivation.ChipBurnShortfall.selector, 0, 600 ether));
        a2.activate(address(based), 2, 2);

        (bool active,,) = a2.activation(address(based), 2);
        assertFalse(active, "nothing recorded when the burn did not land");
    }

    function test_aPausedChipBlocksActivationWithoutCorruptingState() public {
        PausableToken pt = new PausableToken("Chipworks", "CHIP", 18);
        ChipActivation a2 = new ChipActivation(multisig, address(pt), TIERS);
        vm.prank(multisig);
        a2.queueCosts(address(based), COSTS);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        a2.executeCosts(address(based));

        pt.mint(alice, 10_000 ether);
        vm.prank(alice);
        pt.approve(address(a2), type(uint256).max);
        based.mint(alice, 1);
        pt.setPaused(true);

        vm.prank(alice);
        vm.expectRevert();
        a2.activate(address(based), 1, 2);

        pt.setPaused(false);
        vm.prank(alice);
        a2.activate(address(based), 1, 2);
        (bool active,,) = a2.activation(address(based), 1);
        assertTrue(active);
    }

    /* ------------------------------ config timelock -------------------------- */

    function test_costsRequireTheFullFortyEightHours() public {
        vm.prank(multisig);
        act.queueCosts(address(dark), COSTS);

        vm.warp(block.timestamp + 48 hours - 1);
        vm.prank(multisig);
        vm.expectRevert();
        act.executeCosts(address(dark));

        vm.warp(block.timestamp + 1);
        vm.prank(multisig);
        act.executeCosts(address(dark));
        assertTrue(act.isSupportedCollection(address(dark)));
    }

    function test_tierWeightsRequireTheFullFortyEightHours() public {
        uint32[5] memory next = [uint32(10_000), 11_000, 12_000, 13_000, 14_000];
        vm.prank(multisig);
        act.queueTierBps(next);

        vm.warp(block.timestamp + 48 hours - 1);
        vm.prank(multisig);
        vm.expectRevert();
        act.executeTierBps();

        vm.warp(block.timestamp + 1);
        vm.prank(multisig);
        act.executeTierBps();
        assertEq(act.tierBps(4), 14_000);
    }

    /// @notice A queued change is visible long before it binds, and does not bite early.
    function test_aQueuedChangeDoesNotBiteUntilExecuted() public {
        _mintAndActivate(alice, 1, 4);
        (, uint32 before,) = act.activation(address(based), 1);
        assertEq(before, 33_300);

        uint32[5] memory next = [uint32(10_000), 10_001, 10_002, 10_003, 10_004];
        vm.prank(multisig);
        act.queueTierBps(next);
        vm.warp(block.timestamp + 47 hours);

        (, uint32 during,) = act.activation(address(based), 1);
        assertEq(during, 33_300, "unchanged while queued");
    }

    function test_queuedChangesCanBeCancelled() public {
        vm.prank(multisig);
        act.queueCosts(address(dark), COSTS);
        vm.prank(multisig);
        act.cancelCosts(address(dark));
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        vm.expectRevert(ChipActivation.NothingQueued.selector);
        act.executeCosts(address(dark));

        vm.prank(multisig);
        act.queueTierBps([uint32(10_000), 11_000, 12_000, 13_000, 14_000]);
        vm.prank(multisig);
        act.cancelTierBps();
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        vm.expectRevert(ChipActivation.NothingQueued.selector);
        act.executeTierBps();
    }

    function test_decreasingCostsAcrossTiersAreRejected() public {
        uint256[5] memory bad = [uint256(100 ether), 250 ether, 200 ether, 1_200 ether, 4_000 ether];
        vm.prank(multisig);
        vm.expectRevert(ChipActivation.BadConfig.selector);
        act.queueCosts(address(dark), bad);
    }

    function test_zeroOrDecreasingTierWeightsAreRejected() public {
        vm.prank(multisig);
        vm.expectRevert(ChipActivation.BadConfig.selector);
        act.queueTierBps([uint32(10_000), 0, 16_000, 20_000, 33_300]);

        vm.prank(multisig);
        vm.expectRevert(ChipActivation.BadConfig.selector);
        act.queueTierBps([uint32(10_000), 12_500, 11_000, 20_000, 33_300]);
    }

    function test_theConstructorRejectsABadTierTable() public {
        vm.expectRevert(ChipActivation.BadConfig.selector);
        new ChipActivation(multisig, address(chip), [uint32(0), 12_500, 16_000, 20_000, 33_300]);
    }

    function test_onlyTheMultisigCanTouchConfig() public {
        vm.prank(alice);
        vm.expectRevert();
        act.queueCosts(address(dark), COSTS);

        vm.prank(alice);
        vm.expectRevert();
        act.queueTierBps([uint32(10_000), 11_000, 12_000, 13_000, 14_000]);
    }

    /// @notice Executing a cost change re-prices upgrades but never retroactively charges.
    function test_aCostChangeRePricesFutureUpgradesOnly() public {
        _mintAndActivate(alice, 1, 1);

        uint256[5] memory dearer = [uint256(500 ether), 900 ether, 1_500 ether, 3_000 ether, 9_000 ether];
        vm.prank(multisig);
        act.queueCosts(address(based), dearer);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        act.executeCosts(address(based));

        // Still tier 1, still active, nothing clawed back.
        (bool active, uint32 bps,) = act.activation(address(based), 1);
        assertTrue(active);
        assertEq(bps, 12_500);

        assertEq(act.upgradeCost(address(based), 1, 2), 1_500 ether - 900 ether, "new table prices the step");
    }

    /* --------------------------------- rescue -------------------------------- */

    function test_recoverExcessMovesAStrayDonation() public {
        chip.mint(address(act), 5 ether);
        vm.prank(multisig);
        act.recoverExcess(address(chip), multisig);
        assertEq(chip.balanceOf(multisig), 5 ether);
        _assertNoChipHeld();
    }

    function test_recoverNFTReturnsAStrandedNoun() public {
        based.mint(alice, 1);
        vm.prank(alice);
        based.transferFrom(alice, address(act), 1);

        // It also lost any activation by being here.
        assertFalse(act.isActive(address(based), 1));

        vm.prank(multisig);
        act.recoverNFT(address(based), 1, alice);
        assertEq(based.ownerOf(1), alice);
    }

    function test_rescueIsMultisigOnly() public {
        chip.mint(address(act), 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        act.recoverExcess(address(chip), alice);

        vm.prank(alice);
        vm.expectRevert();
        act.recoverNFT(address(based), 1, alice);
    }

    /* ---------------------------------- fuzz --------------------------------- */

    /// @notice Whatever the tier and whoever holds it, the burn equals the table exactly and
    ///         the contract keeps nothing.
    function testFuzz_theBurnAlwaysEqualsTheTableAndNothingIsKept(uint8 tierSeed, uint256 idSeed) public {
        uint8 tier = uint8(bound(tierSeed, 0, 4));
        uint256 tokenId = bound(idSeed, 1, 4_420);

        based.mint(alice, tokenId);
        uint256 deadBefore = chip.balanceOf(DEAD);
        uint256 aliceBefore = chip.balanceOf(alice);

        vm.prank(alice);
        act.activate(address(based), tokenId, tier);

        assertEq(chip.balanceOf(DEAD) - deadBefore, COSTS[tier]);
        assertEq(aliceBefore - chip.balanceOf(alice), COSTS[tier]);
        _assertNoChipHeld();

        (bool active, uint32 bps,) = act.activation(address(based), tokenId);
        assertTrue(active);
        assertEq(bps, TIERS[tier]);
    }

    /// @notice A transfer to anyone other than the activator always resets, for every tier.
    function testFuzz_anyTransferToAnyoneElseResets(uint8 tierSeed, address buyer) public {
        vm.assume(buyer != address(0) && buyer != alice);
        vm.assume(buyer.code.length == 0);
        uint8 tier = uint8(bound(tierSeed, 0, 4));

        _mintAndActivate(alice, 1, tier);
        assertTrue(act.isActive(address(based), 1));

        vm.prank(alice);
        based.transferFrom(alice, buyer, 1);

        assertFalse(act.isActive(address(based), 1));
        (bool active, uint32 bps, address owner) = act.activation(address(based), 1);
        assertFalse(active);
        assertEq(bps, 0);
        assertEq(owner, address(0));
    }
}
