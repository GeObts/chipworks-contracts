// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StockRegistry} from "src/StockRegistry.sol";
import {ChipRounds} from "src/ChipRounds.sol";
import {Venue} from "src/interfaces/IStockRegistry.sol";
import {ISlipstreamFactory} from "src/interfaces/IAmmFactories.sol";
import {IUniswapV3QuoterV2, ISlipstreamQuoterV2} from "src/interfaces/IVenueQuoters.sol";

/// @dev Real WETH/USDC concentrated pools and canonical deployed quoters on Base.
///      No pool, token, feed, or quoter code is mocked. Run serially with BASE_RPC_URL.
contract StockRegistryDonationForkTest is Test {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant UNI_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address internal constant SLIP_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
    address internal constant UNI_QUOTER = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a;
    address internal constant SLIP_QUOTER = 0x254cF9E1E6e233aa1AC962CB9B05b2cfeAaE15b0;
    uint128 internal constant PROBE = 100e6;

    StockRegistry internal registry;
    ChipRounds internal rounds;
    address internal multisig = makeAddr("multisig");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        registry = new StockRegistry(multisig, USDC, UNI_FACTORY, SLIP_FACTORY);
        rounds = new ChipRounds(multisig, address(registry), address(1), address(2), address(3), 0, address(4));
        console2.log("Donation fork block", block.number);
    }

    function test_uniswapQuoteTokenDonation() public {
        _donate(false, false);
    }

    function test_uniswapStockTokenDonation() public {
        _donate(false, true);
    }

    function test_slipstreamQuoteTokenDonation() public {
        _donate(true, false);
    }

    function test_slipstreamStockTokenDonation() public {
        _donate(true, true);
    }

    function _donate(bool slip, bool stockSide) internal {
        address pool = slip
            ? ISlipstreamFactory(SLIP_FACTORY).getPool(WETH, USDC, 100)
            : 0xd0b53D9277642d899DF5C87A3966A349A798F224;
        assertTrue(pool != address(0), "real venue pool required");
        vm.startPrank(multisig);
        registry.addStock(
            StockRegistry.AddStockParams({
                token: WETH,
                feed: FEED,
                venue: slip ? Venue.Slipstream : Venue.UniswapV3,
                pool: pool,
                fee: slip ? 0 : 500,
                tickSpacing: slip ? int24(100) : int24(0),
                minLiquidityUsd: 101e18,
                tokenDecimals: 18
            })
        );
        registry.setDepthConfig(WETH, slip ? SLIP_QUOTER : UNI_QUOTER, PROBE, 500, 120 hours);
        vm.stopPrank();

        bytes32 stateBefore = _state(pool);
        uint256 quotedBefore = _quote(slip);
        assertGt(quotedBefore, 0, "must exercise an executable canonical quote");
        uint256 depthBefore = registry.poolLiquidityUsd(WETH);
        assertEq(depthBefore, 100e18, "finite probe clears its Chainlink bound");
        assertFalse(registry.clearsMinLiquidity(WETH));
        assertEq(rounds.maxSpendFor(WETH), 250_000, "25 bps of the $100 probe in USDC units");

        address donated = stockSide ? WETH : USDC;
        uint256 donation = stockSide ? 1_000 ether : 1_000_000e6;
        address donor = makeAddr("donor");
        deal(donated, donor, donation);
        uint256 balanceBefore = IERC20(donated).balanceOf(pool);
        vm.prank(donor);
        assertTrue(IERC20(donated).transfer(pool, donation));
        assertEq(IERC20(donated).balanceOf(pool), balanceBefore + donation);
        assertEq(_state(pool), stateBefore, "liquidity and slot0 unchanged");
        assertEq(_quote(slip), quotedBefore, "actual output quote unchanged, not just capped metric");
        assertEq(registry.poolLiquidityUsd(WETH), depthBefore);
        assertEq(rounds.maxSpendFor(WETH), 250_000, "donations cannot raise the production ceiling");
        assertFalse(registry.clearsMinLiquidity(WETH));
        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(StockRegistry.InsufficientLiquidity.selector, WETH, depthBefore, uint256(101e18))
        );
        registry.setEnabled(WETH, true);
        // A valid probe at the exact threshold can enable; the quote reverted all pool writes.
        vm.startPrank(multisig);
        registry.setMinLiquidityUsd(WETH, uint128(depthBefore));
        registry.setEnabled(WETH, true);
        vm.stopPrank();
        assertTrue(registry.isEnabled(WETH));
        assertEq(_state(pool), stateBefore);
    }

    function _state(address pool) internal view returns (bytes32) {
        (bool ok, bytes memory active) = pool.staticcall(abi.encodeWithSignature("liquidity()"));
        assertTrue(ok);
        assertGt(abi.decode(active, (uint128)), 0);
        (bool slotOk, bytes memory slot) = pool.staticcall(abi.encodeWithSignature("slot0()"));
        assertTrue(slotOk);
        return keccak256(abi.encode(active, slot));
    }

    function _quote(bool slip) internal returns (uint256 amountOut) {
        if (slip) {
            (amountOut,,,) = ISlipstreamQuoterV2(SLIP_QUOTER)
                .quoteExactInputSingle(ISlipstreamQuoterV2.QuoteExactInputSingleParams(USDC, WETH, PROBE, 100, 0));
        } else {
            (amountOut,,,) = IUniswapV3QuoterV2(UNI_QUOTER)
                .quoteExactInputSingle(IUniswapV3QuoterV2.QuoteExactInputSingleParams(USDC, WETH, PROBE, 500, 0));
        }
    }
}
