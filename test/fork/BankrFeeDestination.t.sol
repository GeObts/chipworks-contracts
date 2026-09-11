// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IBankr {
    function collectFees(bytes32 poolId) external returns (uint256 fees0, uint256 fees1);
    function getShares(bytes32 poolId, address who) external view returns (uint256);
}

/// @notice WHERE DOES THE BANKR FEE STREAM ACTUALLY LAND?
///
/// @dev This cannot be answered by simulating `collectFees` and reading its return value.
///      That number is the amount PULLED FROM THE POOL, and it is identical no matter who
///      calls — keeper, Safe, FeeSplitter and 0xdEaD all simulate to the same 1.057 WETH.
///      Reading it as "what the caller receives" is the exact mistake that produced a wrong
///      answer about this fee stream once already.
///
///      `debug_traceCall` would settle it, and is not available on the RPC's free tier. So
///      this executes the call for real against a fork and MEASURES BALANCE DELTAS, which is
///      the only evidence that cannot be misread.
contract BankrFeeDestinationForkTest is Test {
    address constant DIST = 0x9982538F41f2ae29ddb9d3D9307010052984FDbB;
    address constant SPLITTER = 0xb9b76e1835afE05e5A73065FE01A19B14869F8A3;
    address constant SAFE = 0xe1096B727499a3f70FaD8bc0267F5e69d01373C7;
    address constant KEEPER = 0x6571E3412553Fada40C3D96e61E7Cfd20A0695B9;
    address constant WETH = 0x4200000000000000000000000000000000000006;

    bytes32 constant POOL_ID = 0xbcdd8383e38069f626846b94e93ee4d2c00cadfcce4b9457b0b8b04289030345;

    function _forked() internal view returns (bool) {
        return block.chainid == 8453;
    }

    function _w(address a) internal view returns (uint256) {
        return IERC20(WETH).balanceOf(a);
    }

    /// The keeper calls it, exactly as the cycle would. Who ends up with the WETH?
    function test_whereTheFeesLandWhenTheKeeperCollects() public {
        if (!_forked()) { console2.log("skipped: not forked"); return; }

        console2.log("shares held on this pool");
        console2.log("  FeeSplitter", IBankr(DIST).getShares(POOL_ID, SPLITTER));
        console2.log("  Safe       ", IBankr(DIST).getShares(POOL_ID, SAFE));
        console2.log("  keeper     ", IBankr(DIST).getShares(POOL_ID, KEEPER));

        uint256 k0 = _w(KEEPER);
        uint256 s0 = _w(SPLITTER);
        uint256 m0 = _w(SAFE);
        uint256 d0 = _w(DIST);

        vm.prank(KEEPER);
        (uint256 fees0, uint256 fees1) = IBankr(DIST).collectFees(POOL_ID);

        console2.log("");
        console2.log("collectFees returned (the POOL PULL, not a payout)");
        console2.log("  fees0 wei", fees0);
        console2.log("  fees1 wei", fees1);

        console2.log("");
        console2.log("WETH BALANCE DELTAS - this is the actual answer");
        console2.log("  keeper      ", int256(_w(KEEPER)) - int256(k0));
        console2.log("  FeeSplitter ", int256(_w(SPLITTER)) - int256(s0));
        console2.log("  Safe        ", int256(_w(SAFE)) - int256(m0));
        console2.log("  distributor ", int256(_w(DIST)) - int256(d0));

        // The keeper must never be the one enriched by running the cycle.
        assertEq(_w(KEEPER), k0, "THE KEEPER RECEIVED THE FEES - it must not");
    }

    /// And again from the Safe, to see whether the destination is caller-dependent at all.
    function test_andWhenTheSafeCollects() public {
        if (!_forked()) return;

        uint256 s0 = _w(SPLITTER);
        uint256 m0 = _w(SAFE);
        uint256 d0 = _w(DIST);

        vm.prank(SAFE);
        IBankr(DIST).collectFees(POOL_ID);

        console2.log("WETH deltas when the SAFE collects");
        console2.log("  FeeSplitter ", int256(_w(SPLITTER)) - int256(s0));
        console2.log("  Safe        ", int256(_w(SAFE)) - int256(m0));
        console2.log("  distributor ", int256(_w(DIST)) - int256(d0));
    }

    /// Can the FeeSplitter's share ever be moved ONWARD to the Pot?
    function test_canTheSplittersShareReachThePot() public {
        if (!_forked()) return;

        uint256 before = _w(SPLITTER);
        vm.prank(KEEPER);
        IBankr(DIST).collectFees(POOL_ID);
        uint256 landed = _w(SPLITTER) - before;

        console2.log("WETH that reached the FeeSplitter", landed);
        if (landed == 0) {
            console2.log("  -> nothing reaches the splitter, so nothing can reach the Pot");
        } else {
            console2.log("  -> distributeETH/WETH on the splitter is what forwards it");
        }
    }
}
