// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BoxTestBase} from "./BoxTestBase.sol";
import {Box} from "../../src/box/Box.sol";
import {PrizeVault} from "../../src/box/PrizeVault.sol";
import {Venue} from "../../src/interfaces/IStockRegistry.sol";
import {BlacklistToken} from "../mocks/HostileTokens.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Vm} from "forge-std/Test.sol";

/// @notice Audit round 3 (Grok on 81c7e2e). See audit/box-2026-09-24/TRIAGE-ROUND2.md, part 3.
contract BoxAuditRound3Test is BoxTestBase {
    /* ---------------- BOX-R3-L1: two refusals, then OWED, then claimOwed pays ---------------- */

    /// @dev Grok scenario H. Stocks [A, B, C]: A and B refuse the opener, C would pay, and the vault
    ///      holds no USDC to fall back on. Inside the gas-bounded callback the walk stops after A and
    ///      B, so the box goes OWED. {claimOwed} is an ordinary transaction and walks every stock,
    ///      so it pays in C. Before the fix, claimOwed stopped at the same two refusals every time.
    function test_R3L1_twoRefusalsGoOwed_thenClaimOwedPaysTheThirdStock() public {
        (Box b, PrizeVault v,) = _newWiredPair(0);
        BlacklistToken a = _refusing(v);
        BlacklistToken bb = _refusing(v);
        MockERC20 c = new MockERC20("Accepts", "OK", 8);
        _list(v, address(c));
        c.mint(address(v), 10e8);
        assertEq(v.stockAt(0), address(a));
        assertEq(v.stockAt(1), address(bb));

        // A box whose claimOwed walk ALSO starts on A (claimOwed seeds with keccak(id, sequence)),
        // so the claim has to get past both refusals to reach C.
        (uint256 id, uint64 seq) = _openUntilClaimStartsAt(b, v, 0);
        deal(address(usdc), address(v), 0); // those extra buys paid in USDC: no USDC fallback

        entropy.fulfill(seq, _tier2RollStartingAt(v, 0)); // the walk starts on A: A, B, then stop
        assertEq(b.boxInfo(id).state, b.STATE_OWED(), "two refusals and no USDC: OWED at $1");
        assertEq(c.balanceOf(alice), 0);

        uint256 liab0 = b.outstandingLiabilityUsd();
        vm.prank(bob); // anyone can push it
        b.claimOwed(id);
        assertEq(c.balanceOf(alice), 1e6, "claimOwed walks past the refusals: $1 of C at $100");
        assertEq(liab0 - b.outstandingLiabilityUsd(), 1e6, "the $1 owed is off the books");
    }

    /// @dev The cap is the callback's alone: claimOwed with every stock refusing tries them ALL,
    ///      then USDC, and stays OWED only if nothing can pay.
    function test_R3L1_claimOwedTriesEveryStock() public {
        (Box b, PrizeVault v,) = _newWiredPair(0);
        for (uint256 i; i < 5; ++i) _refusing(v);

        vm.prank(alice);
        uint256 id = b.buyWithUsdc(SKU1, alice);
        uint128 fee = b.quoteOpenFee();
        vm.prank(alice);
        b.open{value: fee}(id);
        vm.recordLogs();
        entropy.fulfill(b.boxInfo(id).sequence, _tier2RollStartingAt(v, 0));
        assertEq(_refusals(), 2, "the callback stops after two");
        assertEq(b.boxInfo(id).state, b.STATE_OWED());

        vm.expectRevert(abi.encodeWithSelector(Box.StillUnpayable.selector, id, 1e6));
        b.claimOwed(id);

        usdc.mint(address(v), 1e6); // USDC arrives: the claim pays in full
        uint256 u0 = usdc.balanceOf(alice);
        vm.recordLogs();
        b.claimOwed(id);
        assertEq(_refusals(), 5, "claimOwed tried all five stocks before USDC");
        assertEq(usdc.balanceOf(alice) - u0, 1e6, "paid $1 in USDC");
    }

    /* ---------------- BOX-L6 cold, under the real callback gas cap ---------------- */

    /// @dev Grok R3-I3(3): the L6 test ran warm, through the uncapped mock. This one delivers the
    ///      callback the way Pyth does, with exactly `callbackGasLimit` gas and every touched account
    ///      cold. 16 stocks: one refuses, fourteen are too thin, the last pays (Grok's worst case, G),
    ///      and all sixteen refuse with no USDC (two tries, then OWED).
    function test_L6_coldCallbackUnderTheGasCap_worstCases() public {
        (uint256 gasG, uint8 stateG) = _coldCase(1, 14);
        assertEq(stateG, 0, "G: paid (box retired)");
        (uint256 gasC, uint8 stateC) = _coldCase(16, 0);
        assertEq(stateC, 3, "all refuse, no USDC: OWED");
        emit log_named_uint("G: 1 refuse + 14 thin + pay, cold, mock gas", gasG);
        emit log_named_uint("all 16 refuse -> OWED, cold, mock gas", gasC);
        assertLt(gasG, 900_000);
        assertLt(gasC, 900_000);
    }

    /* ---------------- helpers ---------------- */

    function _refusals() internal returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("StockSkipped(address,bytes32)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 3 && logs[i].topics[0] == sig && logs[i].topics[2] == bytes32("transfer")) ++n;
        }
    }

    /// @dev Buys and opens $1 boxes until one's claimOwed walk would start at stock `idx`.
    function _openUntilClaimStartsAt(Box b, PrizeVault v, uint256 idx) internal returns (uint256 id, uint64 seq) {
        uint256 n = v.stockCount();
        for (uint256 j; j < 50; ++j) {
            vm.prank(alice);
            id = b.buyWithUsdc(SKU1, alice);
            uint128 fee = b.quoteOpenFee();
            vm.prank(alice);
            b.open{value: fee}(id);
            seq = b.boxInfo(id).sequence;
            bytes32 seed = keccak256(abi.encode(id, seq));
            if (uint256(keccak256(abi.encode(seed))) % n == idx) return (id, seq);
        }
        revert("no box starts there");
    }

    function _coldCase(uint256 refusing, uint256 thin) internal returns (uint256 used, uint8 state) {
        (Box b, PrizeVault v,) = _newWiredPair(0);
        address[] memory touched = new address[](16);
        uint256 t;
        for (uint256 i; i < refusing; ++i) touched[t++] = address(_refusing(v));
        for (uint256 i; i < thin; ++i) {
            MockERC20 x = new MockERC20("Thin", "THN", 8);
            _list(v, address(x));
            x.mint(address(v), 1); // far too little for a $1 prize
            touched[t++] = address(x);
        }
        if (t < 16) {
            MockERC20 last = new MockERC20("Pays", "PAY", 8);
            _list(v, address(last));
            last.mint(address(v), 10e8);
            touched[t++] = address(last);
        }
        // Enough stock value that the $1 prize is under the cap even with no USDC.
        vm.prank(alice);
        uint256 id = b.buyWithUsdc(SKU1, alice);
        uint128 fee = b.quoteOpenFee();
        vm.prank(alice);
        b.open{value: fee}(id);
        uint64 seq = b.boxInfo(id).sequence;
        bytes32 rand = _tier2RollStartingAt(v, 0);

        for (uint256 i; i < t; ++i) vm.cool(touched[i]);
        vm.cool(address(b));
        vm.cool(address(v));
        vm.cool(address(usdc));
        vm.cool(address(registry));
        vm.cool(alice);

        uint32 cap = b.callbackGasLimit();
        vm.prank(address(entropy));
        uint256 g0 = gasleft();
        (bool ok,) = address(b).call{gas: cap}(abi.encodeCall(Box._entropyCallback, (seq, address(entropy), rand)));
        used = g0 - gasleft();
        assertTrue(ok, "the callback completes within callbackGasLimit");
        state = b.boxInfo(id).state;
    }

    function _refusing(PrizeVault v) internal returns (BlacklistToken x) {
        x = new BlacklistToken("Blocked", "BLK", 8);
        _list(v, address(x));
        x.mint(address(v), 10e8); // $1,000
        x.setBlacklisted(alice, true);
    }

    function _list(PrizeVault v, address token) internal {
        registry.setStock(token, Venue.Slipstream, 0, 10, 8, true);
        registry.setPrice(token, 100e18);
        vm.prank(multisig);
        v.addStock(token);
    }

    /// @dev A tier-2 ($1 on SKU1) roll whose hashed walk starts at stock `idx` of `v`.
    function _tier2RollStartingAt(PrizeVault v, uint256 idx) internal view returns (bytes32 r) {
        uint256 n = v.stockCount();
        for (uint256 j;; ++j) {
            r = bytes32(7_500 + 10_000 * j);
            if (uint256(keccak256(abi.encode(r))) % n == idx) return r;
        }
    }
}
