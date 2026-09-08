// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title IdentifyByAddressTest
/// @notice A stock is identified by ADDRESS and by nothing else. This test enforces that by
///         reading the source.
///
/// @dev WHY THIS IS A TEST AND NOT A CODE REVIEW NOTE.
///
///      Every B20 stock lives at a vanity address beginning `0xb2`, and the tokens report
///      human names — `symbol()` returns "NVDAc", `name()` returns "NVIDIA Corporation".
///      Those strings are the natural thing to reach for when writing a registry, a router
///      or a log line, and they are exactly the wrong thing to trust:
///
///      - **Nothing makes a symbol unique.** Anyone can deploy an ERC-20 that reports
///        "NVDAc". If any resolution path matched on the string, a fake would be
///        interchangeable with the real thing at the point it mattered most.
///      - **B20 tokens are node-native precompiles** (ASSUMPTIONS A-15). A failed call to one
///        consumes ALL forwarded gas, so an incidental `symbol()` in a hot path is a gas
///        bomb waiting for the first token that misbehaves — a much worse failure than a
///        wrong label.
///      - **A string comparison in Solidity is a hash comparison**, which reads as
///        deliberate to a reviewer and hides the assumption rather than flagging it.
///
///      So the rule is absolute: `symbol()` and `name()` are never called from `src/`. Not
///      for identity, not for validation, not for an event. The registry is keyed by address,
///      the feed is stored per address, and the site does the labelling off chain where a
///      wrong string is a cosmetic bug rather than a payout to the wrong token.
///
///      A grep enforces it because it is a rule about what must be ABSENT, and absence is
///      what code review reliably misses — nobody notices the `symbol()` that got added to a
///      log line in a hurry. Scanning the directory rather than a fixed file list means a new
///      contract is covered the moment it is created.
contract IdentifyByAddressTest is Test {
    /// @notice Selectors and source spellings that would mean identity came from a string.
    function test_noSourceFileResolvesAStockByNameOrSymbol() public view {
        string[] memory files = _srcFiles();
        assertGt(files.length, 10, "the scan found the source tree");

        for (uint256 i; i < files.length; ++i) {
            string memory body = vm.readFile(files[i]);

            _refute(files[i], body, ".symbol()");
            _refute(files[i], body, ".name()");
            _refute(files[i], body, "symbol()\"");
            _refute(files[i], body, "name()\"");
            // A string comparison of any kind in the money path is the tell for the same
            // mistake wearing a different hat.
            _refute(files[i], body, "keccak256(bytes(");
            _refute(files[i], body, "keccak256(abi.encodePacked(string");
        }
    }

    /// @notice The registry's own key is the token address, and the feed hangs off it.
    /// @dev A companion to the grep: the grep proves nothing reads a string, this proves the
    ///      thing it reads instead is the address.
    function test_theRegistryIsKeyedByAddress() public view {
        string memory registry = vm.readFile("src/StockRegistry.sol");
        assertTrue(_has(registry, "mapping(address token => Stock)"), "stocks keyed by address");
        assertTrue(_has(registry, "address[] internal _tokenList"), "and enumerated by address");
    }

    /* ------------------------------- machinery -------------------------------- */

    /// @dev Every .sol under src/, at any depth, so a new subdirectory is covered
    ///      automatically rather than when somebody remembers to add it here.
    function _srcFiles() internal view returns (string[] memory out) {
        Vm.DirEntry[] memory entries = vm.readDir("src", 5);
        uint256 n;
        string[] memory buf = new string[](entries.length);
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].isDir) continue;
            if (!_has(entries[i].path, ".sol")) continue;
            buf[n++] = entries[i].path;
        }
        out = new string[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = buf[i];
        }
    }

    function _refute(string memory file, string memory body, string memory needle) internal pure {
        if (_has(body, needle)) {
            revert(string.concat("forbidden in src: '", needle, "' found in ", file));
        }
    }

    function _has(string memory haystack, string memory needle) internal pure returns (bool) {
        // Scan host-side: doing six byte-by-byte EVM scans exhausted the test gas
        // allowance as src/ grew. The forbidden patterns and file coverage are unchanged.
        return bytes(needle).length != 0 && vm.contains(haystack, needle);
    }
}
