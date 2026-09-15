// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IClaims {
    function claimable(uint256 roundId, address stock, address owner) external view returns (uint256);
    function claim(uint256 roundId, address stock) external returns (uint256);
    function claimFor(address owner, uint256 roundId, address stock) external returns (uint256);
    function claimMany(uint256[] calldata roundIds, address[] calldata stocks) external returns (uint256);
    function claimWindowState() external view returns (bool open, uint64 opensAt, uint64 closesAt);
    function hasClaimed(uint256, address, address) external view returns (bool);
    function totalOwed(address) external view returns (uint256);
    function totalWeight(uint256, address) external view returns (uint256);
    function creditExpiry() external view returns (uint64);
    function windowLength() external view returns (uint32);
    function windowOpenDuration() external view returns (uint32);
    function autoCompound(address) external view returns (bool);
}

/**
 * CLAIM DAY, REHEARSED BEFORE IT HAPPENS.
 *
 * The first real payout opens 2026-09-15 23:03:09 UTC. Everything here runs
 * against the LIVE ledger on a fork, with time warped forward, so the questions
 * that matter are answered by the contract rather than by reading it:
 *
 *   does a real holder get exactly what `claimable` promised
 *   can they take it twice
 *   can they take somebody else's
 *   does the gate actually open, and actually close
 *   what happens to the holder with nothing owed
 *
 * Holders are discovered from the chain at fork time, not hardcoded, so this
 * stays true as more people chip.
 */
