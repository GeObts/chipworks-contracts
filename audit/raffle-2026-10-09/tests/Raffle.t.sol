// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Raffle} from "../../src/raffle/Raffle.sol";
import {IEntropyV2} from "../../src/interfaces/IEntropyV2.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Venue} from "../../src/interfaces/IStockRegistry.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BlacklistToken, FeeOnTransferToken} from "../mocks/HostileTokens.sol";
import {ReturnShapeToken} from "../mocks/ReturnShapeToken.sol";
import {RaffleTestBase} from "./RaffleTestBase.sol";

/// @dev Entropy whose request always reverts (outage) but quotes a fee.
contract BrokenEntropy {
    function getDefaultProvider() external view returns (address) {
        return address(this);
    }

    function getFeeV2(address, uint32) external pure returns (uint128) {
        return 0.00002 ether;
    }

    function requestV2(address, uint32) external payable returns (uint64) {
        revert("entropy down");
    }
}

/// @dev A registry-enabled prize token that tries to re-enter the raffle on transfer.
contract ReentrantToken is MockERC20 {
    Raffle public target;
    uint256 public targetId;
    bool public armed;
    bool public reentryBlocked;

    constructor() MockERC20("Evil", "EVL", 8) {}

    function arm(Raffle t, uint256 id) external {
        target = t;
        targetId = id;
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && from == address(target)) {
            armed = false;
            try target.claimPrize(targetId) {} catch {
                reentryBlocked = true;
            }
        }
    }
}

