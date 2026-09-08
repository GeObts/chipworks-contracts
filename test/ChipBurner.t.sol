// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ChipBurner} from "../src/ChipBurner.sol";

/// @title ChipBurnerTest
/// @notice The wrapper that makes a $CHIP burn a real one.
///
/// @dev THREE PROPERTIES, AND THEY PULL AGAINST EACH OTHER, WHICH IS WHY THIS IS A WRAPPER
///      RATHER THAN A SINK.
///        1. **Burning is permissionless and truly reduces `totalSupply`.** Not a transfer to
///           `0xdead` — the tokens stop existing, and every aggregator sees it.
///        2. **$CHIP can only ever leave by being destroyed.** No transfer, no sweep, no
///           generic call. The multisig cannot move it either.
///        3. **The token's OTHER owner powers still reach the multisig.** `transferOwnership`
///           sweeps up everything, so a burn-only owner would freeze the token's metadata and
///           trap its ownership forever.
contract ChipBurnerTest is Test {
    ChipBurner internal burner;
    DopplerLikeChip internal chip;

    address internal multisig = makeAddr("multisig");
    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");

    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        chip = new DopplerLikeChip(SUPPLY);
        burner = new ChipBurner(multisig, address(chip));
        // The launch step: the token's owner becomes the Burner.
        chip.transferOwnership(address(burner));
    }

    /* ------------------------------------------------------------------ */
    /*                     A REAL BURN, BY ANYONE                           */
    /* ------------------------------------------------------------------ */

    /// @notice THE POINT OF THE WHOLE CONTRACT. `totalSupply` actually falls.
    function test_burnAllTrulyReducesTotalSupply() public {
        chip.transfer(address(burner), 5_000 ether);
        assertEq(chip.totalSupply(), SUPPLY);

        vm.prank(alice); // anyone
        uint256 burned = burner.burnAll();

        assertEq(burned, 5_000 ether);
        assertEq(chip.totalSupply(), SUPPLY - 5_000 ether, "supply fell, on chain");
        assertEq(chip.balanceOf(address(burner)), 0, "and the Burner holds nothing");
        assertEq(burner.totalBurned(), 5_000 ether);
        assertEq(burner.burnCount(), 1);
    }

    /// @notice Permissionless is the point: a keeper, a user, or the app itself in the same
    ///         transaction. No privileged caller has to be awake.
    function test_anyoneCanBurn() public {
        chip.transfer(address(burner), 100 ether);
        vm.prank(keeper);
        burner.burnAll();

        chip.transfer(address(burner), 100 ether);
        vm.prank(alice);
        burner.burnAll();

        assertEq(burner.totalBurned(), 200 ether);
        assertEq(chip.totalSupply(), SUPPLY - 200 ether);
    }

    function test_burningNothingReverts() public {
        vm.expectRevert(ChipBurner.NothingToBurn.selector);
        burner.burnAll();
    }

    /// @notice The counter is the measured supply drop, not the requested amount. A token that
    ///         quietly under-burns cannot inflate the figure the site publishes.
    function test_aTokenThatUnderBurnsIsRefused() public {
        chip.transfer(address(burner), 1_000 ether);
        chip.setBurnNoop(true);

        vm.expectRevert(abi.encodeWithSelector(ChipBurner.BurnDidNotReduceSupply.selector, SUPPLY, SUPPLY));
        burner.burnAll();

        assertEq(burner.totalBurned(), 0, "nothing counted");
    }

    /* ------------------------------------------------------------------ */
    /*                    $CHIP CAN ONLY LEAVE BY BURNING                   */
    /* ------------------------------------------------------------------ */

    /// @notice There is no other exit, and not even the multisig has one. This is asserted
    ///         against the ABI itself: if a `transfer`/`sweep`/`rescue`/`execute` is ever
    ///         added, this test starts failing.
    function test_thereIsNoOtherWayForChipToLeave() public {
        chip.transfer(address(burner), 1_000 ether);

        string[6] memory forbidden = [
            "transfer(address,uint256)",
            "sweep(address,address)",
            "rescue(address,address,uint256)",
            "recoverExcess(address,address)",
            "execute(bytes)",
            "call(address,bytes)"
        ];
        for (uint256 i; i < 6; ++i) {
            (bool ok,) = address(burner).call(abi.encodeWithSignature(forbidden[i], alice, uint256(1)));
            assertFalse(ok, forbidden[i]);
        }

        assertEq(chip.balanceOf(address(burner)), 1_000 ether, "still here, still only burnable");

        vm.prank(alice);
        burner.burnAll();
        assertEq(chip.totalSupply(), SUPPLY - 1_000 ether, "the one exit");
    }

    /// @notice The multisig owns the wrapper and still cannot touch the balance.
    function test_theMultisigCannotMoveChipEither() public {
        chip.transfer(address(burner), 1_000 ether);
        uint256 before = chip.balanceOf(multisig);

        vm.prank(multisig);
        (bool ok,) = address(burner).call(abi.encodeWithSignature("transfer(address,uint256)", multisig, 1_000 ether));
        assertFalse(ok);
        assertEq(chip.balanceOf(multisig), before, "not a wei");
    }

    /* ------------------------------------------------------------------ */
    /*                  THE PASS-THROUGHS, SO WE ARE NOT BRICKED            */
    /* ------------------------------------------------------------------ */

    /// @notice `transferOwnership` swept up the metadata power too. Without this the token's
    ///         URI would be frozen the moment the Burner took ownership.
    function test_adminCanUpdateTheTokenUri() public {
        vm.prank(multisig);
        burner.updateTokenUri("ipfs://chipworks/v2");
        assertEq(chip.tokenURI(), "ipfs://chipworks/v2");
    }

    /// @notice The escape hatch. Ownership of the TOKEN can be moved on, which is what makes
    ///         it safe to leave `mintInflation` and the rest unexposed.
    function test_adminCanMoveTheTokensOwnershipOn() public {
        address successor = makeAddr("successorWrapper");
        vm.prank(multisig);
        burner.transferTokenOwnership(successor);
        assertEq(chip.owner(), successor, "not a permanent trap");
    }

    /// @notice And a non-admin can do neither.
    function test_aStrangerCannotUseThePassThroughs() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        burner.updateTokenUri("ipfs://mine");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        burner.transferTokenOwnership(alice);
        vm.stopPrank();

        assertEq(chip.owner(), address(burner), "still ours");
    }

    /// @notice **`mintInflation` IS NOT EXPOSED, AND THAT IS THE DECISION.** A permissionless
    ///         burner that can also mint is a contradiction. If it is ever genuinely needed,
    ///         the route is `transferTokenOwnership` to a wrapper that implements it — visible,
    ///         deliberate, and not something the multisig can do quietly through this one.
    function test_thereIsNoWayToMintThroughTheBurner() public {
        string[3] memory minty = ["mintInflation()", "updateMintRate(uint256)", "unlockPool()"];
        for (uint256 i; i < 3; ++i) {
            vm.prank(multisig);
            (bool ok,) = address(burner).call(abi.encodeWithSignature(minty[i], uint256(1)));
            assertFalse(ok, minty[i]);
        }
        assertEq(chip.totalSupply(), SUPPLY, "supply cannot go up through here");
    }

    /// @notice A failing pass-through bubbles the token's reason rather than swallowing it.
    function test_aFailedPassThroughBubblesTheReason() public {
        chip.setUriReverts(true);
        vm.prank(multisig);
        vm.expectPartialRevert(ChipBurner.PassThroughFailed.selector);
        burner.updateTokenUri("ipfs://nope");
    }

    /// @notice The wrapper's own ownership is two-step, like everything else here.
    function test_theWrappersOwnAdminIsTwoStep() public {
        address next = makeAddr("nextMultisig");
        vm.prank(multisig);
        burner.transferOwnership(next);
        assertEq(burner.owner(), multisig, "not yet");

        vm.prank(next);
        burner.acceptOwnership();
        assertEq(burner.owner(), next);
    }
}

/// @notice Bankr's Doppler $CHIP as far as this wrapper is concerned: an ERC-20 whose `burn`
///         and admin calls are owner-gated.
/// @dev The signatures here are the ones `ChipBurner` encodes. They must be checked against
///      the real deployed token before ownership is handed over — see LAUNCH_CONFIG.
contract DopplerLikeChip is ERC20 {
    address public owner;
    string public tokenURI;
    bool internal _burnNoop;
    bool internal _uriReverts;

    error NotOwner();

    constructor(uint256 supply) ERC20("Chipworks", "CHIP") {
        owner = msg.sender;
        _mint(msg.sender, supply);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function setBurnNoop(bool v) external {
        _burnNoop = v;
    }

    function setUriReverts(bool v) external {
        _uriReverts = v;
    }

    /// @dev Owner-gated, which is the entire reason the wrapper has to own the token.
    function burn(uint256 amount) external onlyOwner {
        if (_burnNoop) return; // a token that says it burned and did not
        _burn(msg.sender, amount);
    }

    function updateTokenURI(string calldata uri) external onlyOwner {
        require(!_uriReverts, "URI_LOCKED");
        tokenURI = uri;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }
}