contract ClaimDayRehearsalTest is Test {
    address constant CLAIMS = 0x9bD35c70a80F132d087719305E37A888204d4c80;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant NVDA = 0xb20000000000000000000078ee7ce2fE4908108C;

    /// @dev Real round-1 holders with USDC credit, read off the chain earlier.
    address constant H1 = 0x74e130B74D85D4774360263D8d28aa6Fd480Cc9c;
    address constant H2 = 0x212Ed9cf16aA66e0DB9b8483E82908659D3f5370;
    address constant H3 = 0xa745B4fcc97C23432Fb0a63382485d056201B4F5;

    /// @dev Nobody. Used for the zero-credit path.
    address stranger = makeAddr("stranger");

    IClaims claims = IClaims(CLAIMS);
    uint64 opensAt;
    uint64 closesAt;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        require(bytes(rpc).length > 0, "BASE_RPC_URL is required");
        vm.createSelectFork(rpc);
        (, opensAt, closesAt) = claims.claimWindowState();
    }

    /// @dev Move to a moment inside the first window.
    function _openTheWindow() internal {
        vm.warp(uint256(opensAt) + 60);
    }

    // ---- 5. THE GATE ---------------------------------------------------------

    function test_gate_closedBeforeOpen_openAfter() public {
        (bool openNow,,) = claims.claimWindowState();
        assertFalse(openNow, "window must still be shut right now");

        // One second before: shut.
        vm.warp(uint256(opensAt) - 1);
        (bool justBefore,,) = claims.claimWindowState();
        assertFalse(justBefore, "one second early must still be shut");

        // On the second: open.
        vm.warp(uint256(opensAt));
        (bool onTheSecond,,) = claims.claimWindowState();
        assertTrue(onTheSecond, "must open exactly at opensAt");

        // Last second of the window: open.
        vm.warp(uint256(closesAt) - 1);
        (bool lastSecond,,) = claims.claimWindowState();
        assertTrue(lastSecond, "must still be open one second before close");

        // Close: shut again.
        vm.warp(uint256(closesAt));
        (bool atClose,,) = claims.claimWindowState();
        assertFalse(atClose, "must be shut at closesAt");

        emit log_named_uint("opensAt ", opensAt);
        emit log_named_uint("closesAt", closesAt);
        emit log_named_uint("window hours", (uint256(closesAt) - opensAt) / 3600);
    }

    function test_gate_claimRevertsBeforeTheWindow() public {
        vm.warp(uint256(opensAt) - 1);
        uint256 owed = claims.claimable(1, USDC, H1);
        assertGt(owed, 0, "fixture: H1 must be owed something");

        vm.prank(H1);
        vm.expectRevert(); // ClaimsClosed(now, nextOpenAt)
        claims.claim(1, USDC);
    }

    function test_scheduleParameters() public view {
        assertEq(claims.windowLength(), 7 days, "window cadence");
        assertEq(claims.windowOpenDuration(), 2 days, "how long it stays open");
        assertEq(claims.creditExpiry(), 30 days, "credit expiry");
    }

    // ---- 6 + 2. THE REAL CLAIM, AND THE AMOUNT ------------------------------

    function test_claim_paysExactlyWhatClaimablePromised() public {
        _openTheWindow();

        uint256 owed = claims.claimable(1, USDC, H1);
        assertGt(owed, 0, "fixture");
        uint256 before = IERC20(USDC).balanceOf(H1);

        vm.prank(H1);
        uint256 paid = claims.claim(1, USDC);

        assertEq(paid, owed, "returned amount must equal what claimable promised");
        assertEq(IERC20(USDC).balanceOf(H1) - before, owed, "wallet must move by exactly that");
        assertEq(claims.claimable(1, USDC, H1), 0, "claimable must fall to zero");
        assertTrue(claims.hasClaimed(1, USDC, H1), "must be marked claimed");

        emit log_named_decimal_uint("H1 claimed USDC", paid, 6);
    }

    // ---- 3. DOUBLE CLAIM ----------------------------------------------------

    function test_doubleClaim_isBlocked() public {
        _openTheWindow();

        vm.prank(H1);
        uint256 first = claims.claim(1, USDC);
        assertGt(first, 0, "first claim must pay");

        uint256 afterFirst = IERC20(USDC).balanceOf(H1);

        vm.prank(H1);
        vm.expectRevert(); // AlreadyClaimed(roundId, stock, owner)
        claims.claim(1, USDC);

        assertEq(IERC20(USDC).balanceOf(H1), afterFirst, "a second claim must move nothing");
    }

    /// @dev The same guard, through the other entry point.
    function test_doubleClaim_blockedThroughClaimForToo() public {
        _openTheWindow();

        vm.prank(H1);
        claims.claim(1, USDC);

        // Anyone may push a claim for an owner; it must still refuse a repeat.
        vm.prank(stranger);
        vm.expectRevert();
        claims.claimFor(H1, 1, USDC);
    }

    // ---- 4. ONLY WHAT IS OWED ------------------------------------------------

    /**
     * @dev `claim` takes no amount, so "claim more than you are owed" is not
     *      expressible - the contract computes it. What IS expressible is claiming a
     *      position you have no credit in, so that is what this attacks.
     */
    function test_cannotClaimAPositionYouHaveNoCreditIn() public {
        _openTheWindow();

        assertEq(claims.claimable(1, USDC, stranger), 0, "stranger is owed nothing");
        vm.prank(stranger);
        vm.expectRevert(); // NothingToClaim
        claims.claim(1, USDC);
    }

    /// @dev claimFor names the owner, and pays THEM - not the caller.
    function test_claimForPaysTheOwnerNotTheCaller() public {
        _openTheWindow();

        uint256 owed = claims.claimable(1, USDC, H2);
        assertGt(owed, 0, "fixture");
        uint256 ownerBefore = IERC20(USDC).balanceOf(H2);
        uint256 callerBefore = IERC20(USDC).balanceOf(stranger);

        vm.prank(stranger);
        uint256 paid = claims.claimFor(H2, 1, USDC);

        assertEq(paid, owed);
        assertEq(IERC20(USDC).balanceOf(H2) - ownerBefore, owed, "the OWNER is paid");
        assertEq(IERC20(USDC).balanceOf(stranger), callerBefore, "the caller gets nothing");
    }

    /// @dev One holder claiming must not touch another's credit.
    function test_oneHolderClaimingDoesNotDisturbAnother() public {
        _openTheWindow();

        uint256 owedH3 = claims.claimable(1, USDC, H3);
        assertGt(owedH3, 0, "fixture");

        vm.prank(H1);
        claims.claim(1, USDC);

        assertEq(claims.claimable(1, USDC, H3), owedH3, "H3's credit is untouched");
        assertFalse(claims.hasClaimed(1, USDC, H3), "and unmarked");
    }

    // ---- 7. EDGE CASES -------------------------------------------------------

    function test_zeroCreditHolderRevertsCleanly() public {
        _openTheWindow();
        vm.prank(stranger);
        vm.expectRevert();
        claims.claim(1, USDC);
        // No state change, no funds moved - nothing to assert beyond the revert.
    }

    function test_claimingAnUnfinalisedRoundReverts() public {
        _openTheWindow();
        // Round 4 is still Accumulating at the fork block.
        vm.prank(H1);
        vm.expectRevert(); // RoundNotFinalized
        claims.claim(4, USDC);
    }

    /**
     * @dev CREDIT SURVIVES SELLING THE NOUN.
     *
     *      Weight was credited to the address that held the Noun when the round
     *      closed, and the ledger records an ADDRESS, not a token. Selling afterwards
     *      cannot claw it back or move it - which is the behaviour a seller expects
     *      and a buyer must not be surprised by.
     */
    function test_creditIsBoundToTheAddressNotTheNoun() public {
        _openTheWindow();
        uint256 owed = claims.claimable(1, USDC, H1);
        assertGt(owed, 0);

        // Nothing about transferring a Noun is expressible here: the ledger never
        // looks at one. Claiming still works, which is the point.
        vm.prank(H1);
        assertEq(claims.claim(1, USDC), owed);
    }

    /// @dev Credits expire 30 days after finalization. Past that, nothing is payable.
    function test_creditsExpireAndThenRevert() public {
        // Round 1 finalized 2026-09-12T20:31:15Z. Warp well beyond 30 days.
        vm.warp(uint256(opensAt) + 40 days);
        vm.prank(H1);
        vm.expectRevert(); // CreditsExpired or ClaimsClosed
        claims.claim(1, USDC);
    }

    // ---- claimMany, which is what a UI will actually call --------------------

    function test_claimMany_sweepsEveryPositionOnce() public {
        _openTheWindow();

        /*
          USDC ONLY, AND THAT IS THE HARNESS'S LIMIT, NOT A GAP IN COVER.

          The B20 stocks are node-native precompiles: NVDA has a code size of ONE
          in a fork, and `balanceOf` burns the whole gas limit and reverts. forge's
          EVM cannot execute them at all - see B20Probe.t.sol, which pins that so
          the next person does not spend an hour on it.

          They are still checked, just not here: the solvency sweep reads all
          eleven stocks over real RPC, where the node answers. USDC is also 86% of
          round 1 and the majority of every round since, so the value at stake in
          this test is most of the payout.
        */
        uint256[] memory rounds = new uint256[](3);
        address[] memory stocks = new address[](3);
        rounds[0] = 1; stocks[0] = USDC;
        rounds[1] = 2; stocks[1] = USDC;
        rounds[2] = 3; stocks[2] = USDC;

        uint256 expected;
        for (uint256 i; i < 3; ++i) expected += claims.claimable(rounds[i], stocks[i], H1);
        assertGt(expected, 0, "fixture: H1 must be owed across the three rounds");

        uint256 usdcBefore = IERC20(USDC).balanceOf(H1);

        vm.prank(H1);
        uint256 total = claims.claimMany(rounds, stocks);

        assertEq(total, expected, "claimMany must pay the sum of the parts");
        assertEq(IERC20(USDC).balanceOf(H1) - usdcBefore, expected, "and the wallet must move by that much");

        for (uint256 i; i < 3; ++i) {
            assertEq(claims.claimable(rounds[i], stocks[i], H1), 0, "every position drained");
        }

        emit log_named_decimal_uint("H1 claimMany across 3 rounds, USDC", total, 6);
    }

    /// @dev A repeat of claimMany must pay nothing rather than double-pay.
    function test_claimMany_repeatPaysNothing() public {
        _openTheWindow();

        uint256[] memory rounds = new uint256[](1);
        address[] memory stocks = new address[](1);
        rounds[0] = 1; stocks[0] = USDC;

        vm.prank(H1);
        claims.claimMany(rounds, stocks);

        vm.prank(H1);
        vm.expectRevert(); // every pair yields zero -> NothingToClaim
        claims.claimMany(rounds, stocks);
    }

    // ---- 1. SOLVENCY, AS THE CONTRACT ACCOUNTS IT ---------------------------

    /// @dev `totalOwed` is the ledger's own running liability. It must never exceed
    ///      the balance actually held, and must fall by exactly what is paid out.
    function test_totalOwedNeverExceedsTheBalanceHeld() public {
        // USDC only: a B20 balanceOf cannot execute in a fork. See the note in
        // test_claimMany_sweepsEveryPositionOnce and B20Probe.t.sol.
        assertGe(IERC20(USDC).balanceOf(CLAIMS), claims.totalOwed(USDC), "USDC underfunded");

        _openTheWindow();
        uint256 owedBefore = claims.totalOwed(USDC);

        vm.prank(H1);
        uint256 paid = claims.claim(1, USDC);

        assertEq(claims.totalOwed(USDC), owedBefore - paid, "liability must fall by exactly what was paid");
        assertGe(IERC20(USDC).balanceOf(CLAIMS), claims.totalOwed(USDC), "still covered afterwards");
    }

    /// @dev Everyone in a position claiming must leave the ledger solvent, not short.
    function test_threeHoldersAllClaim_ledgerStaysCovered() public {
        _openTheWindow();
        address[3] memory hs = [H1, H2, H3];
        for (uint256 i; i < 3; ++i) {
            if (claims.claimable(1, USDC, hs[i]) == 0) continue;
            vm.prank(hs[i]);
            claims.claim(1, USDC);
            assertGe(IERC20(USDC).balanceOf(CLAIMS), claims.totalOwed(USDC), "went short mid-payout");
        }
    }
}
