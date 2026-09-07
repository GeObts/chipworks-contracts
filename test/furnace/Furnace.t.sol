// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Furnace} from "../../src/furnace/Furnace.sol";
import {MockNoun} from "../mocks/MockNoun.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BlacklistToken, PausableToken, LyingToken, FeeOnTransferToken} from "../mocks/HostileTokens.sol";

contract FurnaceTest is Test {
    Furnace internal furnace;

    MockNoun internal lil;
    MockNoun internal based;
    MockNoun internal dark;
    MockERC20 internal chip;

    address internal multisig = makeAddr("multisig");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint8 internal constant BASED_RECIPE = 0;
    uint8 internal constant DARK_RECIPE = 1;

    uint16 internal constant BASED_LILS = 5;
    uint256 internal constant BASED_CHIP = 25_000 ether;
    uint16 internal constant DARK_LILS = 12;
    uint256 internal constant DARK_CHIP = 60_000 ether;

    event Forged(
        address indexed caller,
        uint8 indexed recipeId,
        uint256[] fuelIds,
        uint256 chipBurned,
        address indexed outputCollection,
        uint256 outputTokenId
    );
    event RecipeChangeQueued(uint8 indexed recipeId, uint16 fuelCost, uint256 chipCost, uint64 executableAt);

    function setUp() public {
        vm.warp(1_700_000_000);
        lil = new MockNoun(unicode"Lil Based Nouns", "LIL");
        based = new MockNoun("Based Nouns", "BASED");
        dark = new MockNoun("DarkNOUNs", "DARK");
        chip = new MockERC20("Chipworks", "CHIP", 18);

        furnace = new Furnace(
            multisig,
            address(chip),
            0x000000000000000000000000000000000000dEaD,
            address(lil),
            Furnace.Recipe({
                exists: true,
                paused: false,
                outputCollection: address(based),
                fuelCost: BASED_LILS,
                chipCost: BASED_CHIP
            }),
            Furnace.Recipe({
                exists: true, paused: false, outputCollection: address(dark), fuelCost: DARK_LILS, chipCost: DARK_CHIP
            })
        );

        _seed(address(based), 100, 3);
        _seed(address(dark), 200, 2);
    }

    /* ------------------------------- helpers ------------------------------- */

    /// @dev Mint `n` output NFTs to the multisig and deposit them as stock.
    function _seed(address collection, uint256 startId, uint256 n) internal {
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = startId + i;
            MockNoun(collection).mint(multisig, ids[i]);
        }
        vm.startPrank(multisig);
        MockNoun(collection).setApprovalForAll(address(furnace), true);
        furnace.depositStock(collection, ids);
        vm.stopPrank();
    }

    /// @dev Give `to` `n` Lils starting at `startId`, plus CHIP, all approved.
    function _fuel(address to, uint256 startId, uint256 n, uint256 chipAmount) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = startId + i;
            lil.mint(to, ids[i]);
        }
        chip.mint(to, chipAmount);
        vm.startPrank(to);
        lil.setApprovalForAll(address(furnace), true);
        chip.approve(address(furnace), type(uint256).max);
        vm.stopPrank();
    }

    /* ------------------------------------------------------------------ */
    /*                            HAPPY PATH                                */
    /* ------------------------------------------------------------------ */

    function test_forgeBased_burnsInputsAndPaysOldestStock() public {
        uint256[] memory ids = _fuel(alice, 1, BASED_LILS, BASED_CHIP);

        vm.prank(alice);
        uint256 got = furnace.forge(BASED_RECIPE, ids);

        assertEq(got, 100, "FIFO: the oldest deposited token");
        assertEq(based.ownerOf(100), alice, "output delivered");

        for (uint256 i; i < ids.length; ++i) {
            assertEq(lil.ownerOf(ids[i]), DEAD, "every Lil burned");
        }
        assertEq(chip.balanceOf(DEAD), BASED_CHIP, "CHIP burned");
        assertEq(chip.balanceOf(alice), 0);

        assertEq(furnace.totalFuelBurned(), BASED_LILS);
        assertEq(furnace.totalChipBurned(), BASED_CHIP);
        assertEq(furnace.totalForged(), 1);
        assertEq(furnace.stockRemaining(BASED_RECIPE), 2);
    }

    function test_forgeDark_usesItsOwnRecipeAndStock() public {
        uint256[] memory ids = _fuel(alice, 1, DARK_LILS, DARK_CHIP);

        vm.prank(alice);
        uint256 got = furnace.forge(DARK_RECIPE, ids);

        assertEq(got, 200, "oldest Dark in stock");
        assertEq(dark.ownerOf(200), alice);
        assertEq(chip.balanceOf(DEAD), DARK_CHIP);
        assertEq(furnace.totalFuelBurned(), DARK_LILS);
        assertEq(furnace.stockRemaining(DARK_RECIPE), 1);
        assertEq(furnace.stockRemaining(BASED_RECIPE), 3, "Based stock untouched");
    }

    function test_fifoOrderAcrossSeveralForges() public {
        uint256 nextLil = 1;
        for (uint256 k; k < 3; ++k) {
            uint256[] memory ids = _fuel(alice, nextLil, BASED_LILS, BASED_CHIP);
            nextLil += BASED_LILS;
            vm.prank(alice);
            assertEq(furnace.forge(BASED_RECIPE, ids), 100 + k, "strict FIFO");
        }
        assertEq(furnace.stockRemaining(BASED_RECIPE), 0);
        assertEq(furnace.totalForged(), 3);
    }

    function test_emitsForgeHistory() public {
        uint256[] memory ids = _fuel(alice, 1, BASED_LILS, BASED_CHIP);
        vm.expectEmit(true, true, true, true, address(furnace));
        emit Forged(alice, BASED_RECIPE, ids, BASED_CHIP, address(based), 100);
        vm.prank(alice);
        furnace.forge(BASED_RECIPE, ids);
    }

    function test_viewsTheSiteNeeds() public {
        (uint16 fuelCost, uint256 chipCost) = furnace.costOf(BASED_RECIPE);
        assertEq(fuelCost, BASED_LILS);
        assertEq(chipCost, BASED_CHIP);

        (bool available, uint256 tokenId) = furnace.nextOutput(BASED_RECIPE);
        assertTrue(available);
        assertEq(tokenId, 100);

        uint256[] memory q = furnace.stockQueue(address(based));
        assertEq(q.length, 3);
        assertEq(q[0], 100);
        assertEq(q[2], 102);
    }

    /* ------------------------------------------------------------------ */
    /*                          INPUT VALIDATION                            */
    /* ------------------------------------------------------------------ */

    function test_wrongLilCountReverts() public {
        uint256[] memory four = _fuel(alice, 1, 4, BASED_CHIP);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Furnace.WrongFuelCount.selector, uint256(4), BASED_LILS));
        furnace.forge(BASED_RECIPE, four);
    }

    function test_duplicateLilReverts() public {
        _fuel(alice, 1, BASED_LILS, BASED_CHIP);
        uint256[] memory dup = new uint256[](BASED_LILS);
        dup[0] = 1;
        dup[1] = 2;
        dup[2] = 3;
        dup[3] = 4;
        dup[4] = 1; // repeat, and out of order

        // Since batch 9 the inputs must be strictly ascending, so a NON-ADJACENT repeat is
        // caught by the ordering rule rather than by an equality check — it is the same
        // rejection reached one comparison earlier. The adjacent case keeps
        // `DuplicateFuelToken`; see `test_FUR005_anAdjacentDuplicateStillReadsAsADuplicate`.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Furnace.FuelIdsNotAscending.selector, uint256(4), uint256(1)));
        furnace.forge(BASED_RECIPE, dup);
    }

    function test_nonOwnedLilReverts() public {
        uint256[] memory ids = _fuel(alice, 1, BASED_LILS, BASED_CHIP);
        // Bob tries to burn Alice's Lils.
        chip.mint(bob, BASED_CHIP);
        vm.startPrank(bob);
        chip.approve(address(furnace), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(Furnace.NotFuelOwner.selector, uint256(1), bob));
        furnace.forge(BASED_RECIPE, ids);
        vm.stopPrank();
    }

    /// @notice A Lil from the wrong collection is simply not an id this Furnace owns —
    ///         `ownerOf` on the Lil contract fails or names someone else. Either way the
    ///         forge cannot consume a token from a different collection.
    function test_wrongCollectionTokenCannotBeUsed() public {
        _fuel(alice, 1, BASED_LILS, BASED_CHIP);
        based.mint(alice, 900); // a Based Noun, not a Lil

        uint256[] memory ids = new uint256[](BASED_LILS);
        ids[0] = 900;
        ids[1] = 2;
        ids[2] = 3;
        ids[3] = 4;
        ids[4] = 5;

        vm.prank(alice);
        vm.expectRevert(); // Lil #900 does not exist, so ownerOf reverts
        furnace.forge(BASED_RECIPE, ids);
    }

    function test_emptyStockRevertsWithNamedError() public {
        // Drain Based stock.
        uint256 nextLil = 1;
        for (uint256 k; k < 3; ++k) {
            uint256[] memory ids = _fuel(alice, nextLil, BASED_LILS, BASED_CHIP);
            nextLil += BASED_LILS;
            vm.prank(alice);
            furnace.forge(BASED_RECIPE, ids);
        }
        assertEq(furnace.stockRemaining(BASED_RECIPE), 0);

        uint256[] memory more = _fuel(alice, nextLil, BASED_LILS, BASED_CHIP);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Furnace.OutOfStock.selector, BASED_RECIPE, address(based)));
        furnace.forge(BASED_RECIPE, more);

        // And nothing was consumed by the failed attempt.
        assertEq(lil.ownerOf(more[0]), alice, "Lils untouched");
        assertEq(chip.balanceOf(alice), BASED_CHIP, "CHIP untouched");
    }

    function test_unknownRecipeReverts() public {
        uint256[] memory ids = _fuel(alice, 1, BASED_LILS, BASED_CHIP);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Furnace.BadRecipe.selector, uint8(7)));
        furnace.forge(7, ids);
    }

    /* ------------------------------------------------------------------ */
    /*                              PAUSING                                 */
    /* ------------------------------------------------------------------ */

    function test_pauseBlocksOneRecipeOnly() public {
        vm.prank(multisig);
        furnace.setPaused(BASED_RECIPE, true);

        uint256[] memory basedIds = _fuel(alice, 1, BASED_LILS, BASED_CHIP);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Furnace.RecipeIsPaused.selector, BASED_RECIPE));
        furnace.forge(BASED_RECIPE, basedIds);

        // Dark still forges.
        uint256[] memory darkIds = _fuel(bob, 500, DARK_LILS, DARK_CHIP);
        vm.prank(bob);
        assertEq(furnace.forge(DARK_RECIPE, darkIds), 200);
    }

    function test_pauseIsImmediateAndReversible() public {
        vm.prank(multisig);
        furnace.setPaused(BASED_RECIPE, true);
        assertTrue(furnace.recipe(BASED_RECIPE).paused);

        vm.prank(multisig);
        furnace.setPaused(BASED_RECIPE, false);

        uint256[] memory ids = _fuel(alice, 1, BASED_LILS, BASED_CHIP);
        vm.prank(alice);
        assertEq(furnace.forge(BASED_RECIPE, ids), 100);
    }

    function test_pauseOnlyMultisig() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        furnace.setPaused(BASED_RECIPE, true);
    }

    /* ------------------------------------------------------------------ */
    /*                        TIMELOCKED RECIPES                            */
    /* ------------------------------------------------------------------ */

    function test_recipeChangeNeedsFortyEightHoursAndIsAnnounced() public {
        uint64 expectedEta = uint64(block.timestamp) + 48 hours;

        vm.expectEmit(true, true, true, true, address(furnace));
        emit RecipeChangeQueued(BASED_RECIPE, 8, 40_000 ether, expectedEta);
        vm.prank(multisig);
        furnace.queueRecipeChange(BASED_RECIPE, 8, 40_000 ether);

        // Not yet.
        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(Furnace.TimelockNotElapsed.selector, uint64(block.timestamp), expectedEta)
        );
        furnace.executeRecipeChange(BASED_RECIPE);

        // The old price still applies throughout the delay.
        (uint16 fuelCost,) = furnace.costOf(BASED_RECIPE);
        assertEq(fuelCost, BASED_LILS, "unchanged until executed");

        vm.warp(expectedEta);
        vm.prank(multisig);
        furnace.executeRecipeChange(BASED_RECIPE);

        (uint16 newLil, uint256 newChip) = furnace.costOf(BASED_RECIPE);
        assertEq(newLil, 8);
        assertEq(newChip, 40_000 ether);
    }

    function test_queuedChangeCanBeCancelled() public {
        vm.prank(multisig);
        furnace.queueRecipeChange(BASED_RECIPE, 8, 40_000 ether);
        vm.prank(multisig);
        furnace.cancelRecipeChange(BASED_RECIPE);

        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(Furnace.NothingQueued.selector, BASED_RECIPE));
        furnace.executeRecipeChange(BASED_RECIPE);
    }

    function test_recipeChangesAreBounded() public {
        vm.startPrank(multisig);
        vm.expectRevert(Furnace.BadConfig.selector);
        furnace.queueRecipeChange(BASED_RECIPE, 0, 1 ether); // zero Lils

        vm.expectRevert(Furnace.BadConfig.selector);
        furnace.queueRecipeChange(BASED_RECIPE, 101, 1 ether); // past MAX_FUEL_COST
        vm.stopPrank();
    }

    function test_recipeChangeOnlyMultisig() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        furnace.queueRecipeChange(BASED_RECIPE, 8, 1 ether);
    }

    /* ------------------------------------------------------------------ */
    /*                    BURNED MEANS BURNED (the point)                   */
    /* ------------------------------------------------------------------ */

    /// @notice The Furnace never holds an input, so there is no admin path to one. This is
    ///         structural, not a rule someone has to remember.
    function test_furnaceNeverHoldsInputsSoAdminCannotReachThem() public {
        uint256[] memory ids = _fuel(alice, 1, BASED_LILS, BASED_CHIP);
        vm.prank(alice);
        furnace.forge(BASED_RECIPE, ids);

        assertEq(chip.balanceOf(address(furnace)), 0, "no CHIP at rest");
        for (uint256 i; i < ids.length; ++i) {
            assertEq(lil.ownerOf(ids[i]), DEAD);
            assertTrue(lil.ownerOf(ids[i]) != address(furnace));
        }

        // There is no function that could move them: the only NFT mover is withdrawStock,
        // and it can only reach registered OUTPUT stock.
        vm.prank(multisig);
        vm.expectRevert(); // Lils were never stock for any collection
        furnace.withdrawStock(address(lil), 1, multisig);
    }

    function test_adminWithdrawTakesFromTheTailNotTheQueueHead() public {
        // Stock is 100, 101, 102. The next forge must still get 100 after a withdrawal.
        vm.prank(multisig);
        furnace.withdrawStock(address(based), 1, multisig);

        assertEq(based.ownerOf(102), multisig, "tail token returned");
        assertEq(furnace.stockRemaining(BASED_RECIPE), 2);

        uint256[] memory ids = _fuel(alice, 1, BASED_LILS, BASED_CHIP);
        vm.prank(alice);
        assertEq(furnace.forge(BASED_RECIPE, ids), 100, "queue head is untouched");
    }

    function test_withdrawCannotOverdraw() public {
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(Furnace.NotEnoughStock.selector, uint256(4), uint256(3)));
        furnace.withdrawStock(address(based), 4, multisig);
    }

    function test_withdrawOnlyMultisig() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        furnace.withdrawStock(address(based), 1, alice);
    }

    function test_strayNftIsRecoverableButLiveStockIsNot() public {
        based.mint(alice, 777);
        vm.prank(alice);
        based.transferFrom(alice, address(furnace), 777); // arrives outside depositStock

        // It never became forgeable.
        assertEq(furnace.stockRemaining(BASED_RECIPE), 3);

        vm.prank(multisig);
        furnace.rescueStrayNFT(address(based), 777, multisig);
        assertEq(based.ownerOf(777), multisig);

        // Registered stock cannot be taken this way.
        vm.prank(multisig);
        vm.expectRevert();
        furnace.rescueStrayNFT(address(based), 100, multisig);
    }

    /* ------------------------------------------------------------------ */
    /*                          HOSTILE $CHIP                               */
    /* ------------------------------------------------------------------ */

    function _deployWith(address chipAddr) internal returns (Furnace f) {
        f = new Furnace(
            multisig,
            chipAddr,
            0x000000000000000000000000000000000000dEaD,
            address(lil),
            Furnace.Recipe({
                exists: true,
                paused: false,
                outputCollection: address(based),
                fuelCost: BASED_LILS,
                chipCost: BASED_CHIP
            }),
            Furnace.Recipe({
                exists: true, paused: false, outputCollection: address(dark), fuelCost: DARK_LILS, chipCost: DARK_CHIP
            })
        );
        uint256[] memory ids = new uint256[](2);
        ids[0] = 300;
        ids[1] = 301;
        based.mint(multisig, 300);
        based.mint(multisig, 301);
        vm.startPrank(multisig);
        based.setApprovalForAll(address(f), true);
        f.depositStock(address(based), ids);
        vm.stopPrank();
    }

    /// @notice A $CHIP that reports success but moves nothing must not buy a forge.
    function test_lyingChipCannotForge() public {
        LyingToken liar = new LyingToken("Liar", "LIE", 18);
        Furnace f = _deployWith(address(liar));

        uint256[] memory ids = new uint256[](BASED_LILS);
        for (uint256 i; i < BASED_LILS; ++i) {
            ids[i] = 50 + i;
            lil.mint(alice, ids[i]);
        }
        liar.mint(alice, BASED_CHIP);
        vm.startPrank(alice);
        lil.setApprovalForAll(address(f), true);
        liar.approve(address(f), type(uint256).max);
        liar.setLying(true);

        vm.expectRevert(abi.encodeWithSelector(Furnace.ChipBurnShortfall.selector, uint256(0), BASED_CHIP));
        f.forge(BASED_RECIPE, ids);
        vm.stopPrank();

        assertEq(lil.ownerOf(ids[0]), alice, "nothing burned on a failed forge");
        assertEq(based.ownerOf(300), address(f), "stock retained");
    }

    /// @notice A taxing $CHIP delivers less than the cost, so the forge fails closed rather
    ///         than letting someone through under-paid.
    /// @dev Uses a LOCAL fee token whose tax goes to a third party. The shared
    ///      `FeeOnTransferToken` mock happens to send its tax to `0xdead`, which is also the
    ///      Furnace's burn address — so the measured delta there is the full amount and the
    ///      forge legitimately succeeds. That is correct behaviour, not a bug, but it makes
    ///      that mock useless for testing shortfall.
    function test_feeOnTransferChipFailsClosed() public {
        TaxToSomewhereElse taxed = new TaxToSomewhereElse();
        Furnace f = _deployWith(address(taxed));

        uint256[] memory ids = new uint256[](BASED_LILS);
        for (uint256 i; i < BASED_LILS; ++i) {
            ids[i] = 60 + i;
            lil.mint(alice, ids[i]);
        }
        taxed.mint(alice, BASED_CHIP);
        vm.startPrank(alice);
        lil.setApprovalForAll(address(f), true);
        taxed.approve(address(f), type(uint256).max);

        vm.expectRevert(); // ChipBurnShortfall: 1% never arrived
        f.forge(BASED_RECIPE, ids);
        vm.stopPrank();
    }

    /// @notice A frozen $CHIP blocks forging entirely, and consumes nothing.
    function test_frozenChipBlocksForgingCleanly() public {
        BlacklistToken frozen = new BlacklistToken("Freezer", "FRZ", 18);
        Furnace f = _deployWith(address(frozen));

        uint256[] memory ids = new uint256[](BASED_LILS);
        for (uint256 i; i < BASED_LILS; ++i) {
            ids[i] = 70 + i;
            lil.mint(alice, ids[i]);
        }
        frozen.mint(alice, BASED_CHIP);
        frozen.setBlacklisted(alice, true);
        vm.startPrank(alice);
        lil.setApprovalForAll(address(f), true);
        frozen.approve(address(f), type(uint256).max);

        vm.expectRevert(bytes("BLACKLISTED"));
        f.forge(BASED_RECIPE, ids);
        vm.stopPrank();

        assertEq(lil.ownerOf(ids[0]), alice, "no Lil lost to a blocked forge");
    }

    /* ------------------------------------------------------------------ */
    /*                            REENTRANCY                                */
    /* ------------------------------------------------------------------ */

    function test_reentrantRecipientCannotDoubleForge() public {
        ForgeReenterer attacker = new ForgeReenterer(furnace, lil, chip);

        uint256[] memory ids = new uint256[](BASED_LILS * 2);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = 400 + i;
            lil.mint(address(attacker), ids[i]);
        }
        chip.mint(address(attacker), BASED_CHIP * 2);
        attacker.approveAll();

        uint256[] memory first = new uint256[](BASED_LILS);
        uint256[] memory second = new uint256[](BASED_LILS);
        for (uint256 i; i < BASED_LILS; ++i) {
            first[i] = ids[i];
            second[i] = ids[BASED_LILS + i];
        }
        attacker.arm(second);

        // The output uses transferFrom, which does not invoke a receiver hook, so the
        // attacker never gets control mid-forge. nonReentrant is the second line.
        attacker.attack(first);

        assertEq(furnace.totalForged(), 1, "exactly one forge");
        assertEq(furnace.stockRemaining(BASED_RECIPE), 2, "stock fell by exactly one");
    }

    /* ------------------------------------------------------------------ */
    /*                               FUZZ                                   */
    /* ------------------------------------------------------------------ */

    /// @notice Stock can only ever fall by exactly one per successful forge, whatever the
    ///         sequence of forges, deposits, withdrawals and pauses.
    function testFuzz_stockFallsByExactlyOnePerForge(uint8 actions, uint256 seed) public {
        uint256 nextLil = 1_000;
        uint256 nextStock = 5_000;

        for (uint256 step; step < (actions % 12) + 1; ++step) {
            uint256 choice = uint256(keccak256(abi.encode(seed, step))) % 3;
            uint256 before = furnace.stockRemaining(BASED_RECIPE);

            if (choice == 0) {
                // forge
                uint256[] memory ids = _fuel(alice, nextLil, BASED_LILS, BASED_CHIP);
                nextLil += BASED_LILS;
                vm.prank(alice);
                try furnace.forge(BASED_RECIPE, ids) {
                    assertEq(furnace.stockRemaining(BASED_RECIPE), before - 1, "exactly one consumed");
                } catch {
                    assertEq(furnace.stockRemaining(BASED_RECIPE), before, "failed forge consumes nothing");
                }
            } else if (choice == 1) {
                // deposit
                uint256[] memory ids = new uint256[](1);
                ids[0] = nextStock++;
                based.mint(multisig, ids[0]);
                vm.startPrank(multisig);
                based.setApprovalForAll(address(furnace), true);
                furnace.depositStock(address(based), ids);
                vm.stopPrank();
                assertEq(furnace.stockRemaining(BASED_RECIPE), before + 1);
            } else {
                // withdraw
                if (before == 0) continue;
                vm.prank(multisig);
                furnace.withdrawStock(address(based), 1, multisig);
                assertEq(furnace.stockRemaining(BASED_RECIPE), before - 1);
            }
        }

        // The invariant that ties it together: every token ever forged left the contract.
        assertEq(furnace.totalForged(), furnace.forgedByRecipe(BASED_RECIPE) + furnace.forgedByRecipe(DARK_RECIPE));
    }

    /* ------------------------------------------------------------------ */
    /*        THE FUEL IS AN ARGUMENT, NOT AN ASSUMPTION                    */
    /* ------------------------------------------------------------------ */

    /// @notice A Furnace deployed against a COMPLETELY DIFFERENT fuel collection forges Based
    ///         and Dark exactly as before.
    ///
    /// @dev Lil Based Nouns are no longer the burn input; Chiplets is, and Chiplets is a
    ///      plain ERC-721. This proves the swap is a deploy-time argument and nothing more:
    ///      there is no "Lil recipe" to remove, because the fuel is an INPUT to every recipe
    ///      rather than a recipe of its own. Both output paths are unaffected.
    ///
    ///      It is also the test that makes the Chiplets integration a one-line deploy change
    ///      rather than a code change, now that the DN404 seam is gone.
    function test_theFuelCollectionIsADeployArgumentNotAnAssumption() public {
        MockNoun otherFuel = new MockNoun("Some Other Fuel", "FUEL");

        Furnace f = new Furnace(
            multisig,
            address(chip),
            0x000000000000000000000000000000000000dEaD,
            address(otherFuel),
            Furnace.Recipe({
                exists: true,
                paused: false,
                outputCollection: address(based),
                fuelCost: BASED_LILS,
                chipCost: BASED_CHIP
            }),
            Furnace.Recipe({
                exists: true, paused: false, outputCollection: address(dark), fuelCost: DARK_LILS, chipCost: DARK_CHIP
            })
        );

        assertEq(address(f.fuelCollection()), address(otherFuel), "not Lils, and it does not care");

        // Stock both outputs.
        based.mint(multisig, 500);
        dark.mint(multisig, 600);
        vm.startPrank(multisig);
        based.setApprovalForAll(address(f), true);
        dark.setApprovalForAll(address(f), true);
        uint256[] memory oneBased = new uint256[](1);
        oneBased[0] = 500;
        uint256[] memory oneDark = new uint256[](1);
        oneDark[0] = 600;
        f.depositStock(address(based), oneBased);
        f.depositStock(address(dark), oneDark);
        vm.stopPrank();

        // Fund alice with the NEW fuel and forge both paths.
        uint256[] memory basedFuel = new uint256[](BASED_LILS);
        for (uint256 i; i < BASED_LILS; ++i) {
            basedFuel[i] = 1000 + i;
            otherFuel.mint(alice, basedFuel[i]);
        }
        uint256[] memory darkFuel = new uint256[](DARK_LILS);
        for (uint256 i; i < DARK_LILS; ++i) {
            darkFuel[i] = 2000 + i;
            otherFuel.mint(alice, darkFuel[i]);
        }
        chip.mint(alice, BASED_CHIP + DARK_CHIP);

        vm.startPrank(alice);
        otherFuel.setApprovalForAll(address(f), true);
        chip.approve(address(f), type(uint256).max);
        assertEq(f.forge(BASED_RECIPE, basedFuel), 500, "Based path unaffected");
        assertEq(f.forge(DARK_RECIPE, darkFuel), 600, "Dark path unaffected");
        vm.stopPrank();

        assertEq(based.ownerOf(500), alice);
        assertEq(dark.ownerOf(600), alice);
        assertEq(otherFuel.ownerOf(basedFuel[0]), DEAD, "the new fuel burns the same way");
        assertEq(f.totalFuelBurned(), BASED_LILS + DARK_LILS);
    }

    /// @notice And a recipe can ship switched OFF at deploy, which is the other half of
    ///         "removable": at launch the Dark recipe ships paused.
    function test_aRecipeCanShipDisabledWithoutTouchingTheOther() public {
        vm.prank(multisig);
        furnace.setPaused(DARK_RECIPE, true);

        // Based still forges.
        uint256[] memory ids = _fuel(alice, 700, BASED_LILS, BASED_CHIP);
        vm.prank(alice);
        furnace.forge(BASED_RECIPE, ids);

        // Dark is inert.
        uint256[] memory darkIds = _fuel(bob, 800, DARK_LILS, DARK_CHIP);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Furnace.RecipeIsPaused.selector, DARK_RECIPE));
        furnace.forge(DARK_RECIPE, darkIds);
    }

    /* ------------------------------------------------------------------ */
    /*            EXTERNAL REVIEW — BANKR BATCH 9: Furnace.sol              */
    /* ------------------------------------------------------------------ */

    /// @notice SEC-FUR-003. One untransferable token at the head reverts every forge against
    ///         that collection, and everything behind it is unreachable.
    ///
    /// @dev The wedge itself is not prevented — it cannot be, since the Furnace cannot make
    ///      somebody else's collection transferable. What changed is that there is now a way
    ///      out of it. Before `launch-candidate-14` there was none: `withdrawStock` takes the
    ///      tail and `rescueStrayNFT` refuses live stock, so one dead token bricked a recipe
    ///      permanently.
    function test_FUR003_aStuckHeadWedgesTheQueueUntilItIsSkipped() public {
        FreezableNoun out = _freezableRecipe();
        out.freeze(500); // the head

        uint256[] memory f = _fuel(alice, 1, BASED_LILS, BASED_CHIP);
        vm.prank(alice);
        vm.expectRevert(bytes("FROZEN"));
        furnace.forge(BASED_RECIPE, f);

        // The multisig announces the skip and waits.
        vm.prank(multisig);
        furnace.queueStockSkip(address(out));
        assertEq(furnace.pendingSkip(address(out)).tokenId, 500);

        vm.prank(multisig);
        vm.expectPartialRevert(Furnace.TimelockNotElapsed.selector);
        furnace.executeStockSkip(address(out));

        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        furnace.executeStockSkip(address(out));

        // The stuck token is out of the queue and still here; forging resumes behind it.
        assertEq(out.ownerOf(500), address(furnace), "not dispensed, because it cannot be");
        (bool available, uint256 head) = furnace.nextOutput(BASED_RECIPE);
        assertTrue(available);
        assertEq(head, 501, "the queue moved on");

        vm.prank(alice);
        assertEq(furnace.forge(BASED_RECIPE, f), 501, "the recipe works again");
    }

    /// @notice The skip pins the token id, so a queued skip cannot be turned on a healthy
    ///         token that reaches the head during the 48 hours. This is what stops it being
    ///         the queue-jumping lever the contract says does not exist.
    function test_FUR003_aQueuedSkipCannotBeAimedAtADifferentToken() public {
        FreezableNoun out = _freezableRecipe();

        vm.prank(multisig);
        furnace.queueStockSkip(address(out)); // pins 500

        // Somebody forges 500 away normally; 501 is now the head.
        uint256[] memory f = _fuel(alice, 1, BASED_LILS, BASED_CHIP);
        vm.prank(alice);
        assertEq(furnace.forge(BASED_RECIPE, f), 500);

        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(Furnace.SkipTargetMoved.selector, uint256(501), uint256(500)));
        furnace.executeStockSkip(address(out));

        (, uint256 head) = furnace.nextOutput(BASED_RECIPE);
        assertEq(head, 501, "the healthy head is untouched");
    }

    /// @notice A skip can be cancelled, is multisig-only, and needs something to skip.
    function test_FUR003_theSkipIsGovernedLikeEveryOtherQueuedChange() public {
        FreezableNoun out = _freezableRecipe();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        furnace.queueStockSkip(address(out));

        vm.startPrank(multisig);
        furnace.queueStockSkip(address(out));
        furnace.cancelStockSkip(address(out));
        assertFalse(furnace.pendingSkip(address(out)).queued);

        vm.expectRevert(abi.encodeWithSelector(Furnace.NothingSkipQueued.selector, address(out)));
        furnace.executeStockSkip(address(out));

        // Nothing in the queue: nothing to announce.
        vm.expectRevert(abi.encodeWithSelector(Furnace.NotEnoughStock.selector, uint256(1), uint256(0)));
        furnace.queueStockSkip(makeAddr("emptyCollection"));
        vm.stopPrank();
    }

    /// @notice Once skipped the token is no longer live stock, so if it ever becomes
    ///         transferable again the ordinary stray-recovery path can move it.
    function test_FUR003_askippedTokenBecomesRecoverableIfItEverUnfreezes() public {
        FreezableNoun out = _freezableRecipe();
        out.freeze(500);

        vm.prank(multisig);
        furnace.queueStockSkip(address(out));
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        furnace.executeStockSkip(address(out));

        // Still frozen: recovery fails on the collection's own rule, not on ours.
        vm.prank(multisig);
        vm.expectRevert(bytes("FROZEN"));
        furnace.rescueStrayNFT(address(out), 500, multisig);

        out.unfreeze(500);
        vm.prank(multisig);
        furnace.rescueStrayNFT(address(out), 500, multisig);
        assertEq(out.ownerOf(500), multisig, "home at last");
    }

    /// @notice SEC-FUR-004. The head is public, so between reading it and landing a
    ///         transaction anyone can move it on — deliberately, if they want a specific Noun
    ///         to go to somebody else.
    function test_FUR004_anExpectedForgeRefusesTheWrongTokenAndBurnsNothing() public {
        uint256[] memory af = _fuel(alice, 1, BASED_LILS, BASED_CHIP);
        uint256[] memory bf = _fuel(bob, 50, BASED_LILS, BASED_CHIP);

        (, uint256 alicesTarget) = furnace.nextOutput(BASED_RECIPE);
        assertEq(alicesTarget, 100);

        vm.prank(bob); // bob lands first
        furnace.forge(BASED_RECIPE, bf);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Furnace.UnexpectedOutput.selector, uint256(101), uint256(100)));
        furnace.forge(BASED_RECIPE, af, alicesTarget);

        // All-or-nothing: her fuel and her CHIP are untouched.
        for (uint256 i; i < af.length; ++i) {
            assertEq(lil.ownerOf(af[i]), alice, "fuel not burned");
        }
        assertEq(chip.balanceOf(alice), BASED_CHIP, "CHIP not burned");
        assertEq(based.ownerOf(101), address(furnace), "and she took nothing");
    }

    /// @notice The expected form succeeds when the head is what the caller was promised.
    function test_FUR004_anExpectedForgeSucceedsOnAMatch() public {
        uint256[] memory af = _fuel(alice, 1, BASED_LILS, BASED_CHIP);
        (, uint256 head) = furnace.nextOutput(BASED_RECIPE);

        vm.prank(alice);
        assertEq(furnace.forge(BASED_RECIPE, af, head), head);
        assertEq(based.ownerOf(head), alice);
    }

    /// @notice "Give me the next one, I do not mind which" is still a first-class intent. If
    ///         every forge had to name a token, an ordinary one would fail whenever anybody
    ///         else forged first.
    function test_FUR004_theUncheckedFormStillWorks() public {
        uint256[] memory af = _fuel(alice, 1, BASED_LILS, BASED_CHIP);
        uint256[] memory bf = _fuel(bob, 50, BASED_LILS, BASED_CHIP);

        vm.prank(bob);
        furnace.forge(BASED_RECIPE, bf);
        vm.prank(alice);
        assertEq(furnace.forge(BASED_RECIPE, af), 101, "took the next one without complaint");
    }

    /// @notice SEC-FUR-005. Strictly ascending is now the rule, which makes the distinctness
    ///         check a single comparison per element instead of a nested loop.
    function test_FUR005_fuelIdsMustBeStrictlyAscending() public {
        _fuel(alice, 1, BASED_LILS, BASED_CHIP);

        uint256[] memory descending = new uint256[](BASED_LILS);
        for (uint256 i; i < BASED_LILS; ++i) {
            descending[i] = BASED_LILS - i;
        }

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Furnace.FuelIdsNotAscending.selector, uint256(5), uint256(4)));
        furnace.forge(BASED_RECIPE, descending);
    }

    /// @notice An adjacent duplicate keeps the error it always had, because "you sent the
    ///         same token twice" is a better thing to read than "not ascending".
    function test_FUR005_anAdjacentDuplicateStillReadsAsADuplicate() public {
        _fuel(alice, 1, BASED_LILS, BASED_CHIP);

        uint256[] memory dup = new uint256[](BASED_LILS);
        dup[0] = 1;
        dup[1] = 2;
        dup[2] = 2; // repeat, adjacent
        dup[3] = 3;
        dup[4] = 4;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Furnace.DuplicateFuelToken.selector, uint256(2)));
        furnace.forge(BASED_RECIPE, dup);
    }

    /// @notice The full 100-token recipe still forges, so the ordering rule holds at the
    ///         boundary `MAX_FUEL_COST` allows.
    function test_FUR005_aMaximumSizeRecipeStillForges() public {
        vm.startPrank(multisig);
        furnace.queueRecipeChange(BASED_RECIPE, 100, 1 ether);
        vm.warp(block.timestamp + 48 hours);
        furnace.executeRecipeChange(BASED_RECIPE);
        vm.stopPrank();

        uint256[] memory ids = _fuel(alice, 1_000, 100, 1 ether);
        vm.prank(alice);
        assertEq(furnace.forge(BASED_RECIPE, ids), 100);
        assertEq(furnace.totalFuelBurned(), 100);
    }

    /// @notice DECIDED: every forge must burn $CHIP. A free forge is a sink the protocol
    ///         does not want and an abuse vector, so `chipCost == 0` is not configurable.
    ///         This test used to assert the opposite and is inverted deliberately — the
    ///         affordance existed, was never intended, and is now closed. TRIAGE batch 9.
    function test_aZeroChipRecipeCannotBeConfiguredThroughTheTimelock() public {
        vm.prank(multisig);
        vm.expectRevert(Furnace.BadConfig.selector);
        furnace.queueRecipeChange(BASED_RECIPE, BASED_LILS, 0);

        // The live recipe is untouched, so nothing forges for free in the meantime.
        (, uint256 chipCost) = furnace.costOf(BASED_RECIPE);
        assertEq(chipCost, BASED_CHIP);
    }

    /// @notice Guarding only the timelocked path would leave the constructor as a way
    ///         around it, so a Furnace cannot be DEPLOYED with a free recipe either.
    function test_aZeroChipRecipeCannotBeDeployedEither() public {
        vm.expectRevert(Furnace.BadConfig.selector);
        new Furnace(
            multisig,
            address(chip),
            0x000000000000000000000000000000000000dEaD,
            address(lil),
            Furnace.Recipe({
                exists: true, paused: false, outputCollection: address(based), fuelCost: BASED_LILS, chipCost: 0
            }),
            Furnace.Recipe({
                exists: true, paused: false, outputCollection: address(dark), fuelCost: DARK_LILS, chipCost: DARK_CHIP
            })
        );
    }

    /// @dev A Based recipe pointed at a collection whose tokens can be frozen, seeded 500-502.
    function _freezableRecipe() internal returns (FreezableNoun out) {
        out = new FreezableNoun("Freezable Based", "FBASED");
        furnace = new Furnace(
            multisig,
            address(chip),
            0x000000000000000000000000000000000000dEaD,
            address(lil),
            Furnace.Recipe({
                exists: true, paused: false, outputCollection: address(out), fuelCost: BASED_LILS, chipCost: BASED_CHIP
            }),
            Furnace.Recipe({
                exists: true, paused: false, outputCollection: address(dark), fuelCost: DARK_LILS, chipCost: DARK_CHIP
            })
        );

        uint256[] memory ids = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            ids[i] = 500 + i;
            out.mint(multisig, ids[i]);
        }
        vm.startPrank(multisig);
        out.setApprovalForAll(address(furnace), true);
        furnace.depositStock(address(out), ids);
        vm.stopPrank();
    }
}

