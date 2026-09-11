// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IBankr {
    function collectFees(bytes32 poolId) external returns (uint256 fees0, uint256 fees1);
    function getShares(bytes32 poolId, address who) external view returns (uint256);
    function getFeeRoutingMode(bytes32 poolId) external view returns (uint8);
    /// THE OVERLOAD THE RECOVERED ABI MISSED. Selector 0xa480ca79, found by
    /// walking the dispatch table rather than trusting the extracted ABI.
    function collectFees(address beneficiary) external returns (uint256 fees0, uint256 fees1);
}

interface IERC6909 {
    function balanceOf(address owner, uint256 id) external view returns (uint256);
}

/// @notice WHERE DOES THE BANKR FEE STREAM GO? Settled by recording every event.
///
/// @dev THE FIRST VERSION OF THIS TEST WAS WRONG BY OMISSION. It measured ERC-20 WETH
///      balances only, saw every delta come back zero, and concluded the stream was
///      stranded. Uniswap v4 settles internally in **ERC-6909 claim tokens** against the
///      PoolManager — a payout can be complete and correct without a single ERC-20
///      `Transfer` existing. Measuring one token standard and reporting "nothing moved" is
///      the same class of error as reading `collectFees`'s return value as a payout.
///
///      So this records EVERY log the call emits and decodes all of them. A transfer to any
///      address, in any standard, in any currency, shows up. Nothing is inferred.
contract BankrFeeDestinationForkTest is Test {
    address constant DIST = 0x9982538F41f2ae29ddb9d3D9307010052984FDbB;
    address constant SPLITTER = 0xb9b76e1835afE05e5A73065FE01A19B14869F8A3;
    address constant SAFE = 0xe1096B727499a3f70FaD8bc0267F5e69d01373C7;
    address constant KEEPER = 0x6571E3412553Fada40C3D96e61E7Cfd20A0695B9;
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant CHIP = 0x75Af968d2e58749FDA1b42C58186B76f5E511bA3;
    address constant POT = 0x3918a9B479Ce9B58238584c645079AB3bB49855B;

    bytes32 constant POOL_ID = 0xbcdd8383e38069f626846b94e93ee4d2c00cadfcce4b9457b0b8b04289030345;

    bytes32 constant ERC20_TRANSFER = keccak256("Transfer(address,address,uint256)");
    // ERC-6909 as v4 emits it.
    bytes32 constant ERC6909_TRANSFER = keccak256("Transfer(address,address,address,uint256,uint256)");

    /// A wallet with no relationship to anything. If IT can push the fees, they are not stuck.
    address stranger = makeAddr("a complete stranger");

    function _forked() internal view returns (bool) {
        return block.chainid == 8453;
    }

    function _label(address a) internal pure returns (string memory) {
        if (a == SPLITTER) return "FeeSplitter";
        if (a == SAFE) return "SAFE";
        if (a == KEEPER) return "keeper";
        if (a == DIST) return "BankrDistributor";
        if (a == POOL_MANAGER) return "PoolManager";
        if (a == POT) return "Pot";
        return "other";
    }

    function _tok(address a) internal pure returns (string memory) {
        if (a == WETH) return "WETH";
        if (a == CHIP) return "CHIP";
        if (a == POOL_MANAGER) return "v4-claim";
        return "?";
    }

    /// THE TEST THAT SETTLES IT: a stranger calls, and every emitted event is decoded.
    function test_aStrangerCallsCollectFees_andEveryEventIsShown() public {
        if (!_forked()) { console2.log("skipped: not forked"); return; }

        console2.log("routing mode", IBankr(DIST).getFeeRoutingMode(POOL_ID));
        console2.log("shares FeeSplitter", IBankr(DIST).getShares(POOL_ID, SPLITTER));
        console2.log("shares stranger   ", IBankr(DIST).getShares(POOL_ID, stranger));

        // ERC-6909 claim balances, which the first version of this test never looked at.
        uint256 wethId = uint256(uint160(WETH));
        uint256 s6a = IERC6909(POOL_MANAGER).balanceOf(SPLITTER, wethId);
        uint256 d6a = IERC6909(POOL_MANAGER).balanceOf(DIST, wethId);

        uint256 sW0 = IERC20(WETH).balanceOf(SPLITTER);
        uint256 sE0 = SPLITTER.balance;
        uint256 potE0 = POT.balance;
        uint256 potW0 = IERC20(WETH).balanceOf(POT);

        vm.recordLogs();
        vm.prank(stranger);
        (uint256 fees0, uint256 fees1) = IBankr(DIST).collectFees(POOL_ID);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        console2.log("");
        console2.log("collectFees returned  fees0", fees0);
        console2.log("                      fees1", fees1);
        console2.log("events emitted", logs.length);
        console2.log("");

        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory lg = logs[i];
            if (lg.topics.length == 0) continue;

            if (lg.topics[0] == ERC20_TRANSFER && lg.topics.length >= 3) {
                address from = address(uint160(uint256(lg.topics[1])));
                address to = address(uint160(uint256(lg.topics[2])));
                uint256 amt = abi.decode(lg.data, (uint256));
                console2.log(
                    string.concat("ERC20 ", _tok(lg.emitter), "  ", _label(from), " -> ", _label(to)), amt
                );
            } else if (lg.topics[0] == ERC6909_TRANSFER && lg.topics.length >= 4) {
                address from = address(uint160(uint256(lg.topics[2])));
                address to = address(uint160(uint256(lg.topics[3])));
                console2.log(string.concat("ERC6909 claim  ", _label(from), " -> ", _label(to)));
                console2.logBytes(lg.data);
            } else {
                console2.log(string.concat("event from ", _label(lg.emitter)));
                console2.logBytes32(lg.topics[0]);
            }
        }

        _report(sW0, sE0, s6a, d6a, potE0, potW0);
    }

    /// Split out purely to relieve stack pressure; all six deltas, all standards.
    function _report(uint256 sW0, uint256 sE0, uint256 s6a, uint256 d6a, uint256 potE0, uint256 potW0)
        internal
        view
    {
        uint256 wethId = uint256(uint160(WETH));
        console2.log("");
        console2.log("=== DELTAS, ALL STANDARDS ===");
        console2.log("FeeSplitter WETH  ", int256(IERC20(WETH).balanceOf(SPLITTER)) - int256(sW0));
        console2.log("FeeSplitter ETH   ", int256(SPLITTER.balance) - int256(sE0));
        console2.log("FeeSplitter claim ", int256(IERC6909(POOL_MANAGER).balanceOf(SPLITTER, wethId)) - int256(s6a));
        console2.log("Distributor claim ", int256(IERC6909(POOL_MANAGER).balanceOf(DIST, wethId)) - int256(d6a));
        console2.log("Pot ETH           ", int256(POT.balance) - int256(potE0));
        console2.log("Pot WETH          ", int256(IERC20(WETH).balanceOf(POT)) - int256(potW0));
    }

    /// collectFees(ADDRESS) - the overload that takes a beneficiary, not a pool.
    function test_collectFeesByAddress_forTheFeeSplitter() public {
        if (!_forked()) return;

        uint256 wethId = uint256(uint160(WETH));
        uint256 sW0 = IERC20(WETH).balanceOf(SPLITTER);
        uint256 sE0 = SPLITTER.balance;
        uint256 s60 = IERC6909(POOL_MANAGER).balanceOf(SPLITTER, wethId);

        vm.recordLogs();
        vm.prank(stranger);
        (bool ok, bytes memory ret) =
            DIST.call(abi.encodeWithSelector(bytes4(0xa480ca79), SPLITTER));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        console2.log("collectFees(FeeSplitter) from a stranger succeeded", ok);
        if (!ok) {
            console2.log("  revert data:");
            console2.logBytes(ret);
        } else if (ret.length >= 64) {
            (uint256 f0, uint256 f1) = abi.decode(ret, (uint256, uint256));
            console2.log("  returned fees0", f0);
            console2.log("  returned fees1", f1);
        }
        console2.log("  events emitted", logs.length);
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == ERC20_TRANSFER && logs[i].topics.length >= 3) {
                console2.log(
                    string.concat(
                        "  ERC20 ", _tok(logs[i].emitter), "  ",
                        _label(address(uint160(uint256(logs[i].topics[1])))), " -> ",
                        _label(address(uint160(uint256(logs[i].topics[2]))))
                    ),
                    abi.decode(logs[i].data, (uint256))
                );
            }
        }

        console2.log("  FeeSplitter WETH delta ", int256(IERC20(WETH).balanceOf(SPLITTER)) - int256(sW0));
        console2.log("  FeeSplitter ETH delta  ", int256(SPLITTER.balance) - int256(sE0));
        console2.log("  FeeSplitter claim delta", int256(IERC6909(POOL_MANAGER).balanceOf(SPLITTER, wethId)) - int256(s60));
    }

    /// And the same overload aimed at the Safe, in case entitlement is per-caller.
    function test_collectFeesByAddress_forTheSafe() public {
        if (!_forked()) return;
        uint256 m0 = IERC20(WETH).balanceOf(SAFE);
        vm.prank(SAFE);
        (bool ok,) = DIST.call(abi.encodeWithSelector(bytes4(0xa480ca79), SAFE));
        console2.log("collectFees(Safe) from the Safe succeeded", ok);
        console2.log("  Safe WETH delta", int256(IERC20(WETH).balanceOf(SAFE)) - int256(m0));
    }

    /// If the stranger's call DID fund the splitter, can it then be pushed on to the Pot?
    function test_thenTheSplitterForwardsToThePot() public {
        if (!_forked()) return;

        vm.prank(stranger);
        IBankr(DIST).collectFees(POOL_ID);

        uint256 held = IERC20(WETH).balanceOf(SPLITTER) + SPLITTER.balance;
        console2.log("FeeSplitter holds after collect (WETH + ETH)", held);

        if (held == 0) {
            console2.log("-> nothing arrived, so there is nothing to forward");
            return;
        }

        uint256 potBefore = IERC20(WETH).balanceOf(POT) + POT.balance;
        (bool ok,) = SPLITTER.call(abi.encodeWithSignature("distributeWETH()"));
        if (!ok) (ok,) = SPLITTER.call(abi.encodeWithSignature("distributeETH()"));
        console2.log("distribute call succeeded", ok);
        console2.log("Pot gained", int256(IERC20(WETH).balanceOf(POT) + POT.balance) - int256(potBefore));
    }
}
