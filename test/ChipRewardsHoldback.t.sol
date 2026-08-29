// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChipRewardsBase} from "./ChipRewardsBase.t.sol";
import {ChipRounds} from "../src/ChipRounds.sol";
import {ChipClaims} from "../src/ChipClaims.sol";
import {Round, RoundState} from "../src/interfaces/IChipRounds.sol";
import {LyingToken} from "./mocks/HostileTokens.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {StockRegistry} from "../src/StockRegistry.sol";
import {Venue} from "../src/interfaces/IStockRegistry.sol";

/// @notice Spec section 6: each round holds back a share of purchased stock for POL.
contract ChipRewardsHoldbackTest is ChipRewardsBase {
    function _round() internal returns (uint256 id) {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        id = _openAndAccumulate(_ids(1));
        rounds.settleStock(id, address(nvda));
        rounds.finalizeRound(id);
    }

    function test_holdbackDefaultsToZero() public {
        assertEq(rounds.holdbackBps(), 0);
        uint256 id = _round();
        assertEq(claims.acquired(id, address(nvda)), 5e8, "all credited when holdback is off");
        assertEq(nvda.balanceOf(polTreasury), 0);
    }

    function test_fifteenPercentGoesToPol() public {
        vm.prank(multisig);
        rounds.setHoldbackBps(1_500);

        uint256 id = _round();

        // 5 NVDA bought: 0.75 to POL, 4.25 credited.
        assertEq(nvda.balanceOf(polTreasury), 0.75e8, "15% held back");
        assertEq(claims.acquired(id, address(nvda)), 4.25e8);
        assertEq(claims.totalOwed(address(nvda)), 4.25e8);
        assertEq(claims.claimable(id, address(nvda), alice), 4.25e8);

        vm.prank(alice);
        assertEq(claims.claim(id, address(nvda)), 4.25e8);
    }

    /// @notice Spec allows 0-25%. The ceiling is immutable so the multisig can never
    ///         redirect an arbitrary share of every round away from holders.
    function test_holdbackIsCappedAtTwentyFivePercent() public {
        vm.prank(multisig);
        rounds.setHoldbackBps(2_500); // allowed

        vm.prank(multisig);
        vm.expectRevert(ChipRounds.BadConfig.selector);
        rounds.setHoldbackBps(2_501);
    }

    function test_holdbackOnlyMultisig() public {
        vm.prank(alice);
        vm.expectRevert();
        rounds.setHoldbackBps(1_000);
    }

    /// @notice Solvency must hold exactly: whatever is not held back is credited, and the
    ///         contract holds precisely what it owes.
    function test_contractHoldsExactlyWhatItOwesAfterHoldback() public {
        vm.prank(multisig);
        rounds.setHoldbackBps(1_500);
        uint256 id = _round();

        assertEq(nvda.balanceOf(address(claims)), claims.totalOwed(address(nvda)), "solvent");
        assertEq(nvda.balanceOf(address(claims)) + nvda.balanceOf(polTreasury), 5e8, "nothing created or destroyed");
        id;
    }

    /// @notice If the POL treasury cannot receive (frozen, policy-blocked), the round must
    ///         still complete and holders must be credited MORE, never left short.
    function test_polTreasuryUnableToReceiveCreditsHoldersInstead() public {
        vm.prank(multisig);
        rounds.setHoldbackBps(1_500);

        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(aapl)), _one(uint8(100)));

        aapl.setBlacklisted(polTreasury, true); // POL cannot receive AAPL

        uint256 id = _openAndAccumulate(_ids(1));
        rounds.settleStock(id, address(aapl)); // must not revert
        rounds.finalizeRound(id);

        assertEq(aapl.balanceOf(polTreasury), 0, "holdback could not be delivered");
        assertEq(claims.acquired(id, address(aapl)), 4e8, "holders credited the full 4 AAPL");
        assertEq(aapl.balanceOf(address(claims)), claims.totalOwed(address(aapl)), "still solvent");

        vm.prank(alice);
        assertEq(claims.claim(id, address(aapl)), 4e8);
    }

    /// @notice A token that REPORTS a successful transfer while moving nothing takes a
    ///         different path from one that reverts: the call succeeds, so a naive
    ///         implementation would deduct a holdback that never left. Measuring the
    ///         balance delta is what makes the credit correct either way.
    function test_holdbackIsMeasuredByDeltaNotByReturnValue() public {
        LyingToken liar = new LyingToken("Liar", "LIEc", 8);
        MockAggregatorV3 liarFeed = new MockAggregatorV3(8, int256(100 * 1e8), "LIEc / USD");
        address pool = address(uint160(2000));
        uniFactory.setPool(address(liar), address(usdc), FEE, pool);

        vm.startPrank(multisig);
        registry.addStock(
            StockRegistry.AddStockParams({
                token: address(liar),
                feed: address(liarFeed),
                venue: Venue.UniswapV3,
                pool: pool,
                fee: FEE,
                tickSpacing: 0,
                minLiquidityUsd: 0,
                tokenDecimals: 8
            })
        );
        registry.setEnabled(address(liar), true);
        rounds.setHoldbackBps(1_500);
        vm.stopPrank();

        router.setRate(address(usdc), address(liar), 1e8, 100 * 1e6);
        liar.mint(address(router), 1_000_000e8);

        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(liar)), _one(uint8(100)));

        uint256 id = _openAndAccumulate(_ids(1));

        // From here the token starts lying: transfers report success and move nothing.
        liar.setLying(true);
        rounds.settleStock(id, address(liar));
        rounds.finalizeRound(id);

        // The swap consumed the USDC and delivered nothing. That is a real loss, and the
        // accounting must say so: zero credited, budget recorded as spent, and the round
        // still finalizable. Recording it as a "skip" is what previously left the contract
        // claiming to hold quote token it no longer had.
        assertEq(liar.balanceOf(polTreasury), 0, "holdback never actually moved");
        assertEq(claims.acquired(id, address(liar)), 0, "nothing arrived, nothing credited");
        assertEq(claims.totalOwed(address(liar)), 0);
        assertEq(rounds.getRound(id).spent, 1_000e6, "the USDC really did leave");
        assertEq(usdc.balanceOf(address(claims)), claims.totalOwed(address(usdc)), "quote accounting still consistent");
        assertEq(rounds.committedQuote(), 0, "commitment released to match reality");
    }
}
