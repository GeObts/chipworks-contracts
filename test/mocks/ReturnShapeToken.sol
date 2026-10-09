// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice An ERC-20 whose `transfer` can be switched to answer in non-standard shapes WITHOUT
///         moving anything — the tokens a strict return-data check must read as "refused".
///         transferFrom stays standard so the token can be escrowed normally first.
contract ReturnShapeToken is ERC20 {
    enum Shape {
        Standard, // moves the tokens, returns one word = 1
        TwoWords, // moves nothing, returns two words (1, 1): a ">= 32 bytes" check reads true
        NotABool, // moves nothing, returns one word = 2: a bool decode reverts
        False // moves nothing, returns one word = 0
    }

    Shape public shape;

    constructor() ERC20("Shape", "SHP") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setShape(Shape s) external {
        shape = s;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        Shape s = shape;
        if (s == Shape.Standard) return super.transfer(to, amount);
        if (s == Shape.TwoWords) {
            assembly {
                mstore(0x00, 1)
                mstore(0x20, 1)
                return(0x00, 0x40)
            }
        }
        if (s == Shape.NotABool) {
            assembly {
                mstore(0x00, 2)
                return(0x00, 0x20)
            }
        }
        return false;
    }
}
