// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
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
/// @dev Pyth's permissionless reveal (Entropy V2), not in the minimal IEntropyV2.
interface IEntropyReveal {
    function revealWithCallback(
        address provider,
        uint64 sequenceNumber,
        bytes32 userRandomNumber,
        bytes32 providerRevelation
    ) external;
}

/// @dev Entropy V2's Requested event as emitted on Base: its first data word is the user's
///      contribution (verified against live logs: Box request seq 584696, block 52359529).
bytes32 constant ENTROPY_REQUESTED_TOPIC =
    keccak256("Requested(address,address,uint64,bytes32,uint32,bytes)");

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
        vm.recordLogs();
        vm.prank(buyers[2]);
        raffle.buy(id, 20); // the last ticket: a REAL requestV2 on the real Entropy
        (bytes32 ourSeed, bytes32 entropyUser) = _seeds(vm.getRecordedLogs());
        assertTrue(ourSeed != bytes32(0));
        assertEq(entropyUser, ourSeed, "the REAL Entropy recorded our contract-mixed seed as the user contribution");

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

        vm.prank(SAFE);
        vm.expectRevert(); // RedrawNotReady: inside the 1h window
        raffle.retryDraw(id);

        vm.warp(block.timestamp + 1 hours);
        vm.prank(buyers[0]); // a ticket holder cannot force a re-roll
        vm.expectRevert(abi.encodeWithSelector(Raffle.NotAuthorized.selector, buyers[0]));
        raffle.retryDraw(id);
        vm.prank(SAFE);
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

    /// @dev Our DrawRequested seed, and the user contribution in the real Entropy's Requested log.
    function _seeds(Vm.Log[] memory logs) internal view returns (bytes32 ours, bytes32 entropys) {
        bytes32 drawRequested = Raffle.DrawRequested.selector;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(raffle) && logs[i].topics[0] == drawRequested) {
                (, ours) = abi.decode(logs[i].data, (uint128, bytes32));
            }
            if (logs[i].emitter == ENTROPY && logs[i].topics[0] == ENTROPY_REQUESTED_TOPIC) {
                entropys = abi.decode(logs[i].data, (bytes32));
            }
        }
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

/// @notice END TO END WITH THE REAL REVEAL. Forks Base one block before a real Entropy request
///         (Box open, provider seq 584696, block 52359529), so OUR draw is assigned that same
///         sequence. Its provider revelation is public (Entropy's Revealed log, block 52359532),
///         so the draw is completed through the REAL Entropy's permissionless revealWithCallback
///         — Entropy itself verifies the revelation against the provider's commitment chain and
///         calls our callback. Proves the seed is included: same provider revelation, our seed,
///         and the result is exactly keccak(ourSeed, revelation, 0) — not the real Box's number.
contract RaffleForkRealRevealTest is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant ENTROPY = 0x6E7D74FA7d5c90FEF9F0512987605a6d546181Bb;
    address constant REGISTRY = 0x5e4b6CbAc2D9b581428eE7f22E7bd4bf03675458;
    address constant POT = 0x3918a9B479Ce9B58238584c645079AB3bB49855B;
    address constant SAFE = 0xe1096B727499a3f70FaD8bc0267F5e69d01373C7;
    address constant NVDA = 0xb20000000000000000000078ee7ce2fE4908108C;
    address constant PROVIDER = 0x52DeaA1c84233F7bb8C8A45baeDE41091c616506;

    uint256 constant FORK_BLOCK = 52_359_528; // the real request is in 52,359,529
    uint64 constant SEQ = 584_696;
    /// @dev From Entropy's Revealed log for (PROVIDER, SEQ), block 52,359,532.
    bytes32 constant PROVIDER_REVELATION = 0x1a72d5312d0a2d72211999d4bd5745e1c05bc5c28ed0701fc1ff9c5c1b2db9d0;
    /// @dev The number real Base produced for that request, with the Box's user contribution.
    bytes32 constant REAL_BOX_RANDOM = 0x50cf3a69a2f185bf64e70fb024491823e6f87c1f5feaac1679ba34d0e1d843c7;

    Raffle raffle;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);
        vm.etch(NVDA, address(new EtchableERC20()).code);
        EtchableERC20(NVDA).init("NVIDIA Corporation", "NVDAc", 8);
        EtchableERC20(NVDA).mint(SAFE, 10e8);
        raffle = new Raffle(SAFE, USDC, ENTROPY, REGISTRY, POT, 24 hours);
        vm.deal(SAFE, 1 ether);
        vm.prank(SAFE);
        IERC20(NVDA).approve(address(raffle), type(uint256).max);
    }

    function test_fork_realReveal_seedIncluded_drawCompletes() public {
        uint256 reserve = raffle.requiredReserve();
        vm.prank(SAFE);
        uint256 id = raffle.createRaffle{value: reserve}(
            Raffle.Prize({kind: Raffle.PrizeKind.ERC20, token: NVDA, amountOrId: 1e8}), 10, SAFE
        ); // 11 tickets
        address[2] memory b = [makeAddr("real-reveal-0"), makeAddr("real-reveal-1")];
        for (uint256 i; i < 2; ++i) {
            deal(USDC, b[i], 100e6);
            vm.prank(b[i]);
            IERC20(USDC).approve(address(raffle), type(uint256).max);
        }
        vm.prank(b[0]);
        raffle.buy(id, 4);

        vm.recordLogs();
        vm.prank(b[1]);
        raffle.buy(id, 7); // last ticket: the real requestV2(provider, seed, gas)
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 seed;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(raffle) && logs[i].topics[0] == Raffle.DrawRequested.selector) {
                (, seed) = abi.decode(logs[i].data, (uint128, bytes32));
            }
        }
        Raffle.RaffleData memory r = raffle.getRaffle(id);
        assertEq(r.provider, PROVIDER);
        assertEq(r.sequence, SEQ, "our draw took the real request's sequence");
        assertTrue(seed != bytes32(0));

        // Anyone completes it with the public revelation; the REAL Entropy verifies it.
        IEntropyReveal(ENTROPY).revealWithCallback(PROVIDER, SEQ, seed, PROVIDER_REVELATION);

        r = raffle.getRaffle(id);
        assertEq(uint8(r.state), uint8(Raffle.State.Drawn), "the real Entropy ran our callback");
        bytes32 want = keccak256(abi.encodePacked(seed, PROVIDER_REVELATION, bytes32(0)));
        assertEq(r.randomNumber, want, "result = keccak(OUR seed, provider revelation, 0)");
        assertTrue(r.randomNumber != REAL_BOX_RANDOM, "our seed changed the number vs the Box's request");
        assertEq(r.winningTicket, uint64(uint256(want) % 11));

        raffle.settle(id);
        address winner = r.winningTicket < 4 ? b[0] : b[1];
        assertEq(raffle.getRaffle(id).winner, winner);
        assertEq(IERC20(NVDA).balanceOf(winner), 1e8, "prize paid");
        assertEq(IERC20(USDC).balanceOf(address(raffle)), 0, "all ticket money paid out");
        emit log_named_bytes32("seed", seed);
        emit log_named_bytes32("random", r.randomNumber);
        emit log_named_uint("winning ticket", r.winningTicket);
    }
}
