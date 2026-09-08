// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {Furnace} from "../../src/furnace/Furnace.sol";
import {MockNoun} from "../mocks/MockNoun.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title BurnVisibilityTest
/// @notice Burned fuel must actually cease to exist, and burned $CHIP must at least be
///         countable.
///
/// @dev TWO CONTRACTS WE DO NOT OWN, TWO DIFFERENT ANSWERS.
///
///      **Chiplets** is `ERC721Burnable`, so the Furnace calls `burn(tokenId)` on tokens the
///      user has approved it for. That emits `Transfer(owner, address(0), tokenId)` and
///      decrements `totalSupply` — OpenSea and the explorers show the collection shrinking.
///
///      **$CHIP** is Bankr's Doppler token and exposes no `burn` at all, so a transfer to
///      `0xdead` is the only burn available and `totalSupply` never moves. That is a
///      limitation of their contract, not a shortcut in ours, and the honest circulating
///      figure is `totalSupply - balanceOf(0xdead)`.
///
///      The suite also pins the thing that makes approve-then-burn safe: the Furnace can only
///      reach tokens the caller named AND owns, even though the approval it holds is broad.
contract BurnVisibilityTest is Test {
    Furnace internal furnace;
    SeaDropLikeChiplets internal chiplets;
    MockNoun internal based;
    MockNoun internal dark;
    MockERC20 internal chip;

    address internal multisig = makeAddr("multisig");
    address internal alice = makeAddr("alice");
    address internal mallory = makeAddr("mallory");

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint8 internal constant BASED_RECIPE = 0;
    uint16 internal constant FUEL_COST = 5;
    uint256 internal constant CHIP_COST = 25_000 ether;

    function setUp() public {
        vm.warp(1_700_000_000);
        chiplets = new SeaDropLikeChiplets();
        based = new MockNoun("Based Nouns", "BASED");
        dark = new MockNoun("DarkNOUNs", "DARK");
        chip = new MockERC20("Chipworks", "CHIP", 18);

        furnace = new Furnace(
            multisig,
            address(chip),
            0x000000000000000000000000000000000000dEaD,
            address(chiplets),
            Furnace.Recipe({
                exists: true, paused: false, outputCollection: address(based), fuelCost: FUEL_COST, chipCost: CHIP_COST
            }),
            Furnace.Recipe({
                exists: true, paused: false, outputCollection: address(dark), fuelCost: 12, chipCost: 60_000 ether
            })
        );

        uint256[] memory ids = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            ids[i] = 100 + i;
            based.mint(multisig, ids[i]);
        }
        vm.startPrank(multisig);
        based.setApprovalForAll(address(furnace), true);
        furnace.depositStock(address(based), ids);
        vm.stopPrank();
    }

    /// @dev The forge flow the site must implement: approve the Furnace as an operator, then
    ///      forge. Exactly the marketplace pattern.
    function _fuel(address who, uint256 startId, uint256 n) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = startId + i;
            chiplets.mint(who, ids[i]);
        }
        chip.mint(who, CHIP_COST);
        vm.startPrank(who);
        chiplets.setApprovalForAll(address(furnace), true); // step one
        chip.approve(address(furnace), type(uint256).max);
        vm.stopPrank();
    }

    /* ------------------------------------------------------------------ */
    /*                    THE FUEL IS TRULY BURNED                          */
    /* ------------------------------------------------------------------ */

    /// @notice Forging destroys the Chiplets: `totalSupply` falls, `ownerOf` reverts, and the
    ///         dead address receives nothing.
    function test_forgingTrulyBurnsTheFuelAndReducesSupply() public {
        uint256[] memory ids = _fuel(alice, 1, FUEL_COST);
        assertEq(chiplets.totalSupply(), FUEL_COST);

        vm.prank(alice);
        furnace.forge(BASED_RECIPE, ids);

        assertEq(chiplets.totalSupply(), 0, "supply actually fell");
        assertEq(chiplets.balanceOf(DEAD), 0, "and nothing was parked at 0xdead");
        for (uint256 i; i < ids.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, ids[i]));
            chiplets.ownerOf(ids[i]);
        }
        assertEq(furnace.totalFuelTrueBurned(), FUEL_COST, "counted as a true burn");
        assertEq(furnace.totalFuelBurned(), FUEL_COST);
    }

    /// @notice The burn emits `Transfer(owner, address(0), tokenId)` — the event OpenSea and
    ///         the explorers read to decrement a collection's supply.
    function test_theBurnEmitsATransferToTheZeroAddress() public {
        uint256[] memory ids = _fuel(alice, 1, FUEL_COST);

        vm.recordLogs();
        vm.prank(alice);
        furnace.forge(BASED_RECIPE, ids);

        // Scanned rather than matched positionally: a forge emits several events and the
        // burns are not the first of them.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 burns;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(chiplets) && logs[i].topics.length == 4
                    && logs[i].topics[0] == keccak256("Transfer(address,address,uint256)")
                    && logs[i].topics[2] == bytes32(0)
            ) ++burns;
        }
        assertEq(burns, FUEL_COST, "one Transfer-to-zero per Chiplet, which is what a burn is");
    }

    /* ------------------------------------------------------------------ */
    /*        THE APPROVAL IS BROAD; WHAT WE DO WITH IT IS NARROW           */
    /* ------------------------------------------------------------------ */

    /// @notice THE GUARANTEE. `setApprovalForAll` lets the Furnace reach every Chiplet Alice
    ///         owns — as it would any marketplace. The Furnace only ever destroys the ids the
    ///         CALLER named, and only after checking the caller owns them.
    function test_theFurnaceOnlyBurnsTheTokensTheCallerNamed() public {
        uint256[] memory ids = _fuel(alice, 1, FUEL_COST);
        // Alice also holds tokens she is not forging with.
        chiplets.mint(alice, 900);
        chiplets.mint(alice, 901);

        vm.prank(alice);
        furnace.forge(BASED_RECIPE, ids);

        assertEq(chiplets.ownerOf(900), alice, "untouched");
        assertEq(chiplets.ownerOf(901), alice, "untouched");
        assertEq(chiplets.balanceOf(alice), 2);
    }

    /// @notice And it can never burn somebody ELSE'S token, even one approved to it.
    function test_theFurnaceCannotBurnAnotherHoldersTokens() public {
        _fuel(alice, 1, FUEL_COST);

        // Mallory approves the Furnace too, then tries to forge using Alice's ids.
        chip.mint(mallory, CHIP_COST);
        vm.startPrank(mallory);
        chiplets.setApprovalForAll(address(furnace), true);
        chip.approve(address(furnace), type(uint256).max);
        vm.stopPrank();

        uint256[] memory alices = new uint256[](FUEL_COST);
        for (uint256 i; i < FUEL_COST; ++i) {
            alices[i] = 1 + i;
        }

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(Furnace.NotFuelOwner.selector, uint256(1), mallory));
        furnace.forge(BASED_RECIPE, alices);

        assertEq(chiplets.totalSupply(), FUEL_COST, "nothing burned");
        assertEq(chiplets.ownerOf(1), alice);
    }

    /// @notice No approval, no burn. The Furnace has no privileged role to fall back on.
    function test_withoutApprovalTheForgeReverts() public {
        uint256[] memory ids = new uint256[](FUEL_COST);
        for (uint256 i; i < FUEL_COST; ++i) {
            ids[i] = 1 + i;
            chiplets.mint(alice, ids[i]);
        }
        chip.mint(alice, CHIP_COST);
        vm.prank(alice);
        chip.approve(address(furnace), type(uint256).max);
        // Deliberately no setApprovalForAll.

        vm.prank(alice);
        vm.expectRevert();
        furnace.forge(BASED_RECIPE, ids);
        assertEq(chiplets.totalSupply(), FUEL_COST, "nothing burned");
    }

    /* ------------------------------------------------------------------ */
    /*          A COLLECTION WITHOUT `burn` FALLS BACK TO 0xdead            */
    /* ------------------------------------------------------------------ */

    /// @notice Fuel whose collection exposes no `burn` — a Noun, say — goes to `0xdead`
    ///         instead. It is gone, but the supply does not move, and the counters say so.
    function test_aCollectionWithoutBurnFallsBackToDeadAndSaysSo() public {
        MockNoun plain = new MockNoun("No Burn Here", "NOBURN");
        Furnace f = new Furnace(
            multisig,
            address(chip),
            0x000000000000000000000000000000000000dEaD,
            address(plain),
            Furnace.Recipe({
                exists: true, paused: false, outputCollection: address(based), fuelCost: FUEL_COST, chipCost: CHIP_COST
            }),
            Furnace.Recipe({
                exists: true, paused: false, outputCollection: address(dark), fuelCost: 12, chipCost: 60_000 ether
            })
        );

        uint256[] memory outIds = new uint256[](1);
        outIds[0] = 700;
        based.mint(multisig, 700);
        vm.startPrank(multisig);
        based.setApprovalForAll(address(f), true);
        f.depositStock(address(based), outIds);
        vm.stopPrank();

        uint256[] memory ids = new uint256[](FUEL_COST);
        for (uint256 i; i < FUEL_COST; ++i) {
            ids[i] = 1 + i;
            plain.mint(alice, ids[i]);
        }
        chip.mint(alice, CHIP_COST);
        vm.startPrank(alice);
        plain.setApprovalForAll(address(f), true);
        chip.approve(address(f), type(uint256).max);
        vm.stopPrank();

        vm.prank(alice);
        f.forge(BASED_RECIPE, ids);

        assertEq(plain.balanceOf(DEAD), FUEL_COST, "dead-held, not destroyed");
        assertEq(plain.ownerOf(1), DEAD);
        assertEq(f.totalFuelBurned(), FUEL_COST);
        assertEq(f.totalFuelTrueBurned(), 0, "and the counter tells the two apart");
    }

    /* ------------------------------------------------------------------ */
    /*                    $CHIP: COUNTED, NOT DESTROYED                     */
    /* ------------------------------------------------------------------ */

    /// @notice $CHIP has no burn, so the tokens sit at `0xdead` and `totalSupply` does not
    ///         move. The counter is what makes the burn visible at all.
    function test_chipIsCountedAtDeadBecauseItCannotBeDestroyed() public {
        uint256[] memory ids = _fuel(alice, 1, FUEL_COST);
        uint256 supplyBefore = chip.totalSupply();

        vm.prank(alice);
        furnace.forge(BASED_RECIPE, ids);

        assertEq(chip.totalSupply(), supplyBefore, "supply did NOT fall - this is the Bankr limitation");
        assertEq(chip.balanceOf(DEAD), CHIP_COST, "it is at the canonical dead address");
        assertEq(furnace.totalChipBurned(), CHIP_COST, "and it is counted");
    }

    /// @notice The dead address is the canonical one Basescan labels as a burn address.
    function test_theBurnAddressIsTheCanonicalOne() public view {
        assertEq(furnace.BURN_ADDRESS(), 0x000000000000000000000000000000000000dEaD);
    }

    /* ------------------------------------------------------------------ */
    /*       THE APPROVAL IS WHAT AUTHORISES, NOT ANYTHING OF OURS          */
    /* ------------------------------------------------------------------ */

    /// @notice Without an approval, a third party calling the collection's own `burn` is
    ///         refused by the COLLECTION. The Furnace has no privilege to lend it.
    ///
    /// @dev This is the load-bearing property of the whole approve-then-burn design. It lives
    ///      in OpenSea's contract, not in ours: `ERC721SeaDrop.burn` is `_burn(tokenId, true)`
    ///      and ERC721A's approval check refuses anyone who is not the owner, token-approved,
    ///      or an operator. If that ever stopped being true, the Furnace would not be the
    ///      thing that broke — but it is what the Furnace relies on, so it is asserted here.
    function test_theCollectionItselfRefusesAnUnapprovedBurner() public {
        chiplets.mint(alice, 42);

        vm.prank(mallory);
        vm.expectRevert(SeaDropLikeChiplets.TransferCallerNotOwnerNorApproved.selector);
        chiplets.burn(42);

        assertEq(chiplets.ownerOf(42), alice, "still hers");
        assertEq(chiplets.totalSupply(), 1);
    }

    /// @notice And the operator branch is exactly what the Furnace uses: with
    ///         `setApprovalForAll`, the burn is authorised; without it, refused.
    function test_theOperatorBranchIsWhatAuthorisesTheFurnace() public {
        chiplets.mint(alice, 42);
        address operator = makeAddr("someOperator");

        vm.prank(operator);
        vm.expectRevert(SeaDropLikeChiplets.TransferCallerNotOwnerNorApproved.selector);
        chiplets.burn(42);

        vm.prank(alice);
        chiplets.setApprovalForAll(operator, true);

        vm.prank(operator);
        chiplets.burn(42); // now allowed, by the collection's own rule

        assertEq(chiplets.totalSupply(), 0, "supply fell");
    }

    /// @notice Revoking the approval stops the Furnace dead, mid-relationship. Nothing in our
    ///         contracts caches or persists the right to burn.
    function test_revokingApprovalStopsTheFurnaceImmediately() public {
        uint256[] memory ids = _fuel(alice, 1, FUEL_COST);

        vm.prank(alice);
        chiplets.setApprovalForAll(address(furnace), false);

        vm.prank(alice);
        vm.expectRevert();
        furnace.forge(BASED_RECIPE, ids);

        assertEq(chiplets.totalSupply(), FUEL_COST, "nothing burned");
        assertEq(chiplets.ownerOf(1), alice);
    }
}

