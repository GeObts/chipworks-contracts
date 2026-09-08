// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChipRewardsBase} from "test/ChipRewardsBase.t.sol";
import {MockDepthQuoter, MockDepthPool} from "test/mocks/MockDepthQuoter.sol";
import {ChipRounds} from "src/ChipRounds.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract ChipRoundsDonationTest is ChipRewardsBase {
    function test_underfundedProbeCannotMarkAHealthyStockSkipped() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        uint256 id = _openAndAccumulate(_ids(1));
        (bool ok, bytes memory reason) =
            address(rounds).call{gas: 500_000}(abi.encodeCall(ChipRounds.settleStock, (id, address(nvda))));
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(ChipRounds.InsufficientDepthGas.selector));
        assertFalse(rounds.stockSettled(id, address(nvda)));
        assertFalse(rounds.stockSkipped(id, address(nvda)));
        assertEq(rounds.committedQuote(), 1_000e6);
        rounds.settleStock(id, address(nvda));
        assertEq(rounds.getRound(id).spent, 1_000e6);
    }

    function testFuzz_donationCannotRaiseSpendCeiling(uint96 donation, bool stockSide) public {
        address pool = registry.getStock(address(nvda)).pool;
        uint256 beforeCap = rounds.maxSpendFor(address(nvda));
        assertGt(beforeCap, 0);
        // Set the cap wide enough that a balance-based ceiling would visibly increase.
        vm.prank(multisig);
        rounds.setMaxRoundBudget(type(uint128).max);
        beforeCap = rounds.maxSpendFor(address(nvda));
        uint128 active = MockDepthPool(pool).liquidity();
        donation = uint96(bound(donation, 1_000_000e6, type(uint96).max));
        address donor = makeAddr("donor");
        if (stockSide) {
            nvda.mint(donor, donation);
            vm.prank(donor);
            nvda.transfer(pool, donation);
        } else {
            usdc.mint(donor, donation);
            vm.prank(donor);
            usdc.transfer(pool, donation);
        }
        assertEq(MockDepthPool(pool).liquidity(), active);
        assertEq(rounds.maxSpendFor(address(nvda)), beforeCap);
    }

    function test_quoteFailureSkipsOnlyItsStockAndCarriesCommittedQuote() public {
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _chip(basedNouns, basedVault, 2, bob, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        _setSplit(address(basedNouns), 2, bob, _one(address(googl)), _one(uint8(100)));
        uint256 id = _openAndAccumulate(_ids(1, 2));
        (address q,,,) = registry.depthConfig(address(nvda));
        MockDepthQuoter(q).setQuote(address(nvda), 0, 0, 1);
        usdc.mint(registry.getStock(address(nvda)).pool, 1_000_000e6);
        uint256 committed = rounds.committedQuote();
        rounds.settleStock(id, address(nvda));
        assertTrue(rounds.stockSkipped(id, address(nvda)));
        assertEq(rounds.committedQuote(), committed);
        assertEq(rounds.getRound(id).spent, 0);
        rounds.settleStock(id, address(googl));
        assertFalse(rounds.stockSkipped(id, address(googl)));
        assertEq(rounds.getRound(id).spent, 500e6);
        rounds.finalizeRound(id);
        assertEq(rounds.committedQuote(), 0);
        assertEq(pot.available(), 500e6);
    }

    function test_roundAndStockCapsBoundValidQuotes() public {
        assertEq(rounds.maxSpendFor(address(nvda)), 10_000e6);
        vm.startPrank(multisig);
        rounds.setMaxStockSpend(address(nvda), 100e6);
        rounds.setDefaultMaxImpactBps(500);
        vm.stopPrank();
        assertEq(rounds.maxSpendFor(address(nvda)), 100e6);
        _fundPot(1_000e6);
        _chip(basedNouns, basedVault, 1, alice, 0);
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        uint256 id = _openAndAccumulate(_ids(1));
        rounds.settleStock(id, address(nvda));
        assertEq(rounds.getRound(id).spent, 100e6);
        assertEq(rounds.committedQuote(), 900e6);
        rounds.finalizeRound(id);
        assertEq(pot.available(), 900e6);
    }

    function test_capGovernanceRejectsUnauthorizedAndZeroRoundCap() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        rounds.setMaxRoundBudget(1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        rounds.setMaxStockSpend(address(nvda), 1);
        vm.prank(multisig);
        vm.expectRevert(ChipRounds.BadConfig.selector);
        rounds.setMaxRoundBudget(0);
    }
}
