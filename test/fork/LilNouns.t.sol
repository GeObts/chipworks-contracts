// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface ILil {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function totalSupply() external view returns (uint256);
    function tokenByIndex(uint256) external view returns (uint256);
}

/// @notice Pins what Chipworks assumes about Lil Based Nouns, against the live contract.
/// @dev    forge test --match-contract LilNounsForkTest -vv   (needs BASE_RPC_URL)
contract LilNounsForkTest is Test {
    address internal constant LIL = 0xe3c5Ef27B80481518a2363406e354a9361415556;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
    }

    function test_isARealErc721WithTheStatedSupply() public view {
        assertGt(LIL.code.length, 0);
        assertTrue(IERC165(LIL).supportsInterface(0x80ac58cd), "ERC-721");
        assertTrue(IERC165(LIL).supportsInterface(0x5b5e139f), "ERC-721 Metadata");
        assertEq(ILil(LIL).symbol(), "LIL");
        assertEq(ILil(LIL).totalSupply(), 4_420, "4,420 as briefed");
    }

    /// @notice It is an EIP-1967 proxy. Harmless for us — we only ever call ownerOf and
    ///         balanceOf — but worth recording, because it means the collection's behaviour
    ///         can change under us without the address changing.
    function test_isAnUpgradeableProxy() public view {
        assertEq(LIL.code.length, 205, "minimal proxy runtime");
        bytes32 impl = vm.load(LIL, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc);
        assertTrue(impl != bytes32(0), "EIP-1967 implementation slot is set");
        console2.log("implementation:", address(uint160(uint256(impl))));
    }

    /// @notice NOT Enumerable. This is fine — Chipworks never enumerates, because the
    ///         Clutch vault cannot either (ASSUMPTIONS A-10), so rounds are always driven
    ///         by a caller-supplied token id list that the contract verifies one by one.
    ///         Recorded because the SITE and KEEPER cannot enumerate holders on chain and
    ///         must index events or use an off-chain source.
    function test_isNotEnumerable() public {
        assertFalse(IERC165(LIL).supportsInterface(0x780e9d63), "ERC-721 Enumerable absent");
        vm.expectRevert();
        ILil(LIL).tokenByIndex(0);
    }

    /// @notice The only two functions Chipworks actually calls on a collection.
    function test_theTwoCallsChipworksMakesBothWork() public view {
        address owner = IERC721(LIL).ownerOf(1);
        assertTrue(owner != address(0), "ownerOf works: used by the adapter's A-8 check");
        assertGt(IERC721(LIL).balanceOf(owner), 0, "balanceOf works: used by the hoodie boost");
    }
}
