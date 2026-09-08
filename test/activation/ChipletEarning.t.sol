// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {ChipActivation} from "../../src/activation/ChipActivation.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title ChipletEarningTest
/// @notice Chiplets as a fourth earning collection: one flat rate, no tiers, and an activation
///         that costs a Chiplet as well as $CHIP.
///
/// @dev THE 0.1x IS NOT IN THIS CONTRACT, AND THAT IS THE DESIGN. Weight is
///      `tierBps x collectionBaseBps / BPS`, computed in `ChipRounds`. Chiplets report a flat
///      1.00x here and `ChipRounds` supplies 0.1x as `setCollectionBaseBps(chiplets, 1_000)` —
///      exactly how Lil Based Nouns get 0.5x from 5_000. So **adding Chiplets needed no change
///      to `ChipRounds` at all**: the weight formula was already collection-agnostic and the
///      round loop already asks the activation source rather than assuming tiers.
///
///      TWO BURNS, TWO DIFFERENT KINDS, BOTH VERIFIED. The sacrificed Chiplet is genuinely
///      destroyed through OpenSea's `burn` — supply falls. The $CHIP goes to `0xdead` because
///      Bankr's token has no burn — supply does not fall, and that is their limitation, not a
///      shortcut here.
contract ChipletEarningTest is Test {
    ChipActivation internal activation;
    SeaDropLikeChiplets internal chiplets;
    MockERC20 internal chip;

    address internal multisig = makeAddr("multisig");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 internal constant FLAT_COST = 5_000 ether;

    function setUp() public {
        vm.warp(1_700_000_000);
        chip = new MockERC20("Chipworks", "CHIP", 18);
        chiplets = new SeaDropLikeChiplets();

        uint32[5] memory tiers = [uint32(10_000), 12_500, 16_000, 20_000, 33_300];
        activation = new ChipActivation(multisig, address(chip), 0x000000000000000000000000000000000000dEaD, tiers);

        // Flat-rate is declared BEFORE the collection is configured, then the one price goes
        // through the same 48-hour path as any other cost.
        uint256[5] memory flat;
        for (uint256 i; i < 5; ++i) {
            flat[i] = FLAT_COST;
        }
        vm.startPrank(multisig);
        activation.setFlatRateCollection(address(chiplets));
        activation.queueCosts(address(chiplets), flat);
        vm.stopPrank();
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        activation.executeCosts(address(chiplets));
    }

    /// @dev Give `who` two Chiplets and the $CHIP, approved the marketplace way.
    function _hold(address who, uint256 keepId, uint256 burnId) internal {
        chiplets.mint(who, keepId);
        chiplets.mint(who, burnId);
        chip.mint(who, FLAT_COST);
        vm.startPrank(who);
        chiplets.setApprovalForAll(address(activation), true); // step one, as with the Furnace
        chip.approve(address(activation), type(uint256).max);
        vm.stopPrank();
    }

    /* ------------------------------------------------------------------ */
    /*                     THE DOUBLE BURN, VERIFIED                        */
    /* ------------------------------------------------------------------ */

    /// @notice Activating burns a flat $CHIP amount AND one other Chiplet. The Chiplet is
    ///         truly destroyed; the $CHIP goes to `0xdead` because it cannot be.
    function test_activatingBurnsChipAndOneOtherChiplet() public {
        _hold(alice, 1, 2);
        assertEq(chiplets.totalSupply(), 2);

        vm.prank(alice);
        activation.activateFlat(address(chiplets), 1, 2);

        // The sacrifice genuinely left supply.
        assertEq(chiplets.totalSupply(), 1, "supply actually fell");
        assertEq(chiplets.balanceOf(DEAD), 0, "nothing parked at 0xdead");
        vm.expectRevert();
        chiplets.ownerOf(2);

        // The $CHIP could only be dead-held.
        assertEq(chip.balanceOf(DEAD), FLAT_COST, "at the canonical dead address");
        assertEq(activation.totalChipBurned(), FLAT_COST, "and counted");
        assertEq(chiplets.ownerOf(1), alice, "the activated one is untouched");
    }

    /// @notice And it earns: a flat 1.00x from this layer, which `ChipRounds` scales to 0.1x.
    function test_anActivatedChipletReportsTheFlatRate() public {
        _hold(alice, 1, 2);
        vm.prank(alice);
        activation.activateFlat(address(chiplets), 1, 2);

        (bool active, uint32 bps, address owner) = activation.activation(address(chiplets), 1);
        assertTrue(active);
        assertEq(bps, activation.FLAT_TIER_BPS(), "flat 1.00x here");
        assertEq(bps, 10_000);
        assertEq(owner, alice);

        // 10_000 x 1_000 / 10_000 == 1_000 == 0.1x, which is what ChipRounds computes.
        assertEq((uint256(bps) * 1_000) / 10_000, 1_000, "0.1x once ChipRounds applies the base");
    }

    /// @notice A token cannot pay for itself.
    function test_aChipletCannotSacrificeItself() public {
        _hold(alice, 1, 2);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ChipActivation.CannotSacrificeItself.selector, uint256(1)));
        activation.activateFlat(address(chiplets), 1, 1);
    }

    /// @notice The sacrifice must be the caller's. Somebody else's Chiplet is not currency.
    function test_theSacrificeMustBeHeldByTheCaller() public {
        _hold(alice, 1, 2);
        chiplets.mint(bob, 9);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ChipActivation.NotSacrificeOwner.selector, uint256(9), alice));
        activation.activateFlat(address(chiplets), 1, 9);

        assertEq(chiplets.ownerOf(9), bob, "untouched");
    }

    /// @notice Without the operator approval there is no burn, and no activation.
    function test_withoutApprovalTheActivationReverts() public {
        chiplets.mint(alice, 1);
        chiplets.mint(alice, 2);
        chip.mint(alice, FLAT_COST);
        vm.prank(alice);
        chip.approve(address(activation), type(uint256).max);
        // Deliberately no setApprovalForAll.

        vm.prank(alice);
        vm.expectRevert();
        activation.activateFlat(address(chiplets), 1, 2);

        assertEq(chiplets.totalSupply(), 2, "nothing burned");
        (bool active,,) = activation.activation(address(chiplets), 1);
        assertFalse(active);
    }

    /// @notice Not enough $CHIP: nothing is recorded and no Chiplet is destroyed. The two
    ///         burns are one atomic act.
    function test_aFailedChipBurnDestroysNoChiplet() public {
        chiplets.mint(alice, 1);
        chiplets.mint(alice, 2);
        chip.mint(alice, FLAT_COST - 1);
        vm.startPrank(alice);
        chiplets.setApprovalForAll(address(activation), true);
        chip.approve(address(activation), type(uint256).max);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert();
        activation.activateFlat(address(chiplets), 1, 2);

        assertEq(chiplets.totalSupply(), 2, "the sacrifice survived");
        assertEq(chip.balanceOf(DEAD), 0);
    }

    /* ------------------------------------------------------------------ */
    /*                       RESET ON TRANSFER                              */
    /* ------------------------------------------------------------------ */

    /// @notice Selling a Chiplet zeroes it, exactly like a Noun. No keeper, no stored flag —
    ///         {activation} recomputes from the live owner every read.
    function test_earningResetsOnTransferAndTheBuyerMustBurnAgain() public {
        _hold(alice, 1, 2);
        vm.prank(alice);
        activation.activateFlat(address(chiplets), 1, 2);

        (bool active,, address owner) = activation.activation(address(chiplets), 1);
        assertTrue(active);
        assertEq(owner, alice);

        vm.prank(alice);
        chiplets.transferFrom(alice, bob, 1);

        (active,, owner) = activation.activation(address(chiplets), 1);
        assertFalse(active, "sold, so it scores zero");
        assertEq(owner, address(0));

        // Bob re-activates by burning again — his own Chiplet and his own $CHIP.
        chiplets.mint(bob, 3);
        chip.mint(bob, FLAT_COST);
        vm.startPrank(bob);
        chiplets.setApprovalForAll(address(activation), true);
        chip.approve(address(activation), type(uint256).max);
        activation.activateFlat(address(chiplets), 1, 3);
        vm.stopPrank();

        (active,, owner) = activation.activation(address(chiplets), 1);
        assertTrue(active, "and it earns again");
        assertEq(owner, bob);
    }

    /// @notice Sending it away and getting it back does NOT revive the old activation: the
    ///         recorded payer is compared to the live owner, and a round trip changes neither
    ///         — so this is the one case where it DOES revive, and it is the documented
    ///         SEC-ACT-002 behaviour rather than a Chiplet-specific quirk.
    function test_aRoundTripRevivesExactlyAsItDoesForNouns() public {
        _hold(alice, 1, 2);
        vm.prank(alice);
        activation.activateFlat(address(chiplets), 1, 2);

        vm.prank(alice);
        chiplets.transferFrom(alice, bob, 1);
        (bool active,,) = activation.activation(address(chiplets), 1);
        assertFalse(active);

        vm.prank(bob);
        chiplets.transferFrom(bob, alice, 1);
        (active,,) = activation.activation(address(chiplets), 1);
        assertTrue(active, "back with the original payer, so it counts again - SEC-ACT-002");
    }

    /* ------------------------------------------------------------------ */
    /*                    FLAT AND TIERED DO NOT MIX                        */
    /* ------------------------------------------------------------------ */

    /// @notice A flat collection has no tiers to buy or climb.
    function test_flatCollectionsRefuseTheTieredPaths() public {
        _hold(alice, 1, 2);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ChipActivation.WrongActivationKind.selector, address(chiplets)));
        activation.activate(address(chiplets), 1, 0);

        vm.prank(alice);
        activation.activateFlat(address(chiplets), 1, 2);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ChipActivation.WrongActivationKind.selector, address(chiplets)));
        activation.upgrade(address(chiplets), 1, 3);
    }

    /// @notice And a tiered collection refuses the flat path.
    function test_tieredCollectionsRefuseTheFlatPath() public {
        SeaDropLikeChiplets nouns = new SeaDropLikeChiplets();
        uint256[5] memory ladder = [uint256(1 ether), 2 ether, 3 ether, 4 ether, 5 ether];
        vm.prank(multisig);
        activation.queueCosts(address(nouns), ladder);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        activation.executeCosts(address(nouns));

        nouns.mint(alice, 1);
        nouns.mint(alice, 2);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ChipActivation.WrongActivationKind.selector, address(nouns)));
        activation.activateFlat(address(nouns), 1, 2);
    }

    /// @notice The flat rate cannot be given a hidden ladder by a misconfiguration, and the
    ///         kind cannot be changed once the collection is live.
    function test_theFlatConfigurationIsGuarded() public {
        uint256[5] memory ladder = [uint256(1 ether), 2 ether, 3 ether, 4 ether, 5 ether];
        vm.prank(multisig);
        vm.expectRevert(ChipActivation.BadConfig.selector);
        activation.queueCosts(address(chiplets), ladder);

        // Already configured, so it cannot be flipped to flat retroactively either.
        vm.prank(multisig);
        vm.expectRevert(ChipActivation.BadConfig.selector);
        activation.setFlatRateCollection(address(chiplets));
    }

    /// @notice Only the multisig declares a flat collection.
    function test_onlyTheMultisigDeclaresAFlatCollection() public {
        SeaDropLikeChiplets other = new SeaDropLikeChiplets();
        vm.prank(alice);
        vm.expectRevert();
        activation.setFlatRateCollection(address(other));
    }
}

/// @notice Chiplets as it ships: OpenSea's `ERC721SeaDrop`, ERC721A underneath. Not a contract
///         in this repo — the double reproduces `burn(uint256) { _burn(tokenId, true); }` and
///         ERC721A's approval check, which accepts owner, token-approved, or **operator**.
contract SeaDropLikeChiplets is ERC721 {
    uint256 internal _minted;
    uint256 internal _burnCounter;

    error TransferCallerNotOwnerNorApproved();

    constructor() ERC721("Chiplets", "CHIPLET") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
        ++_minted;
    }

    function totalSupply() public view returns (uint256) {
        return _minted - _burnCounter;
    }

    function burn(uint256 tokenId) external {
        address owner = ownerOf(tokenId);
        if (msg.sender != owner && getApproved(tokenId) != msg.sender && !isApprovedForAll(owner, msg.sender)) {
            revert TransferCallerNotOwnerNorApproved();
        }
        _burn(tokenId);
        ++_burnCounter;
    }
}
