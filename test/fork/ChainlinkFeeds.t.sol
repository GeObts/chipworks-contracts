// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @notice Verifies every Coinbase B20 equity feed Chipworks depends on, live on Base.
/// @dev Addresses came from Chainlink's own feed directory for Base mainnet
///      (feeds-ethereum-mainnet-base-1.json), where they are listed as "Coinbase <TICKER>".
///      Resolves ASSUMPTIONS.md A-13.
contract ChainlinkFeedsForkTest is Test {
    struct Feed {
        string ticker;
        address proxy;
    }

    Feed[9] internal feeds;

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

    /// @notice Documents the off-hours behaviour so nobody adds a naive staleness check.
    ///         These feeds have NO heartbeat when equity markets are closed; they hold the
    ///         last close. A weekend `updatedAt` legitimately looks stale. ASSUMPTIONS A-14.
    function test_feedsMayLegitimatelyLookStale() public view {
        (,,, uint256 updatedAt,) = IAggregatorV3(feeds[0].proxy).latestRoundData();
        assertLe(updatedAt, block.timestamp, "never in the future");
        console2.log("NVDA feed age, seconds:", block.timestamp - updatedAt);
    }
}
