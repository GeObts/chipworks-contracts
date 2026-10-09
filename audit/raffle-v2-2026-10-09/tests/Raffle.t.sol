// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Raffle} from "../../src/raffle/Raffle.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Venue} from "../../src/interfaces/IStockRegistry.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ReturnShapeToken} from "../mocks/ReturnShapeToken.sol";
import {MockSlipstreamPool, MockSlipstreamRouter} from "../mocks/MockSlipstream.sol";
import {RaffleTestBase} from "./RaffleTestBase.sol";

/// @dev Entropy whose request always reverts (outage) but quotes a fee.
contract BrokenEntropy {
    function getDefaultProvider() external view returns (address) {
        return address(this);
    }

    function getFeeV2(address, uint32) external pure returns (uint128) {
        return 0.00002 ether;
    }

    function requestV2(address, bytes32, uint32) external payable returns (uint64) {
        revert("entropy down");
    }
}

/// @dev A registry-enabled prize stock that tries to re-enter the raffle when it pays out.
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

    function _deploy(address u, address e, address reg, address p, address r, uint64 redraw, uint64 acq)
        internal
        returns (Raffle)
    {
        return new Raffle(house, u, e, reg, p, r, redraw, acq);
    }

    function test_constructor_zeroAddresses() public {
        address u = address(usdc);
        address e = address(entropy);
        address reg = address(registry);
        address r = address(router);
        vm.expectRevert(Raffle.ZeroAddress.selector);
        _deploy(address(0), e, reg, pot, r, 1 hours, 6 hours);
        vm.expectRevert(Raffle.ZeroAddress.selector);
        _deploy(u, address(0), reg, pot, r, 1 hours, 6 hours);
        vm.expectRevert(Raffle.ZeroAddress.selector);
        _deploy(u, e, address(0), pot, r, 1 hours, 6 hours);
        vm.expectRevert(Raffle.ZeroAddress.selector);
        _deploy(u, e, reg, address(0), r, 1 hours, 6 hours);
        vm.expectRevert(Raffle.ZeroAddress.selector);
        _deploy(u, e, reg, pot, address(0), 1 hours, 6 hours);
    }

    function test_constructor_rejectsNonSixDecimalUsdc() public {
        MockERC20 bad = new MockERC20("x", "x", 18);
        vm.expectRevert(abi.encodeWithSelector(Raffle.UsdcNotSixDecimals.selector, uint8(18)));
        _deploy(address(bad), address(entropy), address(registry), pot, address(router), 1 hours, 6 hours);
    }

    function test_constructor_usdcMustBeTheRegistryQuote() public {
        MockERC20 other = new MockERC20("Other", "O", 6);
        vm.expectRevert(Raffle.BadConfig.selector);
        _deploy(address(other), address(entropy), address(registry), pot, address(router), 1 hours, 6 hours);
    }

    function test_constructor_routerMustSwapInTheRegistryFactory() public {
        MockSlipstreamRouter foreign = new MockSlipstreamRouter(makeAddr("factory-A"));
        vm.expectRevert(Raffle.BadConfig.selector);
        _deploy(address(usdc), address(entropy), address(registry), pot, address(foreign), 1 hours, 6 hours);
        assertEq(raffle.factory(), address(factory), "the router's factory is pinned");
    }

    function test_constructor_timeoutBounds() public {
        address u = address(usdc);
        address e = address(entropy);
        address reg = address(registry);
        address r = address(router);
        vm.expectRevert(Raffle.BadConfig.selector);
        _deploy(u, e, reg, pot, r, 1 hours - 1, 6 hours);
        vm.expectRevert(Raffle.BadConfig.selector);
        _deploy(u, e, reg, pot, r, 30 days + 1, 6 hours);
        vm.expectRevert(Raffle.BadConfig.selector);
        _deploy(u, e, reg, pot, r, 1 hours, 1 hours - 1);
        vm.expectRevert(Raffle.BadConfig.selector);
        _deploy(u, e, reg, pot, r, 1 hours, 7 days + 1);
        _deploy(u, e, reg, pot, r, 30 days, 7 days);
    }

    function test_launchDefaults() public view {
        assertEq(raffle.feeBps(), 1_000);
        assertEq(raffle.minBase(), 10);
        assertEq(raffle.maxBase(), 1_000);
        assertEq(raffle.redrawTimeout(), 1 hours);
        assertEq(raffle.acquireTimeout(), 6 hours);
        (uint32 w, uint16 dev, uint16 slip, uint16 share) = raffle.priceGuard();
        assertEq(w, 30 minutes, "TWAP window");
        assertEq(dev, 100, "manipulation guard: 100 ticks ~ 1%");
        assertEq(slip, 150, "slippage floor 1.5%");
        assertEq(share, 100, "buy <= 1% of the pool's USDC");
        assertEq(raffle.pot(), pot);
        assertEq(raffle.owner(), house);
        assertEq(address(raffle.router()), address(router));
    }

    /* ------------------------------- create -------------------------------- */

    function test_create_onlyOwner() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        raffle.createRaffle{value: RESERVE}(address(nvda), 100);
    }

    function test_create_escrowsNothingButTheReserve_andSnapshots() public {
        uint256 id = _create(100);
        Raffle.RaffleData memory r = raffle.getRaffle(id);
        assertEq(r.base, 100);
        assertEq(r.totalTickets, 110, "fee ON TOP: $100 prize -> 110 tickets");
        assertEq(r.stock, address(nvda));
        assertEq(r.pool, address(pool));
        assertEq(r.tickSpacing, SPACING);
        assertEq(r.creator, house);
        assertEq(uint8(r.prize.kind), uint8(Raffle.PrizeKind.Stock));
        assertEq(r.prize.amount, 0, "no prize until it is bought");
        assertEq(r.ethReserve, RESERVE);
        assertEq(r.redrawTimeout, 1 hours);
        assertEq(r.acquireTimeout, 6 hours);
        assertEq(r.guard.twapWindow, 30 minutes);
        assertEq(r.guard.maxDeviationTicks, 100);
        assertEq(r.guard.maxSlippageBps, 150);
        assertEq(r.guard.maxPoolShareBps, 100);
        assertEq(nvda.balanceOf(address(raffle)), 0, "the house pre-funds nothing");
        assertEq(raffle.ethLiability(), RESERVE);
    }

    function test_create_feeOnTopRoundsUp() public {
        assertEq(raffle.getRaffle(_create(15)).totalTickets, 17, "$15 + ceil(1.5) = 17");
        assertEq(raffle.getRaffle(_create(10)).totalTickets, 11);
        assertEq(raffle.getRaffle(_create(1_000)).totalTickets, 1_100);
    }

    function test_create_baseBounds() public {
        vm.startPrank(house);
        vm.expectRevert(abi.encodeWithSelector(Raffle.BaseOutOfRange.selector, uint64(0), uint64(10), uint64(1_000)));
        raffle.createRaffle{value: RESERVE}(address(nvda), 0);
        vm.expectRevert(abi.encodeWithSelector(Raffle.BaseOutOfRange.selector, uint64(9), uint64(10), uint64(1_000)));
        raffle.createRaffle{value: RESERVE}(address(nvda), 9);
        vm.expectRevert(abi.encodeWithSelector(Raffle.BaseOutOfRange.selector, uint64(1_001), uint64(10), uint64(1_000)));
        raffle.createRaffle{value: RESERVE}(address(nvda), 1_001);
        vm.stopPrank();
    }

    /// @dev The revert data of `revert(reason)`.
    function _err(string memory reason) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("Error(string)", reason);
    }

    function _expectNotBuyable(address stock, Raffle.Refusal why) internal {
        vm.prank(house);
        vm.expectRevert(abi.encodeWithSelector(Raffle.StockNotBuyable.selector, stock, why));
        raffle.createRaffle{value: RESERVE}(stock, 100);
    }

    function test_create_refusesAStockThatCannotBeBoughtNow() public {
        vm.prank(house);
        vm.expectRevert(Raffle.ZeroAddress.selector);
        raffle.createRaffle{value: RESERVE}(address(0), 100);

        registry.setEnabled(address(nvda), false);
        _expectNotBuyable(address(nvda), Raffle.Refusal.StockDisabled);
        registry.setEnabled(address(nvda), true);

        registry.setRegistered(address(nvda), false);
        _expectNotBuyable(address(nvda), Raffle.Refusal.StockDisabled);
        registry.setRegistered(address(nvda), true);

        registry.setStock(address(nvda), Venue.UniswapV3, 3000, SPACING, 8, true);
        _expectNotBuyable(address(nvda), Raffle.Refusal.NotSlipstream);
        registry.setStock(address(nvda), Venue.Slipstream, 0, SPACING, 8, true); // resets the pool
        _expectNotBuyable(address(nvda), Raffle.Refusal.PoolMismatch);
        registry.setPool(address(nvda), address(pool));

        // The registry's pool is not the pool the router swaps in.
        MockSlipstreamPool impostor = new MockSlipstreamPool(address(usdc), address(nvda), SPACING);
        registry.setPool(address(nvda), address(impostor));
        _expectNotBuyable(address(nvda), Raffle.Refusal.PoolMismatch);
        registry.setPool(address(nvda), address(pool));

        // The right address, but the pool's own tick spacing disagrees.
        pool.setTickSpacing(200);
        _expectNotBuyable(address(nvda), Raffle.Refusal.PoolMismatch);
        pool.setTickSpacing(SPACING);

        pool.setObserveReverts(true);
        _expectNotBuyable(address(nvda), Raffle.Refusal.TwapUnavailable);
        pool.setObserveReverts(false);
        pool.setMaxAge(29 minutes); // the oracle buffer does not reach 30 minutes back
        _expectNotBuyable(address(nvda), Raffle.Refusal.TwapUnavailable);
        pool.setMaxAge(type(uint32).max);

        _create(100); // and with everything restored it creates
    }

    function test_create_refusesAPoolWhoseTokensAreNotUsdcAndTheStock() public {
        MockERC20 other = new MockERC20("Other", "OTH", 8);
        MockSlipstreamPool wrongPair = new MockSlipstreamPool(address(other), address(nvda), SPACING);
        registry.setPool(address(nvda), address(wrongPair));
        factory.setPool(address(usdc), address(nvda), SPACING, address(wrongPair));
        _expectNotBuyable(address(nvda), Raffle.Refusal.PoolMismatch);
    }

    function test_create_tooLargeForPool() public {
        vm.prank(house);
        raffle.setBaseLimits(10, 1_000_000);
        // 1% of $10M of pool USDC = $100,000.
        uint256 id = _createBase(100_000);
        assertEq(raffle.getRaffle(id).base, 100_000);
        vm.prank(house);
        vm.expectRevert(abi.encodeWithSelector(Raffle.StockNotBuyable.selector, address(nvda), Raffle.Refusal.TooLargeForPool));
        raffle.createRaffle{value: RESERVE}(address(nvda), 100_001);
    }

    function _createBase(uint64 base) internal returns (uint256) {
        vm.prank(house);
        return raffle.createRaffle{value: RESERVE}(address(nvda), base);
    }

    function test_create_reserveTooLow() public {
        vm.prank(house);
        vm.expectRevert(abi.encodeWithSelector(Raffle.ReserveTooLow.selector, RESERVE - 1, RESERVE));
        raffle.createRaffle{value: RESERVE - 1}(address(nvda), 100);
    }

    /* --------------------------------- buy --------------------------------- */

    function test_buy_guards() public {
        uint256 id = _create(10);
        vm.prank(alice);
        vm.expectRevert(Raffle.ZeroQuantity.selector);
        raffle.buy(id, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Raffle.NotEnoughTickets.selector, uint64(12), uint64(11)));
        raffle.buy(id, 12);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Raffle.WrongState.selector, 99, Raffle.State.None));
        raffle.buy(99, 1);
    }

    function test_buy_rangesAndLiability() public {
        uint256 id = _create(100);
        _buy(alice, id, 3);
        _buy(bob, id, 5);
        _buy(alice, id, 2);
        assertEq(raffle.purchaseCount(id), 3);
        assertEq(raffle.buyerOf(id, 0), alice);
        assertEq(raffle.buyerOf(id, 2), alice);
        assertEq(raffle.buyerOf(id, 3), bob);
        assertEq(raffle.buyerOf(id, 7), bob);
        assertEq(raffle.buyerOf(id, 8), alice);
        assertEq(raffle.usdcLiability(), 10e6);
        assertEq(usdc.balanceOf(address(raffle)), 10e6);
    }

    function test_buy_lastTicketOnlyMarksSoldOut_neverSwapsOrDraws() public {
        uint256 id = _create(10);
        _buy(alice, id, 10);
        vm.warp(block.timestamp + 123);
        _buy(bob, id, 1);
        Raffle.RaffleData memory r = raffle.getRaffle(id);
        assertEq(uint8(r.state), uint8(Raffle.State.SoldOut));
        assertEq(r.soldOutAt, block.timestamp);
        assertEq(router.swaps(), 0, "the last buyer never triggers the swap");
        assertEq(entropy.totalRequests(), 0, "and never the draw");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Raffle.WrongState.selector, id, Raffle.State.SoldOut));
        raffle.buy(id, 1);
    }

    /* ------------------------------- acquire ------------------------------- */

    function test_acquire_buysExactlyTheBudget_holdsTheStock_thenDraws() public {
        uint256 id = _create(100); // 110 tickets: $100 prize + $10 fee
        _sellOut(id, alice);
        uint256 fill = (_expectedOut(100e6) * 9_990) / 10_000;
        router.setFillOut(fill);

        vm.prank(keeperAcct);
        raffle.acquirePrize(id);

        Raffle.RaffleData memory r = raffle.getRaffle(id);
        assertEq(router.lastAmountIn(), 100e6, "spends exactly the prize budget");
        assertEq(r.prize.amount, fill, "the share count is what the swap delivered");
        assertEq(nvda.balanceOf(address(raffle)), fill, "the stock is HELD before the draw");
        assertEq(raffle.erc20PrizeEscrow(address(nvda)), fill);
        assertEq(usdc.balanceOf(address(raffle)), 10e6, "only the Pot's fee remains in USDC");
        assertEq(raffle.usdcLiability(), 10e6);
        assertEq(usdc.allowance(address(raffle), address(router)), 0, "approval reset");
        assertEq(uint8(r.state), uint8(Raffle.State.Drawing), "randomness requested AFTER the prize is held");
        assertEq(entropy.seededRequests(), 1);
    }

    function test_acquire_onlyOwnerOrKeeper() public {
        uint256 id = _create(10);
        _sellOut(id, alice);
        router.setFillOut(_expectedOut(10e6));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Raffle.NotAuthorized.selector, alice));
        raffle.acquirePrize(id);
        vm.prank(house);
        raffle.acquirePrize(id); // the owner may
        assertEq(uint8(_state(id)), uint8(Raffle.State.Drawing));
    }

    function test_acquire_wrongState() public {
        uint256 id = _create(10);
        vm.prank(keeperAcct);
        vm.expectRevert(abi.encodeWithSelector(Raffle.WrongState.selector, id, Raffle.State.Open));
        raffle.acquirePrize(id);
        _sellOut(id, alice);
        _acquire(id);
        vm.prank(keeperAcct);
        vm.expectRevert(abi.encodeWithSelector(Raffle.WrongState.selector, id, Raffle.State.Drawing));
        raffle.acquirePrize(id);
    }

    function test_acquire_minOutIsTheTwapPriceLessSlippage() public {
        uint256 id = _create(100);
        _sellOut(id, alice);
        _acquire(id);
        // $100 at $250 = 0.4 NVDAc = 40,000,000 raw; floor 1.5% under.
        uint256 want = (_expectedOut(100e6) * 9_850) / 10_000;
        assertApproxEqRel(router.lastMinOut(), want, 1e12, "minOut = TWAP output * 98.5%");
        assertLe(router.lastMinOut(), want, "and never above it");
    }

    function test_acquire_twapAwayFromSpotMovesTheFloorByTicks() public {
        // TWAP 80 ticks ABOVE spot: the average price gave MORE stock per USDC than spot does,
        // so the floor rises by 1.0001^80 (~0.80%).
        uint256 id = _create(100);
        _sellOut(id, alice);
        pool.setTwapTick(SPOT_TICK + 80);
        router.setFillOut(_expectedOut(100e6));
        vm.prank(keeperAcct);
        raffle.acquirePrize(id);
        uint256 atSpot = (_expectedOut(100e6) * 9_850) / 10_000;
        assertApproxEqRel(router.lastMinOut(), (atSpot * 10_080_317) / 10_000_000, 1e14, "x1.0001^80");

        // TWAP below spot: the floor falls.
        uint256 id2 = _create(100);
        _sellOut(id2, bob);
        pool.setTwapTick(SPOT_TICK - 80);
        vm.prank(keeperAcct);
        raffle.acquirePrize(id2);
        assertApproxEqRel(router.lastMinOut(), (atSpot * 10_000_000) / 10_080_317, 1e14, "/1.0001^80");
    }

    function test_acquire_spotPushedFromTwap_isRefused() public {
        uint256 id = _create(100);
        _sellOut(id, alice);
        router.setFillOut(_expectedOut(100e6));

        pool.setTwapTick(SPOT_TICK + 101); // spot pushed 101 ticks (~1.01%) below its average
        vm.prank(keeperAcct);
        vm.expectRevert(abi.encodeWithSelector(Raffle.AcquireRefused.selector, id, Raffle.Refusal.SpotDeviates));
        raffle.acquirePrize(id);
        pool.setTwapTick(SPOT_TICK - 101); // and above
        vm.prank(keeperAcct);
        vm.expectRevert(abi.encodeWithSelector(Raffle.AcquireRefused.selector, id, Raffle.Refusal.SpotDeviates));
        raffle.acquirePrize(id);

        pool.setTwapTick(SPOT_TICK - 100); // exactly at the bound is allowed
        vm.prank(keeperAcct);
        raffle.acquirePrize(id);
        assertEq(uint8(_state(id)), uint8(Raffle.State.Drawing));
    }

    function test_acquire_twapRoundsTowardNegativeInfinity() public {
        // Mean = (-9164 * 1800 - 1) / 1800 = -9164.0005...: it must FLOOR to -9165, not
        // truncate to -9164. -9165 is one tick under spot, so the floor shrinks by 1/1.0001.
        uint256 id = _create(100);
        _sellOut(id, alice);
        pool.setCumulativeExtra(-1);
        router.setFillOut(_expectedOut(100e6));
        vm.prank(keeperAcct);
        raffle.acquirePrize(id);
        uint256 atSpot = (_expectedOut(100e6) * 9_850) / 10_000;
        assertApproxEqRel(router.lastMinOut(), (atSpot * 10_000) / 10_001, 1e13, "floor of the mean tick");
    }

    function test_acquire_swapRefusals_moveNothing() public {
        uint256 id = _create(100);
        _sellOut(id, alice);
        uint256 usdcBefore = usdc.balanceOf(address(raffle));

        // The pool fills below the floor: the router itself refuses.
        router.setFillOut((_expectedOut(100e6) * 9_800) / 10_000);
        vm.prank(keeperAcct);
        vm.expectRevert(abi.encodeWithSelector(Raffle.SwapReverted.selector, id, _err("Too little received")));
        raffle.acquirePrize(id);

        // A router that reverts.
        router.setMode(MockSlipstreamRouter.Mode.Revert);
        vm.prank(keeperAcct);
        vm.expectRevert(abi.encodeWithSelector(Raffle.SwapReverted.selector, id, _err("router down")));
        raffle.acquirePrize(id);

        // A router that ignores the floor: caught by the measured balance.
        router.setMode(MockSlipstreamRouter.Mode.IgnoreMin);
        vm.prank(keeperAcct);
        vm.expectRevert(abi.encodeWithSelector(Raffle.AcquireRefused.selector, id, Raffle.Refusal.UnderDelivered));
        raffle.acquirePrize(id);

        // A router that spends only part of the budget.
        router.setMode(MockSlipstreamRouter.Mode.PartialSpend);
        router.setFillOut(_expectedOut(100e6));
        vm.prank(keeperAcct);
        vm.expectRevert(abi.encodeWithSelector(Raffle.AcquireRefused.selector, id, Raffle.Refusal.PartialSpend));
        raffle.acquirePrize(id);

        assertEq(uint8(_state(id)), uint8(Raffle.State.SoldOut), "still waiting for a buy");
        assertEq(usdc.balanceOf(address(raffle)), usdcBefore, "nothing moved");
        assertEq(nvda.balanceOf(address(raffle)), 0);
        assertEq(usdc.allowance(address(raffle), address(router)), 0);

        router.setMode(MockSlipstreamRouter.Mode.Normal);
        _acquire(id); // and it recovers
        assertEq(uint8(_state(id)), uint8(Raffle.State.Drawing));
    }

    function test_acquire_conditionsChangedSinceCreation() public {
        uint256 id = _create(100);
        _sellOut(id, alice);
        router.setFillOut(_expectedOut(100e6));

        registry.setEnabled(address(nvda), false);
        vm.prank(keeperAcct);
        vm.expectRevert(abi.encodeWithSelector(Raffle.AcquireRefused.selector, id, Raffle.Refusal.StockDisabled));
        raffle.acquirePrize(id);
        registry.setEnabled(address(nvda), true);

        pool.setObserveReverts(true);
        vm.prank(keeperAcct);
        vm.expectRevert(abi.encodeWithSelector(Raffle.AcquireRefused.selector, id, Raffle.Refusal.TwapUnavailable));
        raffle.acquirePrize(id);
        pool.setObserveReverts(false);

        // The registry and factory re-point the stock to a new pool: the raffle's guard was
        // validated against the old one, so it refuses.
        MockSlipstreamPool moved = new MockSlipstreamPool(address(usdc), address(nvda), SPACING);
        moved.setSpot(_sqrtPriceFor(PRICE_NUM, PRICE_DEN), SPOT_TICK);
        moved.setTwapTick(SPOT_TICK);
        registry.setPool(address(nvda), address(moved));
        factory.setPool(address(usdc), address(nvda), SPACING, address(moved));
        vm.prank(keeperAcct);
        vm.expectRevert(abi.encodeWithSelector(Raffle.AcquireRefused.selector, id, Raffle.Refusal.PoolMismatch));
        raffle.acquirePrize(id);
        registry.setPool(address(nvda), address(pool));
        factory.setPool(address(usdc), address(nvda), SPACING, address(pool));

        // The pool's USDC shrinks below 100x the budget.
        vm.prank(address(pool));
        usdc.transfer(carol, POOL_USDC - 9_999e6);
        vm.prank(keeperAcct);
        vm.expectRevert(abi.encodeWithSelector(Raffle.AcquireRefused.selector, id, Raffle.Refusal.TooLargeForPool));
        raffle.acquirePrize(id);
        usdc.mint(address(pool), 1e6); // exactly $10,000 -> 1% = $100
        _acquire(id);
        assertEq(uint8(_state(id)), uint8(Raffle.State.Drawing));
    }

    function test_acquire_stockAsToken0() public {
        // A pool where the stock sorts first: USDC is token1, so output = in / price.
        BlacklistTokenLike stock0 = BlacklistTokenLike(address(new MockERC20("Low", "LOW", 8)));
        registry.setStock(address(stock0), Venue.Slipstream, 0, SPACING, 8, true);
        MockSlipstreamPool p = new MockSlipstreamPool(address(stock0), address(usdc), SPACING);
        // token1/token0 = USDC per stock = 2.5 raw USDC per raw stock ($250 again).
        p.setSpot(_sqrtPriceFor(25, 10), 9163);
        p.setTwapTick(9163);
        registry.setPool(address(stock0), address(p));
        factory.setPool(address(usdc), address(stock0), SPACING, address(p));
        usdc.mint(address(p), POOL_USDC);
        stock0.mint(address(router), 1_000_000e8);

        vm.prank(house);
        uint256 id = raffle.createRaffle{value: RESERVE}(address(stock0), 100);
        _sellOut(id, alice);
        router.setFillOut(40_000_000);
        vm.prank(keeperAcct);
        raffle.acquirePrize(id);
        assertApproxEqRel(router.lastMinOut(), (40_000_000 * 9_850) / 10_000, 1e12, "in / price, less 1.5%");
        assertEq(raffle.getRaffle(id).prize.amount, 40_000_000);

        // TWAP 80 ticks above spot here means MORE USDC per stock on average: the stock was
        // dearer, so the floor FALLS by 1.0001^80 (the opposite of the USDC-is-token0 case).
        vm.prank(house);
        uint256 id2 = raffle.createRaffle{value: RESERVE}(address(stock0), 100);
        _sellOut(id2, bob);
        p.setTwapTick(9163 + 80);
        vm.prank(keeperAcct);
        raffle.acquirePrize(id2);
        assertApproxEqRel(router.lastMinOut(), uint256(40_000_000 * 9_850 * 1000) / (10_000 * 1008), 2e14, "/1.0001^80");
    }

    function test_acquire_entropyOutage_prizeHeld_thenAnyoneRequests() public {
        uint256 id = _create(10);
        _sellOut(id, alice);
        entropy.setFee(uint128(RESERVE) + 1); // fee now above the reserve
        _acquire(id);
        assertEq(uint8(_state(id)), uint8(Raffle.State.PrizeReady), "prize held, draw pending");
        assertGt(raffle.getRaffle(id).prize.amount, 0);

        vm.deal(carol, 1 ether);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Raffle.ReserveTooLow.selector, RESERVE, RESERVE + 1));
        raffle.requestDraw(id);
        vm.prank(carol);
        raffle.requestDraw{value: 1}(id);
        assertEq(uint8(_state(id)), uint8(Raffle.State.Drawing));
        assertEq(entropy.seededRequests(), entropy.totalRequests());
    }

    function test_acquire_brokenEntropy_neverBlocksTheBuy() public {
        BrokenEntropy broken = new BrokenEntropy();
        Raffle r2 = new Raffle(house, address(usdc), address(broken), address(registry), pot, address(router), 1 hours, 6 hours);
        vm.prank(house);
        uint256 id = r2.createRaffle{value: RESERVE}(address(nvda), 10);
        vm.prank(alice);
        usdc.approve(address(r2), type(uint256).max);
        vm.prank(alice);
        r2.buy(id, 11);
        router.setFillOut(_expectedOut(10e6));
        vm.prank(house);
        r2.acquirePrize(id);
        assertEq(uint8(r2.getRaffle(id).state), uint8(Raffle.State.PrizeReady));
        assertEq(r2.getRaffle(id).ethReserve, RESERVE, "reserve untouched");
    }

    /* ------------------------------- fallback ------------------------------ */

    function test_fallback_onlyAfterTheTimeout_byAnyone_thenDraws() public {
        uint256 id = _create(100);
        _sellOut(id, alice);
        uint64 soldOutAt = raffle.getRaffle(id).soldOutAt;

        vm.warp(soldOutAt + 6 hours - 1);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(Raffle.AcquireTimeoutNotReached.selector, uint64(block.timestamp), soldOutAt + 6 hours)
        );
        raffle.fallbackToUsdc(id);

        vm.warp(soldOutAt + 6 hours);
        vm.prank(bob); // anyone, not just owner/keeper
        raffle.fallbackToUsdc(id);
        Raffle.RaffleData memory r = raffle.getRaffle(id);
        assertEq(uint8(r.prize.kind), uint8(Raffle.PrizeKind.Usdc));
        assertEq(r.prize.token, address(usdc));
        assertEq(r.prize.amount, 100e6, "the prize is the $100 budget, already held");
        assertEq(uint8(r.state), uint8(Raffle.State.Drawing), "the draw proceeds");
        assertEq(router.swaps(), 0);
    }

    function test_fallback_usesTheRaffleSnapshot_notTheLiveSetting() public {
        uint256 id = _create(10); // snapshot: 6 h
        vm.prank(house);
        raffle.setAcquireTimeout(7 days);
        _sellOut(id, alice);
        vm.warp(block.timestamp + 6 hours);
        raffle.fallbackToUsdc(id); // 6 h is enough for THIS raffle
        assertEq(uint8(raffle.getRaffle(id).prize.kind), uint8(Raffle.PrizeKind.Usdc));

        vm.prank(house);
        raffle.setAcquireTimeout(1 hours);
        uint256 id2 = _create(10); // snapshot: 1 h
        vm.prank(house);
        raffle.setAcquireTimeout(7 days);
        _sellOut(id2, alice);
        vm.warp(block.timestamp + 1 hours);
        raffle.fallbackToUsdc(id2);
        assertEq(uint8(raffle.getRaffle(id2).prize.kind), uint8(Raffle.PrizeKind.Usdc));
    }

    function test_fallback_entropyOutage_prizeReady_thenRequest() public {
        uint256 id = _create(10);
        _sellOut(id, alice);
        vm.warp(block.timestamp + 6 hours);
        entropy.setFee(uint128(RESERVE) + 1);
        raffle.fallbackToUsdc(id);
        assertEq(uint8(_state(id)), uint8(Raffle.State.PrizeReady), "prize held, draw pending");
        // The buy can no longer happen: the prize is fixed as USDC.
        router.setFillOut(_expectedOut(10e6));
        vm.prank(keeperAcct);
        vm.expectRevert(abi.encodeWithSelector(Raffle.WrongState.selector, id, Raffle.State.PrizeReady));
        raffle.acquirePrize(id);
        vm.deal(carol, 1 ether);
        vm.prank(carol);
        raffle.requestDraw{value: 1}(id);
        assertEq(uint8(_state(id)), uint8(Raffle.State.Drawing));
    }

    function test_fallback_racesWithAcquire() public {
        uint256 a = _create(10);
        _sellOut(a, alice);
        _acquire(a);
        vm.warp(block.timestamp + 6 hours);
        vm.expectRevert(abi.encodeWithSelector(Raffle.WrongState.selector, a, Raffle.State.Drawing));
        raffle.fallbackToUsdc(a);

        uint256 b = _create(10);
        _sellOut(b, alice);
        vm.warp(block.timestamp + 6 hours);
        _acquire(b); // a late buy is still allowed while nobody has fallen back
        assertEq(uint8(raffle.getRaffle(b).prize.kind), uint8(Raffle.PrizeKind.Stock));

        uint256 c = _create(10);
        _sellOut(c, alice);
        vm.warp(block.timestamp + 6 hours);
        raffle.fallbackToUsdc(c);
        router.setFillOut(_expectedOut(10e6));
        vm.prank(keeperAcct);
        vm.expectRevert(abi.encodeWithSelector(Raffle.WrongState.selector, c, Raffle.State.Drawing));
        raffle.acquirePrize(c);
    }

    function test_fallback_settlesInUsdc() public {
        uint256 id = _create(100);
        _buy(alice, id, 60);
        _buy(bob, id, 50);
        vm.warp(block.timestamp + 6 hours);
        raffle.fallbackToUsdc(id);
        _reveal(id, _rndFor(70, 110)); // bob's range
        uint256 bobBefore = usdc.balanceOf(bob);
        raffle.settle(id);
        assertEq(raffle.getRaffle(id).winner, bob);
        assertEq(usdc.balanceOf(bob) - bobBefore, 100e6, "winner gets the $100 prize in USDC");
        assertEq(usdc.balanceOf(pot), 10e6, "the Pot gets its fee");
        assertEq(usdc.balanceOf(address(raffle)), 0);
        assertEq(raffle.usdcLiability(), 0);
    }

    function test_fallback_refusedWinner_isCreditedUsdc() public {
        uint256 id = _create(10);
        _sellOut(id, alice);
        vm.warp(block.timestamp + 6 hours);
        raffle.fallbackToUsdc(id);
        _reveal(id, _rndFor(0, 11));
        usdc.setBlacklisted(alice, true);
        raffle.settle(id);
        assertEq(raffle.usdcOwed(alice), 10e6, "credited, not lost");
        assertEq(usdc.balanceOf(pot), 1e6, "the Pot is still paid");
        assertEq(raffle.usdcLiability(), 10e6);
        usdc.setBlacklisted(alice, false);
        raffle.withdrawUsdc(alice);
        assertEq(raffle.usdcLiability(), 0);
    }

    /* ------------------------------ snapshots ------------------------------ */

    function test_snapshots_ownerChangesNeverTouchALiveRaffle() public {
        uint256 id = _create(100);
        vm.startPrank(house);
        raffle.setAcquireTimeout(7 days);
        raffle.setRedrawTimeout(30 days);
        raffle.setPriceGuard(
            Raffle.PriceGuard({twapWindow: 2 hours, maxDeviationTicks: 1, maxSlippageBps: 1, maxPoolShareBps: 1})
        );
        raffle.setFeeBps(2_000);
        vm.stopPrank();

        Raffle.RaffleData memory r = raffle.getRaffle(id);
        assertEq(r.acquireTimeout, 6 hours);
        assertEq(r.redrawTimeout, 1 hours);
        assertEq(r.guard.maxDeviationTicks, 100);
        assertEq(r.guard.maxSlippageBps, 150);
        assertEq(r.feeBps, 1_000);

        _sellOut(id, alice);
        pool.setTwapTick(SPOT_TICK + 50); // allowed by the raffle's 100-tick guard, not by 1 tick
        _acquire(id);
        assertEq(uint8(_state(id)), uint8(Raffle.State.Drawing));

        uint256 id2 = _create(100); // a new raffle takes the new values
        assertEq(raffle.getRaffle(id2).acquireTimeout, 7 days);
        assertEq(raffle.getRaffle(id2).guard.twapWindow, 2 hours);
        assertEq(raffle.getRaffle(id2).totalTickets, 120);
    }

    /* ----------------------------- draw / seed ----------------------------- */

    function test_callback_onlyEntropy() public {
        vm.expectRevert(Raffle.OnlyEntropy.selector);
        raffle._entropyCallback(1, address(entropy), bytes32(0));
    }

    function test_callback_orphanDoesNotRevert() public {
        vm.prank(address(entropy));
        raffle._entropyCallback(77, address(entropy), bytes32(uint256(1)));
    }

    function test_callback_recordsUniformIndex() public {
        uint256 id = _create(10);
        _sellOut(id, alice);
        _acquire(id);
        _reveal(id, bytes32(uint256(11 * 1000 + 6)));
        Raffle.RaffleData memory r = raffle.getRaffle(id);
        assertEq(uint8(r.state), uint8(Raffle.State.Drawn));
        assertEq(r.winningTicket, 6);
    }

    /// @dev The seed Raffle._drawSeed must produce, restated independently.
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
        _buy(bob, id, 6);
        vm.roll(block.number + 5);
        vm.prevrandao(bytes32(uint256(0xabc)));
        bytes32 want = _expectedSeed(id, 1, bob);
        router.setFillOut(_expectedOut(10e6));

        vm.expectEmit(true, true, true, true, address(raffle));
        emit Raffle.DrawRequested(id, address(entropy), 1, FEE, want);
        vm.prank(keeperAcct);
        raffle.acquirePrize(id);
        uint64 seq = raffle.getRaffle(id).sequence;
        assertEq(entropy.userRandomOf(address(entropy), seq), want, "Entropy received exactly our seed");
        assertEq(entropy.seededRequests(), 1);
        assertEq(entropy.totalRequests(), 1);
    }

    function test_draw_everyRequestGetsADistinctSeed() public {
        uint256 a = _create(10);
        uint256 b = _create(10);
        _sellOut(a, alice);
        _sellOut(b, alice);
        _acquire(a);
        _acquire(b);
        bytes32 sa = entropy.userRandomOf(address(entropy), raffle.getRaffle(a).sequence);
        bytes32 sb = entropy.userRandomOf(address(entropy), raffle.getRaffle(b).sequence);
        assertTrue(sa != sb);

        vm.warp(block.timestamp + 1 hours);
        bytes32 want = _expectedSeed(a, 3, alice);
        vm.prank(house);
        raffle.retryDraw(a);
        bytes32 sa2 = entropy.userRandomOf(address(entropy), raffle.getRaffle(a).sequence);
        assertEq(sa2, want);
        assertTrue(sa2 != sa, "a retry never reuses the seed");
    }

    function test_retryDraw_onlyAfterTimeout_onlyIfNeverRevealed_ownerOrKeeper() public {
        uint256 id = _create(10);
        _sellOut(id, alice);
        _acquire(id);
        uint64 seq1 = raffle.getRaffle(id).sequence;

        vm.prank(keeperAcct);
        vm.expectRevert(); // RedrawNotReady
        raffle.retryDraw(id);

        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice); // a ticket holder can never re-roll
        vm.expectRevert(abi.encodeWithSelector(Raffle.NotAuthorized.selector, alice));
        raffle.retryDraw(id);

        entropy.setStatus(seq1, 3); // FAILED: the number is public -> no fresh draw
        vm.prank(keeperAcct);
        vm.expectRevert(abi.encodeWithSelector(Raffle.RevealAlreadyPublic.selector, id, uint8(3)));
        raffle.retryDraw(id);

        entropy.setStatus(seq1, 1);
        vm.prank(keeperAcct);
        raffle.retryDraw(id);
        uint64 seq2 = raffle.getRaffle(id).sequence;
        assertEq(seq2, seq1 + 1);

        vm.warp(block.timestamp + 1 hours);
        vm.prank(house);
        raffle.retryDraw(id); // the owner too
        uint64 seq3 = raffle.getRaffle(id).sequence;

        entropy.fulfill(seq1, bytes32(uint256(1)));
        entropy.fulfill(seq2, bytes32(uint256(2)));
        assertEq(uint8(_state(id)), uint8(Raffle.State.Drawing), "superseded requests are orphans");
        entropy.fulfill(seq3, _rndFor(4, 11));
        assertEq(raffle.getRaffle(id).winningTicket, 4);
    }

    function test_retryDraw_timeoutSnapshotted() public {
        vm.prank(house);
        raffle.setRedrawTimeout(24 hours);
        uint256 a = _create(10);
        vm.prank(house);
        raffle.setRedrawTimeout(1 hours);
        _sellOut(a, alice);
        _acquire(a);
        uint64 at = raffle.getRaffle(a).drawRequestedAt;
        vm.warp(block.timestamp + 1 hours);
        vm.prank(house);
        vm.expectRevert(abi.encodeWithSelector(Raffle.RedrawNotReady.selector, uint64(block.timestamp), at + 24 hours));
        raffle.retryDraw(a);
        vm.warp(at + 24 hours);
        vm.prank(house);
        raffle.retryDraw(a);
    }

    /* -------------------------------- settle ------------------------------- */

    function test_settle_paysTheStockToTheWinner_feeToPot_reserveToCreator() public {
        uint256 id = _create(100);
        _buy(alice, id, 50);
        _buy(bob, id, 40);
        _buy(carol, id, 20);
        _acquire(id);
        uint256 prize = raffle.getRaffle(id).prize.amount;
        _reveal(id, _rndFor(77, 110)); // bob: tickets 50-89
        raffle.settle(id);

        assertEq(raffle.getRaffle(id).winner, bob);
        assertEq(nvda.balanceOf(bob), prize, "the bought shares, all of them");
        assertEq(usdc.balanceOf(pot), 10e6, "fee on top -> Pot");
        assertEq(usdc.balanceOf(address(raffle)), 0);
        assertEq(nvda.balanceOf(address(raffle)), 0);
        assertEq(raffle.erc20PrizeEscrow(address(nvda)), 0);
        assertEq(raffle.usdcLiability(), 0);
        assertEq(raffle.ethOwed(house), RESERVE - FEE, "leftover reserve -> creator");
        uint256 before = house.balance;
        raffle.withdrawEth(house);
        assertEq(house.balance - before, RESERVE - FEE);
        assertEq(raffle.ethLiability(), 0);
    }

    function test_settle_firstAndLastTicket() public {
        uint256 id = _create(10);
        _buy(alice, id, 1);
        _buy(bob, id, 9);
        _buy(carol, id, 1);
        _acquire(id);
        _reveal(id, _rndFor(0, 11));
        raffle.settle(id);
        assertEq(raffle.getRaffle(id).winner, alice);

        uint256 id2 = _create(10);
        _buy(alice, id2, 1);
        _buy(bob, id2, 9);
        _buy(carol, id2, 1);
        _acquire(id2);
        _reveal(id2, _rndFor(10, 11));
        raffle.settle(id2);
        assertEq(raffle.getRaffle(id2).winner, carol);
    }

    function test_settle_beforeDraw_reverts() public {
        uint256 id = _create(10);
        _sellOut(id, alice);
        vm.expectRevert(abi.encodeWithSelector(Raffle.WrongState.selector, id, Raffle.State.SoldOut));
        raffle.settle(id);
    }

    function test_settle_refusedWinner_stockIsCredited_othersStillPaid() public {
        uint256 id = _create(10);
        _sellOut(id, alice);
        _acquire(id);
        uint256 prize = raffle.getRaffle(id).prize.amount;
        _reveal(id, _rndFor(3, 11));
        nvda.setBlacklisted(alice, true);
        raffle.settle(id);
        assertEq(raffle.prizeOwedTo(id), alice);
        assertEq(raffle.erc20PrizeEscrow(address(nvda)), prize, "still counted");
        assertEq(usdc.balanceOf(pot), 1e6, "the Pot is paid anyway");

        vm.expectRevert();
        raffle.claimPrize(id); // still refused: reverts, moves nothing
        assertEq(raffle.prizeOwedTo(id), alice);

        nvda.setBlacklisted(alice, false);
        raffle.claimPrize(id);
        assertEq(nvda.balanceOf(alice), prize);
        assertEq(raffle.erc20PrizeEscrow(address(nvda)), 0);
        vm.expectRevert(Raffle.NothingOwed.selector);
        raffle.claimPrize(id);
    }

    function test_settle_refusedPot_isCredited() public {
        uint256 id = _create(10);
        _sellOut(id, alice);
        _acquire(id);
        _reveal(id, _rndFor(0, 11));
        usdc.setBlacklisted(pot, true);
        raffle.settle(id);
        assertEq(raffle.usdcOwed(pot), 1e6);
        assertEq(raffle.usdcLiability(), 1e6);
        assertGt(nvda.balanceOf(alice), 0, "the winner is paid anyway");
        usdc.setBlacklisted(pot, false);
        raffle.withdrawUsdc(pot);
        vm.expectRevert(Raffle.NothingOwed.selector);
        raffle.withdrawUsdc(pot);
        assertEq(raffle.usdcLiability(), 0);
    }

    function test_withdraw_creditsPayOnlyOnce() public {
        uint256 id = _create(10);
        _sellOut(id, alice);
        _acquire(id);
        _reveal(id, _rndFor(0, 11));
        raffle.settle(id);
        raffle.withdrawEth(house);
        vm.expectRevert(Raffle.NothingOwed.selector);
        raffle.withdrawEth(house);
    }

    function test_reentrancy_prizeTokenCannotReenter() public {
        ReentrantToken evil = new ReentrantToken();
        _newPoolFor(address(evil));
        vm.prank(house);
        uint256 id = raffle.createRaffle{value: RESERVE}(address(evil), 10);
        _sellOut(id, alice);
        router.setFillOut(_expectedOut(10e6));
        vm.prank(keeperAcct);
        raffle.acquirePrize(id);
        uint256 prize = raffle.getRaffle(id).prize.amount;
        _reveal(id, _rndFor(0, 11));
        evil.arm(raffle, id);
        raffle.settle(id);
        assertTrue(evil.reentryBlocked(), "nonReentrant stopped the re-entry");
        assertEq(evil.balanceOf(alice), prize, "paid exactly once");
    }

    /// @dev `_newPool` for a MockERC20 stock (mint through the MockERC20 interface).
    function _newPoolFor(address stock) internal returns (MockSlipstreamPool p) {
        registry.setStock(stock, Venue.Slipstream, 0, SPACING, 8, true);
        p = new MockSlipstreamPool(address(usdc), stock, SPACING);
        p.setSpot(_sqrtPriceFor(PRICE_NUM, PRICE_DEN), SPOT_TICK);
        p.setTwapTick(SPOT_TICK);
        registry.setPool(stock, address(p));
        factory.setPool(address(usdc), stock, SPACING, address(p));
        usdc.mint(address(p), POOL_USDC);
        MockERC20(stock).mint(address(router), 1_000_000e8);
    }

    function test_tryTransfer_strictReturnData() public {
        ReturnShapeToken tok = new ReturnShapeToken();
        registry.setStock(address(tok), Venue.Slipstream, 0, SPACING, 8, true);
        MockSlipstreamPool p = new MockSlipstreamPool(address(usdc), address(tok), SPACING);
        p.setSpot(_sqrtPriceFor(PRICE_NUM, PRICE_DEN), SPOT_TICK);
        p.setTwapTick(SPOT_TICK);
        registry.setPool(address(tok), address(p));
        factory.setPool(address(usdc), address(tok), SPACING, address(p));
        usdc.mint(address(p), POOL_USDC);
        tok.mint(address(router), 1_000_000e8);

        ReturnShapeToken.Shape[3] memory refused =
            [ReturnShapeToken.Shape.TwoWords, ReturnShapeToken.Shape.NotABool, ReturnShapeToken.Shape.False];
        for (uint256 i; i < 3; ++i) {
            tok.setShape(ReturnShapeToken.Shape.Standard); // the router pays in normally
            vm.prank(house);
            uint256 id = raffle.createRaffle{value: RESERVE}(address(tok), 10);
            _sellOut(id, alice);
            router.setFillOut(_expectedOut(10e6));
            vm.prank(keeperAcct);
            raffle.acquirePrize(id);
            uint256 prize = raffle.getRaffle(id).prize.amount;
            _reveal(id, _rndFor(0, 11));
            tok.setShape(refused[i]);
            raffle.settle(id);
            assertEq(uint8(_state(id)), uint8(Raffle.State.Settled), "settle never reverts on the shape");
            assertEq(raffle.prizeOwedTo(id), alice, "not counted as delivered: owed instead");
            assertEq(raffle.erc20PrizeEscrow(address(tok)), prize);
            tok.setShape(ReturnShapeToken.Shape.Standard);
            raffle.claimPrize(id);
        }
    }

    /* --------------------------- owner boundary ---------------------------- */

    function test_ownerSetters_boundsAndAccess() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        raffle.setFeeBps(1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        raffle.setAcquireTimeout(2 hours);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        raffle.setPriceGuard(Raffle.PriceGuard(30 minutes, 100, 150, 100));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        raffle.setKeeper(alice);
        vm.stopPrank();

        vm.startPrank(house);
        vm.expectRevert(Raffle.BadConfig.selector);
        raffle.setFeeBps(2_001);
        vm.expectRevert(Raffle.BadConfig.selector);
        raffle.setBaseLimits(0, 10);
        vm.expectRevert(Raffle.BadConfig.selector);
        raffle.setBaseLimits(11, 10);
        vm.expectRevert(Raffle.BadConfig.selector);
        raffle.setBaseLimits(1, 1_000_001);
        vm.expectRevert(Raffle.BadConfig.selector);
        raffle.setRedrawTimeout(30 days + 1);
        vm.expectRevert(Raffle.BadConfig.selector);
        raffle.setAcquireTimeout(1 hours - 1);
        vm.expectRevert(Raffle.BadConfig.selector);
        raffle.setAcquireTimeout(7 days + 1);
        vm.expectRevert(Raffle.BadConfig.selector);
        raffle.setCallbackGasLimit(99_999);

        _expectBadGuard(5 minutes - 1, 100, 150, 100);
        _expectBadGuard(2 hours + 1, 100, 150, 100);
        _expectBadGuard(30 minutes, 0, 150, 100);
        _expectBadGuard(30 minutes, 501, 150, 100);
        _expectBadGuard(30 minutes, 100, 0, 100);
        _expectBadGuard(30 minutes, 100, 501, 100);
        _expectBadGuard(30 minutes, 100, 150, 0);
        _expectBadGuard(30 minutes, 100, 150, 501);
        raffle.setPriceGuard(Raffle.PriceGuard(2 hours, 500, 500, 500));
        raffle.setPriceGuard(Raffle.PriceGuard(5 minutes, 1, 1, 1));
        raffle.setAcquireTimeout(1 hours);
        raffle.setAcquireTimeout(7 days);
        vm.stopPrank();
    }

    /// @dev Called inside an owner prank (startPrank).
    function _expectBadGuard(uint32 w, uint16 dev, uint16 slip, uint16 share) internal {
        vm.expectRevert(Raffle.BadConfig.selector);
        raffle.setPriceGuard(Raffle.PriceGuard(w, dev, slip, share));
    }

    function test_ownerHasNoPathToEscrow() public {
        uint256 id = _create(100);
        _sellOut(id, alice);
        _acquire(id);
        // Every owner entry point, called mid-raffle: none moves the held stock or ticket money.
        vm.startPrank(house);
        raffle.setFeeBps(2_000);
        raffle.setBaseLimits(1, 1_000_000);
        raffle.setRedrawTimeout(1 hours);
        raffle.setAcquireTimeout(1 hours);
        raffle.setPriceGuard(Raffle.PriceGuard(5 minutes, 1, 1, 1));
        raffle.setCallbackGasLimit(1_000_000);
        raffle.setKeeper(house);
        vm.expectRevert(Raffle.NothingOwed.selector);
        raffle.withdrawUsdc(house);
        vm.expectRevert(Raffle.NothingOwed.selector);
        raffle.claimPrize(id);
        vm.stopPrank();
        assertGt(nvda.balanceOf(address(raffle)), 0);
        assertEq(usdc.balanceOf(address(raffle)), 10e6);
    }

    /* ------------------------------ quotePrize ----------------------------- */

    function test_quotePrize_matchesTheTwapPrice() public view {
        assertApproxEqRel(raffle.quotePrize(address(nvda), 100e6), _expectedOut(100e6), 1e12);
        assertEq(raffle.quotePrize(address(0xdead), 100e6), 0, "unknown stock: 0, never a revert");
    }

    /* --------------------------------- gas --------------------------------- */

    function test_gas_largeRaffle() public {
        entropy.setRecordSeeds(false); // measure the Raffle, not the mock's seed bookkeeping
        vm.prank(house);
        raffle.setBaseLimits(10, 10_000);
        uint256 id = _create(10_000); // 11,000 tickets
        address[4] memory who = [alice, bob, carol, makeAddr("dave")];
        usdc.mint(who[3], 1_000_000e6);
        vm.prank(who[3]);
        usdc.approve(address(raffle), type(uint256).max);
        for (uint256 i; i < 2_000; ++i) {
            _buy(who[i % 4], id, 5);
        }
        uint256 g = gasleft();
        _buy(alice, id, 1);
        uint256 buyOne = g - gasleft();
        _buy(bob, id, 999); // the 11,000th ticket: sold out
        router.setFillOut(_expectedOut(10_000e6));
        g = gasleft();
        vm.prank(keeperAcct);
        raffle.acquirePrize(id);
        uint256 acquireGas = g - gasleft();
        _reveal(id, _rndFor(7_777, 11_000));
        g = gasleft();
        raffle.settle(id);
        uint256 settleGas = g - gasleft();
        emit log_named_uint("buy (1 ticket, 2k purchases deep)", buyOne);
        emit log_named_uint("acquirePrize incl. swap (mock router) + Entropy request", acquireGas);
        emit log_named_uint("settle over 2,003 purchases / 11,000 tickets", settleGas);
        assertLt(buyOne, 120_000);
        assertLt(acquireGas, 500_000);
        assertLt(settleGas, 250_000);
    }

    /* --------------------------------- fuzz -------------------------------- */

    function testFuzz_buyerOfMatchesNaiveScan(uint256 seed, uint8 nPurchases) public {
        uint256 n = bound(nPurchases, 1, 40);
        vm.prank(house);
        raffle.setBaseLimits(1, 1_000_000);
        uint256 id = _create(1_000); // 1,100 tickets
        address[3] memory who = [alice, bob, carol];
        uint64[] memory ends = new uint64[](n);
        address[] memory buyers = new address[](n);
        uint64 sold;
        for (uint256 i; i < n; ++i) {
            uint64 left = 1_100 - sold;
            if (left == 0) break;
            uint64 q = uint64(bound(uint256(keccak256(abi.encode(seed, i))), 1, left > 60 ? 60 : left));
            buyers[i] = who[uint256(keccak256(abi.encode(seed, i, "w"))) % 3];
            _buy(buyers[i], id, q);
            sold += q;
            ends[i] = sold;
        }
        for (uint64 t; t < sold; t += 7) {
            address naive;
            for (uint256 i; i < n; ++i) {
                if (t < ends[i]) {
                    naive = buyers[i];
                    break;
                }
            }
            assertEq(raffle.buyerOf(id, t), naive);
        }
    }

    /// @dev The TWAP adjustment is exactly 1.0001^k, whichever side of spot the TWAP is on.
    function testFuzz_quoteScalesByTickPower(int16 kSeed) public {
        int24 k = int24(int256(bound(int256(kSeed), -500, 500)));
        uint256 atSpot = raffle.quotePrize(address(nvda), 1_000e6);
        pool.setTwapTick(SPOT_TICK + k);
        uint256 q = raffle.quotePrize(address(nvda), 1_000e6);
        // 1.0001^k by float-free reference: ln-free check via repeated multiply in 1e18.
        uint256 f = 1e18;
        uint256 n = k >= 0 ? uint256(int256(k)) : uint256(-int256(k));
        for (uint256 i; i < n; ++i) {
            f = (f * 1_000_100_000_000_000_000) / 1e18;
        }
        uint256 want = k >= 0 ? (atSpot * f) / 1e18 : (atSpot * 1e18) / f;
        assertApproxEqRel(q, want, 1e10, "quote = spot output x 1.0001^k");
    }
}

/// @dev Minimal mint surface used for an arbitrary-address stock in one test.
interface BlacklistTokenLike {
    function mint(address to, uint256 amount) external;
}
