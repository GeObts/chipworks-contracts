// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Raffle} from "../../src/raffle/Raffle.sol";
import {Venue} from "../../src/interfaces/IStockRegistry.sol";
import {MockEntropyV2} from "../mocks/MockEntropyV2.sol";
import {MockStockRegistry} from "../mocks/MockStockRegistry.sol";
import {BlacklistToken} from "../mocks/HostileTokens.sol";
import {MockSlipstreamPool, MockSlipstreamFactory, MockSlipstreamRouter} from "../mocks/MockSlipstream.sol";

/// @notice Drives Raffle v2 through random sequences: the house creates, actors buy, the keeper
///         buys the prize (sometimes refused: pool pushed off its TWAP, fill under the floor,
///         router down), stalled buys fall back to USDC after the timeout, Entropy reveals or
///         stalls or the fee spikes, anyone settles / claims / withdraws, and recipients get
///         blacklisted on USDC and on both prize stocks. Never reverts (fail-on-revert).
contract RaffleHandler is Test {
    Raffle public raffle;
    BlacklistToken public usdc;
    BlacklistToken[2] public stocks;
    MockSlipstreamPool[2] public pools;
    MockSlipstreamRouter public router;
    MockEntropyV2 public entropy;
    address public house;
    address public keeperAcct;
    address public pot;
    address[4] public actors;
    int24 public constant SPOT_TICK = -9164;

    uint256 public constant MAX_RAFFLES = 8;
    mapping(bytes4 => uint256) public calls;

    constructor(
        Raffle r,
        BlacklistToken u,
        BlacklistToken[2] memory s,
        MockSlipstreamPool[2] memory p,
        MockSlipstreamRouter ro,
        MockEntropyV2 e,
        address house_,
        address keeper_,
        address pot_,
        address[4] memory actors_
    ) {
        raffle = r;
        usdc = u;
        stocks = s;
        pools = p;
        router = ro;
        entropy = e;
        house = house_;
        keeperAcct = keeper_;
        pot = pot_;
        actors = actors_;
    }

    function _pick(uint256 seed) internal view returns (uint256 id, bool ok) {
        uint256 n = raffle.raffleCount();
        if (n == 0) return (0, false);
        return (seed % n + 1, true);
    }

    function create(uint256 baseSeed, bool second) external {
        if (raffle.raffleCount() >= MAX_RAFFLES) return;
        uint64 base = uint64(bound(baseSeed, 10, 200));
        uint256 reserve = raffle.requiredReserve();
        vm.deal(house, house.balance + reserve);
        vm.prank(house);
        raffle.createRaffle{value: reserve}(address(stocks[second ? 1 : 0]), base);
        calls[this.create.selector]++;
    }

    function buy(uint256 actorSeed, uint256 raffleSeed, uint256 qtySeed) external {
        (uint256 id, bool ok) = _pick(raffleSeed);
        if (!ok) return;
        Raffle.RaffleData memory r = raffle.getRaffle(id);
        if (r.state != Raffle.State.Open) return;
        address a = actors[actorSeed % 4];
        if (usdc.blacklisted(a)) return;
        uint64 q = uint64(bound(qtySeed, 1, r.totalTickets - r.sold));
        vm.prank(a);
        raffle.buy(id, q);
        calls[this.buy.selector]++;
    }

    /// @dev The keeper tries to buy the prize. One time in four the pool is pushed 101-150 ticks
    ///      off its TWAP (the guard refuses); otherwise it sits within 60 ticks. One time in four
    ///      the router fills 97-98.4% of the reference (under the 1.5% floor: refused); otherwise
    ///      99.4-100%. One time in five the router is down. So buys both land and get refused.
    function acquire(uint256 raffleSeed, uint256 devSeed, uint256 fillSeed, bool routerDown) external {
        (uint256 id, bool ok) = _pick(raffleSeed);
        if (!ok) return;
        Raffle.RaffleData memory r = raffle.getRaffle(id);
        if (r.state != Raffle.State.SoldOut) return;
        MockSlipstreamPool p = r.stock == address(stocks[0]) ? pools[0] : pools[1];
        int256 dev = devSeed % 4 == 0 ? int256(bound(devSeed >> 8, 101, 150)) : int256(bound(devSeed >> 8, 0, 120)) - 60;
        if (devSeed % 4 == 0 && (devSeed >> 16) % 2 == 0) dev = -dev;
        p.setTwapTick(SPOT_TICK + int24(dev));
        uint256 ref = (uint256(r.base) * 1e6 * 4) / 10;
        uint256 fillBps = fillSeed % 4 == 0 ? bound(fillSeed >> 8, 9_700, 9_840) : bound(fillSeed >> 8, 9_940, 10_000);
        router.setFillOut((ref * fillBps) / 10_000);
        router.setMode(routerDown ? MockSlipstreamRouter.Mode.Revert : MockSlipstreamRouter.Mode.Normal);
        vm.prank(keeperAcct);
        try raffle.acquirePrize(id) {
            calls[this.acquire.selector]++;
        } catch {
            calls[bytes4(keccak256("acquireRefused"))]++;
        }
        router.setMode(MockSlipstreamRouter.Mode.Normal);
        p.setTwapTick(SPOT_TICK);
    }

    function fallbackToUsdc(uint256 raffleSeed) external {
        (uint256 id, bool ok) = _pick(raffleSeed);
        if (!ok) return;
        Raffle.RaffleData memory r = raffle.getRaffle(id);
        if (r.state != Raffle.State.SoldOut) return;
        if (block.timestamp < r.soldOutAt + r.acquireTimeout) vm.warp(r.soldOutAt + r.acquireTimeout);
        raffle.fallbackToUsdc(id);
        calls[this.fallbackToUsdc.selector]++;
    }

    function reveal(uint256 raffleSeed, bytes32 rnd) external {
        (uint256 id, bool ok) = _pick(raffleSeed);
        if (!ok) return;
        Raffle.RaffleData memory r = raffle.getRaffle(id);
        if (r.state != Raffle.State.Drawing) return;
        entropy.fulfillFrom(r.provider, r.sequence, rnd);
        calls[this.reveal.selector]++;
    }

    /// @dev The fee jumps above a fresh raffle's reserve; anyone tops up through requestDraw.
    function feeSpikeAndRequest(uint256 raffleSeed, uint256 feeSeed) external {
        (uint256 id, bool ok) = _pick(raffleSeed);
        if (!ok) return;
        Raffle.RaffleData memory r = raffle.getRaffle(id);
        if (r.state != Raffle.State.PrizeReady) return;
        uint256 fee = bound(feeSeed, 0.00001 ether, 0.0002 ether);
        entropy.setFee(uint128(fee));
        uint256 topUp = fee > r.ethReserve ? fee - r.ethReserve : 0;
        vm.deal(address(this), topUp);
        raffle.requestDraw{value: topUp}(id);
        entropy.setFee(0.00002 ether);
        calls[this.feeSpikeAndRequest.selector]++;
    }

    function stallAndRetry(uint256 raffleSeed) external {
        (uint256 id, bool ok) = _pick(raffleSeed);
        if (!ok) return;
        Raffle.RaffleData memory r = raffle.getRaffle(id);
        if (r.state != Raffle.State.Drawing) return;
        vm.warp(block.timestamp + r.redrawTimeout);
        uint256 fee = raffle.quoteDrawFee();
        uint256 topUp = fee > r.ethReserve ? fee - r.ethReserve : 0;
        vm.deal(keeperAcct, keeperAcct.balance + topUp);
        vm.prank(keeperAcct);
        raffle.retryDraw{value: topUp}(id);
        calls[this.stallAndRetry.selector]++;
    }

    function settle(uint256 raffleSeed) external {
        (uint256 id, bool ok) = _pick(raffleSeed);
        if (!ok) return;
        if (raffle.getRaffle(id).state != Raffle.State.Drawn) return;
        raffle.settle(id);
        calls[this.settle.selector]++;
    }

    function toggleBlacklist(uint256 whoSeed, uint256 tokenSeed) external {
        address[5] memory who = [actors[0], actors[1], actors[2], actors[3], pot];
        address w = who[whoSeed % 5];
        uint256 t = tokenSeed % 3;
        BlacklistToken tok = t == 0 ? usdc : stocks[t - 1];
        tok.setBlacklisted(w, !tok.blacklisted(w));
        calls[this.toggleBlacklist.selector]++;
    }

    function claimPrize(uint256 raffleSeed) external {
        (uint256 id, bool ok) = _pick(raffleSeed);
        if (!ok) return;
        address w = raffle.prizeOwedTo(id);
        if (w == address(0)) return;
        BlacklistToken tok = BlacklistToken(raffle.getRaffle(id).prize.token);
        if (tok.blacklisted(w)) return;
        raffle.claimPrize(id);
        calls[this.claimPrize.selector]++;
    }

    function withdraw(uint256 whoSeed) external {
        address[6] memory who = [actors[0], actors[1], actors[2], actors[3], pot, house];
        address w = who[whoSeed % 6];
        if (raffle.usdcOwed(w) != 0 && !usdc.blacklisted(w)) raffle.withdrawUsdc(w);
        if (raffle.ethOwed(w) != 0) raffle.withdrawEth(w);
        calls[this.withdraw.selector]++;
    }

    receive() external payable {}
}

