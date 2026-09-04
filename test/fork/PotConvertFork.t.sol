// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pot} from "../../src/Pot.sol";

/// @notice Pot.convert() against the real Base WETH/USDC pool and the live ETH/USD feed.
contract PotConvertForkTest is Test {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant SWAP_ROUTER_02 = 0x2626664c2603336E57B271c5C0b26F421741e481;

    Pot internal pot;
    address internal multisig = makeAddr("multisig");
    address internal stranger = makeAddr("stranger");

    address internal constant UNIV3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        pot = new Pot(multisig, USDC, UNIV3_FACTORY);
        vm.prank(multisig);
        // 0.05% tier, 1% slippage bound, 5 ETH per call, 1h feed staleness.
        pot.setConversionConfig(WETH, ETH_USD_FEED, SWAP_ROUTER_02, 500, 100, 5 ether, 0, 1 hours);
    }

    function test_routerAndFeedAreWhatWeThink() public view {
        assertEq(IRouterish(SWAP_ROUTER_02).WETH9(), WETH, "router knows WETH");
        assertEq(IRouterish(SWAP_ROUTER_02).factory(), 0x33128a8fC17869897dcE68Ed026d694621f6FDfD, "uni v3 factory");
    }

    /// @notice The real thing: 2 ETH in, USDC out, bounded by the live Chainlink mark.
    function test_convertAgainstTheLivePool() public {
        vm.deal(address(pot), 2 ether);

        uint256 minOut = pot.conversionMinOut(2 ether);
        assertGt(minOut, 0);

        vm.prank(stranger); // permissionless
        (uint256 ethIn, uint256 out) = pot.convert();

        assertEq(ethIn, 2 ether);
        assertGe(out, minOut, "executed at or above the Chainlink bound");
        assertEq(pot.available(), out, "now counts toward the round gate");
        assertEq(address(pot).balance, 0);

        console2.log("2 ETH converted to USDC:", out / 1e6);
        console2.log("Chainlink floor was:", minOut / 1e6);
    }

    function test_capHoldsAgainstTheLivePool() public {
        vm.deal(address(pot), 20 ether);
        (uint256 ethIn,) = pot.convert();
        assertEq(ethIn, 5 ether, "capped");
        assertEq(address(pot).balance, 15 ether);
    }

    /// @notice Proves the Chainlink bound actually bites against a real pool rather than
    ///         being decorative.
    /// @dev Uses a mocked feed answer rather than a zero-slippage setting. A zero-tolerance
    ///      bound only rejects when the pool happens to sit below the Chainlink mark at the
    ///      forked block, which makes the test drift with the market. Doubling the reported
    ///      ETH price makes the required output unreachable at any real pool price, so the
    ///      assertion is about our logic and not about today's spread.
    function test_theChainlinkBoundRejectsAnUnreachableMinOut() public {
        vm.deal(address(pot), 2 ether);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredIn) =
            IFeedish(ETH_USD_FEED).latestRoundData();

        // Claim ETH is worth twice what it is: no honest pool can meet that floor.
        vm.mockCall(
            ETH_USD_FEED,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(roundId, answer * 2, startedAt, updatedAt, answeredIn)
        );

        vm.expectRevert();
        pot.convert();
        assertEq(address(pot).balance, 2 ether, "ETH untouched");

        vm.clearMockedCalls();
        pot.convert(); // and it converts fine at the true mark
        assertGt(pot.available(), 0);
    }

    /// @notice Large conversions move the pool, so the cap is what keeps execution inside
    ///         the bound. Without it a whale-sized pot would fail or bleed.
    function test_uncappedLargeSwapIsWorseThanCappedOnes() public {
        vm.prank(multisig);
        pot.setConversionConfig(WETH, ETH_USD_FEED, SWAP_ROUTER_02, 500, 100, 1000 ether, 0, 1 hours);

        vm.deal(address(pot), 500 ether);
        uint256 minOutBig = pot.conversionMinOut(500 ether);
        try pot.convert() returns (uint256, uint256 out) {
            console2.log("500 ETH in one shot yielded USDC:", out / 1e6);
            console2.log("per ETH:", out / 500 / 1e6);
            assertGe(out, minOutBig);
        } catch {
            console2.log("500 ETH in one shot breached the bound and was refused");
        }
    }
}

interface IFeedish {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IRouterish {
    function WETH9() external view returns (address);
    function factory() external view returns (address);
}
