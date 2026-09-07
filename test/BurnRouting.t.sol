// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {ChipBurner} from "../src/ChipBurner.sol";
import {ChipActivation} from "../src/activation/ChipActivation.sol";
import {Furnace} from "../src/furnace/Furnace.sol";
import {MockNoun} from "./mocks/MockNoun.sol";

/// @title BurnRoutingTest
/// @notice Every app $CHIP burn now lands in the Burner, and from there it stops existing.
///
/// @dev THE TWO ADDRESSES ARE NOT INTERCHANGEABLE, WHICH IS THE POINT OF THIS SUITE.
///
///        - **$CHIP** goes to `chipBurnTarget` — the {ChipBurner}, which owns the token and can
///          call its owner-gated `burn`. `totalSupply` genuinely falls.
///        - **NFTs** go to `BURN_ADDRESS` (`0xdead`) when their collection exposes no `burn`.
///          The Burner has no ERC-721 surface at all: an NFT sent there would be **stranded
///          forever**, with no rescue and no owner able to move it.
///
///      A single "burn address" for both would have been the obvious simplification and it
///      would have quietly destroyed NFTs in a way nobody could undo. They are separate fields
///      and this suite is what keeps them separate.
contract BurnRoutingTest is Test {
    ChipBurner internal burner;
    OwnedChip internal chip;
    ChipActivation internal activation;
    Furnace internal furnace;

    PlainNoun internal chiplets; // no burn(), so the NFT fallback is exercised
    MockNoun internal based;
    MockNoun internal dark;

    address internal multisig = makeAddr("multisig");
    address internal alice = makeAddr("alice");
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant ACT_COST = 50_000 ether;
    uint256 internal constant FORGE_CHIP = 25_000 ether;
    uint16 internal constant FUEL = 25; // chipletsPerBased

    function setUp() public {
        vm.warp(1_700_000_000);
        chip = new OwnedChip(SUPPLY);
        burner = new ChipBurner(multisig, address(chip));
        chip.transferOwnership(address(burner)); // the launch step

        chiplets = new PlainNoun("Chiplets", "CHIPP");
        based = new MockNoun("Based Nouns", "BASED");
        dark = new MockNoun("DarkNOUNs", "DARK");

        uint32[5] memory tiers = [uint32(10_000), 12_500, 16_000, 20_000, 33_300];
        activation = new ChipActivation(multisig, address(chip), address(burner), tiers);

        furnace = new Furnace(
            multisig,
            address(chip),
            address(burner),
            address(chiplets),
            Furnace.Recipe({
                exists: true, paused: false, outputCollection: address(based), fuelCost: FUEL, chipCost: FORGE_CHIP
            }),
            Furnace.Recipe({
                exists: true, paused: false, outputCollection: address(dark), fuelCost: 40, chipCost: 60_000 ether
            })
        );

        // Price the Based collection so a Noun can be activated.
        uint256[5] memory costs;
        for (uint256 i; i < 5; ++i) {
            costs[i] = ACT_COST;
        }
        vm.prank(multisig);
        activation.queueCosts(address(based), costs);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        activation.executeCosts(address(based));

        // Stock the Furnace.
        uint256[] memory stock = new uint256[](1);
        stock[0] = 500;
        based.mint(multisig, 500);
        vm.startPrank(multisig);
        based.setApprovalForAll(address(furnace), true);
        furnace.depositStock(address(based), stock);
        vm.stopPrank();
    }

    /* ------------------------------------------------------------------ */
    /*                    $CHIP REACHES THE BURNER                          */
    /* ------------------------------------------------------------------ */

    /// @notice Activating a Noun sends its $CHIP to the Burner, not to `0xdead`.
    function test_activationChipLandsInTheBurner() public {
        based.mint(alice, 1);
        chip.transfer(alice, ACT_COST);
        vm.startPrank(alice);
        chip.approve(address(activation), type(uint256).max);
        activation.activate(address(based), 1, 0);
        vm.stopPrank();

        assertEq(chip.balanceOf(address(burner)), ACT_COST, "queued at the Burner");
        assertEq(chip.balanceOf(DEAD), 0, "and NOT at 0xdead");
        assertEq(activation.totalChipBurned(), ACT_COST);
    }

    /// @notice Forging sends its $CHIP to the Burner too, while the FUEL still goes to
    ///         `0xdead` because this collection has no `burn`.
    function test_forgeChipGoesToTheBurnerButFuelGoesToDead() public {
        uint256[] memory ids = new uint256[](FUEL);
        for (uint256 i; i < FUEL; ++i) {
            ids[i] = 100 + i;
            chiplets.mint(alice, ids[i]);
        }
        chip.transfer(alice, FORGE_CHIP);

        vm.startPrank(alice);
        chiplets.setApprovalForAll(address(furnace), true);
        chip.approve(address(furnace), type(uint256).max);
        furnace.forge(0, ids);
        vm.stopPrank();

        assertEq(chip.balanceOf(address(burner)), FORGE_CHIP, "$CHIP to the Burner");
        assertEq(chiplets.balanceOf(DEAD), FUEL, "NFTs to 0xdead");
        assertEq(chiplets.balanceOf(address(burner)), 0, "NEVER to the Burner - it would strand them");
        assertEq(furnace.totalFuelTrueBurned(), 0, "this collection has no burn, so dead-held");
    }

    /// @notice And then anyone destroys the lot: `totalSupply` falls by exactly what the app
    ///         burned. This is the end-to-end property the whole change exists for.
    function test_theRoutedChipIsThenTrulyBurned() public {
        based.mint(alice, 1);
        chip.transfer(alice, ACT_COST);
        vm.startPrank(alice);
        chip.approve(address(activation), type(uint256).max);
        activation.activate(address(based), 1, 0);
        vm.stopPrank();

        assertEq(chip.totalSupply(), SUPPLY, "not burned yet, only queued");

        vm.prank(makeAddr("anyKeeper"));
        uint256 burned = burner.burnAll();

        assertEq(burned, ACT_COST);
        assertEq(chip.totalSupply(), SUPPLY - ACT_COST, "supply genuinely fell");
        assertEq(chip.balanceOf(address(burner)), 0);
        assertEq(burner.totalBurned(), ACT_COST);
    }

    /// @notice `effectiveChipSupply` counts what is queued at the Burner as already out of
    ///         circulation — it can only ever be destroyed — and stops double-counting once it
    ///         is, because a real burn removes it from `totalSupply` as well.
    function test_effectiveSupplyIsRightBeforeAndAfterTheBurn() public {
        based.mint(alice, 1);
        chip.transfer(alice, ACT_COST);
        vm.startPrank(alice);
        chip.approve(address(activation), type(uint256).max);
        activation.activate(address(based), 1, 0);
        vm.stopPrank();

        assertEq(activation.effectiveChipSupply(), SUPPLY - ACT_COST, "queued counts as gone");

        burner.burnAll();
        assertEq(chip.totalSupply(), SUPPLY - ACT_COST);
        assertEq(activation.effectiveChipSupply(), SUPPLY - ACT_COST, "and stays right afterwards");
    }

    /* ------------------------------------------------------------------ */
    /*                    THE TARGET IS NOT A LEVER                         */
    /* ------------------------------------------------------------------ */

    /// @notice It is immutable. There is no setter on any of the three, so a documented burn
    ///         cannot be redirected into revenue after the fact.
    function test_theBurnTargetCannotBeChanged() public {
        assertEq(activation.chipBurnTarget(), address(burner));
        assertEq(furnace.chipBurnTarget(), address(burner));

        string[3] memory setters =
            ["setChipBurnTarget(address)", "setBurnTarget(address)", "updateChipBurnTarget(address)"];
        for (uint256 i; i < 3; ++i) {
            vm.prank(multisig);
            (bool ok,) = address(activation).call(abi.encodeWithSignature(setters[i], alice));
            assertFalse(ok, setters[i]);
            vm.prank(multisig);
            (ok,) = address(furnace).call(abi.encodeWithSignature(setters[i], alice));
            assertFalse(ok, setters[i]);
        }
    }

    /// @notice A zero target is refused at construction rather than discovered at the first
    ///         burn, where it would send $CHIP to `address(0)`.
    function test_aZeroBurnTargetIsRefusedAtDeploy() public {
        uint32[5] memory tiers = [uint32(10_000), 12_500, 16_000, 20_000, 33_300];
        vm.expectRevert(ChipActivation.ZeroAddress.selector);
        new ChipActivation(multisig, address(chip), address(0), tiers);
    }

    /// @notice The NFT fallback address is still the canonical dead one, and separate.
    function test_theNftFallbackIsStillDeadAndSeparate() public view {
        assertEq(furnace.BURN_ADDRESS(), DEAD);
        assertEq(activation.BURN_ADDRESS(), DEAD);
        assertTrue(furnace.BURN_ADDRESS() != furnace.chipBurnTarget(), "two different addresses");
    }
}

/// @notice $CHIP with an owner-gated burn, like Bankr's Doppler token.
contract OwnedChip is ERC20 {
    address public owner;

    constructor(uint256 supply) ERC20("Chipworks", "CHIP") {
        owner = msg.sender;
        _mint(msg.sender, supply);
    }

    function burn(uint256 amount) external {
        require(msg.sender == owner, "NOT_OWNER");
        _burn(msg.sender, amount);
    }

    function transferOwnership(address n) external {
        require(msg.sender == owner, "NOT_OWNER");
        owner = n;
    }
}

/// @notice An ERC-721 with no `burn`, so the Furnace's dead-address fallback is exercised.
contract PlainNoun is ERC721 {
    constructor(string memory n, string memory s) ERC721(n, s) {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}
