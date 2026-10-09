// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Raffle} from "../../src/raffle/Raffle.sol";
import {Venue} from "../../src/interfaces/IStockRegistry.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockEntropyV2} from "../mocks/MockEntropyV2.sol";
import {MockStockRegistry} from "../mocks/MockStockRegistry.sol";
import {BlacklistToken} from "../mocks/HostileTokens.sol";

/// @notice Drives the raffle through random sequences: house creates, actors buy, Entropy reveals
///         (or stalls, or the fee spikes), anyone settles / claims / withdraws, and recipients get
///         blacklisted and un-blacklisted on both USDC and a prize token.
contract RaffleHandler is Test {
    Raffle public raffle;
    BlacklistToken public usdc;
    MockERC20 public nvda;
    BlacklistToken public blStock;
    MockEntropyV2 public entropy;
    address public house;
    address public pot;
    address[4] public actors;

    uint256 public constant MAX_RAFFLES = 8;
    uint256 public totalUsdcMinted;
    mapping(bytes4 => uint256) public calls;

    constructor(
        Raffle r,
        BlacklistToken u,
        MockERC20 n,
        BlacklistToken b,
        MockEntropyV2 e,
        address house_,
        address pot_,
        address[4] memory actors_
    ) {
        raffle = r;
        usdc = u;
        nvda = n;
        blStock = b;
        entropy = e;
        house = house_;
        pot = pot_;
        actors = actors_;
    }

    function _pick(uint256 seed) internal view returns (uint256 id, bool ok) {
        uint256 n = raffle.raffleCount();
        if (n == 0) return (0, false);
        return (bound(seed, 1, n), true);
    }

    function create(uint256 baseSeed, uint256 prizeSeed, bool useBlacklistable) external {
        if (raffle.raffleCount() >= MAX_RAFFLES) return;
        uint64 base = uint64(bound(baseSeed, 10, 60));
        uint256 amount = bound(prizeSeed, 1, 1e9);
        address token = useBlacklistable ? address(blStock) : address(nvda);
        if (useBlacklistable && blStock.blacklisted(house)) return; // the house can't fund it
        // Read the reserve BEFORE the prank: vm.prank binds to the very next call.
        uint256 reserve = raffle.requiredReserve();
        vm.deal(house, house.balance + reserve);
        vm.prank(house);
        raffle.createRaffle{value: reserve}(
            Raffle.Prize({kind: Raffle.PrizeKind.ERC20, token: token, amountOrId: amount}), base, house
        );
        calls[this.create.selector]++;
    }

    function buy(uint256 actorSeed, uint256 raffleSeed, uint256 qtySeed) external {
        (uint256 id, bool ok) = _pick(raffleSeed);
        if (!ok) return;
        Raffle.RaffleData memory r = raffle.getRaffle(id);
        if (r.state != Raffle.State.Open) return;
        address a = actors[actorSeed % 4];
        if (usdc.blacklisted(a)) return;
        uint64 qty = uint64(bound(qtySeed, 1, r.totalTickets - r.sold));
        vm.prank(a);
        raffle.buy(id, qty);
        calls[this.buy.selector]++;
    }

    function reveal(uint256 raffleSeed, bytes32 rnd) external {
        (uint256 id, bool ok) = _pick(raffleSeed);
        if (!ok) return;
        Raffle.RaffleData memory r = raffle.getRaffle(id);
        if (r.state != Raffle.State.Drawing) return;
        entropy.fulfill(r.sequence, rnd);
        calls[this.reveal.selector]++;
    }

    function feeSpikeAndRequest(uint256 raffleSeed, uint256 feeSeed) external {
        entropy.setFee(uint128(bound(feeSeed, 0.00001 ether, 0.0002 ether)));
        (uint256 id, bool ok) = _pick(raffleSeed);
        if (!ok) return;
        Raffle.RaffleData memory r = raffle.getRaffle(id);
        if (r.state != Raffle.State.SoldOut) return;
        uint256 fee = raffle.quoteDrawFee();
        uint256 topUp = fee > r.ethReserve ? fee - r.ethReserve : 0;
        vm.deal(address(this), topUp);
        raffle.requestDraw{value: topUp}(id);
        calls[this.feeSpikeAndRequest.selector]++;
    }

    function stallAndRetry(uint256 raffleSeed) external {
        (uint256 id, bool ok) = _pick(raffleSeed);
        if (!ok) return;
        Raffle.RaffleData memory r = raffle.getRaffle(id);
        if (r.state != Raffle.State.Drawing) return;
        vm.warp(block.timestamp + r.redrawTimeout); // the raffle's own snapshot
        uint256 fee = raffle.quoteDrawFee();
        uint256 topUp = fee > r.ethReserve ? fee - r.ethReserve : 0;
        vm.deal(house, house.balance + topUp);
        vm.prank(house); // owner and payee: retry is no longer permissionless
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

    function toggleBlacklist(uint256 who, bool onUsdc, bool value) external {
        address a = who % 6 == 4 ? house : who % 6 == 5 ? pot : actors[who % 4];
        if (onUsdc) usdc.setBlacklisted(a, value);
        else blStock.setBlacklisted(a, value);
        calls[this.toggleBlacklist.selector]++;
    }

    function claimPrize(uint256 raffleSeed) external {
        (uint256 id, bool ok) = _pick(raffleSeed);
        if (!ok) return;
        address w = raffle.prizeOwedTo(id);
        if (w == address(0)) return;
        Raffle.RaffleData memory r = raffle.getRaffle(id);
        if (r.prize.token == address(blStock) && blStock.blacklisted(w)) return;
        raffle.claimPrize(id);
        calls[this.claimPrize.selector]++;
    }

    function withdraw(uint256 who) external {
        address a = who % 6 == 4 ? house : who % 6 == 5 ? pot : actors[who % 4];
        if (raffle.usdcOwed(a) != 0 && !usdc.blacklisted(a)) raffle.withdrawUsdc(a);
        if (raffle.ethOwed(a) != 0) raffle.withdrawEth(a);
        calls[this.withdraw.selector]++;
    }

    receive() external payable {}
}

contract RaffleInvariantTest is Test {
    Raffle internal raffle;
    BlacklistToken internal usdc;
    MockERC20 internal nvda;
    BlacklistToken internal blStock;
    MockEntropyV2 internal entropy;
    MockStockRegistry internal registry;
    RaffleHandler internal handler;

    address internal house = makeAddr("house");
    address internal pot = makeAddr("pot");
    address[4] internal actors;
    uint256 internal constant PER_ACTOR = 1_000_000e6;

    function setUp() public {
        usdc = new BlacklistToken("USD Coin", "USDC", 6);
        nvda = new MockERC20("NVIDIA", "NVDAc", 8);
        blStock = new BlacklistToken("Blacklistable B20", "B20", 8);
        registry = new MockStockRegistry(address(usdc));
        registry.setStock(address(nvda), Venue.Slipstream, 0, 10, 8, true);
        registry.setStock(address(blStock), Venue.Slipstream, 0, 10, 8, true);
        entropy = new MockEntropyV2();
        entropy.setFee(0.00002 ether);
        raffle = new Raffle(house, address(usdc), address(entropy), address(registry), pot, 1 hours);

        actors = [makeAddr("a0"), makeAddr("a1"), makeAddr("a2"), makeAddr("a3")];
        for (uint256 i; i < 4; ++i) {
            usdc.mint(actors[i], PER_ACTOR);
            vm.prank(actors[i]);
            usdc.approve(address(raffle), type(uint256).max);
        }
        nvda.mint(house, 1e18);
        blStock.mint(house, 1e18);
        vm.deal(house, 100 ether);
        vm.startPrank(house);
        nvda.approve(address(raffle), type(uint256).max);
        blStock.approve(address(raffle), type(uint256).max);
        vm.stopPrank();

        handler = new RaffleHandler(raffle, usdc, nvda, blStock, entropy, house, pot, actors);
        targetContract(address(handler));
    }

    function _everyone() internal view returns (address[6] memory e) {
        e = [actors[0], actors[1], actors[2], actors[3], house, pot];
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_usdcAlwaysBalances() public view {
        uint256 expected;
        for (uint256 id = 1; id <= raffle.raffleCount(); ++id) {
            Raffle.RaffleData memory r = raffle.getRaffle(id);
            if (r.state != Raffle.State.Settled) expected += uint256(r.sold) * 1e6;
        }
        address[6] memory e = _everyone();
        for (uint256 i; i < 6; ++i) expected += raffle.usdcOwed(e[i]);
        assertEq(raffle.usdcLiability(), expected, "liability == unsettled ticket money + credits");
        assertEq(usdc.balanceOf(address(raffle)), expected, "USDC held == owed, to the unit");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_usdcConserved() public view {
        uint256 sum = usdc.balanceOf(address(raffle)) + usdc.balanceOf(house) + usdc.balanceOf(pot);
        for (uint256 i; i < 4; ++i) sum += usdc.balanceOf(actors[i]);
        assertEq(sum, 4 * PER_ACTOR, "no USDC created or lost");
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
        uint256 bl;
        for (uint256 id = 1; id <= raffle.raffleCount(); ++id) {
            Raffle.RaffleData memory r = raffle.getRaffle(id);
            bool held = r.state != Raffle.State.Settled || raffle.prizeOwedTo(id) != address(0);
            if (!held) continue;
            if (r.prize.token == address(nvda)) nv += r.prize.amountOrId;
            else bl += r.prize.amountOrId;
        }
        assertEq(raffle.erc20PrizeEscrow(address(nvda)), nv);
        assertEq(raffle.erc20PrizeEscrow(address(blStock)), bl);
        assertEq(nvda.balanceOf(address(raffle)), nv, "every escrowed or owed prize is held");
        assertEq(blStock.balanceOf(address(raffle)), bl, "every escrowed or owed prize is held");
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
