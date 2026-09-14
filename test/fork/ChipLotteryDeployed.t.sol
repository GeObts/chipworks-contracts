// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ChipLottery, IMegapot} from "../../src/lottery/ChipLottery.sol";

interface IERC721Bal2 {
    function balanceOf(address) external view returns (uint256);
}

interface IMegapotView2 {
    function currentDrawingId() external view returns (uint256);
}

/**
 * The SAME contract, but the one that is actually on chain.
 *
 * -- WHY THIS EXISTS SEPARATELY FROM ChipLottery.t.sol ---------------------
 *
 * That suite deploys a fresh instance in `setUp` and proves the SOURCE is
 * correct. It cannot prove the DEPLOYMENT is: a constructor argument typed wrong
 * in the deploy script produces a contract that passes every test in that file
 * and is still wrong on chain. Nine of the ten arguments are immutable addresses,
 * and the ones that fail silently rather than loudly are the worst - a wrong
 * referrer pays somebody else for ever while working perfectly.
 *
 * So this binds to CHIP_LOTTERY from the environment, reads its immutables back
 * off the deployed code, and then buys a real ticket through it.
 *
 *   CHIP_LOTTERY=0x... BASE_RPC_URL=... \
 *     forge test --match-contract ChipLotteryDeployedTest -vv
 */
