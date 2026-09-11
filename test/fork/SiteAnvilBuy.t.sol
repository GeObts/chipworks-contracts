// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Anvil} from "../../src/anvil/Anvil.sol";

/// @notice Proves what the site's Anvil buy button must send, against the deployed Anvil.
///
/// @dev The site computed both prices locally instead of reading them:
///
///        snipeEth     = boxPrice * (1 + PARAMS.snipeFeeBps / 10000)   200 bps
///        snipePremiumBps on chain                                    2500 bps
///        frontPriceEth = boxPrice * (1 + PARAMS.swapFeeBps / 10000)   buyNext adds NO fee
///
///      So the shelf advertised 0.01122 ETH for a snipe the contract charges 0.01375 for.
///      A buy wired to the advertised figure reverts Underpaid on every click. The box
///      price was wrong the other way — 0.01111 quoted for an 0.011 sale.
///
///      There is NO ERC-20 in this path. Both routes are payable and take msg.value.
contract SiteAnvilBuyForkTest is Test {
    address constant ANVIL = 0x93Ac0B6C249c1497429Bc4863C697475DF0Acd4c;
    address constant SPLITTER = 0xb9b76e1835afE05e5A73065FE01A19B14869F8A3;
    address constant BASED = 0xBf57D0535E10E7033447174404b9bEd3D9eF4C88;
    address constant WETH = 0x4200000000000000000000000000000000000006;

    /// What the OLD site would have sent for a snipe: boxPrice * 1.02.
    uint256 constant OLD_SITE_SNIPE = 0.01122 ether;

    Anvil anvil = Anvil(payable(ANVIL));
    address buyer = address(0xB0B);

    function _forked() internal view returns (bool) {
        return block.chainid == 8453;
    }

    function _state()
        internal
        view
        returns (bool forSale, bool isPaused, uint256 boxPrice, uint256 snipePrice, uint256 remaining, uint256 nextId)
    {
        return anvil.shelfState(BASED);
    }

    /// The two figures the site must render, and the premium between them.
    function test_shelfStateIsTheOnlyPriceSource() public {
        if (!_forked()) { console2.log("skipped: not forked"); return; }

        (bool forSale, bool isPaused, uint256 box, uint256 snipe, uint256 remaining, uint256 nextId) = _state();

        assertTrue(forSale, "shelf is not for sale");
        assertFalse(isPaused, "shelf is paused");
        assertEq(box, 0.011 ether, "box price moved");
        assertEq(snipe, 0.01375 ether, "snipe price moved");
        assertEq(anvil.snipePremiumBps(), 2500, "premium is not 25%");

        // The premium really is 25%, not the 2% the site had.
        assertEq(snipe, box + (box * 2500) / 10_000, "premium math");

        console2.log("boxPrice   (buyNext)", box);
        console2.log("snipePrice (snipe)  ", snipe);
        console2.log("remaining           ", remaining);
        console2.log("nextId              ", nextId);
    }

    /// THE BUG: the figure the site used to show would have reverted every time.
    function test_theOldSiteSnipePriceWouldHaveReverted() public {
        if (!_forked()) return;

        (,,, uint256 snipePrice,, ) = _state();
        uint256 id = anvil.shelfQueue(BASED)[0];

        assertLt(OLD_SITE_SNIPE, snipePrice, "old figure was not short");

        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(Anvil.Underpaid.selector, OLD_SITE_SNIPE, snipePrice)
        );
        anvil.snipe{value: OLD_SITE_SNIPE}(BASED, id);

        console2.log("old site would send", OLD_SITE_SNIPE);
        console2.log("contract charges   ", snipePrice);
        console2.log("short by           ", snipePrice - OLD_SITE_SNIPE);
    }

    /// THE FIX: value straight from shelfState. The Noun arrives.
    function test_snipe_withShelfStatePrice() public {
        if (!_forked()) return;

        (,,, uint256 snipePrice,, ) = _state();
        uint256 id = anvil.shelfQueue(BASED)[2]; // a specific one, not the front

        vm.deal(buyer, 1 ether);
        uint256 splitter0 = SPLITTER.balance;

        vm.prank(buyer);
        anvil.snipe{value: snipePrice}(BASED, id);

        assertEq(IERC721(BASED).ownerOf(id), buyer, "buyer did not receive the Noun");
        assertEq(SPLITTER.balance - splitter0, snipePrice, "fees not forwarded in full");
        assertFalse(anvil.isListed(BASED, id), "still listed after the snipe");

        console2.log("sniped Noun", id, "for", snipePrice);
    }

    /// buyNext charges exactly boxPrice. NO fee is added on the box path.
    function test_buyNext_chargesBoxPriceExactly() public {
        if (!_forked()) return;

        (,, uint256 box,,, uint256 nextId) = _state();

        vm.deal(buyer, 1 ether);
        uint256 splitter0 = SPLITTER.balance;

        vm.prank(buyer);
        uint256 got = anvil.buyNext{value: box}(BASED);

        assertEq(got, nextId, "did not get the token shelfState named");
        assertEq(IERC721(BASED).ownerOf(got), buyer, "buyer did not receive it");
        assertEq(SPLITTER.balance - splitter0, box, "fees not forwarded in full");

        console2.log("bought the front Noun", got, "for", box);
    }

    /// One wei short is a revert, in both directions. This is why the float matters.
    function test_oneWeiShortReverts() public {
        if (!_forked()) return;

        (,, uint256 box, uint256 snipePrice,, ) = _state();
        uint256 id = anvil.shelfQueue(BASED)[0];
        vm.deal(buyer, 1 ether);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Anvil.Underpaid.selector, box - 1, box));
        anvil.buyNext{value: box - 1}(BASED);

        // And the box price is NOT enough for a snipe - the premium is real.
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Anvil.Underpaid.selector, box, snipePrice));
        anvil.snipe{value: box}(BASED, id);
    }

    /// Overpaying is safe: the excess comes back.
    function test_overpaymentIsRefunded() public {
        if (!_forked()) return;

        (,, uint256 box,,, ) = _state();
        vm.deal(buyer, 1 ether);
        uint256 before = buyer.balance;

        vm.prank(buyer);
        anvil.buyNext{value: box + 0.05 ether}(BASED);

        assertEq(before - buyer.balance, box, "refund did not come back");
        console2.log("overpaid by 0.05 ETH, charged exactly", box);
    }

    /// There is no token to approve. The buyer holds zero WETH and it does not matter.
    function test_noErc20IsInvolved() public {
        if (!_forked()) return;

        (,, uint256 box,,, ) = _state();
        vm.deal(buyer, 1 ether);

        assertEq(IERC20(WETH).balanceOf(buyer), 0, "buyer has WETH");
        assertEq(IERC20(WETH).allowance(buyer, ANVIL), 0, "buyer approved WETH");
        assertEq(IERC20(WETH).balanceOf(ANVIL), 0, "Anvil holds WETH");

        vm.prank(buyer);
        anvil.buyNext{value: box}(BASED);

        // Still zero afterwards: nothing in the path ever touched an ERC-20.
        assertEq(IERC20(WETH).balanceOf(buyer), 0, "WETH moved");
        assertEq(IERC20(WETH).balanceOf(ANVIL), 0, "WETH reached the Anvil");

        console2.log("bought with native ETH and no approval of any kind");
    }

    /// A paused shelf refuses before it takes money. The kill switch works.
    function test_pausedShelfRefuses() public {
        if (!_forked()) return;

        (,, uint256 box,,, ) = _state();
        address owner = anvil.owner();

        vm.prank(owner);
        anvil.setPaused(BASED, true);

        (bool forSale, bool isPaused,,,, ) = _state();
        assertFalse(forSale, "forSale did not follow the pause");
        assertTrue(isPaused, "not paused");

        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Anvil.CollectionPausedError.selector, BASED));
        anvil.buyNext{value: box}(BASED);

        console2.log("paused: forSale false and buyNext reverts");
    }
}