contract RaffleInvariantTest is Test {
    Raffle internal raffle;
    BlacklistToken internal usdc;
    BlacklistToken internal nvda;
    BlacklistToken internal tsla;
    MockEntropyV2 internal entropy;
    MockStockRegistry internal registry;
    MockSlipstreamFactory internal factory;
    MockSlipstreamRouter internal router;
    MockSlipstreamPool[2] internal pools;
    RaffleHandler internal handler;

    address internal house = makeAddr("house");
    address internal keeperAcct = makeAddr("keeper");
    address internal pot = makeAddr("pot");
    address[4] internal actors;
    uint256 internal constant PER_ACTOR = 1_000_000e6;
    uint256 internal constant POOL_USDC = 10_000_000e6;

    function setUp() public {
        usdc = new BlacklistToken("USD Coin", "USDC", 6);
        nvda = new BlacklistToken("NVIDIA", "NVDAc", 8);
        tsla = new BlacklistToken("Tesla", "TSLAc", 8);
        registry = new MockStockRegistry(address(usdc));
        factory = new MockSlipstreamFactory();
        registry.setSlipstreamFactory(address(factory));
        router = new MockSlipstreamRouter(address(factory));
        BlacklistToken[2] memory s = [nvda, tsla];
        for (uint256 i; i < 2; ++i) {
            registry.setStock(address(s[i]), Venue.Slipstream, 0, 10, 8, true);
            pools[i] = new MockSlipstreamPool(address(usdc), address(s[i]), 10);
            pools[i].setSpot(uint160(Math.sqrt(Math.mulDiv(4, 1 << 192, 10))), -9164);
            pools[i].setTwapTick(-9164);
            registry.setPool(address(s[i]), address(pools[i]));
            factory.setPool(address(usdc), address(s[i]), 10, address(pools[i]));
            usdc.mint(address(pools[i]), POOL_USDC);
            s[i].mint(address(router), 1e18);
        }
        entropy = new MockEntropyV2();
        entropy.setFee(0.00002 ether);
        raffle = new Raffle(house, address(usdc), address(entropy), address(registry), pot, address(router), 1 hours, 6 hours);
        vm.prank(house);
        raffle.setKeeper(keeperAcct);

        actors = [makeAddr("a0"), makeAddr("a1"), makeAddr("a2"), makeAddr("a3")];
        for (uint256 i; i < 4; ++i) {
            usdc.mint(actors[i], PER_ACTOR);
            vm.prank(actors[i]);
            usdc.approve(address(raffle), type(uint256).max);
        }
        vm.deal(house, 100 ether);

        handler = new RaffleHandler(raffle, usdc, s, pools, router, entropy, house, keeperAcct, pot, actors);
        targetContract(address(handler));
    }

    function _everyone() internal view returns (address[6] memory e) {
        e = [actors[0], actors[1], actors[2], actors[3], house, pot];
    }

    /// @dev The USDC one raffle still holds: ticket money until settle, less a bought prize's budget.
    function _usdcHeldBy(Raffle.RaffleData memory r) internal pure returns (uint256) {
        if (r.state == Raffle.State.Settled) return 0;
        uint256 held = uint256(r.sold) * 1e6;
        if (r.state >= Raffle.State.PrizeReady && r.prize.kind == Raffle.PrizeKind.Stock) held -= uint256(r.base) * 1e6;
        return held;
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_usdcAlwaysBalances() public view {
        uint256 expected;
        for (uint256 id = 1; id <= raffle.raffleCount(); ++id) expected += _usdcHeldBy(raffle.getRaffle(id));
        address[6] memory e = _everyone();
        for (uint256 i; i < 6; ++i) expected += raffle.usdcOwed(e[i]);
        assertEq(raffle.usdcLiability(), expected, "liability == unspent ticket money + credits");
        assertEq(usdc.balanceOf(address(raffle)), expected, "USDC held == owed, to the unit");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_usdcConserved() public view {
        // Every USDC unit is with an actor, the house, the Pot, the raffle or a pool (the swap's
        // other side). None is created, lost, or left with the router.
        uint256 sum = usdc.balanceOf(address(raffle)) + usdc.balanceOf(house) + usdc.balanceOf(pot)
            + usdc.balanceOf(address(pools[0])) + usdc.balanceOf(address(pools[1]));
        for (uint256 i; i < 4; ++i) sum += usdc.balanceOf(actors[i]);
        assertEq(sum, usdc.totalSupply(), "no USDC created, lost or stranded");
        assertEq(usdc.balanceOf(address(router)), 0);
        assertEq(usdc.allowance(address(raffle), address(router)), 0, "no lingering approval");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_ethAlwaysBalances() public view {
        uint256 expected;
        for (uint256 id = 1; id <= raffle.raffleCount(); ++id) {
            expected += raffle.getRaffle(id).ethReserve;
        }
        address[6] memory e = _everyone();
        for (uint256 i; i < 6; ++i) expected += raffle.ethOwed(e[i]);
        assertEq(raffle.ethLiability(), expected, "liability == reserves + credits");
        assertEq(address(raffle).balance, expected, "ETH held == owed, to the wei");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_prizesAlwaysBalance() public view {
        uint256 nv;
        uint256 ts;
        for (uint256 id = 1; id <= raffle.raffleCount(); ++id) {
            Raffle.RaffleData memory r = raffle.getRaffle(id);
            if (r.prize.kind != Raffle.PrizeKind.Stock || r.state < Raffle.State.PrizeReady) continue;
            bool held = r.state != Raffle.State.Settled || raffle.prizeOwedTo(id) != address(0);
            if (!held) continue;
            if (r.prize.token == address(nvda)) nv += r.prize.amount;
            else ts += r.prize.amount;
        }
        assertEq(raffle.erc20PrizeEscrow(address(nvda)), nv);
        assertEq(raffle.erc20PrizeEscrow(address(tsla)), ts);
        assertEq(nvda.balanceOf(address(raffle)), nv, "every bought or owed prize is held");
        assertEq(tsla.balanceOf(address(raffle)), ts, "every bought or owed prize is held");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_noDrawWithoutAHeldPrize() public view {
        for (uint256 id = 1; id <= raffle.raffleCount(); ++id) {
            Raffle.RaffleData memory r = raffle.getRaffle(id);
            if (r.state < Raffle.State.PrizeReady) {
                assertEq(r.prize.amount, 0, "no prize recorded before it is held");
                assertEq(r.sequence, 0, "and no randomness requested");
                continue;
            }
            assertGt(r.prize.amount, 0, "a raffle at or past PrizeReady holds its prize");
            if (r.prize.kind == Raffle.PrizeKind.Usdc) {
                assertEq(r.prize.amount, uint256(r.base) * 1e6, "a USDC prize is exactly the budget");
                assertEq(r.prize.token, address(usdc));
            } else {
                assertEq(r.prize.token, r.stock, "a stock prize is the stock fixed at creation");
            }
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_drawIsHonest() public view {
        for (uint256 id = 1; id <= raffle.raffleCount(); ++id) {
            Raffle.RaffleData memory r = raffle.getRaffle(id);
            assertLe(r.sold, r.totalTickets);
            if (r.state >= Raffle.State.SoldOut) assertEq(r.sold, r.totalTickets);
            if (r.state >= Raffle.State.Drawn) {
                assertEq(r.winningTicket, uint64(uint256(r.randomNumber) % r.totalTickets));
            }
            if (r.state == Raffle.State.Settled) {
                assertEq(r.winner, raffle.buyerOf(id, r.winningTicket), "winner holds the winning ticket");
            }
        }
    }
}
