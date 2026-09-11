// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Does ANY function on the Bankr distributor release the fees?
///
/// @dev "I tested collectFees and it moved nothing" is not the same claim as "nothing can
///      move it", and the difference is worth about $27k a month. The recovered ABI listed
///      seven functions; walking the dispatch table found roughly forty selectors, including
///      a `collectFees(address)` overload the ABI had missed entirely.
///
///      So this sweeps every selector in the dispatch table against the three argument shapes
///      a claim would plausibly take — (), (address), (bytes32) — from a stranger, and
///      reports any call that MOVES WETH out of the distributor. It cannot prove a negative
///      over all possible calldata, and it does not pretend to: what it rules out is a
///      simple, callable claim path, which is what "can anyone push these fees" means.
contract BankrFeeSurfaceForkTest is Test {
    address constant DIST = 0x9982538F41f2ae29ddb9d3D9307010052984FDbB;
    address constant SPLITTER = 0xb9b76e1835afE05e5A73065FE01A19B14869F8A3;
    address constant SAFE = 0xe1096B727499a3f70FaD8bc0267F5e69d01373C7;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    bytes32 constant POOL_ID = 0xbcdd8383e38069f626846b94e93ee4d2c00cadfcce4b9457b0b8b04289030345;

    address stranger = makeAddr("stranger");

    /// Every selector found in the distributor's dispatch table.
    function _selectors() internal pure returns (bytes4[26] memory s) {
        s = [
            bytes4(0x45c3193d), bytes4(0x47933f49), bytes4(0x4cfaa8c1), bytes4(0x5a6f4c5f),
            bytes4(0x6f174dca), bytes4(0x7bc5451f), bytes4(0x7e3dea55), bytes4(0x8341a679),
            bytes4(0x988d2561), bytes4(0x988d2590), bytes4(0xb43df6e3), bytes4(0xcc0d7e37),
            bytes4(0xcdb5303f), bytes4(0xd3754237), bytes4(0xd44f6738), bytes4(0xd93275b1),
            bytes4(0xe736b3d1), bytes4(0xefd1fc6a), bytes4(0xf0342625), bytes4(0xfc6e3bef),
            bytes4(0xa480ca79), bytes4(0x817db73b), bytes4(0xc6bbd5a7), bytes4(0xdc4c90d3),
            bytes4(0x8da5cb5b), bytes4(0x5ebb58fb)
        ];
    }

    function test_noCallableFunctionReleasesTheFees() public {
        if (block.chainid != 8453) { console2.log("skipped: not forked"); return; }

        uint256 distBefore = IERC20(WETH).balanceOf(DIST);
        console2.log("distributor WETH at start", distBefore);
        console2.log("");

        bytes4[26] memory sels = _selectors();
        uint256 moved;

        for (uint256 i; i < sels.length; ++i) {
            // Four shapes: no args, the pool id, the splitter, the Safe.
            bytes[4] memory calls = [
                abi.encodePacked(sels[i]),
                abi.encodeWithSelector(sels[i], POOL_ID),
                abi.encodeWithSelector(sels[i], SPLITTER),
                abi.encodeWithSelector(sels[i], SAFE)
            ];

            for (uint256 j; j < calls.length; ++j) {
                uint256 snap = vm.snapshotState();
                uint256 s0 = IERC20(WETH).balanceOf(SPLITTER);
                uint256 d0 = IERC20(WETH).balanceOf(DIST);

                vm.prank(stranger);
                (bool ok,) = DIST.call(calls[j]);

                if (ok) {
                    int256 dDist = int256(IERC20(WETH).balanceOf(DIST)) - int256(d0);
                    int256 dSplit = int256(IERC20(WETH).balanceOf(SPLITTER)) - int256(s0);
                    if (dDist != 0 || dSplit != 0) {
                        moved++;
                        console2.log("*** MOVES MONEY ***");
                        console2.logBytes4(sels[i]);
                        console2.log("  arg shape", j);
                        console2.log("  distributor delta", dDist);
                        console2.log("  splitter delta", dSplit);
                    }
                }
                vm.revertToState(snap);
            }
        }

        console2.log("");
        if (moved == 0) {
            console2.log("NO callable function on the distributor moves WETH out of it.");
        } else {
            console2.log("functions that moved money:", moved);
        }
        assertEq(moved, 0, "something DOES release the fees - see the log above");
    }
}
