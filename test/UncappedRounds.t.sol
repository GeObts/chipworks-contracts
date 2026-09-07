// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChipRewardsBase} from "./ChipRewardsBase.t.sol";
import {ChipRounds} from "../src/ChipRounds.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3SwapRouter, ISlipstreamSwapRouter} from "../src/interfaces/ISwapRouters.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title UncappedRoundsTest
/// @notice The depth-aware impact trim, and the round cap coming off on top of it.
///
/// @dev WHY THESE TWO CHANGES BELONG IN ONE SUITE. `maxRoundBudget` was not caution — it was
///      the mitigation two accepted findings named. EXT-R-L-1 and SEC-POT-002 were both
///      accepted on the written condition that *"the round cap does not go above $10,000
///      until dynamic slippage or private routing is in place"*, because `maxSlippageBps` is
///      a FIXED 2%: a sandwicher's take is bounded by it and grows linearly with the slice,
///      while the defence does not move at all. Removing the cap without replacing that is
///      what would have reopened both findings.
///
///      `maxImpactBps` is the replacement, and it is a different KIND of bound. It sizes each
///      buy from `poolLiquidityUsd` — the same measured depth the registry's enable-gate
///      already uses — so exposure per buy is a function of the POOL, not of the round.
///      Doubling the round no longer doubles what is extractable from any one stock; it
///      spreads the same bounded buys over more rounds. That is what lets the cap go.
///
///      THE BEHAVIOUR CHANGE IS THE POINT. Before the trim, a slice too large for its pool
///      bought NOTHING — the router refused the whole thing on `amountOutMinimum` and the
///      entire slice carried. Now it buys up to the safe size and carries only the remainder,
///      so thin names distribute instead of being skipped.
contract UncappedRoundsTest is ChipRewardsBase {
    ShallowPoolRouter internal shallow;

    /// @dev Points BOTH the router and the registry's measured depth at the same reserves, so
    ///      the trim and the fill model one pool rather than disagreeing about it. Wiring only
    ///      the router — as the first draft of this suite did — leaves the trim reading the
    ///      deep default depth and sizing a buy the shallow router then refuses, which tests
    ///      nothing.
    function _useShallowPool(address stock, uint256 quoteReserve, uint256 stockReserve) internal {
        if (address(shallow) == address(0)) {
            shallow = new ShallowPoolRouter();
            vm.prank(multisig);
            rounds.setRouters(address(shallow), address(shallow));
        }
        shallow.setReserves(address(usdc), stock, quoteReserve, stockReserve);
        MockERC20(stock).mint(address(shallow), stockReserve);

        address pool = registry.getStock(stock).pool;
        deal(address(usdc), pool, quoteReserve);
        deal(stock, pool, stockReserve);
    }

    /* ------------------------------------------------------------------ */
    /*                        NO CEILING, ONLY A FLOOR                      */
    /* ------------------------------------------------------------------ */

    function test_openRoundTakesTheWholePotWithNoCap() public {
        _fundPot(500_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        uint256 id = _openAndAccumulate(_ids(1));
        assertEq(rounds.getRound(id).budget, 500_000e6, "no cap, the whole pot");
        assertEq(pot.available(), 0, "nothing held back");
    }

    function test_theFloorIsTheOnlyRemainingSizeGate() public {
        _fundPot(249e6);
        vm.expectRevert(abi.encodeWithSelector(ChipRounds.PotTooSmall.selector, uint256(249e6), uint256(MIN_POT)));
        rounds.openRound();

        _fundPot(1e6); // now exactly the floor
        uint256 id = rounds.openRound();
        assertEq(rounds.getRound(id).budget, 250e6);
    }

    function test_roundParamsNoLongerCarryAMaximum() public {
        vm.prank(multisig);
        rounds.setRoundParams(12 hours, 1 hours, 500e6);
        assertEq(rounds.roundDuration(), 12 hours);
        assertEq(rounds.minPotToOpen(), 500e6);
    }

    /* ------------------------------------------------------------------ */
    /*                            THE TRIM ITSELF                           */
    /* ------------------------------------------------------------------ */

    /// @notice THE HEADLINE. A slice far larger than its pool now BUYS what is safe and
    ///         carries the rest, where before the trim it bought nothing at all.
    function test_aSliceTooLargeForItsPoolFillsToTheLimitAndCarriesTheRest() public {
        _useShallowPool(address(nvda), 2_000e6, 10e8); // ~$4,000 at the $200 mark
        uint256 ceiling = rounds.maxSpendFor(address(nvda));
        assertGt(ceiling, 0, "depth is measurable");
        assertLt(ceiling, 200_000e6, "and far below the slice");

        _fundPot(200_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        uint256 id = _openAndAccumulate(_ids(1));

        rounds.settleStock(id, address(nvda));

        assertFalse(rounds.stockSkipped(id, address(nvda)), "it BOUGHT, it did not skip");
        assertEq(rounds.getRound(id).spent, ceiling, "spent exactly the safe amount");
        assertGt(claims.claimable(id, address(nvda), alice), 0, "holders were paid");

        rounds.finalizeRound(id);
        assertEq(pot.available(), 200_000e6 - ceiling, "the remainder carried to the Pot");
        assertEq(IERC20(address(usdc)).balanceOf(address(rounds)), 0, "the engine holds nothing");
    }

    /// @notice The bound is a function of the POOL, not of the round. This is the property
    ///         that replaces the cap: a round ten times bigger does not put ten times more
    ///         through any single stock, so extractable value does not scale with the pot.
    function test_theSpendCeilingDoesNotMoveWhenTheRoundGetsBigger() public {
        _useShallowPool(address(nvda), 2_000e6, 10e8);
        uint256 ceiling = rounds.maxSpendFor(address(nvda));

        _fundPot(50_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        uint256 small = _openAndAccumulate(_ids(1));
        rounds.settleStock(small, address(nvda));
        rounds.finalizeRound(small);

        assertEq(rounds.getRound(small).spent, ceiling, "the small round was already at the ceiling");

        // A buy at the bound leaves the pool richer than the mark. In the real market
        // arbitrage closes that within the day between rounds; here it is done explicitly,
        // because otherwise this test measures drift rather than the ceiling.
        _useShallowPool(address(nvda), 2_000e6, 10e8);

        vm.warp(block.timestamp + 24 hours);
        _fundPot(500_000e6);
        uint256 big = _openAndAccumulate(_ids(1));
        rounds.settleStock(big, address(nvda));
        rounds.finalizeRound(big);

        // A 10x round bought about the same amount of this stock — the pool moved slightly,
        // so the ceiling moved slightly, but it did not scale with the pot.
        assertApproxEqRel(rounds.getRound(big).spent, ceiling, 0.05e18, "a 10x round, the same buy");
    }

    /// @notice Depth that cannot be read is not "unlimited". A pool with nothing measurable in
    ///         it refuses the buy rather than sizing it from a zero.
    function test_unreadableDepthFailsClosed() public {
        address pool = registry.getStock(address(nvda)).pool;
        deal(address(usdc), pool, 0);
        deal(address(nvda), pool, 0);
        assertEq(rounds.maxSpendFor(address(nvda)), 0);

        _fundPot(10_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        uint256 id = _openAndAccumulate(_ids(1));

        rounds.settleStock(id, address(nvda));
        assertTrue(rounds.stockSkipped(id, address(nvda)), "no depth, no buy");
        assertEq(rounds.getRound(id).spent, 0);

        rounds.finalizeRound(id);
        assertEq(pot.available(), 10_000e6, "and every wei came home");
    }

    /// @notice The bound is per stock, and ceilinged so it cannot be widened into
    ///         meaninglessness by a compromised multisig.
    function test_theImpactBoundIsPerStockAndCeilinged() public {
        assertEq(rounds.maxImpactBps(address(nvda)), rounds.defaultMaxImpactBps());

        vm.prank(multisig);
        rounds.setMaxImpactBps(address(nvda), 200);
        assertEq(rounds.maxImpactBps(address(nvda)), 200);
        assertEq(rounds.maxImpactBps(address(googl)), rounds.defaultMaxImpactBps(), "others untouched");

        // Hoisted: reading the constant inside the call would consume the prank.
        uint32 tooWide = rounds.MAX_IMPACT_CEILING_BPS() + 1;
        vm.prank(multisig);
        vm.expectRevert(ChipRounds.BadConfig.selector);
        rounds.setMaxImpactBps(address(nvda), tooWide);

        vm.prank(multisig);
        vm.expectRevert(ChipRounds.BadConfig.selector);
        rounds.setDefaultMaxImpactBps(0);
    }

    /* ------------------------------------------------------------------ */
    /*             THE SCENARIO THE BRIEF ASKED TO BE PROVEN                */
    /* ------------------------------------------------------------------ */

    /// @notice A $500k round against real measured B20 depth buys each name up to its own
    ///         limit, carries the rest, and distributes across everything with depth instead
    ///         of skipping.
    ///
    /// @dev The depths are the ones actually measured on Base in ASSUMPTIONS A-22: GOOGL
    ///      ~$130k, SPCX ~$41k, and a thin name. GOOGL and AAPL stand in for the two deepest;
    ///      NVDA is the thin one.
    function test_aHalfMillionRoundAgainstRealB20Depth() public {
        _useShallowPool(address(googl), 65_000e6, 162.5e8); // ~$130k, spot exactly $400
        _useShallowPool(address(aapl), 20_500e6, 82e8); // ~$41k, spot exactly $250
        _useShallowPool(address(nvda), 700e6, 3.5e8); // ~$1.4k, spot exactly $200

        uint256 gCap = rounds.maxSpendFor(address(googl));
        uint256 aCap = rounds.maxSpendFor(address(aapl));
        uint256 nCap = rounds.maxSpendFor(address(nvda));
        emit log_named_uint("GOOGL ceiling, USDC", gCap / 1e6);
        emit log_named_uint("AAPL  ceiling, USDC", aCap / 1e6);
        emit log_named_uint("NVDA  ceiling, USDC", nCap / 1e6);

        _fundPot(500_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(
            address(basedNouns),
            1,
            alice,
            _threeAddrs(address(googl), address(aapl), address(nvda)),
            _threePct(34, 33, 33)
        );

        uint256 id = _openAndAccumulate(_ids(1));
        rounds.settleStock(id, address(googl));
        rounds.settleStock(id, address(aapl));
        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);

        // Every name with depth bought something. None was skipped.
        assertFalse(rounds.stockSkipped(id, address(googl)), "GOOGL filled");
        assertFalse(rounds.stockSkipped(id, address(aapl)), "AAPL filled");
        assertFalse(rounds.stockSkipped(id, address(nvda)), "even the thin name filled");
        assertGt(claims.claimable(id, address(googl), alice), 0);
        assertGt(claims.claimable(id, address(aapl), alice), 0);
        assertGt(claims.claimable(id, address(nvda), alice), 0);

        // Each spent its own ceiling, and the rest went home.
        assertEq(rounds.getRound(id).spent, gCap + aCap + nCap, "each at its own limit");
        assertEq(pot.available(), 500_000e6 - (gCap + aCap + nCap), "the remainder carried");
        assertEq(IERC20(address(usdc)).balanceOf(address(rounds)), 0, "nothing stranded");
    }

    /// @notice And the carried remainder genuinely funds the next round.
    function test_theCarriedRemainderFundsTheNextRound() public {
        _useShallowPool(address(nvda), 2_000e6, 10e8);

        _fundPot(100_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));

        uint256 id = _openAndAccumulate(_ids(1));
        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);
        uint256 carried = pot.available();
        assertGt(carried, 99_000e6, "nearly all of it carried");

        _useShallowPool(address(nvda), 2_000e6, 10e8); // arbitrage restores the peg
        vm.warp(block.timestamp + 24 hours);
        uint256 id2 = _openAndAccumulate(_ids(1));
        assertEq(rounds.getRound(id2).budget, carried, "the carried money, uncapped");
        rounds.settleStock(id2, address(nvda));
        rounds.finalizeRound(id2);
        assertGt(claims.claimable(id2, address(nvda), alice), 0, "and bought again");
    }

    /// @notice A deep pool is not trimmed at all: the whole slice fills, so the trim is a
    ///         bound and not a tax.
    function test_aDeepPoolIsNotTrimmed() public {
        _fundPot(20_000e6); // the default fixture pools are ~$10m a pair
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));

        uint256 id = _openAndAccumulate(_ids(1));
        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);

        assertEq(rounds.getRound(id).spent, 20_000e6, "spent to the last unit");
        assertEq(pot.available(), 0, "nothing carried");
    }

    function _threeAddrs(address a, address b, address c) internal pure returns (address[] memory o) {
        o = new address[](3);
        (o[0], o[1], o[2]) = (a, b, c);
    }

    function _threePct(uint8 a, uint8 b, uint8 c) internal pure returns (uint8[] memory o) {
        o = new uint8[](3);
        (o[0], o[1], o[2]) = (a, b, c);
    }
}

