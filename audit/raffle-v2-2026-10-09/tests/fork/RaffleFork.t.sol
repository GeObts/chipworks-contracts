// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Raffle} from "../../src/raffle/Raffle.sol";
import {IEntropyV2} from "../../src/interfaces/IEntropyV2.sol";
import {IStockRegistry} from "../../src/interfaces/IStockRegistry.sol";

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
bytes32 constant ENTROPY_REQUESTED_TOPIC = keccak256("Requested(address,address,uint64,bytes32,uint32,bytes)");

address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
address constant ENTROPY = 0x6E7D74FA7d5c90FEF9F0512987605a6d546181Bb;
address constant REGISTRY = 0x5e4b6CbAc2D9b581428eE7f22E7bd4bf03675458;
address constant POT = 0x3918a9B479Ce9B58238584c645079AB3bB49855B;
address constant SAFE = 0xe1096B727499a3f70FaD8bc0267F5e69d01373C7;
address constant ROUTER = 0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F;
address constant NVDA = 0xb20000000000000000000078ee7ce2fE4908108C;
address constant NVDA_POOL = 0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9;

/// @notice Raffle v2 on a Base-mainnet fork against the REAL StockRegistry, Slipstream factory,
///         pools and pool oracles, router, Pyth Entropy v2, Circle USDC, Pot and Safe.
/// @dev    WHAT A FORGE FORK CANNOT DO: execute a B20 stock (the Box's A-15/A-17: the opcode
///         they use is missing in forge/anvil), so the real SWAP cannot run here — a pool's
///         token transfer reverts. The real swap is proven with eth_simulateV1 on the live node
///         (tools/raffle/raffle-live-sim.cjs). Everything around it runs here for real: pool
///         identity checks, the real TWAP read, the price maths against the real pools, the
///         keeper/owner gate, the USDC fallback, and the real seeded Entropy draw.
contract RaffleForkTest is Test {
    Raffle raffle;
    address keeperAcct = makeAddr("fork-keeper");
    address[3] buyers;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        raffle = new Raffle(SAFE, USDC, ENTROPY, REGISTRY, POT, ROUTER, 24 hours, 6 hours);
        vm.prank(SAFE);
        raffle.setKeeper(keeperAcct);
        buyers = [makeAddr("fork-buyer-0"), makeAddr("fork-buyer-1"), makeAddr("fork-buyer-2")];
        for (uint256 i; i < 3; ++i) {
            deal(USDC, buyers[i], 5_000e6);
            vm.prank(buyers[i]);
            IERC20(USDC).approve(address(raffle), type(uint256).max);
        }
        vm.deal(SAFE, 1 ether);
    }

    function _create(address stock, uint64 base) internal returns (uint256 id) {
        uint256 reserve = raffle.requiredReserve(); // read before the prank
        vm.prank(SAFE);
        id = raffle.createRaffle{value: reserve}(stock, base);
    }

    /// @dev Every enabled stock passes the real pool checks and the real 30-min TWAP read, and
    ///      the TWAP-priced quote for $1,000 lands within 5% of the stock's Chainlink mark (a
    ///      sanity cross-check ONLY here in the test; the contract never reads Chainlink).
    function test_fork_everyEnabledStock_isRaffleable_andPricedSanely() public {
        address[] memory tokens = IStockRegistry(REGISTRY).enabledTokens();
        assertGt(tokens.length, 0);
        for (uint256 i; i < tokens.length; ++i) {
            uint256 id = _create(tokens[i], 1_000);
            Raffle.RaffleData memory r = raffle.getRaffle(id);
            assertEq(r.pool, IStockRegistry(REGISTRY).getStock(tokens[i]).pool);

            uint256 quoted = raffle.quotePrize(tokens[i], 1_000e6);
            (uint256 price1e18,) = IStockRegistry(REGISTRY).priceUsd(tokens[i]);
            uint8 dec = IStockRegistry(REGISTRY).getStock(tokens[i]).tokenDecimals;
            uint256 viaChainlink = (1_000e18 * (10 ** dec)) / price1e18;
            emit log_named_address("stock", tokens[i]);
            emit log_named_uint("  TWAP quote for $1,000 (raw)", quoted);
            emit log_named_uint("  Chainlink-implied (raw)    ", viaChainlink);
            assertApproxEqRel(quoted, viaChainlink, 0.05e18, "TWAP quote within 5% of Chainlink");
        }
    }

    function test_fork_buyOut_fallback_realSeededEntropy_settlesInUsdc() public {
        uint256 id = _create(NVDA, 100); // 110 tickets
        assertEq(raffle.getRaffle(id).pool, NVDA_POOL);
        vm.prank(buyers[0]);
        raffle.buy(id, 50);
        vm.prank(buyers[1]);
        raffle.buy(id, 40);
        vm.prank(buyers[2]);
        raffle.buy(id, 20);
        assertEq(uint8(raffle.getRaffle(id).state), uint8(Raffle.State.SoldOut));

        // A ticket holder can neither buy the prize nor fall back early.
        vm.prank(buyers[0]);
        vm.expectRevert(abi.encodeWithSelector(Raffle.NotAuthorized.selector, buyers[0]));
        raffle.acquirePrize(id);
        vm.expectRevert();
        raffle.fallbackToUsdc(id);

        // FORK LIMIT: the real swap reverts here (B20 cannot execute in forge). It must refuse
        // cleanly and move nothing — exactly what a failing swap does on mainnet.
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(raffle));
        vm.prank(keeperAcct);
        vm.expectRevert();
        raffle.acquirePrize(id);
        assertEq(IERC20(USDC).balanceOf(address(raffle)), usdcBefore);
        assertEq(IERC20(USDC).allowance(address(raffle), ROUTER), 0);

        // After 6 h anyone falls back: the prize is the $100 already held; the REAL Entropy is asked.
        vm.warp(block.timestamp + 6 hours);
        uint256 entropyEthBefore = ENTROPY.balance;
        vm.recordLogs();
        raffle.fallbackToUsdc(id);
        (bytes32 ourSeed, bytes32 entropyUser) = _seeds(vm.getRecordedLogs());
        Raffle.RaffleData memory r = raffle.getRaffle(id);
        assertEq(uint8(r.state), uint8(Raffle.State.Drawing));
        assertEq(uint8(r.prize.kind), uint8(Raffle.PrizeKind.Usdc));
        assertTrue(ourSeed != bytes32(0));
        assertEq(entropyUser, ourSeed, "the REAL Entropy recorded our contract-mixed seed");
        uint128 liveFee = raffle.quoteDrawFee();
        assertEq(ENTROPY.balance - entropyEthBefore, liveFee, "Entropy received exactly the fee");
        IEntropyV2.RequestV2 memory req = IEntropyV2(ENTROPY).getRequestV2(r.provider, r.sequence);
        assertEq(req.requester, address(raffle));
        assertEq(req.callbackStatus, 1, "CALLBACK_NOT_STARTED");

        vm.prank(ENTROPY);
        raffle._entropyCallback(r.sequence, r.provider, bytes32(uint256(110) * 1_000_003 + 77));
        uint256 potBefore = IERC20(USDC).balanceOf(POT);
        uint256 winnerBefore = IERC20(USDC).balanceOf(buyers[1]);
        raffle.settle(id);
        assertEq(raffle.getRaffle(id).winner, buyers[1], "ticket 77 is buyer 1's");
        assertEq(IERC20(USDC).balanceOf(buyers[1]) - winnerBefore, 100e6, "the $100 prize in real USDC");
        assertEq(IERC20(USDC).balanceOf(POT) - potBefore, 10e6, "the fee on top to the real Pot");
        assertEq(IERC20(USDC).balanceOf(address(raffle)), 0);
        assertEq(raffle.ethOwed(SAFE), r.ethReserve, "leftover reserve to the creator (the Safe)");
    }

    function test_fork_retryDraw_ownerOrKeeper_againstRealEntropyStatus() public {
        uint256 id = _create(NVDA, 10);
        vm.prank(buyers[0]);
        raffle.buy(id, 11);
        vm.warp(block.timestamp + 6 hours);
        raffle.fallbackToUsdc(id);
        Raffle.RaffleData memory r = raffle.getRaffle(id);

        vm.prank(keeperAcct);
        vm.expectRevert(); // RedrawNotReady: inside the 24 h window
        raffle.retryDraw(id);

        vm.warp(block.timestamp + 24 hours);
        vm.prank(buyers[0]); // a ticket holder cannot force a re-roll
        vm.expectRevert(abi.encodeWithSelector(Raffle.NotAuthorized.selector, buyers[0]));
        raffle.retryDraw(id);
        vm.prank(keeperAcct);
        raffle.retryDraw(id); // real getRequestV2 says CALLBACK_NOT_STARTED -> fresh request
        Raffle.RaffleData memory r2 = raffle.getRaffle(id);
        assertGt(r2.sequence, r.sequence);

        vm.prank(ENTROPY);
        raffle._entropyCallback(r.sequence, r.provider, bytes32(uint256(1)));
        assertEq(uint8(raffle.getRaffle(id).state), uint8(Raffle.State.Drawing), "superseded = orphan");
        vm.prank(ENTROPY);
        raffle._entropyCallback(r2.sequence, r2.provider, bytes32(uint256(5)));
        assertEq(raffle.getRaffle(id).winningTicket, 5);
    }

    function test_fork_onlyTheSafeCreates() public {
        address stranger = makeAddr("stranger");
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert();
        raffle.createRaffle{value: 0.01 ether}(NVDA, 10);
    }

    /// @dev Our DrawRequested seed, and the user contribution in the real Entropy's Requested log.
    function _seeds(Vm.Log[] memory logs) internal view returns (bytes32 ours, bytes32 entropys) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(raffle) && logs[i].topics[0] == Raffle.DrawRequested.selector) {
                (, ours) = abi.decode(logs[i].data, (uint128, bytes32));
            }
            if (logs[i].emitter == ENTROPY && logs[i].topics[0] == ENTROPY_REQUESTED_TOPIC) {
                entropys = abi.decode(logs[i].data, (bytes32));
            }
        }
    }
}