contract RaffleTest is RaffleTestBase {
    /* ----------------------------- constructor ----------------------------- */

    function test_constructor_rejectsNonSixDecimalUsdc() public {
        MockERC20 bad = new MockERC20("x", "x", 18);
        vm.expectRevert(abi.encodeWithSelector(Raffle.UsdcNotSixDecimals.selector, uint8(18)));
        new Raffle(house, address(bad), address(entropy), address(registry), pot, 1 hours);
    }

    function test_constructor_redrawTimeoutBounds() public {
        vm.expectRevert(Raffle.BadConfig.selector);
        new Raffle(house, address(usdc), address(entropy), address(registry), pot, 59 minutes);
        vm.expectRevert(Raffle.BadConfig.selector);
        new Raffle(house, address(usdc), address(entropy), address(registry), pot, 31 days);
        Raffle ok = new Raffle(house, address(usdc), address(entropy), address(registry), pot, 30 days);
        assertEq(ok.redrawTimeout(), 30 days);
    }

    function test_constructor_zeroAddresses() public {
        vm.expectRevert(Raffle.ZeroAddress.selector);
        new Raffle(house, address(usdc), address(entropy), address(registry), address(0), 1 hours);
        vm.expectRevert(Raffle.ZeroAddress.selector);
        new Raffle(house, address(usdc), address(0), address(registry), pot, 1 hours); // entropy_
        vm.expectRevert(Raffle.ZeroAddress.selector);
        new Raffle(house, address(usdc), address(entropy), address(0), pot, 1 hours);
        vm.expectRevert(Raffle.ZeroAddress.selector);
        new Raffle(house, address(0), address(entropy), address(registry), pot, 1 hours);
    }

    function test_launchDefaults() public view {
        assertEq(raffle.feeBps(), 1_000);
        assertEq(raffle.minBase(), 10);
        assertEq(raffle.maxBase(), 1_000);
        assertEq(raffle.redrawTimeout(), 1 hours);
        assertFalse(raffle.nftPrizesEnabled(), "NFT prizes OFF at launch");
        assertEq(raffle.keeper(), address(0), "no keeper until the Safe sets one");
        assertEq(raffle.pot(), pot);
        assertEq(raffle.owner(), house);
    }

    /* ------------------------------- create -------------------------------- */

    function test_create_onlyOwner() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        raffle.createRaffle{value: RESERVE}(_erc20Prize(address(nvda), PRIZE), 100, alice);
    }

    function test_create_ticketsAndEscrow() public {
        uint256 id = _create(100);
        Raffle.RaffleData memory r = raffle.getRaffle(id);
        assertEq(r.totalTickets, 110);
        assertEq(r.base, 100);
        assertEq(r.feeBps, 1_000);
        assertEq(uint8(r.state), uint8(Raffle.State.Open));
        assertEq(r.ethReserve, RESERVE);
        assertEq(nvda.balanceOf(address(raffle)), PRIZE);
        assertEq(raffle.erc20PrizeEscrow(address(nvda)), PRIZE);
        assertEq(raffle.ethLiability(), RESERVE);
        assertEq(address(raffle).balance, RESERVE);
    }

    function test_create_feeTicketsRoundUp() public {
        assertEq(raffle.ticketsFor(15), 17); // ceil(1.5) = 2
        assertEq(raffle.ticketsFor(10), 11);
        assertEq(raffle.ticketsFor(1_000), 1_100);
        vm.prank(house);
        raffle.setFeeBps(0);
        assertEq(raffle.ticketsFor(15), 15);
    }

    function test_create_nonRoundBase_ticketsRoundUp() public {
        uint256 id = _create(15); // 15 + ceil(1.5) = 17: the Pot gets $2, never less than 10%
        assertEq(raffle.getRaffle(id).totalTickets, 17);
        _buy(alice, id, 17);
        _reveal(id, _rndFor(0, 17));
        raffle.settle(id);
        assertEq(usdc.balanceOf(pot), 2e6);
    }

    function test_withdraw_creditsPayOnlyOnce() public {
        uint256 id = _create(10);
        _buy(alice, id, 11);
        _reveal(id, _rndFor(0, 11));
        raffle.settle(id);
        uint256 credit = raffle.ethOwed(house);
        uint256 before = house.balance;
        raffle.withdrawEth(house);
        vm.expectRevert(Raffle.NothingOwed.selector);
        raffle.withdrawEth(house);
        assertEq(house.balance - before, credit, "ETH credit paid exactly once");
    }

    function test_create_baseBounds() public {
        vm.startPrank(house);
        vm.expectRevert(abi.encodeWithSelector(Raffle.BaseOutOfRange.selector, uint64(9), uint64(10), uint64(1_000)));
        raffle.createRaffle{value: RESERVE}(_erc20Prize(address(nvda), PRIZE), 9, house);
        vm.expectRevert(abi.encodeWithSelector(Raffle.BaseOutOfRange.selector, uint64(1_001), uint64(10), uint64(1_000)));
        raffle.createRaffle{value: RESERVE}(_erc20Prize(address(nvda), PRIZE), 1_001, house);
        raffle.setBaseLimits(5, 5_000);
        raffle.createRaffle{value: RESERVE}(_erc20Prize(address(nvda), PRIZE), 5_000, house);
        vm.stopPrank();
    }

    function test_create_prizeMustBeRegistryEnabled() public {
        registry.setEnabled(address(nvda), false);
        vm.prank(house);
        vm.expectRevert(abi.encodeWithSelector(Raffle.PrizeNotAllowed.selector, address(nvda)));
        raffle.createRaffle{value: RESERVE}(_erc20Prize(address(nvda), PRIZE), 100, house);
    }

    function test_create_zeroPrize() public {
        vm.prank(house);
        vm.expectRevert(Raffle.ZeroPrize.selector);
        raffle.createRaffle{value: RESERVE}(_erc20Prize(address(nvda), 0), 100, house);
    }

    function test_create_nftOffAtLaunch() public {
        noun.mint(house, 7);
        vm.prank(house);
        vm.expectRevert(Raffle.NftPrizesDisabled.selector);
        raffle.createRaffle{value: RESERVE}(
            Raffle.Prize({kind: Raffle.PrizeKind.ERC721, token: address(noun), amountOrId: 7}), 100, house
        );
    }

    function test_create_reserveTooLow() public {
        vm.prank(house);
        vm.expectRevert(abi.encodeWithSelector(Raffle.ReserveTooLow.selector, RESERVE - 1, RESERVE));
        raffle.createRaffle{value: RESERVE - 1}(_erc20Prize(address(nvda), PRIZE), 100, house);
    }

    function test_create_rejectsFeeOnTransferPrize() public {
        FeeOnTransferToken fot = new FeeOnTransferToken("fot", "FOT", 8, 100);
        registry.setStock(address(fot), Venue.Slipstream, 0, 10, 8, true);
        fot.mint(house, 1e10);
        vm.startPrank(house);
        fot.approve(address(raffle), type(uint256).max);
        vm.expectRevert(); // PrizeNotReceived: the escrow is measured, not trusted
        raffle.createRaffle{value: RESERVE}(_erc20Prize(address(fot), 1e9), 100, house);
        vm.stopPrank();
    }

    function test_create_zeroPayee() public {
        vm.prank(house);
        vm.expectRevert(Raffle.ZeroAddress.selector);
        raffle.createRaffle{value: RESERVE}(_erc20Prize(address(nvda), PRIZE), 100, address(0));
    }

    /* --------------------------------- buy --------------------------------- */

    function test_buy_rangesAndLiability() public {
        uint256 id = _create(10); // 11 tickets
        _buy(alice, id, 3);
        _buy(bob, id, 1);
        _buy(alice, id, 5);
        assertEq(raffle.purchaseCount(id), 3, "one slot per purchase, not per ticket");
        assertEq(raffle.buyerOf(id, 0), alice);
        assertEq(raffle.buyerOf(id, 2), alice);
        assertEq(raffle.buyerOf(id, 3), bob);
        assertEq(raffle.buyerOf(id, 4), alice);
        assertEq(raffle.buyerOf(id, 8), alice);
        vm.expectRevert(abi.encodeWithSelector(Raffle.TicketOutOfRange.selector, uint64(9), uint64(9)));
        raffle.buyerOf(id, 9);
        assertEq(usdc.balanceOf(address(raffle)), 9e6);
        assertEq(raffle.usdcLiability(), 9e6);
    }

    function test_buy_guards() public {
        uint256 id = _create(10);
        vm.prank(alice);
        vm.expectRevert(Raffle.ZeroQuantity.selector);
        raffle.buy(id, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Raffle.NotEnoughTickets.selector, uint64(12), uint64(11)));
        raffle.buy(id, 12);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Raffle.WrongState.selector, uint256(99), Raffle.State.None));
        raffle.buy(99, 1);
    }

    function test_buy_lastTicketRequestsDrawFromReserve() public {
        uint256 id = _create(10);
        _buy(alice, id, 10);
        uint256 lastBuyerEth = bob.balance;
        _buy(bob, id, 1); // ticket 11 of 11
        Raffle.RaffleData memory r = raffle.getRaffle(id);
        assertEq(uint8(r.state), uint8(Raffle.State.Drawing));
        assertEq(r.ethReserve, RESERVE - FEE, "fee paid from the reserve");
        assertEq(bob.balance, lastBuyerEth, "the last buyer pays no ETH");
        assertEq(r.sequence, 1);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Raffle.WrongState.selector, id, Raffle.State.Drawing));
        raffle.buy(id, 1);
    }

    function test_buy_feeSpike_lastBuyStillSucceeds_thenAnyoneRequests() public {
        uint256 id = _create(10);
        entropy.setFee(uint128(RESERVE) + 1); // fee now above the reserve
        _buy(alice, id, 11);
        assertEq(uint8(_state(id)), uint8(Raffle.State.SoldOut), "purchase stands, draw pending");
        assertEq(raffle.getRaffle(id).ethReserve, RESERVE, "reserve untouched");

        vm.deal(carol, 1 ether);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Raffle.ReserveTooLow.selector, RESERVE, RESERVE + 1));
        raffle.requestDraw(id);

        vm.prank(carol);
        raffle.requestDraw{value: 1}(id); // top up the 1-wei shortfall
        assertEq(uint8(_state(id)), uint8(Raffle.State.Drawing));
        assertEq(entropy.seededRequests(), entropy.totalRequests(), "requestDraw uses the seeded overload");
        assertTrue(entropy.userRandomOf(address(entropy), raffle.getRaffle(id).sequence) != bytes32(0));
        assertEq(raffle.getRaffle(id).ethReserve, 0);
        assertEq(raffle.ethLiability(), 0);
    }

    function test_buy_entropyOutage_lastBuyStillSucceeds() public {
        BrokenEntropy broken = new BrokenEntropy();
        Raffle r2 = new Raffle(house, address(usdc), address(broken), address(registry), pot, 1 hours);
        vm.startPrank(house);
        nvda.approve(address(r2), type(uint256).max);
        uint256 id = r2.createRaffle{value: RESERVE}(_erc20Prize(address(nvda), PRIZE), 10, house);
        vm.stopPrank();
        vm.prank(alice);
        usdc.approve(address(r2), type(uint256).max);
        vm.prank(alice);
        r2.buy(id, 11);
        assertEq(uint8(r2.getRaffle(id).state), uint8(Raffle.State.SoldOut));
        assertEq(r2.getRaffle(id).ethReserve, RESERVE, "reserve untouched on a failed request");
        assertEq(address(r2).balance, RESERVE);
    }

    /* ------------------------------- callback ------------------------------- */

    function test_callback_onlyEntropy() public {
        vm.prank(alice);
        vm.expectRevert(Raffle.OnlyEntropy.selector);
        raffle._entropyCallback(1, address(entropy), bytes32(uint256(1)));
    }

    function test_callback_orphanDoesNotRevert() public {
        vm.prank(address(entropy));
        raffle._entropyCallback(42, address(entropy), bytes32(uint256(1))); // unknown request
    }

    function test_callback_recordsUniformIndex() public {
        uint256 id = _create(10);
        _buy(alice, id, 11);
        bytes32 rnd = bytes32(uint256(keccak256("x")));
        _reveal(id, rnd);
        Raffle.RaffleData memory r = raffle.getRaffle(id);
        assertEq(uint8(r.state), uint8(Raffle.State.Drawn));
        assertEq(r.randomNumber, rnd);
        assertEq(r.winningTicket, uint64(uint256(rnd) % 11));
        // A second delivery of the same request is an orphan: the draw cannot be overwritten.
        vm.prank(address(entropy));
        raffle._entropyCallback(r.sequence, address(entropy), bytes32(uint256(5)));
        assertEq(raffle.getRaffle(id).randomNumber, rnd);
    }

    /* -------------------------------- settle -------------------------------- */

    function test_settle_paysEveryLeg() public {
        uint256 id = _create(100); // 110 tickets: $100 house, $10 Pot
        _buy(alice, id, 40); // tickets 0-39
        _buy(bob, id, 30); //   40-69
        _buy(carol, id, 40); // 70-109
        _reveal(id, _rndFor(55, 110)); // bob's ticket
        uint256 houseUsdc = usdc.balanceOf(house);
        raffle.settle(id);

        Raffle.RaffleData memory r = raffle.getRaffle(id);
        assertEq(r.winner, bob);
        assertEq(r.winningTicket, 55);
        assertEq(nvda.balanceOf(bob), PRIZE, "prize pushed to the winner");
        assertEq(usdc.balanceOf(house) - houseUsdc, 100e6, "base to the payee");
        assertEq(usdc.balanceOf(pot), 10e6, "fee tickets to the Pot");
        assertEq(usdc.balanceOf(address(raffle)), 0);
        assertEq(raffle.usdcLiability(), 0);
        assertEq(raffle.erc20PrizeEscrow(address(nvda)), 0);
        assertEq(raffle.ethOwed(house), RESERVE - FEE, "leftover reserve credited to the payee");

        uint256 before = house.balance;
        vm.prank(alice); // anyone may deliver it; it only pays the payee
        raffle.withdrawEth(house);
        assertEq(house.balance - before, RESERVE - FEE);
        assertEq(address(raffle).balance, 0);

        vm.expectRevert(abi.encodeWithSelector(Raffle.WrongState.selector, id, Raffle.State.Settled));
        raffle.settle(id);
    }

    function test_settle_beforeDraw_reverts() public {
        uint256 id = _create(10);
        _buy(alice, id, 11);
        vm.expectRevert(abi.encodeWithSelector(Raffle.WrongState.selector, id, Raffle.State.Drawing));
        raffle.settle(id);
    }

    function test_settle_firstAndLastTicket() public {
        uint256 id = _create(10);
        _buy(alice, id, 1);
        _buy(bob, id, 9);
        _buy(carol, id, 1);
        _reveal(id, _rndFor(0, 11));
        raffle.settle(id);
        assertEq(raffle.getRaffle(id).winner, alice);

        uint256 id2 = _create(10);
        _buy(alice, id2, 1);
        _buy(bob, id2, 9);
        _buy(carol, id2, 1);
        _reveal(id2, _rndFor(10, 11));
        raffle.settle(id2);
        assertEq(raffle.getRaffle(id2).winner, carol);
    }

    function test_settle_refusedWinner_creditsPrize_othersStillPaid() public {
        BlacklistToken bl = new BlacklistToken("B20", "B20", 8);
        registry.setStock(address(bl), Venue.Slipstream, 0, 10, 8, true);
        bl.mint(house, PRIZE);
        vm.startPrank(house);
        bl.approve(address(raffle), PRIZE);
        uint256 id = raffle.createRaffle{value: RESERVE}(_erc20Prize(address(bl), PRIZE), 10, house);
        vm.stopPrank();
        _buy(alice, id, 11);
        bl.setBlacklisted(alice, true); // the winner is sanctioned
        _reveal(id, _rndFor(3, 11));
        raffle.settle(id);

        assertEq(raffle.prizeOwedTo(id), alice, "prize credited, not lost");
        assertEq(bl.balanceOf(address(raffle)), PRIZE);
        assertEq(raffle.erc20PrizeEscrow(address(bl)), PRIZE);
        assertEq(usdc.balanceOf(pot), 1e6, "the Pot was still paid");

        vm.expectRevert(bytes("BLACKLISTED"));
        raffle.claimPrize(id);
        bl.setBlacklisted(alice, false);
        vm.prank(bob); // anyone may push it; it only goes to alice
        raffle.claimPrize(id);
        assertEq(bl.balanceOf(alice), PRIZE);
        assertEq(raffle.prizeOwedTo(id), address(0));
        vm.expectRevert(Raffle.NothingOwed.selector);
        raffle.claimPrize(id);
    }

    function test_settle_refusedPayee_creditsUsdc() public {
        BlacklistToken bu = new BlacklistToken("USDC", "USDC", 6);
        Raffle r2 = new Raffle(house, address(bu), address(entropy), address(registry), pot, 1 hours);
        vm.startPrank(house);
        nvda.approve(address(r2), type(uint256).max);
        uint256 id = r2.createRaffle{value: RESERVE}(_erc20Prize(address(nvda), PRIZE), 10, house);
        vm.stopPrank();
        bu.mint(alice, 11e6);
        vm.startPrank(alice);
        bu.approve(address(r2), 11e6);
        r2.buy(id, 11);
        vm.stopPrank();
        bu.setBlacklisted(house, true);
        entropy.fulfill(r2.getRaffle(id).sequence, _rndFor(0, 11));
        r2.settle(id);
        assertEq(bu.balanceOf(pot), 1e6, "Pot paid");
        assertEq(nvda.balanceOf(alice), PRIZE, "winner paid");
        assertEq(r2.usdcOwed(house), 10e6, "payee credited");
        assertEq(r2.usdcLiability(), 10e6);
        assertEq(bu.balanceOf(address(r2)), 10e6);
        bu.setBlacklisted(house, false);
        r2.withdrawUsdc(house);
        assertEq(bu.balanceOf(house), 10e6);
        assertEq(r2.usdcLiability(), 0);
        assertEq(r2.usdcOwed(house), 0);
        vm.expectRevert(Raffle.NothingOwed.selector);
        r2.withdrawUsdc(house); // a credit pays exactly once
        assertEq(bu.balanceOf(house), 10e6);
    }

    function test_reentrancy_prizeTokenCannotReenter() public {
        ReentrantToken evil = new ReentrantToken();
        registry.setStock(address(evil), Venue.Slipstream, 0, 10, 8, true);
        evil.mint(house, PRIZE);
        vm.startPrank(house);
        evil.approve(address(raffle), PRIZE);
        uint256 id = raffle.createRaffle{value: RESERVE}(_erc20Prize(address(evil), PRIZE), 10, house);
        vm.stopPrank();
        _buy(alice, id, 11);
        _reveal(id, _rndFor(0, 11));
        evil.arm(raffle, id);
        raffle.settle(id);
        assertTrue(evil.reentryBlocked(), "nonReentrant stopped the re-entry");
        assertEq(evil.balanceOf(alice), PRIZE, "paid exactly once");
    }

    /* ------------------------------ retryDraw ------------------------------- */

    function test_retryDraw_onlyAfterTimeout_andOnlyIfNeverRevealed() public {
        uint256 id = _create(10);
        _buy(alice, id, 11);
        uint64 seq1 = raffle.getRaffle(id).sequence;

        vm.prank(house);
        vm.expectRevert(); // RedrawNotReady
        raffle.retryDraw(id);

        vm.warp(block.timestamp + 1 hours);
        entropy.setStatus(seq1, 3); // CALLBACK_FAILED: the number is public -> no fresh draw
        vm.prank(house);
        vm.expectRevert(abi.encodeWithSelector(Raffle.RevealAlreadyPublic.selector, id, uint8(3)));
        raffle.retryDraw(id);

        entropy.setStatus(seq1, 1); // CALLBACK_NOT_STARTED
        vm.prank(house);
        raffle.retryDraw(id);
        uint64 seq2 = raffle.getRaffle(id).sequence;
        assertEq(seq2, seq1 + 1);
        assertEq(raffle.getRaffle(id).ethReserve, RESERVE - 2 * FEE, "second fee from the reserve");

        // The stale request is now an orphan; only the new one can draw.
        entropy.fulfill(seq1, bytes32(uint256(1)));
        assertEq(uint8(_state(id)), uint8(Raffle.State.Drawing));
        entropy.fulfill(seq2, _rndFor(4, 11));
        assertEq(uint8(_state(id)), uint8(Raffle.State.Drawn));
        assertEq(raffle.getRaffle(id).winningTicket, 4);
    }

    function test_retryDraw_onlyOwnerPayeeOrKeeper() public {
        // The house creates with carol as payee, so owner, payee and keeper are three accounts.
        vm.prank(house);
        uint256 id = raffle.createRaffle{value: RESERVE}(_erc20Prize(address(nvda), PRIZE), 10, carol);
        _buy(alice, id, 11);
        vm.warp(block.timestamp + 1 hours);

        // A ticket holder can never choose to re-roll; neither can a stranger, or an unset keeper.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Raffle.NotAuthorized.selector, alice));
        raffle.retryDraw(id);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Raffle.NotAuthorized.selector, bob));
        raffle.retryDraw(id);

        // Only the owner names the keeper.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        raffle.setKeeper(bob);
        vm.prank(house);
        raffle.setKeeper(bob);
        assertEq(raffle.keeper(), bob);

        vm.deal(bob, 1 ether);
        vm.prank(bob);
        raffle.retryDraw{value: RESERVE}(id); // keeper
        uint64 s2 = raffle.getRaffle(id).sequence;

        vm.warp(block.timestamp + 1 hours);
        vm.prank(carol);
        raffle.retryDraw(id); // payee
        uint64 s3 = raffle.getRaffle(id).sequence;
        assertGt(s3, s2);

        vm.warp(block.timestamp + 1 hours);
        vm.prank(house);
        raffle.retryDraw(id); // owner
        assertGt(raffle.getRaffle(id).sequence, s3);

        // Clearing the keeper removes its access again.
        vm.prank(house);
        raffle.setKeeper(address(0));
        vm.warp(block.timestamp + 1 hours);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Raffle.NotAuthorized.selector, bob));
        raffle.retryDraw(id);
    }

    function test_retryDraw_timeoutSnapshottedAtCreation() public {
        vm.prank(house);
        raffle.setRedrawTimeout(24 hours);
        uint256 a = _create(10); // snapshot: 24 h
        assertEq(raffle.getRaffle(a).redrawTimeout, 24 hours);

        vm.prank(house);
        raffle.setRedrawTimeout(1 hours); // later change: must not shorten raffle `a`
        uint256 b = _create(10); // snapshot: 1 h
        assertEq(raffle.getRaffle(b).redrawTimeout, 1 hours);
        assertEq(raffle.getRaffle(a).redrawTimeout, 24 hours, "unchanged by the setter");

        _buy(alice, a, 11);
        _buy(alice, b, 11);
        uint64 requestedAt = raffle.getRaffle(a).drawRequestedAt;
        vm.warp(block.timestamp + 1 hours);

        vm.prank(house);
        vm.expectRevert(
            abi.encodeWithSelector(Raffle.RedrawNotReady.selector, uint64(block.timestamp), requestedAt + 24 hours)
        );
        raffle.retryDraw(a);
        vm.prank(house);
        raffle.retryDraw(b); // its own 1 h has passed

        // And the reverse: raising the global value does not lengthen a live raffle either.
        vm.prank(house);
        raffle.setRedrawTimeout(30 days);
        vm.warp(block.timestamp + 23 hours);
        vm.prank(house);
        raffle.retryDraw(a); // 24 h after its request
    }

    /* ------------------------------ user seed ------------------------------- */

    /// @dev The seed Raffle._drawSeed must produce for this request, restated independently.
    function _expectedSeed(uint256 id, uint256 nonce, address lastBuyer) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                address(raffle),
                id,
                nonce,
                raffle.getRaffle(id).totalTickets,
                lastBuyer,
                blockhash(block.number - 1),
                block.prevrandao,
                block.timestamp
            )
        );
    }

    function test_draw_passesContractMixedSeedToEntropy() public {
        uint256 id = _create(10);
        _buy(alice, id, 5);
        vm.roll(block.number + 5);
        vm.prevrandao(bytes32(uint256(0xabc)));
        bytes32 want = _expectedSeed(id, 1, bob);

        vm.expectEmit(true, true, true, true, address(raffle));
        emit Raffle.DrawRequested(id, address(entropy), 1, FEE, want);
        _buy(bob, id, 6); // the last ticket requests the draw

        uint64 seq = raffle.getRaffle(id).sequence;
        assertEq(entropy.userRandomOf(address(entropy), seq), want, "Entropy received exactly our seed");
        assertEq(entropy.seededRequests(), 1, "the seeded overload was used");
        assertEq(entropy.totalRequests(), 1, "and no other overload");
    }

    function test_draw_everyRequestGetsADistinctSeed() public {
        uint256 a = _create(10);
        uint256 b = _create(10);
        _buy(alice, a, 11);
        _buy(alice, b, 11); // same block, same buyer, same sold: only id and nonce differ
        bytes32 sa = entropy.userRandomOf(address(entropy), raffle.getRaffle(a).sequence);
        bytes32 sb = entropy.userRandomOf(address(entropy), raffle.getRaffle(b).sequence);
        assertTrue(sa != sb);

        vm.warp(block.timestamp + 1 hours);
        bytes32 want = _expectedSeed(a, 3, alice); // third request overall
        vm.prank(house);
        raffle.retryDraw(a);
        bytes32 sa2 = entropy.userRandomOf(address(entropy), raffle.getRaffle(a).sequence);
        assertEq(sa2, want);
        assertTrue(sa2 != sa, "a retry never reuses the seed");
        assertEq(entropy.seededRequests(), entropy.totalRequests());
    }

    /* --------------------------- create: base 0 ----------------------------- */

    function test_create_baseZero_reverts() public {
        vm.prank(house);
        vm.expectRevert(abi.encodeWithSelector(Raffle.BaseOutOfRange.selector, uint64(0), uint64(10), uint64(1_000)));
        raffle.createRaffle{value: RESERVE}(_erc20Prize(address(nvda), PRIZE), 0, house);
    }

    /* ------------------------ strict transfer results ----------------------- */

    /// @dev A refused-looking answer must never count as delivered, and must never revert settle.
    function _settleWithShape(ReturnShapeToken.Shape shape) internal returns (uint256 id, ReturnShapeToken tok) {
        tok = new ReturnShapeToken();
        registry.setStock(address(tok), Venue.Slipstream, 0, 10, 18, true);
        tok.mint(house, PRIZE);
        vm.prank(house);
        tok.approve(address(raffle), type(uint256).max);
        vm.prank(house);
        id = raffle.createRaffle{value: RESERVE}(_erc20Prize(address(tok), PRIZE), 10, house);
        _buy(alice, id, 11);
        _reveal(id, _rndFor(0, 11));
        tok.setShape(shape);
        raffle.settle(id);
    }

    function test_tryTransfer_strictReturnData() public {
        ReturnShapeToken.Shape[3] memory refused =
            [ReturnShapeToken.Shape.TwoWords, ReturnShapeToken.Shape.NotABool, ReturnShapeToken.Shape.False];
        for (uint256 i; i < 3; ++i) {
            (uint256 id, ReturnShapeToken tok) = _settleWithShape(refused[i]);
            assertEq(uint8(_state(id)), uint8(Raffle.State.Settled), "settle never reverts on the shape");
            assertEq(raffle.prizeOwedTo(id), alice, "not counted as delivered: owed instead");
            assertEq(raffle.erc20PrizeEscrow(address(tok)), PRIZE, "escrow still counts it");
            assertEq(tok.balanceOf(address(raffle)), PRIZE, "and it is still held");

            tok.setShape(ReturnShapeToken.Shape.Standard);
            raffle.claimPrize(id);
            assertEq(tok.balanceOf(alice), PRIZE, "claimable once the token answers normally");
        }
        (uint256 okId,) = _settleWithShape(ReturnShapeToken.Shape.Standard);
        assertEq(raffle.prizeOwedTo(okId), address(0), "a standard answer is delivered at settle");
    }

    /* ------------------------------ NFT prizes ------------------------------ */

    function test_nftPrize_whenEnabled_fullCycle() public {
        noun.mint(house, 7);
        vm.startPrank(house);
        raffle.setNftPrizesEnabled(true);
        Raffle.Prize memory p = Raffle.Prize({kind: Raffle.PrizeKind.ERC721, token: address(noun), amountOrId: 7});
        vm.expectRevert(abi.encodeWithSelector(Raffle.PrizeNotAllowed.selector, address(noun)));
        raffle.createRaffle{value: RESERVE}(p, 10, house);
        raffle.setNftCollectionAllowed(address(noun), true);
        noun.approve(address(raffle), 7);
        uint256 id = raffle.createRaffle{value: RESERVE}(p, 10, house);
        vm.stopPrank();
        assertEq(noun.ownerOf(7), address(raffle));

        _buy(alice, id, 5);
        _buy(bob, id, 6);
        _reveal(id, _rndFor(8, 11));
        raffle.settle(id);
        assertEq(raffle.prizeOwedTo(id), bob, "an NFT is never pushed inside settle");
        assertEq(usdc.balanceOf(pot), 1e6);
        raffle.claimPrize(id);
        assertEq(noun.ownerOf(7), bob);
    }

    /* ------------------------------ ownership ------------------------------- */

    function test_ownerSetters_boundsAndAccess() public {
        vm.startPrank(house);
        vm.expectRevert(Raffle.BadConfig.selector);
        raffle.setFeeBps(2_001);
        vm.expectRevert(Raffle.BadConfig.selector);
        raffle.setBaseLimits(0, 10);
        vm.expectRevert(Raffle.BadConfig.selector);
        raffle.setBaseLimits(20, 10);
        vm.expectRevert(Raffle.BadConfig.selector);
        raffle.setBaseLimits(1, 1_000_001);
        vm.expectRevert(Raffle.BadConfig.selector);
        raffle.setRedrawTimeout(59 minutes);
        vm.expectRevert(Raffle.BadConfig.selector);
        raffle.setCallbackGasLimit(99_999);
        vm.stopPrank();
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        raffle.setFeeBps(500);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        raffle.setNftPrizesEnabled(true);
        vm.stopPrank();
    }

    function test_feeChange_doesNotTouchLiveRaffle() public {
        uint256 id = _create(100); // 110 tickets at 10%
        vm.prank(house);
        raffle.setFeeBps(2_000);
        assertEq(raffle.getRaffle(id).totalTickets, 110);
        assertEq(raffle.getRaffle(id).feeBps, 1_000);
    }

    /// @dev The owner's whole surface: none of these can move a prize, ticket money or a reserve.
    function test_ownerHasNoPathToEscrow() public {
        uint256 id = _create(10);
        _buy(alice, id, 5);
        uint256 usdcHeld = usdc.balanceOf(address(raffle));
        uint256 prizeHeld = nvda.balanceOf(address(raffle));
        uint256 ethHeld = address(raffle).balance;
        vm.startPrank(house);
        raffle.setFeeBps(2_000);
        raffle.setBaseLimits(1, 1_000_000);
        raffle.setRedrawTimeout(30 days);
        raffle.setCallbackGasLimit(1_000_000);
        raffle.setNftPrizesEnabled(true);
        raffle.setNftCollectionAllowed(address(noun), true);
        vm.expectRevert(Raffle.NothingOwed.selector);
        raffle.withdrawUsdc(house);
        vm.expectRevert(Raffle.NothingOwed.selector);
        raffle.withdrawEth(house);
        vm.expectRevert(Raffle.NothingOwed.selector);
        raffle.claimPrize(id);
        raffle.transferOwnership(alice);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(raffle)), usdcHeld);
        assertEq(nvda.balanceOf(address(raffle)), prizeHeld);
        assertEq(address(raffle).balance, ethHeld);
        assertEq(uint8(_state(id)), uint8(Raffle.State.Open));
    }

    /* ---------------------------- binary search ----------------------------- */

    /// @dev buyerOf(t) agrees with a naive scan for random purchase layouts.
    function testFuzz_buyerOfMatchesNaiveScan(uint256 seed, uint8 purchasesRaw) public {
        vm.prank(house);
        raffle.setBaseLimits(1, 1_000_000);
        uint64 base = 300;
        uint256 id = _create(base);
        uint64 n = raffle.getRaffle(id).totalTickets;
        uint256 count = bound(purchasesRaw, 1, 60);
        address[] memory owners = new address[](n);
        uint64 sold;
        address[3] memory who = [alice, bob, carol];
        for (uint256 i; i < count && sold < n - 1; ++i) {
            uint64 q = uint64(bound(uint256(keccak256(abi.encode(seed, i))), 1, 12));
            if (sold + q > n - 1) q = n - 1 - sold;
            address b = who[uint256(keccak256(abi.encode(seed, i, "w"))) % 3];
            _buy(b, id, q);
            for (uint64 t = sold; t < sold + q; ++t) owners[t] = b;
            sold += q;
        }
        for (uint64 t; t < sold; ++t) assertEq(raffle.buyerOf(id, t), owners[t]);
    }

    /* --------------------------------- gas ---------------------------------- */

    function test_gas_largeRaffle() public {
        vm.prank(house);
        raffle.setBaseLimits(1, 1_000_000);
        entropy.setRecordSeeds(false); // measure the Raffle, not the mock's seed bookkeeping
        uint256 id = _create(10_000); // 11,000 tickets
        uint64 n = raffle.getRaffle(id).totalTickets;
        // 2,000 single-ticket purchases, then one big buy, then the last ticket.
        for (uint256 i; i < 2_000; ++i) _buy(i % 2 == 0 ? alice : bob, id, 1);
        uint256 g = gasleft();
        _buy(carol, id, 1);
        uint256 buyOne = g - gasleft();
        _buy(alice, id, n - 2_002);
        g = gasleft();
        _buy(bob, id, 1); // last ticket: also requests Entropy
        uint256 lastBuy = g - gasleft();
        _reveal(id, _rndFor(1_337, n));
        g = gasleft();
        raffle.settle(id);
        uint256 settleGas = g - gasleft();
        emit log_named_uint("buy (1 ticket, 2k purchases deep)", buyOne);
        emit log_named_uint("last buy incl. Entropy request", lastBuy);
        emit log_named_uint("settle over 2,003 purchases / 11,000 tickets", settleGas);
        assertLt(buyOne, 120_000);
        assertLt(lastBuy, 250_000);
        assertLt(settleGas, 250_000);
    }
}
