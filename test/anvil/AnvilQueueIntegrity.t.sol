// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Anvil} from "../../src/anvil/Anvil.sol";
import {MockNoun} from "../mocks/MockNoun.sol";

/// @title AnvilQueueIntegrityTest
/// @notice External review batch 7 (Bankr, Anvil). The shelf's bookkeeping, attacked.
///
/// @dev THE SHELF IS A PROMISE, AND THESE TESTS ARE WHAT MAKE IT ONE.
///
///      `Anvil` claims two things a buyer can act on: `buyNext` hands out the oldest Noun
///      still on the shelf, and the multisig cannot take the Noun you are about to receive
///      out from under you. Both were breakable before `launch-candidate-11` — not by an
///      attacker, but by the protocol's own ordinary restock flow, which is worse, because
///      nobody would have been looking for it.
contract AnvilQueueIntegrityTest is Test {
    address internal multisig = makeAddr("multisig");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    Anvil internal anvil;
    MockNoun internal based;
    Sink internal splitter;

    uint256 internal constant PRICE = 0.4 ether;
    uint32 internal constant PREMIUM = 2_500;

    function setUp() public {
        vm.warp(1_700_000_000);
        based = new MockNoun("Based Nouns", "BASED");
        splitter = new Sink();
        anvil = new Anvil(multisig, address(splitter), PREMIUM);

        _shelve(_ids5(1, 2, 3, 4, 5));
        _setPrice(PRICE);

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    /* ------------------------------------------------------------------ */
    /*     M-1 - A RE-SHELVED SNIPED TOKEN MUST NOT JUMP THE QUEUE          */
    /* ------------------------------------------------------------------ */

    /// @notice THE EXACT SEQUENCE. Somebody snipes Noun 2 out of the middle of the shelf.
    ///         Later the protocol buys it back on the open market and re-shelves it. It must
    ///         go to the BACK of the queue, because that is when it re-joined.
    ///
    /// @dev Before the fix the array slot Noun 2 originally occupied was never retired — the
    ///      snipe only flipped a per-token flag. Re-listing the same token id turned that
    ///      stale slot back on, and the token reappeared at its ORIGINAL position, ahead of
    ///      three Nouns that had been waiting longer. This is invariant #21 in AUDIT_BRIEF,
    ///      and the buyer it cheats is the one holding the head.
    function test_M1_aResheledSnipedNounGoesToTheBackNotItsOldSlot() public {
        // Snipe 2 out of the middle.
        vm.prank(bob);
        anvil.snipe{value: _snipePrice()}(address(based), 2);
        assertEq(based.ownerOf(2), bob);
        assertEq(anvil.shelfRemaining(address(based)), 4, "1, 3, 4, 5 left");

        // The protocol buys it back and restocks it.
        vm.prank(bob);
        based.transferFrom(bob, multisig, 2);
        _shelve(_one(2));

        assertEq(anvil.shelfRemaining(address(based)), 5, "1, 3, 4, 5, 2 - counted once");
        assertEq(anvil.shelfQueue(address(based)), _ids5(1, 3, 4, 5, 2), "2 is at the TAIL");

        // And draining the shelf proves the order is real, not just what the view says.
        uint256[5] memory expected = [uint256(1), 3, 4, 5, 2];
        for (uint256 i; i < 5; ++i) {
            vm.prank(alice);
            assertEq(anvil.buyNext{value: PRICE}(address(based)), expected[i], "strict FIFO");
        }
        assertEq(anvil.shelfRemaining(address(based)), 0);
    }

    /// @notice The count must not double-count either. `shelfRemaining` is what the site
    ///         shows and what `Bought` reports, so an inflated number is a lie to every buyer
    ///         looking at the shelf, not just an internal slip.
    function test_M1_theRemainingCountNeverDoubleCountsARestock() public {
        vm.prank(bob);
        anvil.snipe{value: _snipePrice()}(address(based), 3);

        vm.prank(bob);
        based.transferFrom(bob, multisig, 3);
        _shelve(_one(3));

        assertEq(anvil.shelfRemaining(address(based)), 5, "five real Nouns, counted five times");

        // The count must also survive being walked all the way down.
        for (uint256 i; i < 5; ++i) {
            vm.prank(alice);
            anvil.buyNext{value: PRICE}(address(based));
            assertEq(anvil.shelfRemaining(address(based)), 4 - i, "decrements by exactly one");
        }
    }

    /// @notice A restocked token can never be sold twice, however many stale slots exist.
    function test_M1_aRestockedNounCannotBeSoldTwice() public {
        vm.prank(bob);
        anvil.snipe{value: _snipePrice()}(address(based), 1); // the head itself

        vm.prank(bob);
        based.transferFrom(bob, multisig, 1);
        _shelve(_one(1));

        uint256[5] memory expected = [uint256(2), 3, 4, 5, 1];
        for (uint256 i; i < 5; ++i) {
            vm.prank(alice);
            assertEq(anvil.buyNext{value: PRICE}(address(based)), expected[i]);
        }

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Anvil.ShelfEmpty.selector, address(based)));
        anvil.buyNext{value: PRICE}(address(based));
    }

    /// @notice The same hazard through `unshelve` rather than `snipe`: a Noun taken off the
    ///         shelf and put back later is a new arrival, not a returning one.
    function test_M1_anUnshelvedThenResheledNounAlsoGoesToTheBack() public {
        vm.prank(multisig);
        anvil.unshelve(address(based), 1, multisig); // takes 5, the tail

        assertEq(anvil.shelfQueue(address(based)), _ids4(1, 2, 3, 4));

        _shelve(_one(5));
        assertEq(anvil.shelfQueue(address(based)), _ids5(1, 2, 3, 4, 5), "back at the tail");
        assertEq(anvil.shelfRemaining(address(based)), 5);
    }

    /* ------------------------------------------------------------------ */
    /*        M-2 - A PURCHASE MUST NOT COST MORE AS THE SHELF GROWS        */
    /* ------------------------------------------------------------------ */

    /// @notice A buy on a 400-deep shelf must cost about the same as a buy on a 5-deep one.
    ///
    /// @dev `_settle` counted the shelf by walking it, so every purchase paid for the whole
    ///      remaining queue. The shelf is meant to grow; that is a gas ceiling on the
    ///      product, and eventually a denial of service on the Box. The count is now
    ///      maintained as items go on and off, so a purchase is O(1).
    function test_M2_buyingStaysCheapOnALargeShelf() public {
        uint256 small = _measureBuyGas();

        MockNoun big = new MockNoun("Big", "BIG");
        uint256[] memory many = new uint256[](400);
        for (uint256 i; i < 400; ++i) {
            many[i] = i + 1;
            big.mint(multisig, i + 1);
        }
        vm.startPrank(multisig);
        big.setApprovalForAll(address(anvil), true);
        anvil.shelve(address(big), many);
        vm.stopPrank();
        _setPriceFor(address(big), PRICE);

        vm.prank(alice);
        uint256 before = gasleft();
        anvil.buyNext{value: PRICE}(address(big));
        uint256 large = before - gasleft();

        emit log_named_uint("buy gas, 5-deep shelf ", small);
        emit log_named_uint("buy gas, 400-deep shelf", large);
        assertLt(large, small + 5_000, "a purchase must not scale with the shelf");
    }

    /// @notice Restocking must not be quadratic either. `shelve` counted the shelf once per
    ///         token, inside the loop — so a 400-token restock walked the shelf 400 times.
    function test_M2_restockingIsNotQuadratic() public {
        MockNoun big = new MockNoun("Big", "BIG");
        uint256[] memory many = new uint256[](400);
        for (uint256 i; i < 400; ++i) {
            many[i] = i + 1;
            big.mint(multisig, i + 1);
        }

        vm.startPrank(multisig);
        big.setApprovalForAll(address(anvil), true);
        uint256 before = gasleft();
        anvil.shelve(address(big), many);
        uint256 used = before - gasleft();
        vm.stopPrank();

        emit log_named_uint("gas to shelve 400", used);
        // Quadratic counting cost roughly 400 * 400 / 2 warm SLOADs on top of the transfers.
        // 400 x 60k is a generous ceiling for the linear shape and far under the old one.
        assertLt(used, 24_000_000, "shelving must be linear in the batch");
    }

    /* ------------------------------------------------------------------ */
    /*      L-3 - THE HEAD IS PROTECTED EVEN WHEN IT IS ALSO THE TAIL       */
    /* ------------------------------------------------------------------ */

    /// @notice `unshelve` removes from the tail so it can never take the Noun the next buyer
    ///         is about to receive. With exactly one Noun left the tail IS the head, and the
    ///         guarantee quietly stopped holding.
    function test_L3_theLastNounCannotBeUnshelvedWhileTheShelfIsLive() public {
        for (uint256 i; i < 4; ++i) {
            vm.prank(alice);
            anvil.buyNext{value: PRICE}(address(based));
        }
        assertEq(anvil.shelfRemaining(address(based)), 1);
        (bool available, uint256 head) = anvil.nextOnShelf(address(based));
        assertTrue(available);
        assertEq(head, 5, "somebody can see this and is about to buy it");

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(Anvil.WouldTakeTheHead.selector, address(based), uint256(5)));
        anvil.unshelve(address(based), 1, multisig);

        assertEq(based.ownerOf(5), address(anvil), "still on the shelf");
        (, uint256 stillHead) = anvil.nextOnShelf(address(based));
        assertEq(stillHead, 5);
    }

    /// @notice ...but the shelf can still be wound down, by pausing it first. Refusing
    ///         outright would strand the last Noun forever: `recoverNFT` refuses a shelved
    ///         token, so there would be no path off the shelf but a sale.
    function test_L3_pausingFirstLetsTheShelfBeEmptied() public {
        for (uint256 i; i < 4; ++i) {
            vm.prank(alice);
            anvil.buyNext{value: PRICE}(address(based));
        }

        vm.startPrank(multisig);
        anvil.setPaused(address(based), true); // nobody is about to buy anything now
        anvil.unshelve(address(based), 1, multisig);
        vm.stopPrank();

        assertEq(based.ownerOf(5), multisig, "wound down");
        assertEq(anvil.shelfRemaining(address(based)), 0);
    }

    /// @notice Down to two, the tail is not the head, so an ordinary trim still works.
    function test_L3_trimmingTheTailStillWorksAboveOne() public {
        for (uint256 i; i < 3; ++i) {
            vm.prank(alice);
            anvil.buyNext{value: PRICE}(address(based));
        }
        assertEq(anvil.shelfRemaining(address(based)), 2);

        vm.prank(multisig);
        anvil.unshelve(address(based), 1, multisig);

        assertEq(based.ownerOf(5), multisig, "the tail went");
        (, uint256 head) = anvil.nextOnShelf(address(based));
        assertEq(head, 4, "the head is untouched");
    }

    /* ------------------------------------------------------------------ */
    /*        L-1 - REDIRECTING REVENUE DESERVES THE SAME NOTICE            */
    /* ------------------------------------------------------------------ */

    /// @notice 100% of every sale goes to `feeSplitter`. Changing it redirects all revenue,
    ///         which is a larger act than changing a price — and prices were the timelocked
    ///         thing while this was instant.
    function test_L1_theFeeSplitterIsTimelocked() public {
        Sink evil = new Sink();

        vm.prank(multisig);
        anvil.queueFeeSplitter(address(evil));
        assertEq(anvil.feeSplitter(), address(splitter), "not yet");

        vm.prank(multisig);
        vm.expectPartialRevert(Anvil.TimelockNotElapsed.selector);
        anvil.executeFeeSplitter();

        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        anvil.executeFeeSplitter();
        assertEq(anvil.feeSplitter(), address(evil), "48 hours of notice later");

        vm.prank(alice);
        anvil.buyNext{value: PRICE}(address(based));
        assertEq(address(evil).balance, PRICE, "and revenue follows");
    }

    function test_L1_theFeeSplitterQueueCanBeCancelledAndIsOwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert();
        anvil.queueFeeSplitter(alice);

        vm.startPrank(multisig);
        anvil.queueFeeSplitter(address(new Sink()));
        anvil.cancelFeeSplitter();

        vm.expectRevert(Anvil.NothingQueued.selector);
        anvil.executeFeeSplitter();
        vm.stopPrank();

        assertEq(anvil.feeSplitter(), address(splitter));
    }

    /* ------------------------------------------------------------------ */
    /*             L-2 - A QUEUED CHANGE MUST NOT KEEP FOREVER              */
    /* ------------------------------------------------------------------ */

    /// @notice A change queued and forgotten must not be executable months later. The point
    ///         of the 48 hours is that the notice is FRESH; a year-old queued price is a
    ///         change nobody is still watching for.
    function test_L2_aStaleQueuedPriceExpires() public {
        vm.prank(multisig);
        anvil.queueQueuePrice(address(based), 9 ether);

        vm.warp(block.timestamp + 48 hours + anvil.CONFIG_GRACE() + 1);

        vm.prank(multisig);
        vm.expectPartialRevert(Anvil.TimelockExpired.selector);
        anvil.executeQueuePrice(address(based));

        assertEq(anvil.queuePrice(address(based)), PRICE, "unchanged");

        // Re-queueing is how you proceed: fresh notice, fresh window.
        vm.prank(multisig);
        anvil.queueQueuePrice(address(based), 9 ether);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        anvil.executeQueuePrice(address(based));
        assertEq(anvil.queuePrice(address(based)), 9 ether);
    }

    function test_L2_aStaleQueuedPremiumExpires() public {
        vm.prank(multisig);
        anvil.queueSnipePremium(9_000);

        vm.warp(block.timestamp + 48 hours + anvil.CONFIG_GRACE() + 1);
        vm.prank(multisig);
        vm.expectPartialRevert(Anvil.TimelockExpired.selector);
        anvil.executeSnipePremium();

        assertEq(anvil.snipePremiumBps(), PREMIUM);
    }

    function test_L2_aStaleQueuedFeeSplitterExpires() public {
        Sink evil = new Sink();
        vm.prank(multisig);
        anvil.queueFeeSplitter(address(evil));

        vm.warp(block.timestamp + 48 hours + anvil.CONFIG_GRACE() + 1);
        vm.prank(multisig);
        vm.expectPartialRevert(Anvil.TimelockExpired.selector);
        anvil.executeFeeSplitter();

        assertEq(anvil.feeSplitter(), address(splitter));
    }

    /// @notice The window is real on both sides: executable the moment it matures, and right
    ///         up to the last second of the grace period.
    function test_L2_theExecutionWindowIsOpenAtBothEnds() public {
        vm.prank(multisig);
        anvil.queueQueuePrice(address(based), 1 ether);
        vm.warp(block.timestamp + 48 hours); // exactly mature
        vm.prank(multisig);
        anvil.executeQueuePrice(address(based));
        assertEq(anvil.queuePrice(address(based)), 1 ether);

        vm.prank(multisig);
        anvil.queueQueuePrice(address(based), 2 ether);
        vm.warp(block.timestamp + 48 hours + anvil.CONFIG_GRACE()); // the last valid second
        vm.prank(multisig);
        anvil.executeQueuePrice(address(based));
        assertEq(anvil.queuePrice(address(based)), 2 ether);
    }

    /* ------------------------------------------------------------------ */
    /*             THE SLOT BOOKKEEPING, AT ITS AWKWARD EDGES               */
    /* ------------------------------------------------------------------ */

    /// @notice `unshelve` walks the tail, and the tail may be a retired slot. Those are
    ///         dropped without counting against the requested number, or the multisig would
    ///         silently get fewer Nouns than it asked for.
    function test_unshelveSkipsRetiredSlotsAtTheTail() public {
        vm.startPrank(bob);
        anvil.snipe{value: _snipePrice()}(address(based), 5); // the tail
        anvil.snipe{value: _snipePrice()}(address(based), 4); // and the one behind it
        vm.stopPrank();
        assertEq(anvil.shelfRemaining(address(based)), 3);

        vm.prank(multisig);
        anvil.unshelve(address(based), 2, multisig);

        assertEq(based.ownerOf(3), multisig, "took the real tail");
        assertEq(based.ownerOf(2), multisig, "and the one behind it");
        assertEq(anvil.shelfRemaining(address(based)), 1);
        assertEq(anvil.shelfQueue(address(based)), _one(1));
    }

    /// @notice Asking for more than exists is refused up front rather than part-way through.
    function test_unshelveRefusesMoreThanTheShelfHolds() public {
        vm.prank(multisig);
        vm.expectRevert(Anvil.NothingToWithdraw.selector);
        anvil.unshelve(address(based), 6, multisig);

        // Five exist, but the head is protected, so five is also refused.
        vm.prank(multisig);
        vm.expectPartialRevert(Anvil.WouldTakeTheHead.selector);
        anvil.unshelve(address(based), 5, multisig);

        // Four is the most a live shelf will give up.
        vm.prank(multisig);
        anvil.unshelve(address(based), 4, multisig);
        assertEq(anvil.shelfRemaining(address(based)), 1);
        (, uint256 head) = anvil.nextOnShelf(address(based));
        assertEq(head, 1, "the original head, untouched");
    }

    /// @notice An empty shelf refuses rather than under-flowing the count.
    function test_unshelveOnAnEmptyShelfReverts() public {
        vm.startPrank(multisig);
        anvil.setPaused(address(based), true);
        anvil.unshelve(address(based), 5, multisig);

        vm.expectRevert(Anvil.NothingToWithdraw.selector);
        anvil.unshelve(address(based), 1, multisig);
        vm.stopPrank();

        assertEq(anvil.shelfRemaining(address(based)), 0);
    }

    /// @notice The cursor is persisted past retired slots, so a shelf full of holes does not
    ///         make every subsequent buy re-walk them.
    function test_theCursorDoesNotRewalkRetiredSlots() public {
        vm.startPrank(bob);
        anvil.snipe{value: _snipePrice()}(address(based), 1);
        anvil.snipe{value: _snipePrice()}(address(based), 2);
        anvil.snipe{value: _snipePrice()}(address(based), 3);
        vm.stopPrank();

        vm.prank(alice);
        uint256 g0 = gasleft();
        assertEq(anvil.buyNext{value: PRICE}(address(based)), 4, "skips the three holes");
        uint256 first = g0 - gasleft();

        vm.prank(alice);
        uint256 g1 = gasleft();
        assertEq(anvil.buyNext{value: PRICE}(address(based)), 5);
        uint256 second = g1 - gasleft();

        assertLt(second, first, "the holes were walked once, not once per buy");
    }

    /// @notice `isListed` still answers for a token that was never shelved, and for one that
    ///         has left. It is a view over the slot table now rather than its own mapping.
    function test_isListedTracksTheSlotTable() public {
        assertTrue(anvil.isListed(address(based), 1));
        assertFalse(anvil.isListed(address(based), 999));

        vm.prank(alice);
        anvil.buyNext{value: PRICE}(address(based));
        assertFalse(anvil.isListed(address(based), 1), "sold");

        vm.prank(bob);
        anvil.snipe{value: _snipePrice()}(address(based), 3);
        assertFalse(anvil.isListed(address(based), 3), "sniped");

        vm.prank(multisig);
        anvil.unshelve(address(based), 1, multisig);
        assertFalse(anvil.isListed(address(based), 5), "unshelved");
    }

    /// @notice `shelfState` is the site's one-call view and must agree with the parts.
    function test_shelfStateAgreesWithTheIndividualViews() public {
        vm.prank(bob);
        anvil.snipe{value: _snipePrice()}(address(based), 1);

        (bool forSale, bool isPaused, uint256 boxPrice, uint256 snipe_, uint256 remaining, uint256 nextId) =
            anvil.shelfState(address(based));

        assertTrue(forSale);
        assertFalse(isPaused);
        assertEq(boxPrice, PRICE);
        assertEq(snipe_, _snipePrice());
        assertEq(remaining, anvil.shelfRemaining(address(based)));
        (, uint256 head) = anvil.nextOnShelf(address(based));
        assertEq(nextId, head);
        assertEq(nextId, 2, "the head moved past the sniped one");
    }

    /* -------------------------------- helpers -------------------------------- */

    function _measureBuyGas() internal returns (uint256) {
        vm.prank(alice);
        uint256 before = gasleft();
        anvil.buyNext{value: PRICE}(address(based));
        return before - gasleft();
    }

    /// @dev Mints an id the first time it is seen, so a test can re-shelve a Noun the
    ///      protocol has bought back without minting a second copy of it.
    mapping(uint256 => bool) internal _minted;

    function _shelve(uint256[] memory ids) internal {
        for (uint256 i; i < ids.length; ++i) {
            if (!_minted[ids[i]]) {
                _minted[ids[i]] = true;
                based.mint(multisig, ids[i]);
            }
        }
        vm.startPrank(multisig);
        based.setApprovalForAll(address(anvil), true);
        anvil.shelve(address(based), ids);
        vm.stopPrank();
    }

    function _setPrice(uint256 price) internal {
        _setPriceFor(address(based), price);
    }

    function _setPriceFor(address collection, uint256 price) internal {
        vm.prank(multisig);
        anvil.queueQueuePrice(collection, price);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        anvil.executeQueuePrice(collection);
    }

    function _snipePrice() internal pure returns (uint256) {
        return PRICE + (PRICE * PREMIUM) / 10_000;
    }

    function _one(uint256 a) internal pure returns (uint256[] memory o) {
        o = new uint256[](1);
        o[0] = a;
    }

    function _ids4(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (uint256[] memory o) {
        o = new uint256[](4);
        (o[0], o[1], o[2], o[3]) = (a, b, c, d);
    }

    function _ids5(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e) internal pure returns (uint256[] memory o) {
        o = new uint256[](5);
        (o[0], o[1], o[2], o[3], o[4]) = (a, b, c, d, e);
    }
}

contract Sink {
    receive() external payable {}
}
