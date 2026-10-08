// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Raffle} from "../../src/raffle/Raffle.sol";
import {IEntropyV2} from "../../src/interfaces/IEntropyV2.sol";
import {IStockRegistry} from "../../src/interfaces/IStockRegistry.sol";
import {EtchableERC20} from "../mocks/EtchableERC20.sol";

/// @notice The Raffle on a Base-mainnet fork: the REAL Pyth Entropy v2 (fee, provider, request,
///         request status), the REAL Circle USDC, the REAL StockRegistry (NVDAc must be enabled
///         there), the REAL Pot, and the REAL Safe as the house.
/// @dev    B20s cannot execute in a forked EVM (the Box's A-15/A-17), so NVDAc is etched with a
///         runnable ERC-20 at its real address — the registry check still runs against the real
///         registry. Entropy's reveal needs the provider's off-chain revelation, so it is
///         delivered AS Entropy (msg.sender == the real Entropy), exactly as BoxFork does.
///         Real-B20 transfers are proven separately with eth_simulateV1 on the live node.
contract RaffleForkTest is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant ENTROPY = 0x6E7D74FA7d5c90FEF9F0512987605a6d546181Bb;
    address constant REGISTRY = 0x5e4b6CbAc2D9b581428eE7f22E7bd4bf03675458;
    address constant POT = 0x3918a9B479Ce9B58238584c645079AB3bB49855B;
    address constant SAFE = 0xe1096B727499a3f70FaD8bc0267F5e69d01373C7;
    address constant NVDA = 0xb20000000000000000000078ee7ce2fE4908108C;

    Raffle raffle;
    address[3] buyers;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        assertTrue(IStockRegistry(REGISTRY).isEnabled(NVDA), "NVDAc is enabled in the real registry");
        vm.etch(NVDA, address(new EtchableERC20()).code);
        EtchableERC20(NVDA).init("NVIDIA Corporation", "NVDAc", 8);
        EtchableERC20(NVDA).mint(SAFE, 10e8);

        raffle = new Raffle(SAFE, USDC, ENTROPY, REGISTRY, POT, 1 hours);
        buyers = [makeAddr("fork-buyer-0"), makeAddr("fork-buyer-1"), makeAddr("fork-buyer-2")];
        for (uint256 i; i < 3; ++i) {
            deal(USDC, buyers[i], 500e6);
            vm.prank(buyers[i]);
            IERC20(USDC).approve(address(raffle), type(uint256).max);
        }
        vm.deal(SAFE, 1 ether);
        vm.prank(SAFE);
        IERC20(NVDA).approve(address(raffle), type(uint256).max);
    }

    function _create(uint64 base) internal returns (uint256 id) {
        uint256 reserve = raffle.requiredReserve(); // read before the prank
        vm.prank(SAFE);
        id = raffle.createRaffle{value: reserve}(
            Raffle.Prize({kind: Raffle.PrizeKind.ERC20, token: NVDA, amountOrId: 1e8}), base, SAFE
        );
    }

    function test_fork_fullCycle_realEntropyRealUsdc() public {
        uint128 liveFee = raffle.quoteDrawFee();
        emit log_named_uint("live Entropy fee (wei) at callbackGasLimit 200k", liveFee);
        assertGt(liveFee, 0);
        assertLt(liveFee, 0.001 ether, "fee is cents, as measured");

        uint256 id = _create(100); // 110 tickets
        uint256 reserve = raffle.getRaffle(id).ethReserve;
        assertEq(reserve, 3 * uint256(liveFee));

        vm.prank(buyers[0]);
        raffle.buy(id, 50);
        vm.prank(buyers[1]);
        raffle.buy(id, 40);
        uint256 entropyEthBefore = ENTROPY.balance;
        vm.prank(buyers[2]);
        raffle.buy(id, 20); // the last ticket: a REAL requestV2 on the real Entropy

        Raffle.RaffleData memory r = raffle.getRaffle(id);
        assertEq(uint8(r.state), uint8(Raffle.State.Drawing));
        assertEq(r.provider, IEntropyV2(ENTROPY).getDefaultProvider());
        assertEq(r.ethReserve, reserve - liveFee, "the real fee came out of the reserve");
        assertEq(ENTROPY.balance - entropyEthBefore, liveFee, "Entropy received exactly the fee");
        IEntropyV2.RequestV2 memory req = IEntropyV2(ENTROPY).getRequestV2(r.provider, r.sequence);
        assertEq(req.requester, address(raffle), "the real Entropy recorded our request");
        assertEq(req.callbackStatus, 1, "CALLBACK_NOT_STARTED");
        // The provider rounds the callback gas UP to its own minimum (500k on Base today) at the
        // same fee, so the callback gets at least what we asked for.
        assertGe(uint256(req.gasLimit10k) * 10_000, raffle.callbackGasLimit());
        emit log_named_uint("gas limit Entropy recorded for the callback", uint256(req.gasLimit10k) * 10_000);

        // Deliver the reveal as Entropy, landing on buyer 1's range (tickets 50-89).
        bytes32 rnd = bytes32(uint256(110) * 1_000_003 + 77);
        vm.prank(ENTROPY);
        raffle._entropyCallback(r.sequence, r.provider, rnd);
        assertEq(raffle.getRaffle(id).winningTicket, 77);

        uint256 potBefore = IERC20(USDC).balanceOf(POT);
        uint256 safeBefore = IERC20(USDC).balanceOf(SAFE);
        raffle.settle(id);
        assertEq(raffle.getRaffle(id).winner, buyers[1]);
        assertEq(IERC20(NVDA).balanceOf(buyers[1]), 1e8, "prize to the winner");
        assertEq(IERC20(USDC).balanceOf(POT) - potBefore, 10e6, "fee tickets to the real Pot");
        assertEq(IERC20(USDC).balanceOf(SAFE) - safeBefore, 100e6, "base to the Safe");
        assertEq(IERC20(USDC).balanceOf(address(raffle)), 0);

        uint256 safeEth = SAFE.balance;
        raffle.withdrawEth(SAFE);
        assertEq(SAFE.balance - safeEth, reserve - liveFee, "leftover reserve back to the Safe");
    }

    function test_fork_retryDraw_againstRealEntropyStatus() public {
        uint256 id = _create(10);
        vm.prank(buyers[0]);
        raffle.buy(id, 11);
        Raffle.RaffleData memory r = raffle.getRaffle(id);

        vm.expectRevert(); // RedrawNotReady: inside the 1h window
        raffle.retryDraw(id);

        vm.warp(block.timestamp + 1 hours);
        raffle.retryDraw(id); // real getRequestV2 says CALLBACK_NOT_STARTED -> fresh request
        Raffle.RaffleData memory r2 = raffle.getRaffle(id);
        assertGt(r2.sequence, r.sequence);
        assertEq(uint8(r2.state), uint8(Raffle.State.Drawing));

        // The superseded request is an orphan even when delivered by the real Entropy.
        vm.prank(ENTROPY);
        raffle._entropyCallback(r.sequence, r.provider, bytes32(uint256(1)));
        assertEq(uint8(raffle.getRaffle(id).state), uint8(Raffle.State.Drawing));
        vm.prank(ENTROPY);
        raffle._entropyCallback(r2.sequence, r2.provider, bytes32(uint256(5)));
        assertEq(uint8(raffle.getRaffle(id).state), uint8(Raffle.State.Drawn));
        assertEq(raffle.getRaffle(id).winningTicket, 5);
    }

    function test_fork_onlyTheSafeCreates() public {
        address stranger = makeAddr("stranger");
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert();
        raffle.createRaffle{value: 0.01 ether}(
            Raffle.Prize({kind: Raffle.PrizeKind.ERC20, token: NVDA, amountOrId: 1}), 10, stranger
        );
    }
}