/// @dev A fee-on-transfer token whose tax goes somewhere OTHER than the burn address, so a
///      shortfall is actually observable at `0xdead`.
contract TaxToSomewhereElse is MockERC20 {
    address public constant TAX_SINK = address(0xFEE5);

    constructor() MockERC20("Taxed", "TAX", 18) {}

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = value / 100; // 1%
        super._update(from, TAX_SINK, fee);
        super._update(from, to, value - fee);
    }
}

/// @dev Attempts to re-enter `forge` while receiving the output NFT.
contract ForgeReenterer is IERC721Receiver {
    Furnace public immutable furnace;
    MockNoun public immutable lil;
    MockERC20 public immutable chip;
    uint256[] internal _second;
    bool internal _armed;

    constructor(Furnace f, MockNoun l, MockERC20 c) {
        furnace = f;
        lil = l;
        chip = c;
    }

    function approveAll() external {
        lil.setApprovalForAll(address(furnace), true);
        chip.approve(address(furnace), type(uint256).max);
    }

    function arm(uint256[] calldata second) external {
        _second = second;
        _armed = true;
    }

    function attack(uint256[] calldata first) external {
        furnace.forge(0, first);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external override returns (bytes4) {
        if (_armed) {
            _armed = false;
            try furnace.forge(0, _second) {} catch {}
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @notice An output collection that can render one token id untransferable — a paused
///         collection, a compliance freeze, a broken migration. The Furnace cannot prevent
///         this; SEC-FUR-003 is about being able to recover from it.
contract FreezableNoun is ERC721 {
    mapping(uint256 => bool) public frozen;

    constructor(string memory n, string memory s) ERC721(n, s) {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    function freeze(uint256 tokenId) external {
        frozen[tokenId] = true;
    }

    function unfreeze(uint256 tokenId) external {
        frozen[tokenId] = false;
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        require(!frozen[tokenId], "FROZEN");
        return super._update(to, tokenId, auth);
    }
}
