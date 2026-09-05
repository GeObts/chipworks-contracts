// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {POLTreasury} from "../src/POLTreasury.sol";
import {INonfungiblePositionManager} from "../src/interfaces/INonfungiblePositionManager.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {BlacklistToken, PausableToken, LyingToken} from "./mocks/HostileTokens.sol";
import {MockPositionManager, MockGauge} from "./mocks/MockPositionManager.sol";
import {MockAerodromeVoter, MockSlipstreamFactoryReal, PoolMath} from "./mocks/MockAerodrome.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {ConversionRoutes} from "../src/base/ConversionRoutes.sol";

contract POLTreasuryTest is Test {
    POLTreasury internal pol;

    /// @dev ConversionRoutes only accepts a router of this factory (SEC-POT-001).
    address internal uniV3Factory = makeAddr("uniV3Factory");
    MockPositionManager internal npm;
    MockSlipstreamFactoryReal internal clFactory;
    MockAerodromeVoter internal voter;
    MockERC20 internal usdc;
    MockERC20 internal nvda;
    BlacklistToken internal aapl;
    MockERC20 internal aero;

    address internal multisig = makeAddr("multisig");
    address internal manager = makeAddr("bankrOptimizer");
    address internal rewards = makeAddr("chipRewards");
    address internal splitter = makeAddr("feeSplitter");
    address internal stranger = makeAddr("stranger");
    address internal rescueTo = makeAddr("rescueTo");

    int24 internal constant SPACING = 100;
    uint256 internal constant MARK_USD_1E8 = 200e8; // $200.00
    uint256 internal constant MARK_QUOTE = 200e6; // the same price in USDC units

    mapping(address => MockAggregatorV3) internal feeds;
    mapping(address => address) internal pools;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        nvda = new MockERC20("NVIDIA Corporation", "NVDAc", 8);
        aapl = new BlacklistToken("Apple Inc.", "AAPLc", 8);
        aero = new MockERC20("Aerodrome", "AERO", 18);
        npm = new MockPositionManager();
        clFactory = npm.clFactory();
        voter = new MockAerodromeVoter();

        pol = new POLTreasury(multisig, address(usdc), address(npm), splitter, uniV3Factory, address(voter));

        vm.startPrank(multisig);
        pol.setManager(manager);
        pol.setRewards(rewards);
        pol.setIncomeToken(address(aero), true);
        vm.stopPrank();

        _listAsset(address(nvda), 8);
        _listAsset(address(aapl), 8);
    }

    /// @notice Register a POL asset the way the multisig will at launch, and stand up the
    ///         canonical pool it pairs into.
    /// @dev Since batch 6 an asset is only usable in an LP operation once it has a Chainlink
    ///      feed and a real pool for the pair — see the H-02 fix. Every suite that mints has
    ///      to do this, so it lives in one helper.
    function _listAsset(address token, uint8 decimals_) internal returns (address pool) {
        MockAggregatorV3 feed = new MockAggregatorV3(8, int256(MARK_USD_1E8), "asset / USD");
        vm.prank(multisig);
        pol.setPolAsset(token, address(feed), 500, 0);

        pool = clFactory.createPool(
            address(usdc), token, SPACING, PoolMath.sqrtPriceX96For(token, address(usdc), decimals_, MARK_QUOTE)
        );
        feeds[token] = feed;
        pools[token] = pool;
    }

    function _mintParams(address t0, address t1, uint256 a0, uint256 a1)
        internal
        view
        returns (INonfungiblePositionManager.MintParams memory)
    {
        return INonfungiblePositionManager.MintParams({
            token0: t0,
            token1: t1,
            tickSpacing: 100,
            tickLower: -887200,
            tickUpper: 887200,
            amount0Desired: a0,
            amount1Desired: a1,
            amount0Min: (a0 * 99) / 100,
            amount1Min: (a1 * 99) / 100,
            recipient: address(pol),
            deadline: block.timestamp,
            sqrtPriceX96: 0
        });
    }

    /* ------------------------------------------------------------------ */
    /*                            POSITIONS                                 */
    /* ------------------------------------------------------------------ */

    function test_mintPosition_pairsHoldbackWithUsdc() public {
        nvda.mint(address(pol), 10e8);
        usdc.mint(address(pol), 2_000e6);

        vm.prank(manager);
        (uint256 tokenId,,,) = pol.mintPosition(_mintParams(address(nvda), address(usdc), 10e8, 2_000e6));

        assertEq(pol.positionCount(), 1);
        assertTrue(pol.holdsPosition(tokenId));
        assertEq(npm.ownerOf(tokenId), address(pol), "position stays here");
    }

    function test_mintPosition_clearsApprovalsAfterwards() public {
        nvda.mint(address(pol), 10e8);
        usdc.mint(address(pol), 2_000e6);

        vm.prank(manager);
        pol.mintPosition(_mintParams(address(nvda), address(usdc), 10e8, 2_000e6));

        assertEq(nvda.allowance(address(pol), address(npm)), 0, "no stale allowance");
        assertEq(usdc.allowance(address(pol), address(npm)), 0);
    }

    /// @notice The manager may never mint a position to their own wallet.
    function test_mintPosition_recipientIsForcedToTheTreasury() public {
        nvda.mint(address(pol), 10e8);
        usdc.mint(address(pol), 2_000e6);

        INonfungiblePositionManager.MintParams memory p = _mintParams(address(nvda), address(usdc), 10e8, 2_000e6);
        p.recipient = manager; // manager tries to redirect the NFT to themselves

        vm.prank(manager);
        (uint256 tokenId,,,) = pol.mintPosition(p);
        assertEq(npm.ownerOf(tokenId), address(pol), "overridden");
    }

    function test_mintPosition_onlyManagerOrMultisig() public {
        nvda.mint(address(pol), 10e8);
        usdc.mint(address(pol), 2_000e6);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(POLTreasury.NotManager.selector, stranger));
        pol.mintPosition(_mintParams(address(nvda), address(usdc), 10e8, 2_000e6));

        vm.prank(multisig); // owner can also do it
        pol.mintPosition(_mintParams(address(nvda), address(usdc), 10e8, 2_000e6));
    }

    function test_increaseAndDecreaseLiquidity() public {
        nvda.mint(address(pol), 20e8);
        usdc.mint(address(pol), 4_000e6);

        vm.startPrank(manager);
        (uint256 tokenId,,,) = pol.mintPosition(_mintParams(address(nvda), address(usdc), 10e8, 2_000e6));
        pol.increaseLiquidity(tokenId, 10e8, 2_000e6, 99e7, 1_980e6);
        (uint256 a0, uint256 a1) = pol.decreaseLiquidity(tokenId, 1_000, 1, 1);
        vm.stopPrank();

        assertGt(a0 + a1, 0, "tokens came back to the treasury");
    }

    function test_liquidityCallsRejectUnknownPositions() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(POLTreasury.UnknownPosition.selector, uint256(999)));
        pol.decreaseLiquidity(999, 1, 1, 1);
    }

    function test_collectFees_isPermissionless() public {
        nvda.mint(address(pol), 10e8);
        usdc.mint(address(pol), 2_000e6);
        vm.prank(manager);
        (uint256 tokenId,,,) = pol.mintPosition(_mintParams(address(nvda), address(usdc), 10e8, 2_000e6));

        npm.setOwedFees(tokenId, 5e8, 100e6);
        nvda.mint(address(npm), 5e8);
        usdc.mint(address(npm), 100e6);

        vm.prank(stranger); // anyone
        (uint256 a0, uint256 a1) = pol.collectFees(tokenId);
        assertEq(a0, 5e8);
        assertEq(a1, 100e6);
        assertEq(nvda.balanceOf(address(pol)), 5e8);
    }

    /// @notice One broken position must not stop the others from being collected.
    function test_collectAllFees_skipsFailures() public {
        nvda.mint(address(pol), 20e8);
        usdc.mint(address(pol), 4_000e6);
        vm.startPrank(manager);
        (uint256 idA,,,) = pol.mintPosition(_mintParams(address(nvda), address(usdc), 10e8, 2_000e6));
        (uint256 idB,,,) = pol.mintPosition(_mintParams(address(nvda), address(usdc), 10e8, 2_000e6));
        vm.stopPrank();

        npm.setOwedFees(idA, 1e8, 0);
        nvda.mint(address(npm), 1e8);
        npm.setCollectReverts(idB, true);

        uint256 collected = pol.collectAllFees();
        assertEq(collected, 1, "one succeeded, one skipped");
        assertEq(nvda.balanceOf(address(pol)), 1e8);
    }

    /* ------------------------------------------------------------------ */
    /*                              INCOME                                  */
    /* ------------------------------------------------------------------ */

    function test_forwardIncome_sendsToTheSplitter() public {
        aero.mint(address(pol), 500 ether);

        vm.prank(stranger); // permissionless
        uint256 amount = pol.forwardIncome(address(aero));

        assertEq(amount, 500 ether);
        assertEq(aero.balanceOf(splitter), 500 ether, "income re-enters the fee flow");
        assertEq(aero.balanceOf(address(pol)), 0);
    }

    function test_forwardIncome_refusesNonIncomeTokens() public {
        nvda.mint(address(pol), 10e8);
        vm.expectRevert(abi.encodeWithSelector(POLTreasury.ProtectedToken.selector, address(nvda)));
        pol.forwardIncome(address(nvda));
    }

    function test_forwardIncomeMany_skipsEmptyAndBroken() public {
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        BlacklistToken frozenIncome = new BlacklistToken("Frozen", "FRZ", 18);
        vm.startPrank(multisig);
        pol.setIncomeToken(address(weth), true);
        pol.setIncomeToken(address(frozenIncome), true);
        vm.stopPrank();

        aero.mint(address(pol), 100 ether);
        frozenIncome.mint(address(pol), 100 ether);
        frozenIncome.setBlacklisted(address(pol), true);
        // weth balance deliberately zero

        address[] memory tokens = new address[](3);
        tokens[0] = address(aero);
        tokens[1] = address(weth);
        tokens[2] = address(frozenIncome);

        uint256 forwarded = pol.forwardIncomeMany(tokens);
        assertEq(forwarded, 1, "only AERO went");
        assertEq(aero.balanceOf(splitter), 100 ether);
        assertEq(frozenIncome.balanceOf(address(pol)), 100 ether, "frozen one waits, not lost");
    }

    /// @notice A frozen income token blocks only its own forward.
    function test_frozenIncomeTokenDoesNotBlockOthers() public {
        BlacklistToken frozen = new BlacklistToken("Frozen", "FRZ", 18);
        vm.prank(multisig);
        pol.setIncomeToken(address(frozen), true);

        frozen.mint(address(pol), 100 ether);
        aero.mint(address(pol), 100 ether);
        frozen.setBlacklisted(address(pol), true);

        vm.expectRevert(bytes("BLACKLISTED"));
        pol.forwardIncome(address(frozen));

        pol.forwardIncome(address(aero)); // unaffected
        assertEq(aero.balanceOf(splitter), 100 ether);

        frozen.setBlacklisted(address(pol), false);
        pol.forwardIncome(address(frozen));
        assertEq(frozen.balanceOf(splitter), 100 ether, "recovers, nothing lost");
    }

    /* ------------------------------------------------------------------ */
    /*                           HOSTILE TOKENS                             */
    /* ------------------------------------------------------------------ */

    /// @notice A frozen POL asset blocks only operations on itself. A position built from
    ///         a different pair must still be manageable.
    function test_frozenPolAssetDoesNotBlockOtherPositions() public {
        nvda.mint(address(pol), 10e8);
        aapl.mint(address(pol), 10e8);
        usdc.mint(address(pol), 4_000e6);

        vm.prank(manager);
        (uint256 healthy,,,) = pol.mintPosition(_mintParams(address(nvda), address(usdc), 10e8, 2_000e6));

        aapl.setBlacklisted(address(pol), true);

        // The AAPL position cannot be opened...
        vm.prank(manager);
        vm.expectRevert(bytes("BLACKLISTED"));
        pol.mintPosition(_mintParams(address(aapl), address(usdc), 10e8, 2_000e6));

        // ...but the NVDA one is entirely unaffected.
        npm.setOwedFees(healthy, 1e8, 0);
        nvda.mint(address(npm), 1e8);
        pol.collectFees(healthy);
        assertEq(nvda.balanceOf(address(pol)), 1e8);
    }

    function test_pausedPolAssetRecoversOnceUnpaused() public {
        PausableToken paused = new PausableToken("Pauser", "PAUSE", 8);
        _listAsset(address(paused), 8);

        paused.mint(address(pol), 10e8);
        usdc.mint(address(pol), 2_000e6);
        paused.setPaused(true);

        vm.prank(manager);
        vm.expectRevert(bytes("PAUSED"));
        pol.mintPosition(_mintParams(address(paused), address(usdc), 10e8, 2_000e6));

        paused.setPaused(false);
        vm.prank(manager);
        pol.mintPosition(_mintParams(address(paused), address(usdc), 10e8, 2_000e6));
        assertEq(pol.positionCount(), 1);
    }

    /* ------------------------------------------------------------------ */
    /*                              RESCUE                                  */
    /* ------------------------------------------------------------------ */

    function test_rescueCannotTouchTheQuoteToken() public {
        usdc.mint(address(pol), 10_000e6);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(POLTreasury.ProtectedToken.selector, address(usdc)));
        pol.recoverExcess(address(usdc), rescueTo, 1);
    }

    function test_rescueCannotTouchAPolAsset() public {
        nvda.mint(address(pol), 10e8);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(POLTreasury.ProtectedToken.selector, address(nvda)));
        pol.recoverExcess(address(nvda), rescueTo, 1);
    }

    function test_rescueCannotTouchAnIncomeToken() public {
        aero.mint(address(pol), 100 ether);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(POLTreasury.ProtectedToken.selector, address(aero)));
        pol.recoverExcess(address(aero), rescueTo, 1);
    }

    function test_rescueMovesOnlyUnrecognisedTokens() public {
        MockERC20 junk = new MockERC20("Airdrop", "JUNK", 18);
        junk.mint(address(pol), 777 ether);

        assertFalse(pol.isProtected(address(junk)));
        vm.prank(multisig);
        pol.recoverExcess(address(junk), rescueTo, 777 ether);
        assertEq(junk.balanceOf(rescueTo), 777 ether);
    }

    /// @notice Marking a token as POL protects it from then on, even retroactively.
    function test_markingATokenAsPolProtectsItImmediately() public {
        MockERC20 later = new MockERC20("Later", "LATE", 18);
        later.mint(address(pol), 100 ether);

        vm.prank(multisig);
        pol.recoverExcess(address(later), rescueTo, 50 ether); // allowed while unrecognised

        _listAsset(address(later), 18);

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(POLTreasury.ProtectedToken.selector, address(later)));
        pol.recoverExcess(address(later), rescueTo, 1);
    }

    function test_rescue_onlyMultisig() public {
        MockERC20 junk = new MockERC20("Airdrop", "JUNK", 18);
        junk.mint(address(pol), 100 ether);

        vm.prank(manager); // even the optimizer cannot rescue
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, manager));
        pol.recoverExcess(address(junk), rescueTo, 100 ether);
    }

    function test_rescue_cannotOverdraw() public {
        MockERC20 junk = new MockERC20("Airdrop", "JUNK", 18);
        junk.mint(address(pol), 100 ether);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(POLTreasury.NothingToRecover.selector, address(junk)));
        pol.recoverExcess(address(junk), rescueTo, 100 ether + 1);
    }

    /* ------------------------------------------------------------------ */
    /*                          ROLES AND LEDGER                            */
    /* ------------------------------------------------------------------ */

    /// @notice The optimizer manages positions but must not be able to change wiring.
    function test_managerCannotChangeConfiguration() public {
        vm.startPrank(manager);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, manager));
        pol.setFeeSplitter(manager);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, manager));
        pol.removePolAsset(address(nvda));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, manager));
        pol.setManager(manager);
        vm.stopPrank();
    }

    function test_managerCanBeRevoked() public {
        vm.prank(multisig);
        pol.setManager(address(0));

        nvda.mint(address(pol), 10e8);
        usdc.mint(address(pol), 2_000e6);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(POLTreasury.NotManager.selector, manager));
        pol.mintPosition(_mintParams(address(nvda), address(usdc), 10e8, 2_000e6));
    }

    function test_compoundLedger_onlyRewardsCanCredit() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(POLTreasury.NotRewards.selector, stranger));
        pol.notifyCompound(stranger, address(nvda), 1e8, 200e18);

        vm.prank(rewards);
        pol.notifyCompound(stranger, address(nvda), 1e8, 200e18);
        assertEq(pol.compoundShares(stranger), 200e18);
        assertEq(pol.totalCompoundShares(), 200e18);
    }

    function test_compoundLedger_accumulates() public {
        vm.startPrank(rewards);
        pol.notifyCompound(stranger, address(nvda), 1e8, 200e18);
        pol.notifyCompound(stranger, address(nvda), 1e8, 300e18);
        pol.notifyCompound(manager, address(nvda), 1e8, 100e18);
        vm.stopPrank();

        assertEq(pol.compoundShares(stranger), 500e18);
        assertEq(pol.compoundShares(manager), 100e18);
        assertEq(pol.totalCompoundShares(), 600e18);
    }

    /* ------------------------------------------------------------------ */
    /*                              GAUGES                                  */
    /* ------------------------------------------------------------------ */

    function test_stakeAndClaimGaugeRewards() public {
        nvda.mint(address(pol), 10e8);
        usdc.mint(address(pol), 2_000e6);
        vm.prank(manager);
        (uint256 tokenId,,,) = pol.mintPosition(_mintParams(address(nvda), address(usdc), 10e8, 2_000e6));

        MockGauge gauge = new MockGauge(address(npm), address(aero));
        aero.mint(address(gauge), 1_000 ether);
        voter.setGauge(pools[address(nvda)], address(gauge));

        vm.prank(manager);
        pol.stakePosition(tokenId, address(gauge));
        assertEq(npm.ownerOf(tokenId), address(gauge), "staked");

        gauge.setPendingReward(tokenId, 250 ether);
        vm.prank(stranger); // claiming is permissionless
        pol.claimGaugeRewards(tokenId);
        assertEq(aero.balanceOf(address(pol)), 250 ether);

        // And that AERO can be pushed straight back to the splitter.
        pol.forwardIncome(address(aero));
        assertEq(aero.balanceOf(splitter), 250 ether);
    }

    function test_stakePosition_onlyManager() public {
        nvda.mint(address(pol), 10e8);
        usdc.mint(address(pol), 2_000e6);
        vm.prank(manager);
        (uint256 tokenId,,,) = pol.mintPosition(_mintParams(address(nvda), address(usdc), 10e8, 2_000e6));
        MockGauge gauge = new MockGauge(address(npm), address(aero));
        voter.setGauge(pools[address(nvda)], address(gauge));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(POLTreasury.NotManager.selector, stranger));
        pol.stakePosition(tokenId, address(gauge));
    }

    function test_unstakeReturnsThePosition() public {
        nvda.mint(address(pol), 10e8);
        usdc.mint(address(pol), 2_000e6);
        vm.prank(manager);
        (uint256 tokenId,,,) = pol.mintPosition(_mintParams(address(nvda), address(usdc), 10e8, 2_000e6));
        MockGauge gauge = new MockGauge(address(npm), address(aero));
        voter.setGauge(pools[address(nvda)], address(gauge));

        vm.startPrank(manager);
        pol.stakePosition(tokenId, address(gauge));
        pol.unstakePosition(tokenId, address(gauge));
        vm.stopPrank();

        assertEq(npm.ownerOf(tokenId), address(pol));
    }

    /* ------------------------------------------------------------------ */
    /*                 POL FUNDS ITS OWN PAIRING (item 2)                   */
    /* ------------------------------------------------------------------ */

    /// @notice POL receives its splitter slice in whatever asset was flowing. It must be
    ///         able to realise that into the quote token itself, or it cannot pair the
    ///         stock holdback and the whole point of the leg is lost.
    function test_convertsItsEthSliceIntoPairableUsdc() public {
        MockWETH weth = new MockWETH();
        MockAggregatorV3 ethFeed = new MockAggregatorV3(8, 2_400e8, "ETH / USD");
        MockSwapRouter swapRouter = new MockSwapRouter();
        swapRouter.setFactory(uniV3Factory);
        swapRouter.setRate(address(weth), address(usdc), 2_400e6, 1e18);
        usdc.mint(address(swapRouter), 1_000_000e6);

        vm.startPrank(multisig);
        pol.setWeth(address(weth));
        pol.setRoute(address(weth), address(ethFeed), address(swapRouter), 500, 100, 100 ether, 0, 1 hours);
        vm.stopPrank();

        // The splitter's POL leg arrives as ETH.
        vm.deal(address(pol), 2 ether);
        assertEq(IERC20(address(usdc)).balanceOf(address(pol)), 0, "no pairable asset yet");

        vm.prank(stranger); // permissionless
        (uint256 amountIn, uint256 out) = pol.convert(address(weth));

        assertEq(amountIn, 2 ether);
        assertEq(out, 4_800e6);
        assertEq(IERC20(address(usdc)).balanceOf(address(pol)), 4_800e6, "now it can pair");
    }

    function test_convertsAeroIncomeItKeeps() public {
        MockAggregatorV3 aeroFeed = new MockAggregatorV3(8, 0.5e8, "AERO / USD");
        MockSwapRouter swapRouter = new MockSwapRouter();
        swapRouter.setFactory(uniV3Factory);
        swapRouter.setRate(address(aero), address(usdc), 0.5e6, 1e18);
        usdc.mint(address(swapRouter), 1_000_000e6);

        vm.prank(multisig);
        pol.setRoute(address(aero), address(aeroFeed), address(swapRouter), 500, 200, 100_000 ether, 0, 1 hours);

        aero.mint(address(pol), 1_000 ether);
        (, uint256 out) = pol.convert(address(aero));
        assertEq(out, 500e6);
    }

    function test_convertRejectsAnUnroutedToken() public {
        vm.expectRevert(abi.encodeWithSelector(ConversionRoutes.NoRoute.selector, address(nvda)));
        pol.convert(address(nvda));
    }

    function test_routeConfigOnlyMultisig() public {
        vm.startPrank(manager); // even the optimizer cannot set routes
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, manager));
        pol.setRoute(address(aero), address(0x1), address(0x2), 500, 100, 1 ether, 0, 1 hours);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, manager));
        pol.setWeth(address(0x1));
        vm.stopPrank();
    }

    /// @notice The quote token itself can never be given a route: it is the destination.
    function test_cannotRouteTheQuoteToken() public {
        vm.prank(multisig);
        vm.expectRevert(ConversionRoutes.CannotRouteQuoteToken.selector);
        pol.setRoute(address(usdc), address(0x1), address(0x2), 500, 100, 1 ether, 0, 1 hours);
    }

    /* ------------------------------------------------------------------ */
    /*         EXTERNAL REVIEW — BANKR BATCH 6, THE MEDIUMS AND LOWS        */
    /* ------------------------------------------------------------------ */

    /// @notice M-01. The keeper floor SEC-POT-002 added was unreachable from this contract:
    ///         `convert` hardcoded `callerMinOut = 0`, so the parameter existed and the
    ///         defence did not. The overload makes it real.
    function test_M01_aKeeperCanInsistOnAFloorTighterThanChainlink() public {
        MockAggregatorV3 aeroFeed = new MockAggregatorV3(8, 0.5e8, "AERO / USD");
        MockSwapRouter swapRouter = new MockSwapRouter();
        swapRouter.setFactory(uniV3Factory);
        usdc.mint(address(swapRouter), 1_000_000e6);

        // A 2% Chainlink haircut, so the contract alone would accept 490 USDC for 1000 AERO.
        vm.prank(multisig);
        pol.setRoute(address(aero), address(aeroFeed), address(swapRouter), 500, 200, 100_000 ether, 0, 1 hours);
        aero.mint(address(pol), 1_000 ether);

        // The pool pays 492: inside the Chainlink bound, worse than the keeper's own quote.
        swapRouter.setRate(address(aero), address(usdc), 0.492e6, 1e18);

        vm.prank(stranger);
        vm.expectRevert(); // the router refuses its own amountOutMinimum
        pol.convert(address(aero), 495e6);

        // Without a floor the same fill is accepted, which is exactly the exposure M-01 names.
        vm.prank(stranger);
        (, uint256 out) = pol.convert(address(aero));
        assertEq(out, 492e6);
    }

    /// @notice M-01. The floor can only be raised, never used to widen the Chainlink bound.
    function test_M01_aCallerCannotWidenTheChainlinkBound() public {
        MockAggregatorV3 aeroFeed = new MockAggregatorV3(8, 0.5e8, "AERO / USD");
        MockSwapRouter swapRouter = new MockSwapRouter();
        swapRouter.setFactory(uniV3Factory);
        usdc.mint(address(swapRouter), 1_000_000e6);

        vm.prank(multisig);
        pol.setRoute(address(aero), address(aeroFeed), address(swapRouter), 500, 200, 100_000 ether, 0, 1 hours);
        aero.mint(address(pol), 1_000 ether);

        // A terrible fill, with the caller passing a floor of 1 wei to wave it through.
        swapRouter.setRate(address(aero), address(usdc), 0.01e6, 1e18);
        vm.prank(stranger);
        vm.expectRevert(); // the Chainlink minimum still applies
        pol.convert(address(aero), 1);
    }

    /// @notice M-02. `forwardIncome` moves the FULL balance of an income token to the
    ///         splitter, so an income token that was also a POL asset or the quote token
    ///         would turn a permissionless function into a drain of pairing inventory.
    function test_M02_incomeTokensAreDisjointFromPolAssetsAndTheQuote() public {
        vm.startPrank(multisig);

        vm.expectRevert(abi.encodeWithSelector(POLTreasury.TokenNotDisjoint.selector, address(usdc)));
        pol.setIncomeToken(address(usdc), true);

        vm.expectRevert(abi.encodeWithSelector(POLTreasury.TokenNotDisjoint.selector, address(nvda)));
        pol.setIncomeToken(address(nvda), true);

        vm.stopPrank();
    }

    /// @notice M-02, the other direction. Registering an income token as POL is refused too,
    ///         or the same overlap could be reached by doing it in the other order.
    function test_M02_theDisjointnessHoldsInBothDirections() public {
        MockAggregatorV3 feed = new MockAggregatorV3(8, 1e8, "AERO / USD");

        vm.startPrank(multisig);
        vm.expectRevert(abi.encodeWithSelector(POLTreasury.TokenNotDisjoint.selector, address(aero)));
        pol.setPolAsset(address(aero), address(feed), 500, 0);

        // And the quote token can never be a POL asset.
        vm.expectRevert(abi.encodeWithSelector(POLTreasury.TokenNotDisjoint.selector, address(usdc)));
        pol.setPolAsset(address(usdc), address(feed), 500, 0);
        vm.stopPrank();
    }

    /// @notice M-03. A donated position must not join the list `collectAllFees` walks.
    ///         Registration on receipt is limited to positions minted TO this contract.
    function test_M03_donatedPositionsAreNotAutoRegistered() public {
        MockERC20 junkA = new MockERC20("Junk A", "JA", 18);
        MockERC20 junkB = new MockERC20("Junk B", "JB", 18);
        junkA.mint(stranger, 1e18);
        junkB.mint(stranger, 1e18);

        vm.startPrank(stranger);
        junkA.approve(address(npm), type(uint256).max);
        junkB.approve(address(npm), type(uint256).max);
        (uint256 donated,,,) = npm.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(junkA),
                token1: address(junkB),
                tickSpacing: SPACING,
                tickLower: -887200,
                tickUpper: 887200,
                amount0Desired: 1e18,
                amount1Desired: 1e18,
                amount0Min: 0,
                amount1Min: 0,
                recipient: stranger,
                deadline: block.timestamp,
                sqrtPriceX96: 0
            })
        );
        npm.safeTransferFrom(stranger, address(pol), donated);
        vm.stopPrank();

        assertEq(npm.ownerOf(donated), address(pol), "the treasury does hold it");
        assertFalse(pol.holdsPosition(donated), "but it is not in the sweep");
        assertEq(pol.positionCount(), 0, "so the list cannot be grown by donation");
    }

    /// @notice M-03. A deliberate transfer in is still trackable, by the multisig.
    function test_M03_theMultisigCanRegisterADeliberateTransferIn() public {
        nvda.mint(address(pol), 10e8);
        usdc.mint(address(pol), 2_000e6);
        vm.prank(manager);
        (uint256 tokenId,,,) = pol.mintPosition(_mintParams(address(nvda), address(usdc), 10e8, 2_000e6));

        // Out and back, which loses the auto-registration.
        vm.prank(address(pol));
        npm.transferFrom(address(pol), stranger, tokenId);
        vm.prank(manager);
        pol.prunePosition(tokenId);
        assertFalse(pol.holdsPosition(tokenId));

        vm.prank(stranger);
        npm.safeTransferFrom(stranger, address(pol), tokenId);
        assertFalse(pol.holdsPosition(tokenId), "a transfer in does not self-register");

        vm.prank(multisig);
        pol.registerPosition(tokenId);
        assertTrue(pol.holdsPosition(tokenId));

        // Registering a real position somebody else owns is refused.
        vm.prank(address(pol));
        npm.transferFrom(address(pol), stranger, tokenId);
        vm.prank(manager);
        pol.prunePosition(tokenId);

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(POLTreasury.UnknownPosition.selector, tokenId));
        pol.registerPosition(tokenId);
    }

    /// @notice M-03. The list can shrink again, but only for a position genuinely gone.
    function test_M03_pruningRequiresThePositionToBeReallyGone() public {
        nvda.mint(address(pol), 10e8);
        usdc.mint(address(pol), 2_000e6);
        vm.prank(manager);
        (uint256 tokenId,,,) = pol.mintPosition(_mintParams(address(nvda), address(usdc), 10e8, 2_000e6));
        assertEq(pol.positionCount(), 1);

        // Still held here: refused.
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(POLTreasury.PositionStillHeld.selector, tokenId));
        pol.prunePosition(tokenId);

        // Staked in a gauge, so not held here but very much ours: also refused.
        MockGauge gauge = new MockGauge(address(npm), address(aero));
        voter.setGauge(pools[address(nvda)], address(gauge));
        vm.startPrank(manager);
        pol.stakePosition(tokenId, address(gauge));
        vm.expectRevert(abi.encodeWithSelector(POLTreasury.PositionStillHeld.selector, tokenId));
        pol.prunePosition(tokenId);

        // Genuinely gone: pruned.
        pol.unstakePosition(tokenId, address(gauge));
        vm.stopPrank();
        vm.prank(address(pol));
        npm.transferFrom(address(pol), stranger, tokenId);

        vm.prank(manager);
        pol.prunePosition(tokenId);
        assertEq(pol.positionCount(), 0);
        assertFalse(pol.holdsPosition(tokenId));
    }

    /// @notice LOW. The rescue names the position manager explicitly rather than relying on
    ///         an ERC-721 happening not to expose an ERC-20 transfer shape. That is a
    ///         property of somebody else's contract, not ours.
    function test_LOW_theRescueCannotTargetThePositionManager() public {
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(POLTreasury.ProtectedToken.selector, address(npm)));
        pol.recoverExcess(address(npm), rescueTo, 1);

        assertTrue(pol.isProtected(address(npm)));
    }

    /// @notice LOW. A POL asset with no feed cannot be registered at all, so the price band
    ///         can never be silently absent — the failure mode this repo already documents
    ///         once, in the `setCustodian` wiring trap.
    function test_LOW_aPolAssetCannotBeRegisteredWithoutAUsableFeed() public {
        MockERC20 tsla = new MockERC20("Tesla", "TSLAc", 8);
        MockAggregatorV3 feed = new MockAggregatorV3(8, 300e8, "TSLA / USD");

        vm.startPrank(multisig);
        vm.expectRevert(POLTreasury.ZeroAddress.selector);
        pol.setPolAsset(address(tsla), address(0), 500, 0);

        vm.expectRevert(POLTreasury.BadConfig.selector);
        pol.setPolAsset(address(tsla), address(feed), 0, 0); // a band of zero is not a band

        vm.expectRevert(POLTreasury.BadConfig.selector);
        pol.setPolAsset(address(tsla), address(feed), 1_001, 0); // nor is 10.01%
        vm.stopPrank();

        assertFalse(pol.isPolAsset(address(tsla)));
    }

    /// @notice Removing a POL asset also removes its protection from the rescue. That is a
    ///         real consequence of a single call, so it is asserted rather than assumed.
    function test_removingAPolAssetAlsoUnprotectsIt() public {
        assertTrue(pol.isProtected(address(nvda)));

        vm.prank(multisig);
        pol.removePolAsset(address(nvda));

        assertFalse(pol.isPolAsset(address(nvda)));
        assertFalse(pol.isProtected(address(nvda)));

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(POLTreasury.TokenNotPolAsset.selector, address(nvda)));
        pol.removePolAsset(address(nvda));
    }

    /// @notice A stale feed stops liquidity moving rather than letting it move on a price
    ///         nobody is standing behind. Equity feeds have no off-hours heartbeat, so this
    ///         is a live condition every weekend, not a hypothetical.
    function test_aStalePolFeedRefusesLiquidityOperations() public {
        MockERC20 msft = new MockERC20("Microsoft", "MSFTc", 8);
        MockAggregatorV3 feed = new MockAggregatorV3(8, int256(MARK_USD_1E8), "MSFT / USD");
        vm.prank(multisig);
        pol.setPolAsset(address(msft), address(feed), 500, 1 hours);
        clFactory.createPool(
            address(usdc), address(msft), SPACING, PoolMath.sqrtPriceX96For(address(msft), address(usdc), 8, MARK_QUOTE)
        );

        msft.mint(address(pol), 10e8);
        usdc.mint(address(pol), 2_000e6);
        skip(2 hours);

        vm.prank(manager);
        vm.expectPartialRevert(ConversionRoutes.StaleFeed.selector);
        pol.mintPosition(_mintParams(address(msft), address(usdc), 10e8, 2_000e6));
    }
}