/// @notice A constant-product router: output degrades with trade size, so a large buy against
///         small reserves under-delivers and trips the Chainlink-derived `amountOutMinimum`.
/// @dev The stock `MockSwapRouter` is a fixed-rate double — it fills any size at the same
///      price, so it cannot express "too big for this pool" and could never have caught this.
contract ShallowPoolRouter {
    mapping(address => mapping(address => uint256)) public reserveIn;
    mapping(address => mapping(address => uint256)) public reserveOut;

    function setReserves(address tokenIn, address tokenOut, uint256 rIn, uint256 rOut) external {
        reserveIn[tokenIn][tokenOut] = rIn;
        reserveOut[tokenIn][tokenOut] = rOut;
    }

    function exactInputSingle(IUniswapV3SwapRouter.ExactInputSingleParams calldata p) external returns (uint256) {
        return _swap(p.tokenIn, p.tokenOut, p.recipient, p.amountIn, p.amountOutMinimum);
    }

    function exactInputSingle(ISlipstreamSwapRouter.ExactInputSingleParams calldata p) external returns (uint256) {
        return _swap(p.tokenIn, p.tokenOut, p.recipient, p.amountIn, p.amountOutMinimum);
    }

    function _swap(address tokenIn, address tokenOut, address to, uint256 amountIn, uint256 minOut)
        internal
        returns (uint256 out)
    {
        uint256 rIn = reserveIn[tokenIn][tokenOut];
        uint256 rOut = reserveOut[tokenIn][tokenOut];
        require(rIn != 0 && rOut != 0, "no pool");

        out = (amountIn * rOut) / (rIn + amountIn); // x*y=k, no fee
        require(out >= minOut, "Too little received");

        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        reserveIn[tokenIn][tokenOut] = rIn + amountIn;
        reserveOut[tokenIn][tokenOut] = rOut - out;
        IERC20(tokenOut).transfer(to, out);
    }
}
