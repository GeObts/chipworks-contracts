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
import {BlacklistToken} from "./mocks/HostileTokens.sol";

/// @notice The per-token conversion route table. This is what makes recycled POL income
///         spendable instead of stranded — the gap the full-system fork test found.
contract PotRoutesTest is Test {
    Pot internal pot;
    MockERC20 internal usdc;
    MockWETH internal weth;
    MockERC20 internal aero;
    MockAggregatorV3 internal ethFeed;
    MockAggregatorV3 internal aeroFeed;
    MockSwapRouter internal router;

    address internal multisig = makeAddr("multisig");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant ETH_USD = 2_400;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockWETH();
        aero = new MockERC20("Aerodrome", "AERO", 18);
        ethFeed = new MockAggregatorV3(8, int256(ETH_USD * 1e8), "ETH / USD");
        aeroFeed = new MockAggregatorV3(8, 0.5e8, "AERO / USD"); // $0.50
        router = new MockSwapRouter();

        pot = new Pot(multisig, address(usdc));

        vm.startPrank(multisig);
        pot.setConversionConfig(address(weth), address(ethFeed), address(router), 500, 100, 5 ether, 1 hours);
        pot.setRoute(address(aero), address(aeroFeed), address(router), 500, 200, 10_000 ether, 1 hours);
        vm.stopPrank();

        router.setRate(address(weth), address(usdc), ETH_USD * 1e6, 1e18);
        router.setRate(address(aero), address(usdc), 0.5e6, 1e18); // $0.50 per AERO
        usdc.mint(address(router), 10_000_000e6);
    }

    /* ------------------------------------------------------------------ */
    /*                        THE POINT OF THE TABLE                        */
    /* ------------------------------------------------------------------ */

    /// @notice Recycled POL income becomes spendable round budget.
    function test_aeroBecomesSpendableRoundBudget() public {
        aero.mint(address(pot), 800 ether);

        assertEq(pot.available(), 0, "AERO is not budget yet");

        vm.prank(stranger); // permissionless, same as the ETH path
        (uint256 amountIn, uint256 out) = pot.convert(address(aero));

        assertEq(amountIn, 800 ether);
        assertEq(out, 400e6, "800 AERO at $0.50");
        assertEq(pot.available(), 400e6, "now a round can spend it");
        assertEq(aero.balanceOf(address(pot)), 0);
    }

    function test_bothRoutesCoexist() public {
        vm.deal(address(pot), 2 ether);
        aero.mint(address(pot), 100 ether);

        pot.convert(); // ETH path
        pot.convert(address(aero)); // token path

        assertEq(pot.available(), 4_800e6 + 50e6);
    }

    /// @notice Decimals are read per token, so an 18-decimal and a 6-decimal income token
    ///         both price correctly against a 6-decimal quote.
    function test_handlesDifferentTokenDecimals() public {
        MockERC20 sixDec = new MockERC20("Six", "SIX", 6);
        MockAggregatorV3 sixFeed = new MockAggregatorV3(8, 2e8, "SIX / USD"); // $2
        vm.prank(multisig);
        pot.setRoute(address(sixDec), address(sixFeed), address(router), 500, 100, 1_000_000e6, 1 hours);
        router.setRate(address(sixDec), address(usdc), 2e6, 1e6);

        sixDec.mint(address(pot), 100e6); // 100 tokens
        (, uint256 out) = pot.convert(address(sixDec));
        assertEq(out, 200e6, "100 tokens at $2");
    }

    /* ------------------------------------------------------------------ */
    /*                     SAME GUARANTEES AS THE ETH PATH                  */
    /* ------------------------------------------------------------------ */

    function test_minOutComesFromThatTokensFeed() public view {
        // 1,000 AERO at $0.50 minus the 2% bound = 490 USDC
        assertEq(pot.minOutFor(address(aero), 1_000 ether), 490e6);
    }

    function test_capsPerCall() public {
        aero.mint(address(pot), 25_000 ether);
        assertEq(pot.nextConversionAmount(address(aero)), 10_000 ether);
        (uint256 amountIn,) = pot.convert(address(aero));
        assertEq(amountIn, 10_000 ether);
        assertEq(aero.balanceOf(address(pot)), 15_000 ether, "rest waits");
    }

    function test_rejectsExecutionWorseThanTheBound() public {
        aero.mint(address(pot), 1_000 ether);
        router.setRate(address(aero), address(usdc), 0.4e6, 1e18); // 20% worse

        vm.expectRevert(MockSwapRouter.TooLittleReceived.selector);
        pot.convert(address(aero));
        assertEq(aero.balanceOf(address(pot)), 1_000 ether, "untouched");
    }

    function test_rejectsStaleFeed() public {
        aero.mint(address(pot), 1_000 ether);
        vm.warp(block.timestamp + 3 hours);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConversionRoutes.StaleFeed.selector, uint256(block.timestamp - 3 hours), uint256(1 hours)
            )
        );
        pot.convert(address(aero));
    }

    function test_rejectsDustTooSmallToPrice() public {
        aero.mint(address(pot), 1); // 1 wei of AERO
        assertEq(pot.minOutFor(address(aero), 1), 0);
        vm.expectRevert(abi.encodeWithSelector(ConversionRoutes.AmountTooSmall.selector, uint256(1)));
        pot.convert(address(aero));
    }

    function test_revertsWithNothingToConvert() public {
        vm.expectRevert(ConversionRoutes.NothingToConvert.selector);
        pot.convert(address(aero));
    }

    /* ------------------------------------------------------------------ */
    /*                          ROUTE MANAGEMENT                            */
    /* ------------------------------------------------------------------ */

    function test_unregisteredTokenHasNoRoute() public {
        MockERC20 rando = new MockERC20("Rando", "RND", 18);
        rando.mint(address(pot), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(ConversionRoutes.NoRoute.selector, address(rando)));
        pot.convert(address(rando));
    }

    function test_cannotRouteTheQuoteToken() public {
        vm.prank(multisig);
        vm.expectRevert(ConversionRoutes.CannotRouteQuoteToken.selector);
        pot.setRoute(address(usdc), address(aeroFeed), address(router), 500, 100, 1_000e6, 1 hours);
    }

    function test_setRoute_onlyMultisig() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        pot.setRoute(address(aero), address(aeroFeed), address(router), 500, 100, 1 ether, 1 hours);
    }

    function test_setRoute_rejectsNonsense() public {
        vm.startPrank(multisig);
        vm.expectRevert(ConversionRoutes.RouteZeroAddress.selector);
        pot.setRoute(address(aero), address(0), address(router), 500, 100, 1 ether, 1 hours);

        vm.expectRevert(ConversionRoutes.RouteBadConfig.selector);
        pot.setRoute(address(aero), address(aeroFeed), address(router), 0, 100, 1 ether, 1 hours);

        vm.expectRevert(ConversionRoutes.RouteBadConfig.selector);
        pot.setRoute(address(aero), address(aeroFeed), address(router), 500, 10_000, 1 ether, 1 hours);

        vm.expectRevert(ConversionRoutes.RouteBadConfig.selector);
        pot.setRoute(address(aero), address(aeroFeed), address(router), 500, 100, 0, 1 hours);
        vm.stopPrank();
    }

    /// @notice A token whose decimals cannot be read is rejected, not guessed at: a wrong
    ///         guess silently mis-prices every conversion of it.
    function test_setRoute_rejectsATokenWithUnreadableDecimals() public {
        address notAToken = makeAddr("notAToken");
        vm.prank(multisig);
        vm.expectRevert(ConversionRoutes.RouteBadConfig.selector);
        pot.setRoute(notAToken, address(aeroFeed), address(router), 500, 100, 1 ether, 1 hours);
    }

    function test_disableRoute_stopsConversionButNotSweeping() public {
        aero.mint(address(pot), 100 ether);
        vm.prank(multisig);
        pot.disableRoute(address(aero));

        vm.expectRevert(abi.encodeWithSelector(ConversionRoutes.NoRoute.selector, address(aero)));
        pot.convert(address(aero));

        vm.prank(multisig);
        pot.sweepNonQuote(address(aero), multisig);
        assertEq(aero.balanceOf(multisig), 100 ether, "escape hatch still open");
    }

    function test_routeCanBeUpdatedInPlace() public {
        MockAggregatorV3 newFeed = new MockAggregatorV3(8, 1e8, "AERO / USD v2"); // $1
        vm.prank(multisig);
        pot.setRoute(address(aero), address(newFeed), address(router), 500, 100, 10_000 ether, 1 hours);

        assertEq(pot.minOutFor(address(aero), 1_000 ether), 990e6, "priced off the new feed");
        assertEq(pot.routedTokens().length, 2, "not double-listed");
    }

    function test_routedTokensEnumerates() public view {
        address[] memory toks = pot.routedTokens();
        assertEq(toks.length, 2);
        assertEq(toks[0], address(weth));
        assertEq(toks[1], address(aero));
    }

    /* ------------------------------------------------------------------ */
    /*                          HOSTILE TOKENS                              */
    /* ------------------------------------------------------------------ */

    /// @notice A frozen income token must not stop other routes converting.
    function test_frozenIncomeTokenBlocksOnlyItsOwnRoute() public {
        BlacklistToken frozen = new BlacklistToken("Frozen", "FRZ", 18);
        MockAggregatorV3 frozenFeed = new MockAggregatorV3(8, 1e8, "FRZ / USD");
        vm.prank(multisig);
        pot.setRoute(address(frozen), address(frozenFeed), address(router), 500, 100, 10_000 ether, 1 hours);
        router.setRate(address(frozen), address(usdc), 1e6, 1e18);

        frozen.mint(address(pot), 100 ether);
        frozen.setBlacklisted(address(pot), true);
        aero.mint(address(pot), 100 ether);

        vm.expectRevert(bytes("BLACKLISTED"));
        pot.convert(address(frozen));

        pot.convert(address(aero)); // unaffected
        assertEq(pot.available(), 50e6);

        frozen.setBlacklisted(address(pot), false);
        pot.convert(address(frozen));
        assertEq(pot.available(), 50e6 + 100e6, "recovers, nothing lost");
    }

    /* ------------------------------------------------------------------ */
    /*                               FUZZ                                   */
    /* ------------------------------------------------------------------ */

    function testFuzz_neverExceedsCapAndAlwaysMeetsTheBound(uint96 balance) public {
        balance = uint96(bound(balance, 1e15, 1_000_000 ether));
        aero.mint(address(pot), balance);

        uint256 cap = 10_000 ether;
        uint256 expectedIn = balance > cap ? cap : balance;

        (uint256 amountIn, uint256 out) = pot.convert(address(aero));
        assertEq(amountIn, expectedIn);
        assertEq(aero.balanceOf(address(pot)), balance - expectedIn);
        assertGe(out, pot.minOutFor(address(aero), amountIn));
    }
}
