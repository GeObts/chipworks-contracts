// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Anvil} from "../../src/anvil/Anvil.sol";
import {ChipActivation} from "../../src/activation/ChipActivation.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockNoun} from "../mocks/MockNoun.sol";

/// @notice The buy side of the Anvil, and the honest absence of the sell side.
contract AnvilTest is Test {
    address internal multisig = makeAddr("multisig");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    Anvil internal anvil;
    MockNoun internal based;
    MockNoun internal dark;
    RevenueSink internal splitter;

    uint256 internal constant PRICE = 0.4 ether;
    uint32 internal constant PREMIUM = 2_500; // +25%

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        based = new MockNoun("Based Nouns", "BASED");
        dark = new MockNoun("DarkNOUNs", "DARK");
        splitter = new RevenueSink();

        anvil = new Anvil(multisig, address(splitter), PREMIUM);

        _shelve(based, _ids(1, 2, 3, 4, 5));
        _setPrice(address(based), PRICE);

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    /* -------------------------------- helpers -------------------------------- */

    function _shelve(MockNoun c, uint256[] memory ids) internal {
        for (uint256 i; i < ids.length; ++i) {
            c.mint(multisig, ids[i]);
        }
        vm.startPrank(multisig);
        c.setApprovalForAll(address(anvil), true);
        anvil.shelve(address(c), ids);
        vm.stopPrank();
    }

    function _setPrice(address collection, uint256 price) internal {
        vm.prank(multisig);
        anvil.queueQueuePrice(collection, price);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        anvil.executeQueuePrice(collection);
    }

    function _ids(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e) internal pure returns (uint256[] memory o) {
        o = new uint256[](5);
        o[0] = a;
        o[1] = b;
        o[2] = c;
        o[3] = d;
        o[4] = e;
    }

    function _one(uint256 a) internal pure returns (uint256[] memory o) {
        o = new uint256[](1);
        o[0] = a;
    }

    function _snipePrice() internal pure returns (uint256) {
        return PRICE + (PRICE * PREMIUM) / 10_000;
    }

    /* --------------------------------- the Box -------------------------------- */

    /// @notice FIFO, and the head is readable before you commit. This is the property that
    ///         makes "the Box" a queue rather than a lottery.
    function test_buyNextIsFifoAndTheHeadIsReadableInAdvance() public {
        (bool available, uint256 nextId) = anvil.nextOnShelf(address(based));
        assertTrue(available);
        assertEq(nextId, 1, "oldest shelved is first out");

        vm.prank(alice);
        uint256 got = anvil.buyNext{value: PRICE}(address(based));

        assertEq(got, 1, "and that is exactly what you get");
        assertEq(based.ownerOf(1), alice);

        (, uint256 thenNext) = anvil.nextOnShelf(address(based));
        assertEq(thenNext, 2, "the queue advances by one");
    }

    function test_buyingDrainsTheShelfInOrder() public {
        uint256[5] memory expected = [uint256(1), 2, 3, 4, 5];
        for (uint256 i; i < 5; ++i) {
            vm.prank(alice);
            assertEq(anvil.buyNext{value: PRICE}(address(based)), expected[i], "strict order");
        }
        assertEq(anvil.shelfRemaining(address(based)), 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Anvil.ShelfEmpty.selector, address(based)));
        anvil.buyNext{value: PRICE}(address(based));
    }

    function test_shelfQueueReportsWhatIsLeftInOrder() public {
        vm.prank(alice);
        anvil.buyNext{value: PRICE}(address(based));
        vm.prank(bob);
        anvil.snipe{value: _snipePrice()}(address(based), 4);

        uint256[] memory q = anvil.shelfQueue(address(based));
        assertEq(q.length, 3);
        assertEq(q[0], 2);
        assertEq(q[1], 3);
        assertEq(q[2], 5, "4 was sniped out of the middle");
    }

    /* --------------------------------- sniping -------------------------------- */

    function test_snipeCostsTheQueuePricePlusThePremium() public {
        uint256 expected = 0.5 ether; // 0.4 + 25%
        assertEq(anvil.snipePriceOf(address(based)), expected);

        vm.prank(alice);
        anvil.snipe{value: expected}(address(based), 4);

        assertEq(based.ownerOf(4), alice);
        assertEq(splitter.received(), expected, "100% forwarded");
        assertEq(anvil.totalSnipes(), 1);
    }

    /// @notice THE PROPERTY THAT KEEPS THE QUEUE HONEST: sniping does not reorder it.
    function test_snipingDoesNotPromoteAnybodyUpTheQueue() public {
        vm.prank(alice);
        anvil.snipe{value: _snipePrice()}(address(based), 2); // second in line, taken out

        (, uint256 nextId) = anvil.nextOnShelf(address(based));
        assertEq(nextId, 1, "the head is untouched");

        vm.prank(bob);
        assertEq(anvil.buyNext{value: PRICE}(address(based)), 1);

        // 2 is gone, so the next box is 3 — not a promoted 5, not a reshuffle.
        vm.prank(bob);
        assertEq(anvil.buyNext{value: PRICE}(address(based)), 3);
        vm.prank(bob);
        assertEq(anvil.buyNext{value: PRICE}(address(based)), 4);
    }

    function test_cannotSnipeAnUnshelvedOrAlreadySoldNoun() public {
        vm.prank(alice);
        anvil.snipe{value: _snipePrice()}(address(based), 3);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Anvil.NotListed.selector, address(based), 3));
        anvil.snipe{value: _snipePrice()}(address(based), 3);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Anvil.NotListed.selector, address(based), 99));
        anvil.snipe{value: _snipePrice()}(address(based), 99);
    }

    function test_aBoughtNounCannotBeSnipedAfterwards() public {
        vm.prank(alice);
        anvil.buyNext{value: PRICE}(address(based)); // takes 1

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Anvil.NotListed.selector, address(based), 1));
        anvil.snipe{value: _snipePrice()}(address(based), 1);
    }

    /* --------------------------------- payment -------------------------------- */

    function test_underpayingIsRefused() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Anvil.Underpaid.selector, PRICE - 1, PRICE));
        anvil.buyNext{value: PRICE - 1}(address(based));

        assertEq(based.ownerOf(1), address(anvil), "still on the shelf");
        assertEq(anvil.shelfRemaining(address(based)), 5);
    }

    function test_underpayingASnipeIsRefused() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Anvil.Underpaid.selector, PRICE, _snipePrice()));
        anvil.snipe{value: PRICE}(address(based), 3); // queue price is not enough
    }

    function test_overpaymentIsRefunded() public {
        uint256 before = alice.balance;
        vm.prank(alice);
        anvil.buyNext{value: 1 ether}(address(based));

        assertEq(before - alice.balance, PRICE, "charged the price, refunded the rest");
        assertEq(splitter.received(), PRICE);
        assertEq(address(anvil).balance, 0);
    }

    /// @notice 100% of revenue leaves in the same transaction. The Anvil holds no ETH.
    function test_everyWeiIsForwardedAndNothingIsHeld() public {
        vm.prank(alice);
        anvil.buyNext{value: PRICE}(address(based));
        vm.prank(bob);
        anvil.snipe{value: _snipePrice()}(address(based), 5);

        assertEq(splitter.received(), PRICE + _snipePrice());
        assertEq(address(anvil).balance, 0, "the Anvil never holds ETH");
        assertEq(anvil.totalRevenueWei(), PRICE + _snipePrice());
    }

    /// @notice If revenue cannot be routed, the Noun does not leave. Fail closed: there is
    ///         no ETH withdraw path, so a sale that could not forward would strand money.
    function test_aBrokenFeeSplitterBlocksTheSaleRatherThanStrandingTheEth() public {
        RejectingSink bad = new RejectingSink();
        vm.prank(multisig);
        anvil.setFeeSplitter(address(bad));

        vm.prank(alice);
        vm.expectRevert(Anvil.FeeForwardFailed.selector);
        anvil.buyNext{value: PRICE}(address(based));

        assertEq(based.ownerOf(1), address(anvil), "the Noun stayed");
        assertEq(address(anvil).balance, 0);
    }

    /* ------------------------------ the sell side ----------------------------- */

    /// @notice The sell side is not built, says so, and cannot be switched on.
    function test_theSellSideIsHonestlyClosed() public {
        assertFalse(anvil.sellEnabled(), "the site reads this and says 'after the audit'");

        vm.prank(alice);
        vm.expectRevert(Anvil.SellNotOpen.selector);
        anvil.sellToAnvil(address(based), 1);

        // And not even the multisig can open it: there is deliberately no setter.
        vm.prank(multisig);
        vm.expectRevert(Anvil.SellNotOpen.selector);
        anvil.sellToAnvil(address(based), 1);
    }

    /* ---------------------------- pause and pricing --------------------------- */

    function test_pauseIsImmediateAndPerCollection() public {
        _shelve(dark, _ids(10, 11, 12, 13, 14));
        _setPrice(address(dark), 1 ether);

        vm.prank(multisig);
        anvil.setPaused(address(based), true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Anvil.CollectionPausedError.selector, address(based)));
        anvil.buyNext{value: PRICE}(address(based));

        // Dark is unaffected.
        vm.prank(alice);
        assertEq(anvil.buyNext{value: 1 ether}(address(dark)), 10);

        // And unpausing resumes at the same queue position.
        vm.prank(multisig);
        anvil.setPaused(address(based), false);
        vm.prank(alice);
        assertEq(anvil.buyNext{value: PRICE}(address(based)), 1, "same head as before the pause");
    }

    function test_anUnpricedCollectionIsNotForSale() public {
        _shelve(dark, _ids(10, 11, 12, 13, 14));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Anvil.NotForSale.selector, address(dark)));
        anvil.buyNext{value: 1 ether}(address(dark));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Anvil.NotForSale.selector, address(dark)));
        anvil.snipe{value: 1 ether}(address(dark), 10);
    }

    function test_priceChangesNeedTheFullFortyEightHours() public {
        vm.prank(multisig);
        anvil.queueQueuePrice(address(based), 0.9 ether);

        vm.warp(block.timestamp + 48 hours - 1);
        vm.prank(multisig);
        vm.expectRevert();
        anvil.executeQueuePrice(address(based));

        // Still the old price while queued.
        vm.prank(alice);
        anvil.buyNext{value: PRICE}(address(based));

        vm.warp(block.timestamp + 1);
        vm.prank(multisig);
        anvil.executeQueuePrice(address(based));
        assertEq(anvil.queuePrice(address(based)), 0.9 ether);
    }

    function test_premiumChangesAreTimelockedAndCapped() public {
        vm.prank(multisig);
        vm.expectRevert(Anvil.BadConfig.selector);
        anvil.queueSnipePremium(20_001);

        vm.prank(multisig);
        anvil.queueSnipePremium(5_000);
        assertEq(anvil.snipePremiumBps(), PREMIUM, "unchanged while queued");

        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        anvil.executeSnipePremium();
        assertEq(anvil.snipePremiumBps(), 5_000);
        assertEq(anvil.snipePriceOf(address(based)), 0.6 ether);
    }

    function test_queuedChangesCanBeCancelled() public {
        vm.startPrank(multisig);
        anvil.queueQueuePrice(address(based), 9 ether);
        anvil.cancelQueuePrice(address(based));
        anvil.queueSnipePremium(9_000);
        anvil.cancelSnipePremium();
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(Anvil.NothingQueued.selector);
        anvil.executeQueuePrice(address(based));
        vm.expectRevert(Anvil.NothingQueued.selector);
        anvil.executeSnipePremium();
        vm.stopPrank();

        assertEq(anvil.queuePrice(address(based)), PRICE);
    }

    function test_configIsMultisigOnly() public {
        vm.startPrank(alice);
        vm.expectRevert();
        anvil.queueQueuePrice(address(based), 1 ether);
        vm.expectRevert();
        anvil.setPaused(address(based), true);
        vm.expectRevert();
        anvil.shelve(address(based), _one(9));
        vm.expectRevert();
        anvil.unshelve(address(based), 1, alice);
        vm.stopPrank();
    }

    /* --------------------------- shelving and rescue -------------------------- */

    /// @notice Withdrawals come off the TAIL, so the multisig can never take the Noun the
    ///         next buyer is about to receive.
    function test_unshelveTakesFromTheTailNotTheHead() public {
        vm.prank(multisig);
        anvil.unshelve(address(based), 2, multisig);

        assertEq(based.ownerOf(5), multisig);
        assertEq(based.ownerOf(4), multisig);
        assertEq(anvil.shelfRemaining(address(based)), 3);

        (, uint256 nextId) = anvil.nextOnShelf(address(based));
        assertEq(nextId, 1, "the head never moved");
    }

    function test_unshelveSkipsAlreadySoldEntries() public {
        vm.prank(alice);
        anvil.snipe{value: _snipePrice()}(address(based), 5); // the tail is already gone

        vm.prank(multisig);
        anvil.unshelve(address(based), 1, multisig);

        assertEq(based.ownerOf(4), multisig, "took the next real one down");
        assertEq(anvil.shelfRemaining(address(based)), 3);
    }

    function test_cannotUnshelveMoreThanIsThere() public {
        vm.prank(multisig);
        vm.expectRevert(Anvil.NothingToWithdraw.selector);
        anvil.unshelve(address(based), 6, multisig);
    }

    function test_recoverNFTCannotTakeAShelvedNoun() public {
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(Anvil.IsShelved.selector, address(based), 1));
        anvil.recoverNFT(address(based), 1, multisig);
        assertEq(based.ownerOf(1), address(anvil));
    }

    function test_recoverNFTReturnsAStrayNoun() public {
        based.mint(bob, 42);
        vm.prank(bob);
        based.transferFrom(bob, address(anvil), 42); // pushed in, never shelved

        assertFalse(anvil.isListed(address(based), 42), "not for sale at any price");
        assertEq(anvil.shelfRemaining(address(based)), 5, "and not in the queue");

        vm.prank(multisig);
        anvil.recoverNFT(address(based), 42, bob);
        assertEq(based.ownerOf(42), bob);
    }

    function test_recoverExcessSweepsAStrayToken() public {
        MockERC20 junk = new MockERC20("Junk", "JNK", 18);
        junk.mint(address(anvil), 5 ether);
        vm.prank(multisig);
        anvil.recoverExcess(address(junk), multisig);
        assertEq(junk.balanceOf(multisig), 5 ether);
    }

    /* --------------------------------- reentry -------------------------------- */

    /// @notice There is no ERC-721 receiver hook to re-enter through at all: the Noun is
    ///         handed over with `transferFrom`, not `safeTransferFrom`.
    function test_thereIsNoReceiverHookOnTheWayOut() public {
        ReentrantBuyer attacker = new ReentrantBuyer(anvil, address(based));
        vm.deal(address(attacker), 10 ether);

        attacker.attack(PRICE); // exact payment: no refund, no callback

        assertEq(based.ownerOf(1), address(attacker), "it bought normally");
        assertFalse(attacker.hookFired(), "and was never called back");
        assertEq(anvil.shelfRemaining(address(based)), 4);
    }

    /// @notice The one callback that does exist is the overpayment refund, and re-entering
    ///         from it reverts the whole purchase rather than yielding two Nouns for one.
    function test_aReentrantRefundCannotDoubleDip() public {
        ReentrantBuyer attacker = new ReentrantBuyer(anvil, address(based));
        vm.deal(address(attacker), 10 ether);

        // Overpay by 1 wei to force the refund callback, and re-enter from it.
        vm.expectRevert(Anvil.RefundFailed.selector);
        attacker.attack(PRICE + 1);

        assertEq(anvil.shelfRemaining(address(based)), 5, "nothing left the shelf");
        assertEq(based.ownerOf(1), address(anvil));
        assertEq(splitter.received(), 0, "and no revenue was booked");
    }

    /* ------------------------------- un-chipped ------------------------------- */

    /// @notice A NOUN BOUGHT FROM THE ANVIL ARRIVES UN-CHIPPED, structurally.
    ///
    /// @dev Nothing in the Anvil calls the activation vault. It does not have to: the Anvil
    ///      is not a registered custodian, so shelving a Noun looks to ChipActivation exactly
    ///      like selling it to a stranger, and the seller's activation is void from that
    ///      moment. The buyer receives a clean Noun and chips it themselves at full price.
    function test_aPurchasedNounArrivesUnChipped() public {
        MockERC20 chip = new MockERC20("Chipworks", "CHIP", 18);
        ChipActivation act =
            new ChipActivation(multisig, address(chip), [uint32(10_000), 12_500, 16_000, 20_000, 33_300]);
        vm.prank(multisig);
        act.queueCosts(address(based), [uint256(0), 0, 0, 0, 0]);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        act.executeCosts(address(based));

        // The multisig chips a Noun at the top tier, then shelves it.
        MockNoun fresh = new MockNoun("Based Nouns", "BASED");
        fresh.mint(multisig, 77);
        vm.startPrank(multisig);
        act.queueCosts(address(fresh), [uint256(0), 0, 0, 0, 0]);
        vm.stopPrank();
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        act.executeCosts(address(fresh));
        vm.prank(multisig);
        act.activate(address(fresh), 77, 4);
        assertTrue(act.isActive(address(fresh), 77), "chipped while the multisig held it");

        vm.startPrank(multisig);
        fresh.setApprovalForAll(address(anvil), true);
        anvil.shelve(address(fresh), _one(77));
        vm.stopPrank();

        // Shelving alone already voided it: the Anvil is not a custodian.
        assertFalse(act.isActive(address(fresh), 77), "void the moment it hits the shelf");

        _setPrice(address(fresh), PRICE);
        vm.prank(alice);
        anvil.buyNext{value: PRICE}(address(fresh));

        assertEq(fresh.ownerOf(77), alice);
        (bool active, uint32 bps, address owner) = act.activation(address(fresh), 77);
        assertFalse(active, "the buyer gets a clean Noun");
        assertEq(bps, 0);
        assertEq(owner, address(0));

        // And she can chip it herself, from scratch.
        vm.prank(alice);
        act.activate(address(fresh), 77, 1);
        assertTrue(act.isActive(address(fresh), 77));
        assertEq(act.effectiveOwner(address(fresh), 77), alice);
    }

    /* ---------------------------------- fuzz ---------------------------------- */

    /// @notice However much is overpaid, the buyer is charged exactly the price and the
    ///         Anvil keeps nothing.
    function testFuzz_overpaymentIsAlwaysRefundedExactly(uint256 extra) public {
        extra = bound(extra, 0, 50 ether);
        uint256 before = alice.balance;

        vm.prank(alice);
        anvil.buyNext{value: PRICE + extra}(address(based));

        assertEq(before - alice.balance, PRICE);
        assertEq(address(anvil).balance, 0);
        assertEq(splitter.received(), PRICE);
    }
}

/// @notice Stands in for the FeeSplitter: accepts ETH, does no work (C-1).
contract RevenueSink {
    uint256 public received;

    receive() external payable {
        received += msg.value;
    }
}

/// @notice A fee recipient that refuses ETH.
contract RejectingSink {
    receive() external payable {
        revert("no");
    }
}

/// @notice Buys, and tries to buy again from whichever callback it is given.
contract ReentrantBuyer {
    Anvil internal immutable anvil;
    address internal immutable collection;
    uint256 internal price;
    bool internal reentered;

    /// @notice Whether the ERC-721 receiver hook was ever invoked. It should not be.
    bool public hookFired;

    constructor(Anvil anvil_, address collection_) {
        anvil = anvil_;
        collection = collection_;
    }

    function attack(uint256 value) external {
        price = value;
        anvil.buyNext{value: value}(collection);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        hookFired = true;
        return this.onERC721Received.selector;
    }

    /// @dev The refund lands here. Try to buy again from inside it.
    receive() external payable {
        if (!reentered) {
            reentered = true;
            anvil.buyNext{value: price}(collection); // must fail: nonReentrant
        }
    }
}
