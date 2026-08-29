// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MockNoun is ERC721 {
    constructor(string memory n, string memory s) ERC721(n, s) {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}

/// @notice ERC721 whose ownerOf burns all gas, modelling a hostile or broken collection.
contract GasBombNoun {
    function ownerOf(uint256) external pure returns (address) {
        assembly {
            invalid()
        }
    }

    function balanceOf(address) external pure returns (uint256) {
        assembly {
            invalid()
        }
    }
}