/// @notice Chiplets as it will actually ship: **OpenSea's `ERC721SeaDrop`**, which is
///         `ERC721A` underneath. Not a contract in this repo.
///
/// @dev MODELLED ON THE REAL AUTHORISATION PATH, because that is the thing under test.
///      `ERC721SeaDrop.burn(uint256)` — present in both the standard and the cloneable
///      variant OpenSea's drop UI deploys — is exactly:
///
///          function burn(uint256 tokenId) external { _burn(tokenId, true); }
///
///      and ERC721A's `_burn` with `approvalCheck == true` authorises:
///
///          if (!_isSenderApprovedOrOwner(...))
///              if (!isApprovedForAll(from, _msgSenderERC721A())) revert TransferCallerNotOwnerNorApproved
///
///      i.e. owner, or token-approved, **or operator**. That last branch is what makes
///      approve-then-burn work, and it is reproduced faithfully below rather than approximated
///      with OpenZeppelin's `ERC721Burnable`, which has a different lineage.
///
///      ERC721A's `totalSupply()` is `_currentIndex - _burnCounter - _startTokenId()`, so a
///      burn genuinely reduces it, and `ownerOf` on a burned id reverts. Both are mirrored.
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

    /// @dev The SeaDrop signature, with ERC721A's approval check.
    function burn(uint256 tokenId) external {
        address owner = ownerOf(tokenId);
        if (msg.sender != owner && getApproved(tokenId) != msg.sender && !isApprovedForAll(owner, msg.sender)) {
            revert TransferCallerNotOwnerNorApproved();
        }
        _burn(tokenId);
        ++_burnCounter;
    }
}