contract ChipLotteryDeployedTest is Test {
    address constant CHIP = 0x75Af968d2e58749FDA1b42C58186B76f5E511bA3;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant V3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant JACKPOT = 0x3bAe643002069dBCbcd62B1A4eb4C4A397d042a2;
    address constant TICKET_NFT = 0x48FfE35AbB9f4780a4f1775C2Ce1c46185b366e4;
    address constant HOOK = 0xBDF938149ac6a781F94FAa0ed45E6A0e984c6544;
    address constant REFERRER = 0x70D3a9aA7e10070d3F528e91c9bCf5158c922C66;
    address constant SAFE = 0xe1096B727499a3f70FaD8bc0267F5e69d01373C7;
    address constant V3_QUOTER = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a;

    ChipLottery lottery;
    address buyer = makeAddr("deployedBuyer");
    uint256 normalBallMax;
    uint256 bonusBallMax;
    uint256 wethFor1;

    uint256 constant MAX_CHIP_1 = 1_000_000 ether;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        require(bytes(rpc).length > 0, "BASE_RPC_URL is required");
        address deployed = vm.envOr("CHIP_LOTTERY", address(0));
        require(deployed != address(0), "CHIP_LOTTERY=<deployed address> is required");

        vm.createSelectFork(rpc);
        require(deployed.code.length > 0, "CHIP_LOTTERY has no code at this block");
        lottery = ChipLottery(deployed);

        (normalBallMax, bonusBallMax) = _ballMaxima();
        wethFor1 = _quoteWethFor(1_000_000);

        deal(CHIP, buyer, 50_000_000 ether);
        vm.prank(buyer);
        IERC20(CHIP).approve(address(lottery), type(uint256).max);
    }

    // ---- 1. the deployment matches the intent ------------------------------

    /// @dev Every immutable, read back off the deployed code rather than assumed
    ///      from the arguments the deploy script believed it passed.
    function test_deployedImmutablesAreCorrect() public view {
        assertEq(lottery.owner(), SAFE, "owner must be the Safe");
        assertEq(address(lottery.chip()), CHIP, "chip");
        assertEq(address(lottery.weth()), WETH, "weth");
        assertEq(address(lottery.usdc()), USDC, "usdc");
        assertEq(address(lottery.poolManager()), POOL_MANAGER, "poolManager");
        assertEq(address(lottery.v3Router()), V3_ROUTER, "v3Router");
        assertEq(address(lottery.jackpot()), JACKPOT, "jackpot");
        assertEq(lottery.referrer(), REFERRER, "REFERRER WRONG - fees would pay someone else for ever");
        assertEq(lottery.v3Fee(), uint24(500), "v3Fee");
        assertEq(lottery.currency0(), WETH, "currency0");
        assertEq(lottery.currency1(), CHIP, "currency1");
        assertEq(lottery.hooks(), HOOK, "hook");
        assertEq(lottery.tickSpacing(), int24(200), "tickSpacing");
        assertEq(lottery.poolFee(), uint24(8_388_608), "dynamic-fee flag");
        assertEq(lottery.chipIsCurrency0(), false, "ordering");
        assertEq(lottery.MAX_TICKETS(), 10, "ticket cap");
    }

    /// @dev It must be empty the moment it lands.
    function test_deployedHoldsNothing() public view {
        (uint256 c, uint256 w, uint256 u) = lottery.sweepZero();
        assertEq(c, 0, "CHIP");
        assertEq(w, 0, "WETH");
        assertEq(u, 0, "USDC");
    }

    // ---- 2. it actually works, as deployed ---------------------------------

    function test_deployedContractBuysARealTicket() public {
        uint256 chipBefore = IERC20(CHIP).balanceOf(buyer);
        IMegapot.Pick[] memory p = _picks(1);

        vm.prank(buyer);
        uint256 spent = lottery.buyWithChip(p, buyer, wethFor1, MAX_CHIP_1, block.timestamp + 300);

        assertEq(IERC721Bal2(TICKET_NFT).balanceOf(buyer), 1, "ticket minted to the buyer");
        assertEq(chipBefore - IERC20(CHIP).balanceOf(buyer), spent, "reported spend equals real spend");
        assertLt(spent, MAX_CHIP_1, "change came back");

        (uint256 c, uint256 w, uint256 u) = lottery.sweepZero();
        assertTrue(c == 0 && w == 0 && u == 0, "nothing left behind");

        emit log_named_decimal_uint("CHIP spent via the DEPLOYED contract", spent, 18);
    }

    /// @dev The guard that costs the most if the deployment somehow lacks it.
    function test_deployedRejectsSelfReferral() public {
        deal(CHIP, REFERRER, 5_000_000 ether);
        vm.prank(REFERRER);
        IERC20(CHIP).approve(address(lottery), type(uint256).max);
        IMegapot.Pick[] memory p = _picks(1);

        vm.prank(REFERRER);
        vm.expectRevert(abi.encodeWithSelector(ChipLottery.SelfReferral.selector, REFERRER));
        lottery.buyWithChip(p, REFERRER, wethFor1, MAX_CHIP_1, block.timestamp + 300);
    }

    function test_deployedCallbackIsClosed() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ChipLottery.NotPoolManager.selector, buyer));
        lottery.unlockCallback(abi.encode(uint256(1), uint256(1)));
    }

    // ---- helpers -----------------------------------------------------------

    /// @dev Maxima cached in setUp: a helper that calls out while building an
    ///      argument eats the vm.prank aimed at the call under test.
    function _picks(uint256 n) internal view returns (IMegapot.Pick[] memory p) {
        uint256 normalMax = normalBallMax;
        uint256 bonusMax = bonusBallMax;
        p = new IMegapot.Pick[](n);
        for (uint256 i; i < n; ++i) {
            uint8[] memory balls = new uint8[](5);
            for (uint256 b; b < 5; ++b) {
                balls[b] = uint8(1 + ((i + b) % normalMax));
            }
            for (uint256 a; a < 5; ++a) {
                for (uint256 c = a + 1; c < 5; ++c) {
                    if (balls[c] < balls[a]) (balls[a], balls[c]) = (balls[c], balls[a]);
                }
            }
            p[i] = IMegapot.Pick({balls: balls, bonusball: uint8(1 + (i % bonusMax))});
        }
    }

    /// @dev Word 9 and word 10 of thirteen unnamed ones, by offset. Destructuring all
    ///      thirteen blows the stack, and naming the other eleven would dress up
    ///      guesses as facts.
    function _ballMaxima() internal view returns (uint256 normalMax, uint256 bonusMax) {
        uint256 id = IMegapotView2(JACKPOT).currentDrawingId();
        (bool ok, bytes memory ret) = JACKPOT.staticcall(abi.encodeWithSignature("getDrawingState(uint256)", id));
        require(ok && ret.length >= 11 * 32, "getDrawingState failed");
        assembly {
            normalMax := mload(add(ret, add(32, mul(9, 32))))
            bonusMax := mload(add(ret, add(32, mul(10, 32))))
        }
        require(normalMax >= 5 && bonusMax >= 1, "implausible ball maxima - do not trust this run");
    }

    /// @dev Quoted, never written down. A frozen figure derived from chain state is a
    ///      slow-motion false alarm.
    function _quoteWethFor(uint256 usdcOut) internal returns (uint256) {
        (bool ok, bytes memory ret) = V3_QUOTER.call(
            abi.encodeWithSignature(
                "quoteExactOutputSingle((address,address,uint256,uint24,uint160))",
                WETH,
                USDC,
                usdcOut,
                uint24(500),
                uint160(0)
            )
        );
        require(ok && ret.length >= 32, "v3 exact-output quote failed");
        uint256 amountIn = abi.decode(ret, (uint256));
        require(amountIn > 0, "quoter returned zero");
        return (amountIn * 1005) / 1000;
    }
}
