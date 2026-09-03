// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IActivationCustodian} from "../../src/interfaces/IActivationCustodian.sol";

/// @notice An honest custodian: holds a Noun and names the depositor as beneficiary.
/// @dev Models what NounLoans does, without any lending economics.
contract MockCustodian is IActivationCustodian {
    mapping(address collection => mapping(uint256 tokenId => address)) internal _beneficiary;

    function deposit(address collection, uint256 tokenId) external {
        IERC721(collection).transferFrom(msg.sender, address(this), tokenId);
        _beneficiary[collection][tokenId] = msg.sender;
    }

    function withdraw(address collection, uint256 tokenId, address to) external {
        require(_beneficiary[collection][tokenId] == msg.sender, "not yours");
        delete _beneficiary[collection][tokenId];
        IERC721(collection).transferFrom(address(this), to, tokenId);
    }

    /// @notice Simulate a liquidation: the beneficiary changes without the token moving.
    function setBeneficiary(address collection, uint256 tokenId, address who) external {
        _beneficiary[collection][tokenId] = who;
    }

    function beneficiaryOf(address collection, uint256 tokenId) external view override returns (address) {
        return _beneficiary[collection][tokenId];
    }
}

/// @notice A custodian that names an attacker as beneficiary for EVERY token, including ones
///         it has never held. Used to prove the blast radius is its own custody only.
contract LyingCustodian is IActivationCustodian {
    address public immutable attacker;

    constructor(address attacker_) {
        attacker = attacker_;
    }

    function beneficiaryOf(address, uint256) external view override returns (address) {
        return attacker;
    }

    function pull(address collection, uint256 tokenId, address from) external {
        IERC721(collection).transferFrom(from, address(this), tokenId);
    }
}

/// @notice A custodian whose view burns every wei of gas handed to it.
contract GasBombCustodian {
    function beneficiaryOf(address, uint256) external pure returns (address) {
        assembly {
            invalid()
        }
    }

    function pull(address collection, uint256 tokenId, address from) external {
        IERC721(collection).transferFrom(from, address(this), tokenId);
    }
}

/// @notice A custodian that returns nothing at all, so the return data is too short to decode.
contract SilentCustodian {
    fallback() external {}

    function pull(address collection, uint256 tokenId, address from) external {
        IERC721(collection).transferFrom(from, address(this), tokenId);
    }
}
