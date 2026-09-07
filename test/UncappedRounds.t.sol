// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChipRewardsBase} from "./ChipRewardsBase.t.sol";
import {ChipRounds} from "../src/ChipRounds.sol";
import {RoundState} from "../src/interfaces/IChipRounds.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3SwapRouter, ISlipstreamSwapRouter} from "../src/interfaces/ISwapRouters.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title UncappedRoundsTest
/// @notice What a round does now that there is no maximum budget.
///
/// @dev THE CAP WAS A BLAST RADIUS, NOT A SAFETY MECHANISM. `maxRoundBudget` existed so that
///      while the contracts were unreviewed a bug could only ever reach one capped round's
///      worth of value. The audit is complete, so it is gone. The floor stays, because it is
///      a different thing: it stops a round firing on dust.
///
///      THE POINT OF THIS SUITE IS THE THIN-POOL CASE. A bigger round means bigger per-stock
///      slices, and B20 pools on Base are small — most under $14k of measured depth. So the
///      question the cap removal actually raises is: what happens when a slice is larger than
///      its pool can fill at the Chainlink mark?
///
///      The answer, asserted below, is **all-or-nothing per stock**: the swap reverts inside
///      the router, `_buy` reports it did not execute, nothing moves, and the whole slice is
///      marked skipped and returned to the Pot at finalize. The round does not revert, no
///      funds are lost, and healthy stocks in the same round are unaffected.
///
///      It does NOT partially fill. A thin stock in a big round buys nothing rather than
///      buying what it safely could. That is the safe direction and it is a real limitation —
///      OPEN_ITEMS 26 carries it.
contract UncappedRoundsTest is ChipRewardsBase {
    ShallowPoolRouter internal shallow;

    /// @dev Wires a constant-product router in place of the fixed-rate mock, so output
    ///      degrades with size the way a real pool does. A fixed-rate mock cannot express
    ///      "too big for this pool" at all, which is why the existing suite never caught it.
    function _useShallowPool(address stock, uint256 quoteReserve, uint256 stockReserve) internal {
        shallow = new ShallowPoolRouter();
        shallow.setFactory(address(uniFactory));
        shallow.setReserves(address(usdc), stock, quoteReserve, stockReserve);
        MockERC20(stock).mint(address(shallow), stockReserve);

        vm.prank(multisig);
        rounds.setRouters(address(shallow), address(shallow));
    }

    /* ------------------------------------------------------------------ */
    /*                        NO CEILING, ONLY A FLOOR                      */
    /* ------------------------------------------------------------------ */

    /// @notice A pot far larger than the old $10k cap distributes in full.
    function test_aHugePotDistributesFullyAcrossStocksWithDepth() public {
        _fundPot(500_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _two(address(nvda), address(aapl)), _two(uint8(50), uint8(50)));

        uint256 id = _openAndAccumulate(_ids(1));
        assertEq(rounds.getRound(id).budget, 500_000e6, "no cap, the whole pot");

        rounds.settleStock(id, address(nvda));
        rounds.settleStock(id, address(aapl));
        rounds.finalizeRound(id);

        // Both halves bought and booked; nothing carried.
        assertGt(claims.claimable(id, address(nvda), alice), 0);
        assertGt(claims.claimable(id, address(aapl), alice), 0);
        assertEq(rounds.getRound(id).spent, 500_000e6, "spent to the last unit");
        assertEq(uint8(rounds.getRound(id).state), uint8(RoundState.Finalized));
    }

    /// @notice The floor is the only size gate left, and it still bites.
    function test_theFloorIsTheOnlyRemainingSizeGate() public {
        _fundPot(249e6);
        vm.expectRevert(abi.encodeWithSelector(ChipRounds.PotTooSmall.selector, uint256(249e6), uint256(MIN_POT)));
        rounds.openRound();

        _fundPot(1e6); // now 250e6, exactly the floor
        uint256 id = rounds.openRound();
        assertEq(rounds.getRound(id).budget, 250e6);
    }

    /// @notice There is no maximum to configure any more. The four-argument form is gone.
    function test_roundParamsNoLongerCarryAMaximum() public {
        vm.prank(multisig);
        rounds.setRoundParams(12 hours, 1 hours, 500e6);
        assertEq(rounds.roundDuration(), 12 hours);
        assertEq(rounds.minPotToOpen(), 500e6);
    }

    /* ------------------------------------------------------------------ */
    /*             THE THIN POOL, WHICH IS WHAT THE CAP WAS HIDING          */
    /* ------------------------------------------------------------------ */

    /// @notice A slice far larger than its pool: the stock is skipped, the round finalizes,
    ///         the money comes back to the Pot, and NOTHING IS LOST.
    function test_aSliceTooLargeForItsPoolCarriesAndTheRoundStillFinalizes() public {
        // A pool priced AT the $200 mark but only ~$4k deep: 2,000 USDC against 10 NVDA.
        // The round will try to spend 200,000 through it.
        _useShallowPool(address(nvda), 2_000e6, 10e8);

        _fundPot(200_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));

        uint256 potBefore = pot.available();
        uint256 id = _openAndAccumulate(_ids(1));

        // Does not revert. The stock is skipped with a reason.
        rounds.settleStock(id, address(nvda));
        assertTrue(rounds.stockSkipped(id, address(nvda)), "skipped, not reverted");
        assertEq(rounds.getRound(id).spent, 0, "nothing was spent");

        rounds.finalizeRound(id);
        assertEq(uint8(rounds.getRound(id).state), uint8(RoundState.Finalized), "the round completed");

        // Every wei came home. This is the property that matters most.
        assertEq(pot.available(), potBefore, "the whole budget returned to the Pot");
        assertEq(claims.claimable(id, address(nvda), alice), 0, "nothing credited");
        assertEq(IERC20(address(usdc)).balanceOf(address(rounds)), 0, "the engine holds nothing");
    }

    /// @notice The same round, with a healthy stock beside the thin one: the healthy half
    ///         fills, the thin half carries. One thin pool does not spoil the round.
    function test_aThinStockDoesNotStopAHealthyOneInTheSameRound() public {
        // A deep NVDA pool and a shallow AAPL pool, on the same router.
        shallow = new ShallowPoolRouter();
        shallow.setFactory(address(uniFactory));
        // Both priced at their marks. NVDA deep (~$10m), AAPL shallow (~$2k).
        shallow.setReserves(address(usdc), address(nvda), 5_000_000e6, 25_000e8);
        shallow.setReserves(address(usdc), address(aapl), 1_000e6, 4e8);
        nvda.mint(address(shallow), 25_000e8);
        aapl.mint(address(shallow), 4e8);
        vm.prank(multisig);
        rounds.setRouters(address(shallow), address(shallow));

        _fundPot(100_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _two(address(nvda), address(aapl)), _two(uint8(50), uint8(50)));

        uint256 id = _openAndAccumulate(_ids(1));
        rounds.settleStock(id, address(nvda));
        rounds.settleStock(id, address(aapl));
        rounds.finalizeRound(id);

        assertGt(claims.claimable(id, address(nvda), alice), 0, "the deep pool filled");
        assertTrue(rounds.stockSkipped(id, address(aapl)), "the thin pool carried");
        assertEq(claims.claimable(id, address(aapl), alice), 0);

        // Half spent, half returned. Nothing stranded.
        assertEq(rounds.getRound(id).spent, 50_000e6, "exactly the healthy half");
        assertEq(pot.available(), 50_000e6, "the other half is back in the Pot");
        assertEq(IERC20(address(usdc)).balanceOf(address(rounds)), 0);
    }

    /// @notice And the carried value is genuinely spendable again: the next round picks it
    ///         up. This is the whole of "carry to the next round".
    function test_theCarriedRemainderFundsTheNextRound() public {
        _useShallowPool(address(nvda), 2_000e6, 10e8);

        _fundPot(100_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));

        uint256 id = _openAndAccumulate(_ids(1));
        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);
        assertEq(pot.available(), 100_000e6, "carried in full");

        // Deepen the pool, run the next round, and the same money buys.
        shallow.setReserves(address(usdc), address(nvda), 20_000_000e6, 100_000e8);
        nvda.mint(address(shallow), 100_000e8);

        vm.warp(block.timestamp + 24 hours);
        uint256 id2 = _openAndAccumulate(_ids(1));
        assertEq(rounds.getRound(id2).budget, 100_000e6, "the carried money, uncapped");
        rounds.settleStock(id2, address(nvda));
        rounds.finalizeRound(id2);

        assertGt(claims.claimable(id2, address(nvda), alice), 0, "bought the second time round");
        assertEq(pot.available(), 0);
    }
}

/// @notice A constant-product router: output degrades with trade size, so a large buy against
///         small reserves under-delivers and trips the Chainlink-derived `amountOutMinimum`.
/// @dev The existing `MockSwapRouter` is a fixed-rate double — it fills any size at the same
///      price, so it cannot express "too big for this pool" and never could have caught this.
contract ShallowPoolRouter {
    address public factory;
    mapping(address => mapping(address => uint256)) public reserveIn;
    mapping(address => mapping(address => uint256)) public reserveOut;

    function setFactory(address f) external {
        factory = f;
    }

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

        // x*y=k, no fee. The bigger the trade against the reserve, the worse the fill.
        out = (amountIn * rOut) / (rIn + amountIn);
        require(out >= minOut, "Too little received");

        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        reserveIn[tokenIn][tokenOut] = rIn + amountIn;
        reserveOut[tokenIn][tokenOut] = rOut - out;
        IERC20(tokenOut).transfer(to, out);
    }
}
