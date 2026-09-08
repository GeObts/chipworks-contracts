// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StockRegistryFixture} from "test/StockRegistry.t.sol";
import {StockRegistry} from "src/StockRegistry.sol";
import {Venue} from "src/interfaces/IStockRegistry.sol";
import {MockDepthQuoter, MockDepthPool} from "test/mocks/MockDepthQuoter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract StockRegistryDepthTest is StockRegistryFixture {
    function testFuzz_donationsCannotChangeDepthOrEnablement(uint96 donation, bool stockSide, bool slipstream) public {
        _addNvda(20_000e18);
        _fundNvdaPool();
        if (slipstream) {
            vm.prank(multisig);
            registry.setVenue(address(nvda), Venue.Slipstream, nvdaSlipPool, 0, TICK_100);
            nvdaPool = nvdaSlipPool;
            vm.etch(nvdaPool, address(new MockDepthPool()).code);
            MockDepthPool(nvdaPool).setLiquidity(1e18);
            quoter = new MockDepthQuoter(address(slipFactory));
            quoter.setQuote(address(nvda), 10_330.8e6, 1e8, 180e6);
            _configureDepth(address(nvda), 10_330.8e6);
        }
        uint256 beforeDepth = registry.poolLiquidityUsd(address(nvda));
        assertGt(beforeDepth, 0, "exercise a working quote, not a missing config");
        uint128 active = MockDepthPool(nvdaPool).liquidity();
        donation = uint96(bound(donation, 1, type(uint96).max));
        address donor = makeAddr("donor");
        if (stockSide) {
            uint256 beforeBalance = nvda.balanceOf(nvdaPool);
            nvda.mint(donor, donation);
            vm.prank(donor);
            nvda.transfer(nvdaPool, donation);
            assertEq(nvda.balanceOf(nvdaPool), beforeBalance + donation);
        } else {
            uint256 beforeBalance = usdc.balanceOf(nvdaPool);
            usdc.mint(donor, donation);
            vm.prank(donor);
            usdc.transfer(nvdaPool, donation);
            assertEq(usdc.balanceOf(nvdaPool), beforeBalance + donation);
        }
        assertEq(MockDepthPool(nvdaPool).liquidity(), active);
        assertEq(registry.poolLiquidityUsd(address(nvda)), beforeDepth);
        assertFalse(registry.clearsMinLiquidity(address(nvda)));
        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(
                StockRegistry.InsufficientLiquidity.selector, address(nvda), beforeDepth, uint256(20_000e18)
            )
        );
        registry.setEnabled(address(nvda), true);
        assertEq(quoter.lastTokenIn(), address(usdc));
        if (slipstream) assertEq(quoter.lastTickSpacing(), TICK_100);
        else assertEq(quoter.lastFee(), FEE_030);
    }

    function test_missingQuoteConfigCannotClearEvenZeroThreshold() public {
        _addNvda(0);
        usdc.mint(nvdaPool, 1_000_000e6);
        _assertClosed();
    }

    function test_zeroActiveLiquidityCannotClearEvenWithDonations() public {
        _addNvda(0);
        _fundNvdaPool();
        MockDepthPool(nvdaPool).setLiquidity(0);
        usdc.mint(nvdaPool, 1_000_000e6);
        _assertClosed();
    }

    function test_failedQuoteCannotClearZeroThreshold() public {
        _addNvda(0);
        _fundNvdaPool();
        quoter.setFail(true);
        _assertClosed();
    }

    function test_zeroOrOutOfBoundsQuoteFailsClosed() public {
        _addNvda(0);
        _fundNvdaPool();
        quoter.setQuote(address(nvda), 10_330.8e6, 0, 1);
        _assertClosed();
        quoter.setQuote(address(nvda), 10_330.8e6, 1e8, 360e6);
        _assertClosed();
        quoter.setQuote(address(nvda), 10_330.8e6, 1e8, 90e6);
        _assertClosed();
    }

    function test_staleFutureAndMissingTimestampsFailClosed() public {
        _addNvda(0);
        _fundNvdaPool();
        vm.warp(1_000_000);
        nvdaFeed.setStaleAnswer(180e8, block.timestamp - 120 hours - 1);
        _assertClosed();
        nvdaFeed.setStaleAnswer(180e8, block.timestamp + 1);
        _assertClosed();
        nvdaFeed.setStaleAnswer(180e8, 0);
        _assertClosed();
        nvdaFeed.setStaleAnswer(180e8, block.timestamp - 120 hours);
        assertTrue(registry.clearsMinLiquidity(address(nvda)), "freshness boundary includes last close");
    }

    function test_quoteOverflowFailsClosed() public {
        _addNvda(0);
        _fundNvdaPool();
        quoter.setQuote(address(nvda), 10_330.8e6, type(uint256).max, 10_330.8e6);
        _assertClosed();
    }

    function test_malformedAndGasExhaustingQuotersFailClosed() public {
        _addNvda(0);
        _fundNvdaPool();
        // Quoter was configured before replacing code to exercise the read failure boundary.
        vm.etch(address(quoter), hex"600160005360016000f3"); // one byte return
        _assertClosed();
        vm.etch(address(quoter), hex"5b600056"); // consume the subcall gas allowance
        _assertClosed();
    }

    function test_missingOrMalformedPoolStateFailsClosed() public {
        _addNvda(0);
        _fundNvdaPool();
        vm.etch(nvdaPool, hex"");
        _assertClosed();
        vm.etch(nvdaPool, hex"600160005360016000f3");
        _assertClosed();
    }

    function test_configurationOnlyOwnerAndMatchingFactory() public {
        _addNvda(0);
        vm.prank(randomer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, randomer));
        registry.setDepthConfig(address(nvda), address(quoter), 1e6, 200, 120 hours);
        MockDepthQuoter wrong = new MockDepthQuoter(address(slipFactory));
        vm.prank(multisig);
        vm.expectRevert(StockRegistry.InvalidDepthConfig.selector);
        registry.setDepthConfig(address(nvda), address(wrong), 1e6, 200, 120 hours);
    }

    function test_configurationRejectsUnsafeParameters() public {
        _addNvda(0);
        vm.startPrank(multisig);
        vm.expectRevert(StockRegistry.InvalidDepthConfig.selector);
        registry.setDepthConfig(address(nvda), address(quoter), 0, 200, 120 hours);
        vm.expectRevert(StockRegistry.InvalidDepthConfig.selector);
        registry.setDepthConfig(address(nvda), address(quoter), 1e6, 501, 120 hours);
        vm.expectRevert(StockRegistry.InvalidDepthConfig.selector);
        registry.setDepthConfig(address(nvda), address(quoter), 1e6, 200, 71 hours);
        vm.stopPrank();
    }

    function test_configurationChangeDisablesAndVenueChangeClearsConfiguration() public {
        _addNvda(0);
        _fundNvdaPool();
        vm.prank(multisig);
        registry.setEnabled(address(nvda), true);
        _configureDepth(address(nvda), 10_330.8e6);
        assertFalse(registry.isEnabled(address(nvda)));
        vm.prank(multisig);
        registry.setVenue(address(nvda), Venue.Slipstream, nvdaSlipPool, 0, TICK_100);
        (address configured,,,) = registry.depthConfig(address(nvda));
        assertEq(configured, address(0));
    }

    function test_reportQuotesEachStockOnlyOnce() public {
        _addNvda(0);
        _fundNvdaPool();
        uint256 beforeCalls = quoter.calls();
        registry.liquidityReport();
        assertEq(quoter.calls(), beforeCalls + 1);
    }

    function _assertClosed() internal {
        assertEq(registry.poolLiquidityUsd(address(nvda)), 0);
        assertFalse(registry.clearsMinLiquidity(address(nvda)));
        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(StockRegistry.InsufficientLiquidity.selector, address(nvda), uint256(0), uint256(0))
        );
        registry.setEnabled(address(nvda), true);
    }
}