/// @notice END TO END WITH THE REAL REVEAL. Forks Base one block before a real Entropy request
///         (Box open, provider seq 584696, block 52359529), so OUR draw is assigned that same
///         sequence. The raffle is created against the real NVDAc pool (TWAP read at that
///         block), sold out, falls back to USDC (the swap cannot run in forge), and its draw is
///         completed through the REAL Entropy's permissionless revealWithCallback with the
///         public provider revelation: Entropy verifies it against the provider's commitment
///         chain and calls our callback. Result = keccak(ourSeed, revelation, 0).
contract RaffleForkRealRevealTest is Test {
    address constant PROVIDER = 0x52DeaA1c84233F7bb8C8A45baeDE41091c616506;
    uint256 constant FORK_BLOCK = 52_359_528;
    uint64 constant SEQ = 584_696;
    bytes32 constant PROVIDER_REVELATION = 0x1a72d5312d0a2d72211999d4bd5745e1c05bc5c28ed0701fc1ff9c5c1b2db9d0;
    bytes32 constant REAL_BOX_RANDOM = 0x50cf3a69a2f185bf64e70fb024491823e6f87c1f5feaac1679ba34d0e1d843c7;

    Raffle raffle;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);
        raffle = new Raffle(SAFE, USDC, ENTROPY, REGISTRY, POT, ROUTER, 24 hours, 6 hours);
        vm.deal(SAFE, 1 ether);
    }

    function test_fork_realReveal_seedIncluded_drawCompletes() public {
        uint256 reserve = raffle.requiredReserve();
        vm.prank(SAFE);
        uint256 id = raffle.createRaffle{value: reserve}(NVDA, 10); // 11 tickets, real pool + TWAP
        address[2] memory b = [makeAddr("real-reveal-0"), makeAddr("real-reveal-1")];
        for (uint256 i; i < 2; ++i) {
            deal(USDC, b[i], 100e6);
            vm.prank(b[i]);
            IERC20(USDC).approve(address(raffle), type(uint256).max);
        }
        vm.prank(b[0]);
        raffle.buy(id, 4);
        vm.prank(b[1]);
        raffle.buy(id, 7);
        vm.warp(block.timestamp + 6 hours);

        vm.recordLogs();
        raffle.fallbackToUsdc(id); // the real requestV2(provider, seed, gas)
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

        IEntropyReveal(ENTROPY).revealWithCallback(PROVIDER, SEQ, seed, PROVIDER_REVELATION);

        r = raffle.getRaffle(id);
        assertEq(uint8(r.state), uint8(Raffle.State.Drawn), "the real Entropy ran our callback");
        bytes32 want = keccak256(abi.encodePacked(seed, PROVIDER_REVELATION, bytes32(0)));
        assertEq(r.randomNumber, want, "result = keccak(OUR seed, provider revelation, 0)");
        assertTrue(r.randomNumber != REAL_BOX_RANDOM, "our seed changed the number vs the Box's request");

        raffle.settle(id);
        address winner = r.winningTicket < 4 ? b[0] : b[1];
        assertEq(raffle.getRaffle(id).winner, winner);
        assertEq(IERC20(USDC).balanceOf(address(raffle)), 0, "all ticket money paid out");
        emit log_named_bytes32("seed", seed);
        emit log_named_bytes32("random", r.randomNumber);
        emit log_named_uint("winning ticket", r.winningTicket);
    }
}
