// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Pot} from "../src/Pot.sol";
import {ConversionRoutes} from "../src/base/ConversionRoutes.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {MockWETH} from "./mocks/MockWETH.sol";

contract PotConvertTest is Test {
    Pot internal pot;
    MockERC20 internal usdc;
    MockWETH internal weth;
    MockAggregatorV3 internal ethFeed;
    MockSwapRouter internal router;

    /// @dev ConversionRoutes only accepts a router of this factory (SEC-POT-001).
    address internal uniV3Factory = makeAddr("uniV3Factory");

    address internal multisig = makeAddr("multisig");
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant ETH_USD = 2_400;
    uint128 internal constant CAP = 5 ether;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockWETH();
        ethFeed = new MockAggregatorV3(8, int256(ETH_USD * 1e8), "ETH / USD");
        router = new MockSwapRouter();
        router.setFactory(uniV3Factory);

        pot = new Pot(multisig, address(usdc), uniV3Factory);
        vm.prank(multisig);
        pot.setConversionConfig(address(weth), address(ethFeed), address(router), 500, 100, CAP, 0, 1 hours);

        // Router pays 2,400 USDC per WETH: out = in * 2400e6 / 1e18
        router.setRate(address(weth), address(usdc), ETH_USD * 1e6, 1e18);
        usdc.mint(address(router), 10_000_000e6);
    }

    /* ------------------------------------------------------------------ */
    /*                            HAPPY PATH                                */
    /* ------------------------------------------------------------------ */

    function test_convert_isPermissionless() public {
        vm.deal(address(pot), 2 ether);

        vm.prank(stranger); // anyone, same ethos as openRound
        (uint256 ethIn, uint256 out) = pot.convert();

        assertEq(ethIn, 2 ether);
        assertEq(out, 4_800e6, "2 ETH at $2,400");
        assertEq(pot.available(), 4_800e6);
        assertEq(address(pot).balance, 0);
    }

    /// @notice Un-converted ETH must not count toward the $250 round gate.
    function test_unconvertedEthDoesNotCountAsAvailable() public {
        vm.deal(address(pot), 10 ether);
        assertEq(pot.available(), 0, "ETH is not round currency until converted");
        assertEq(pot.convertibleBalance(), 10 ether);
    }

    function test_convert_alsoConsumesWethSittingInThePot() public {
        weth.mint(address(pot), 1 ether);
        vm.deal(address(pot), 1 ether);

        (uint256 ethIn, uint256 out) = pot.convert();
        assertEq(ethIn, 2 ether, "ETH and WETH both used");
        assertEq(out, 4_800e6);
        assertEq(IERC20(address(weth)).balanceOf(address(pot)), 0);
    }

    /* ------------------------------------------------------------------ */
    /*                            THE SIZE CAP                              */
    /* ------------------------------------------------------------------ */

    /// @notice A fat pot must not be walked through the pool in one shot.
    function test_convert_capsEachCall() public {
        vm.deal(address(pot), 50 ether);

        assertEq(pot.nextConversionAmount(), CAP);
        (uint256 ethIn,) = pot.convert();
        assertEq(ethIn, CAP, "capped at 5 ETH");
        assertEq(address(pot).balance, 45 ether, "rest waits for the next call");
    }

    function test_convert_repeatedCallsDrainABigBalance() public {
        vm.deal(address(pot), 12 ether);

        pot.convert(); // 5
        pot.convert(); // 5
        pot.convert(); // 2
        assertEq(address(pot).balance, 0);
        assertEq(pot.available(), 12 * 2_400e6 / 1);
    }

    function test_convert_capIsConfigurable() public {
        vm.prank(multisig);
        pot.setConversionConfig(address(weth), address(ethFeed), address(router), 500, 100, 1 ether, 0, 1 hours);
        vm.deal(address(pot), 50 ether);
        (uint256 ethIn,) = pot.convert();
        assertEq(ethIn, 1 ether);
    }

    /* ------------------------------------------------------------------ */
    /*                          THE PRICE BOUND                             */
    /* ------------------------------------------------------------------ */

    function test_convert_minOutComesFromChainlink() public {
        vm.deal(address(pot), 1 ether);
        // 1 ETH at $2,400, minus the 1% bound = 2,376 USDC
        assertEq(pot.conversionMinOut(1 ether), 2_376e6);
    }

    function test_convert_revertsWhenExecutionIsWorseThanTheBound() public {
        vm.deal(address(pot), 1 ether);
        // Pool pays only 2,000 per ETH: far below the 1% bound off a $2,400 mark.
        router.setRate(address(weth), address(usdc), 2_000e6, 1e18);

        vm.expectRevert(MockSwapRouter.TooLittleReceived.selector);
        pot.convert();
        assertEq(address(pot).balance, 1 ether, "ETH untouched");
    }

    function test_convert_toleratesExecutionInsideTheBound() public {
        vm.deal(address(pot), 1 ether);
        // 0.5% worse than the mark, inside the 1% bound.
        router.setRate(address(weth), address(usdc), 2_388e6, 1e18);
        (, uint256 out) = pot.convert();
        assertEq(out, 2_388e6);
    }

    function test_convert_slippageBoundIsConfigurable() public {
        vm.deal(address(pot), 1 ether);
        router.setRate(address(weth), address(usdc), 2_300e6, 1e18); // ~4.2% worse

        vm.expectRevert(MockSwapRouter.TooLittleReceived.selector);
        pot.convert();

        vm.prank(multisig);
        pot.setConversionConfig(address(weth), address(ethFeed), address(router), 500, 500, CAP, 0, 1 hours);
        (, uint256 out) = pot.convert();
        assertEq(out, 2_300e6, "passes with a 5% bound");
    }

    function test_convert_tracksTheFeed() public {
        vm.deal(address(pot), 1 ether);
        ethFeed.setAnswer(4_000e8);
        assertEq(pot.conversionMinOut(1 ether), 3_960e6, "bound follows the mark up");
    }

    /* ------------------------------------------------------------------ */
    /*                            FEED SAFETY                               */
    /* ------------------------------------------------------------------ */

    /// @notice Unlike the equity feeds, ETH/USD has a real heartbeat, so staleness here is
    ///         a genuine fault and must block the swap.
    function test_convert_rejectsStaleEthFeed() public {
        vm.deal(address(pot), 1 ether);
        vm.warp(block.timestamp + 3 hours);

        vm.expectRevert(
            abi.encodeWithSelector(
                ConversionRoutes.StaleFeed.selector, uint256(block.timestamp - 3 hours), uint256(1 hours)
            )
        );
        pot.convert();
    }

    function test_convert_staleCheckCanBeDisabled() public {
        vm.prank(multisig);
        pot.setConversionConfig(address(weth), address(ethFeed), address(router), 500, 100, CAP, 0, 0);
        vm.deal(address(pot), 1 ether);
        vm.warp(block.timestamp + 30 days);
        (, uint256 out) = pot.convert();
        assertEq(out, 2_400e6);
    }

    function test_convert_rejectsNonPositivePrice() public {
        vm.deal(address(pot), 1 ether);
        ethFeed.setAnswer(0);
        vm.expectRevert(ConversionRoutes.BadFeedAnswer.selector);
        pot.convert();
    }

    function test_convert_revertsIfFeedIsDown() public {
        vm.deal(address(pot), 1 ether);
        ethFeed.setRevertOnRead(true);
        vm.expectRevert(bytes("feed down"));
        pot.convert();
    }

    /* ------------------------------------------------------------------ */
    /*                          GUARDS AND CONFIG                           */
    /* ------------------------------------------------------------------ */

    function test_convert_revertsWithNothingToConvert() public {
        vm.expectRevert(ConversionRoutes.NothingToConvert.selector);
        pot.convert();
    }

    function test_convert_revertsWhenUnconfigured() public {
        Pot fresh = new Pot(multisig, address(usdc), uniV3Factory);
        vm.deal(address(fresh), 1 ether);
        vm.expectRevert(Pot.ConversionNotConfigured.selector);
        fresh.convert();
    }

    function test_setConversionConfig_onlyMultisig() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        pot.setConversionConfig(address(weth), address(ethFeed), address(router), 500, 100, CAP, 0, 1 hours);
    }

    function test_setConversionConfig_rejectsNonsense() public {
        vm.startPrank(multisig);

        vm.expectRevert(ConversionRoutes.RouteZeroAddress.selector);
        pot.setConversionConfig(address(0), address(ethFeed), address(router), 500, 100, CAP, 0, 1 hours);

        vm.expectRevert(ConversionRoutes.RouteBadConfig.selector);
        pot.setConversionConfig(address(weth), address(ethFeed), address(router), 0, 100, CAP, 0, 1 hours);

        vm.expectRevert(ConversionRoutes.RouteBadConfig.selector);
        pot.setConversionConfig(address(weth), address(ethFeed), address(router), 500, 10_000, CAP, 0, 1 hours);

        vm.expectRevert(ConversionRoutes.RouteBadConfig.selector);
        pot.setConversionConfig(address(weth), address(ethFeed), address(router), 500, 100, 0, 0, 1 hours);

        vm.stopPrank();
    }

    /// @notice The escape hatch still works if the route is broken.
    function test_sweepEthStillWorksIfConversionIsBroken() public {
        vm.deal(address(pot), 3 ether);
        router.setFailAlways(true);

        vm.expectRevert(MockSwapRouter.RouterDown.selector);
        pot.convert();

        vm.prank(multisig);
        pot.sweepEth(multisig);
        assertEq(multisig.balance, 3 ether);
    }

    /* ------------------------------------------------------------------ */
    /*                               FUZZ                                   */
    /* ------------------------------------------------------------------ */

    /// @notice Dust below the pricing floor must be refused, not swapped unbounded.
    ///         Found by the fuzzer: a few thousand wei rounds the Chainlink-derived
    ///         minimum output down to zero, which would have meant a swap with no price
    ///         protection at all.
    function test_convert_refusesDustTooSmallToPrice() public {
        vm.deal(address(pot), 6_329 wei);
        assertEq(pot.conversionMinOut(6_329 wei), 0, "rounds to zero");

        vm.expectRevert(abi.encodeWithSelector(ConversionRoutes.AmountTooSmall.selector, uint256(6_329)));
        pot.convert();
        assertEq(address(pot).balance, 6_329 wei, "dust just waits");
    }

    function testFuzz_convertNeverExceedsTheCapAndNeverLosesEth(uint96 balance) public {
        // Below ~1 gwei the minimum output rounds to zero; that path is covered above.
        balance = uint96(bound(balance, 1 gwei, 1_000 ether));
        vm.deal(address(pot), balance);

        uint256 expectedIn = balance > CAP ? CAP : balance;
        (uint256 ethIn, uint256 out) = pot.convert();

        assertEq(ethIn, expectedIn, "never more than the cap");
        assertEq(address(pot).balance, balance - expectedIn, "remainder retained");
        assertGe(out, pot.conversionMinOut(ethIn), "always at or above the bound");
    }
}
