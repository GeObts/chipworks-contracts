// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @notice Reconciles the B20 feed and token tables in ASSUMPTIONS.md against live Base.
///
/// @dev THE FAILURE THIS EXISTS TO CATCH IS A TRANSPOSED ROW.
///
///      Nine feeds, nine addresses, hand-copied from Chainlink's directory into a markdown
///      table and then into `DEPLOY.md`. Swap two rows and everything still works: every
///      address is a real, live, correctly-shaped Chainlink feed returning a sane positive
///      price at 8 decimals. A round would buy NVDA priced at AAPL's mark, the Chainlink
///      bound would enforce the wrong number, and no assertion about liveness or decimals
///      would notice.
///
///      The earlier version of this file logged `description()` and asserted nothing about
///      it, which is exactly that hole. Now the description is the assertion: each feed must
///      identify itself as "Coinbase <TICKER>" for the ticker we filed it under. That is the
///      only check here the mapping can actually fail.
contract ChainlinkFeedsForkTest is Test {
    struct Feed {
        string ticker;
        address proxy;
    }

    struct Stock {
        string symbol;
        address token;
    }

    Feed[9] internal feeds;

    /// @notice All thirteen B20 stocks Base publishes (ASSUMPTIONS A-18). Nine are the
    ///         launch set; the last four are registered disabled and have no feed yet.
    Stock[13] internal stocks;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));

        feeds[0] = Feed("NVDA", 0x04689a41629776563E6822F76f2e57D148d28513);
        feeds[1] = Feed("GOOGL", 0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2);
        feeds[2] = Feed("AAPL", 0x787f13dEa48Db0897CbCDD985de77809D837F988);
        feeds[3] = Feed("META", 0x6526aE6797A76123638b863AeE4dD27Ba4E4b27D);
        feeds[4] = Feed("TSLA", 0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4);
        feeds[5] = Feed("AMZN", 0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295);
        feeds[6] = Feed("MSFT", 0xeB10A6c9aa7E537aEd766C08c35Dae35B321b18c);
        feeds[7] = Feed("COIN", 0x408e44f504A7371a345F03a73dDC96A4b48e8aa7);
        feeds[8] = Feed("MSTR", 0xB3cE282CD188b35DA0E38D8Bc7d58e33173D202a);

        stocks[0] = Stock("NVDAc", 0xb20000000000000000000078ee7ce2fE4908108C);
        stocks[1] = Stock("GOOGLc", 0xb2000000000000000000002D0BA3164cc74f58B7);
        stocks[2] = Stock("AAPLc", 0xb200000000000000000000C2e324d24d7eEcd1fb);
        stocks[3] = Stock("METAc", 0xb2000000000000000000008bC8786B856E61707C);
        stocks[4] = Stock("TSLAc", 0xb2000000000000000000001e800a7f5189430cD0);
        stocks[5] = Stock("AMZNc", 0xb200000000000000000000d9192b6B456483C2E8);
        stocks[6] = Stock("MSFTc", 0xB200000000000000000000Ab99cFa739E253872B);
        stocks[7] = Stock("COINc", 0xb200000000000000000000c85a31389D71F3ecfb);
        stocks[8] = Stock("MSTRc", 0xb2000000000000000000004884b426556b92883d);
        // The four beyond the launch set. Verified so they can be registered disabled.
        stocks[9] = Stock("CRCLc", 0xB20000000000000000000019f6E7C675b73C2e4D);
        stocks[10] = Stock("INTCc", 0xB2000000000000000000004AFF16039bA04bdFBc);
        stocks[11] = Stock("SNDKc", 0xb200000000000000000000397293Cb8cda9a10c5);
        stocks[12] = Stock("SPCXc", 0xb2000000000000000000007b9fcbd005511aCBd5);
    }

    /* ----------------------------- the reconciliation ---------------------------- */

    /// @notice THE ONE THAT CAN FAIL ON A TRANSPOSED TABLE. Every feed must name itself.
    function test_everyFeedIdentifiesAsTheTickerWeFiledItUnder() public view {
        for (uint256 i; i < feeds.length; ++i) {
            string memory expected = string.concat("Coinbase ", feeds[i].ticker);
            string memory actual = IAggregatorV3(feeds[i].proxy).description();
            assertEq(actual, expected, "feed description does not match its row in A-13");
        }
    }

    /// @notice No two rows point at the same feed, which a copy-paste slip would produce and
    ///         the description check alone would not catch if both rows were wrong together.
    function test_noTwoTickersShareAFeed() public view {
        for (uint256 i; i < feeds.length; ++i) {
            for (uint256 j = i + 1; j < feeds.length; ++j) {
                assertTrue(feeds[i].proxy != feeds[j].proxy, "duplicate feed address in the table");
            }
        }
    }

    function test_everyFeedIsLiveAndStandard() public view {
        for (uint256 i; i < feeds.length; ++i) {
            IAggregatorV3 f = IAggregatorV3(feeds[i].proxy);
            assertGt(feeds[i].proxy.code.length, 0, "feed has code");
            assertEq(f.decimals(), 8, "8 decimals, as assumed by StockRegistry");

            (, int256 answer,, uint256 updatedAt,) = f.latestRoundData();
            assertGt(answer, 0, "positive price");
            assertGt(updatedAt, 0, "has been updated");

            console2.log(feeds[i].ticker, uint256(answer) / 1e8, f.description());
        }
    }

    /* ------------------------------- the token table ----------------------------- */

    /// @notice A B20 token CANNOT be called from a forked EVM, and this pins that down.
    ///
    /// @dev The first version of this test asserted `decimals()` and `symbol()` for all
    ///      thirteen. It reverted, having burned a billion gas — which is ASSUMPTIONS A-15
    ///      happening in front of us rather than a bug in the table. These tokens are
    ///      node-native precompiles: a real node answers, a forked EVM cannot execute them,
    ///      and the failed call consumes every wei of gas forwarded to it.
    ///
    ///      That is worth an assertion of its own, because the tempting "fix" is to make
    ///      `StockRegistry.addStock` probe `decimals()` and trust it. On mainnet that works;
    ///      in any fork test or `forge script` simulation it reverts. The registry instead
    ///      falls back to the supplied value when the token is not callable, and DEPLOY.md
    ///      tells you to broadcast with `--skip-simulation`. Both exist because of this.
    ///
    ///      The decimals and symbols themselves were reconciled against a live Base node by
    ///      direct RPC, outside the EVM, on 2026-09-03 — all thirteen at 8 decimals with the
    ///      symbols recorded in A-18. There is no way to do that from inside a fork, so this
    ///      asserts the limitation and A-18 carries the result.
    function test_aB20TokenCannotBeCalledFromAFork() public {
        for (uint256 i; i < stocks.length; ++i) {
            (bool ok,) = stocks[i].token.staticcall{gas: 100_000}(abi.encodeWithSignature("decimals()"));
            assertFalse(ok, "a fork must not be able to execute a B20 precompile");
        }
    }

    /// @notice The precompile shape from ASSUMPTIONS A-15, re-checked for all thirteen: one
    ///         byte of code (`0xef`), yet `balanceOf` and `decimals` answer correctly on a
    ///         real node. This is why a forked EVM cannot execute them and why every
    ///         optional call to one is a gas-capped staticcall.
    function test_everyB20TokenIsANodeNativePrecompile() public view {
        for (uint256 i; i < stocks.length; ++i) {
            bytes memory code = stocks[i].token.code;
            assertEq(code.length, 1, "one byte of code");
            assertEq(uint8(code[0]), 0xef, "the 0xef marker byte");
        }
    }

    /// @notice No two rows share a token address either.
    function test_noTwoStocksShareAnAddress() public view {
        for (uint256 i; i < stocks.length; ++i) {
            for (uint256 j = i + 1; j < stocks.length; ++j) {
                assertTrue(stocks[i].token != stocks[j].token, "duplicate token address in the table");
            }
        }
    }

    /* --------------------------------- off hours --------------------------------- */

    /// @notice Documents the off-hours behaviour so nobody adds a naive staleness check.
    ///         These feeds have NO heartbeat when equity markets are closed; they hold the
    ///         last close. A weekend `updatedAt` legitimately looks stale. ASSUMPTIONS A-14.
    ///
    ///         The handling is `ChipRounds.maxFeedAge`: a SKIP with the budget carried, never
    ///         a revert, floored at 72 hours so it cannot be tightened into skipping every
    ///         Monday. See `test/b20/FrozenFeed.t.sol`.
    function test_feedsMayLegitimatelyLookStale() public view {
        (,,, uint256 updatedAt,) = IAggregatorV3(feeds[0].proxy).latestRoundData();
        assertLe(updatedAt, block.timestamp, "never in the future");
        console2.log("NVDA feed age, seconds:", block.timestamp - updatedAt);
    }
}

interface IB20 {
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}
