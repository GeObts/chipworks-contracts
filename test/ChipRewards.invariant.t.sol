// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChipRewardsBase} from "./ChipRewardsBase.t.sol";
import {ChipRounds} from "../src/ChipRounds.sol";
import {ChipClaims} from "../src/ChipClaims.sol";
import {Round, RoundState} from "../src/interfaces/IChipRounds.sol";

/// @dev Drives random sequences of the whole lifecycle: open, contribute, close, settle,
///      finalize, claim, freeze/unfreeze the hostile stock, expire, sweep, and rescue.
///      Every call is wrapped in try/catch because most orderings are legitimately
///      invalid — the point is that no ordering can break solvency.
contract RewardsHandler is Test {
    ChipRounds public rounds;
    ChipClaims public claims;
    ChipRewardsBase public fixtureRef;

    address[] public actors;
    address[] public stocks;
    address public multisig;
    address public rescueTo;

    uint256 public currentRound;

    constructor(
        ChipRounds rounds_,
        ChipClaims claims_,
        address multisig_,
        address[] memory actors_,
        address[] memory stocks_
    ) {
        rounds = rounds_;
        claims = claims_;
        multisig = multisig_;
        actors = actors_;
        stocks = stocks_;
        rescueTo = address(0xBEEF);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _stock(uint256 seed) internal view returns (address) {
        return stocks[seed % stocks.length];
    }

    function openRound(uint256 seed) external {
        vm.prank(_actor(seed));
        try rounds.openRound() returns (uint256 id) {
            currentRound = id;
        } catch {}
    }

    function contribute(uint256 seed, uint256 idSeed, uint256 collectionSeed) external {
        if (currentRound == 0) return;
        uint256[] memory ids = new uint256[](3);
        ids[0] = (idSeed % 6) + 1;
        ids[1] = (idSeed % 5) + 1;
        ids[2] = (seed % 6) + 1;
        address collection = collectionSeed % 2 == 0 ? fixtureCollectionA() : fixtureCollectionB();
        vm.prank(_actor(seed));
        try rounds.contributeWeights(currentRound, collection, ids) {} catch {}
    }

    function warp(uint256 seed) external {
        vm.warp(block.timestamp + (seed % 40 days) + 1 hours);
    }

    function closeAccumulation(uint256 seed) external {
        if (currentRound == 0) return;
        vm.prank(_actor(seed));
        try rounds.closeAccumulation(currentRound) {} catch {}
    }

    function settle(uint256 seed, uint256 stockSeed) external {
        if (currentRound == 0) return;
        vm.prank(_actor(seed));
        try rounds.settleStock(currentRound, _stock(stockSeed)) {} catch {}
    }

    function finalize(uint256 seed) external {
        if (currentRound == 0) return;
        vm.prank(_actor(seed));
        try rounds.finalizeRound(currentRound) {} catch {}
    }

    function claim(uint256 seed, uint256 roundSeed, uint256 stockSeed) external {
        uint256 total = rounds.roundCount();
        if (total == 0) return;
        uint256 id = (roundSeed % total) + 1;
        vm.prank(_actor(seed));
        try claims.claim(id, _stock(stockSeed)) {} catch {}
    }

    function sweep(uint256 roundSeed, uint256 stockSeed, uint256 batch) external {
        uint256 total = rounds.roundCount();
        if (total == 0) return;
        uint256 id = (roundSeed % total) + 1;
        try claims.sweepExpired(id, _stock(stockSeed), batch % 4) {} catch {}
    }

    /// @dev Randomly retune the claim schedule, so the invariants are exercised across
    ///      configurations rather than just the defaults.
    function reconfigureSchedule(uint32 w, uint32 d, uint64 e) external {
        w = uint32(1 days + (w % (29 days)));
        d = uint32(1 hours + (d % w));
        e = uint64(e % (365 days));
        vm.prank(multisig);
        try claims.setCreditExpiry(e) {} catch {}
        vm.prank(multisig);
        try claims.setClaimSchedule(w, d) {} catch {}
    }

    function toggleFreeze(uint256 seed) external {
        address target = seed % 3 == 0 ? address(claims) : _actor(seed);
        try fixtureFreezer().setBlacklisted(target, seed % 2 == 0) {} catch {}
    }

    function airdrop(uint256 seed, uint128 amount) external {
        fixtureMinter(_stock(seed), amount);
    }

    function rescue(uint256 seed, uint256 amount) external {
        address token = _stock(seed);
        vm.prank(multisig);
        try claims.recoverExcess(token, rescueTo, amount) {} catch {}
    }

    function cancelRound(uint256 roundSeed) external {
        uint256 total = rounds.roundCount();
        if (total == 0) return;
        try rounds.cancelRound((roundSeed % total) + 1) {} catch {}
    }

    function setAutoCompound(uint256 seed) external {
        vm.prank(_actor(seed));
        claims.setAutoCompound(seed % 2 == 0);
    }

    /* --- indirection so the handler can reach the fixture's mocks --- */
    function fixtureCollectionA() public view virtual returns (address) {}
    function fixtureCollectionB() public view virtual returns (address) {}
    function fixtureFreezer() public view virtual returns (IFreezer) {}
    function fixtureMinter(address token, uint128 amount) public virtual {}
}

interface IFreezer {
    function setBlacklisted(address account, bool b) external;
}

interface IMintable {
    function mint(address to, uint256 amount) external;
}

contract BoundHandler is RewardsHandler {
    address public colA;
    address public colB;
    address public freezerToken;

    constructor(
        ChipRounds r,
        ChipClaims c,
        address ms,
        address[] memory a,
        address[] memory s,
        address colA_,
        address colB_,
        address freezer_
    ) RewardsHandler(r, c, ms, a, s) {
        colA = colA_;
        colB = colB_;
        freezerToken = freezer_;
    }

    function fixtureCollectionA() public view override returns (address) {
        return colA;
    }

    function fixtureCollectionB() public view override returns (address) {
        return colB;
    }

    function fixtureFreezer() public view override returns (IFreezer) {
        return IFreezer(freezerToken);
    }

    function fixtureMinter(address token, uint128 amount) public override {
        try IMintable(token).mint(address(claims), amount) {} catch {}
    }
}

/// @notice THE invariant: whatever sequence of rounds, freezes, claims, sweeps, rescues
///         and time travel occurs, ChipRounds can always pay everyone it owes.
contract ChipRewardsInvariantTest is ChipRewardsBase {
    BoundHandler internal handler;

    function setUp() public override {
        super.setUp();

        // Six chipped Nouns across both collections, at assorted tiers.
        _chip(basedNouns, basedVault, 1, alice, 0);
        _chip(basedNouns, basedVault, 2, bob, 2);
        _chip(basedNouns, basedVault, 3, carol, 4);
        _chip(darkNouns, darkVault, 1, alice, 1);
        _chip(darkNouns, darkVault, 2, bob, 3);
        _chip(darkNouns, darkVault, 3, carol, 0);

        // Assorted splits, including one Noun with no split at all.
        _setSplit(address(basedNouns), 1, alice, _one(address(nvda)), _one(uint8(100)));
        _setSplit(address(basedNouns), 2, bob, _two(address(nvda), address(aapl)), _two(uint8(50), uint8(50)));
        _setSplit(address(basedNouns), 3, carol, _one(address(aapl)), _one(uint8(100)));
        _setSplit(address(darkNouns), 1, alice, _two(address(googl), address(aapl)), _two(uint8(30), uint8(70)));
        _setSplit(address(darkNouns), 2, bob, _one(address(googl)), _one(uint8(100)));

        // Exercise the POL holdback path too.
        vm.prank(multisig);
        rounds.setHoldbackBps(1_500);

        usdc.mint(address(pot), 500_000e6); // deep pot so rounds keep opening

        address[] memory actors = new address[](4);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;
        actors[3] = keeper;

        address[] memory stocks = new address[](4);
        stocks[0] = address(nvda);
        stocks[1] = address(googl);
        stocks[2] = address(aapl);
        stocks[3] = address(usdc);

        handler = new BoundHandler(
            rounds, claims, multisig, actors, stocks, address(basedNouns), address(darkNouns), address(aapl)
        );
        targetContract(address(handler));
    }

    /// @notice Solvency, per token. The LEDGER must always hold at least what it owes.
    /// @dev The split sharpens this: credits live in ChipClaims and nowhere else, so the
    ///      contract that owes is the contract that holds, with no engine balance mixed in.
    function invariant_alwaysSolvent() public view {
        assertGe(nvda.balanceOf(address(claims)), claims.totalOwed(address(nvda)), "NVDA");
        assertGe(googl.balanceOf(address(claims)), claims.totalOwed(address(googl)), "GOOGL");
        assertGe(aapl.balanceOf(address(claims)), claims.totalOwed(address(aapl)), "AAPL");
        assertGe(usdc.balanceOf(address(claims)), claims.totalOwed(address(usdc)), "USDC");
    }

    /// @notice A live round's committed budget is always backed by the engine's own balance.
    /// @dev Post-split this is two clean statements instead of one mixed one: the engine
    ///      holds budget in flight, the ledger holds credits, and neither can cover for the
    ///      other. Checked together with {invariant_alwaysSolvent}.
    function invariant_quoteCommitmentIsBacked() public view {
        assertGe(usdc.balanceOf(address(rounds)), rounds.committedQuote(), "engine over-committed");
    }

    /// @notice THE SCHEDULE GUARANTEE. However the config is retuned, every round that has
    ///         ever been finalized still reports at least three full claim windows between
    ///         its finalize and its expiry. A round's schedule is frozen when it finalizes,
    ///         so a later config change can never strand one.
    function invariant_everyRoundKeepsThreeClaimWindows() public view {
        uint256 total = rounds.roundCount();
        for (uint256 id = 1; id <= total; ++id) {
            ChipClaims.Schedule memory sch = claims.scheduleOf(id);
            if (sch.finalizedAt == 0) continue; // never finalized, or cancelled: no credits
            assertGe(claims.guaranteedWindows(id), 3, "round starved of claim windows");
            assertGe(sch.expiresAt, sch.finalizedAt, "expiry cannot precede finalize");
        }
    }

    /// @notice A frozen stock must never corrupt the accounting of a healthy one: NVDA and
    ///         GOOGL stay solvent no matter what AAPL does.
    function invariant_frozenStockDoesNotCorruptHealthyOnes() public view {
        assertGe(nvda.balanceOf(address(claims)), claims.totalOwed(address(nvda)), "NVDA vs AAPL freeze");
        assertGe(googl.balanceOf(address(claims)), claims.totalOwed(address(googl)), "GOOGL vs AAPL freeze");
    }
}
