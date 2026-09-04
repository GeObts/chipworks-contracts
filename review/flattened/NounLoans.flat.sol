// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20 ^0.8.24;

// lib/openzeppelin-contracts/contracts/utils/Context.sol

// OpenZeppelin Contracts (last updated v5.0.1) (utils/Context.sol)

/**
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }

    function _contextSuffixLength() internal view virtual returns (uint256) {
        return 0;
    }
}

// lib/openzeppelin-contracts/contracts/utils/Errors.sol

// OpenZeppelin Contracts (last updated v5.1.0) (utils/Errors.sol)

/**
 * @dev Collection of common custom errors used in multiple contracts
 *
 * IMPORTANT: Backwards compatibility is not guaranteed in future versions of the library.
 * It is recommended to avoid relying on the error API for critical functionality.
 *
 * _Available since v5.1._
 */
library Errors {
    /**
     * @dev The ETH balance of the account is not enough to perform the operation.
     */
    error InsufficientBalance(uint256 balance, uint256 needed);

    /**
     * @dev A call to an address target failed. The target may have reverted.
     */
    error FailedCall();

    /**
     * @dev The deployment failed.
     */
    error FailedDeployment();

    /**
     * @dev A necessary precompile is missing.
     */
    error MissingPrecompile(address);
}

// src/interfaces/IActivationCustodian.sol

/// @title IActivationCustodian
/// @notice What a contract must expose to hold a Noun on someone's behalf without that Noun
///         losing its activation.
///
/// @dev THIS IS THE WHOLE REASON CHIPWORKS RUNS ITS OWN ACTIVATION VAULT.
///
///      Soft staking means the NFT never leaves the owner's wallet, and the activation is
///      void the moment it does. That rule is correct for a sale and wrong for a deposit:
///      an owner who locks their Noun as loan collateral has not sold it, and should not
///      stop earning. A third-party vault cannot tell the two apart, because from the
///      collection's point of view both are just `ownerOf` changing.
///
///      {ChipActivation} resolves it with an allowlist. When `ownerOf` is a registered
///      custodian, the effective owner is whatever that custodian names as the beneficiary,
///      and the activation survives. When it is anything else — a buyer, an unregistered
///      contract, a marketplace escrow — the activation resets.
///
///      TRUST MODEL. A custodian is trusted, but only over the tokens it actually holds:
///      {ChipActivation} asks the address `ownerOf` returned and no other, so a hostile
///      custodian can only misdirect rewards for Nouns already in its own custody, which it
///      could withhold anyway. It cannot name a beneficiary for a token it does not hold,
///      and it cannot affect any other collection. Registration is multisig-only and
///      revocable immediately; revoking resets every activation that custodian was holding.
interface IActivationCustodian {
    /// @notice Who is the real owner of `tokenId`, for a token this contract holds.
    /// @dev MUST return the address the deposit is held for. MUST return the zero address
    ///      for a token this contract does not hold on anyone's behalf — that reads as "no
    ///      effective owner" and resets the activation, which is the safe direction.
    ///      MUST NOT revert; {ChipActivation} gas-caps the call and treats a failure as zero.
    function beneficiaryOf(address collection, uint256 tokenId) external view returns (address);
}

// src/interfaces/IActivationSource.sol

/// @title IActivationSource
/// @notice The ONLY activation-related surface Chipworks contracts depend on.
/// @dev This exists so that the entire risk of "we guessed Clutch's ABI wrong"
///      is concentrated in one small, swappable adapter contract instead of
///      being welded into ChipRewards.
///
///      Two things it normalises that a raw vault does not:
///        1. Collections. The Clutch market is multi-collection (Based Nouns +
///           DarkNOUNs) but the documented vault signatures take a bare
///           `tokenId`. Everything here is keyed by (collection, tokenId).
///           See ASSUMPTIONS.md A-3.
///        2. Tiers. Clutch tiers are an index 0..4; Chipworks needs the numeric
///           multiplier. The adapter returns basis points (10000 = 1.00x), so
///           the tier table is configuration, never a hardcoded constant.
interface IActivationSource {
    /// @notice Full activation state for one NFT, in one call.
    /// @param collection The ERC-721 contract address.
    /// @param tokenId    The token id within `collection`.
    /// @return active    Whether the token has a live activation right now.
    /// @return tierBps   Tier multiplier in basis points (10000 = 1.00x). Zero when inactive.
    /// @return owner     Address rewards should be booked to. Zero when inactive.
    function activation(address collection, uint256 tokenId)
        external
        view
        returns (bool active, uint32 tierBps, address owner);

    /// @notice Who counts as the owner of `tokenId` for Chipworks' purposes.
    /// @dev Normally just `IERC721.ownerOf`. An implementation that supports custody — a Noun
    ///      locked as loan collateral is deposited, not sold — resolves through to the real
    ///      beneficiary instead, so the depositor stays in control of their own Noun.
    ///
    ///      Used to authorise `setSplit`, which is why it is on this interface rather than
    ///      only on the implementation: without it, depositing a Noun as collateral would
    ///      silently take away the owner's ability to re-pick their stocks, even though the
    ///      Noun keeps earning for them.
    ///
    ///      MUST NOT revert. Returns the zero address when there is no answer, which every
    ///      caller must treat as "nobody" rather than as a match.
    function effectiveOwner(address collection, uint256 tokenId) external view returns (address);

    /// @notice True if `collection` is one this source can answer for.
    function isSupportedCollection(address collection) external view returns (bool);
}

// lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol

// OpenZeppelin Contracts (last updated v5.1.0) (utils/introspection/IERC165.sol)

/**
 * @dev Interface of the ERC-165 standard, as defined in the
 * https://eips.ethereum.org/EIPS/eip-165[ERC].
 *
 * Implementers can declare support of contract interfaces, which can then be
 * queried by others ({ERC165Checker}).
 *
 * For an implementation, see {ERC165}.
 */
interface IERC165 {
    /**
     * @dev Returns true if this contract implements the interface defined by
     * `interfaceId`. See the corresponding
     * https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[ERC section]
     * to learn more about how these ids are created.
     *
     * This function call must use less than 30 000 gas.
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

// lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol

// OpenZeppelin Contracts (last updated v5.1.0) (token/ERC20/IERC20.sol)

/**
 * @dev Interface of the ERC-20 standard as defined in the ERC.
 */
interface IERC20 {
    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @dev Returns the value of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the value of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 value) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the
     * allowance mechanism. `value` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

// lib/openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol

// OpenZeppelin Contracts (last updated v5.1.0) (token/ERC721/IERC721Receiver.sol)

/**
 * @title ERC-721 token receiver interface
 * @dev Interface for any contract that wants to support safeTransfers
 * from ERC-721 asset contracts.
 */
interface IERC721Receiver {
    /**
     * @dev Whenever an {IERC721} `tokenId` token is transferred to this contract via {IERC721-safeTransferFrom}
     * by `operator` from `from`, this function is called.
     *
     * It must return its Solidity selector to confirm the token transfer.
     * If any other value is returned or the interface is not implemented by the recipient, the transfer will be
     * reverted.
     *
     * The selector can be obtained in Solidity with `IERC721Receiver.onERC721Received.selector`.
     */
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
}

// lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol

// OpenZeppelin Contracts (last updated v5.1.0) (utils/ReentrancyGuard.sol)

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If EIP-1153 (transient storage) is available on the chain you're deploying at,
 * consider using {ReentrancyGuardTransient} instead.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 */
abstract contract ReentrancyGuard {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    uint256 private _status;

    /**
     * @dev Unauthorized reentrant call.
     */
    error ReentrancyGuardReentrantCall();

    constructor() {
        _status = NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and making it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() private {
        // On the first call to nonReentrant, _status will be NOT_ENTERED
        if (_status == ENTERED) {
            revert ReentrancyGuardReentrantCall();
        }

        // Any calls to nonReentrant after this point will fail
        _status = ENTERED;
    }

    function _nonReentrantAfter() private {
        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = NOT_ENTERED;
    }

    /**
     * @dev Returns true if the reentrancy guard is currently set to "entered", which indicates there is a
     * `nonReentrant` function in the call stack.
     */
    function _reentrancyGuardEntered() internal view returns (bool) {
        return _status == ENTERED;
    }
}

// lib/openzeppelin-contracts/contracts/utils/Address.sol

// OpenZeppelin Contracts (last updated v5.1.0) (utils/Address.sol)

/**
 * @dev Collection of functions related to the address type
 */
library Address {
    /**
     * @dev There's no code at `target` (it is not a contract).
     */
    error AddressEmptyCode(address target);

    /**
     * @dev Replacement for Solidity's `transfer`: sends `amount` wei to
     * `recipient`, forwarding all available gas and reverting on errors.
     *
     * https://eips.ethereum.org/EIPS/eip-1884[EIP1884] increases the gas cost
     * of certain opcodes, possibly making contracts go over the 2300 gas limit
     * imposed by `transfer`, making them unable to receive funds via
     * `transfer`. {sendValue} removes this limitation.
     *
     * https://consensys.net/diligence/blog/2019/09/stop-using-soliditys-transfer-now/[Learn more].
     *
     * IMPORTANT: because control is transferred to `recipient`, care must be
     * taken to not create reentrancy vulnerabilities. Consider using
     * {ReentrancyGuard} or the
     * https://solidity.readthedocs.io/en/v0.8.20/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions pattern].
     */
    function sendValue(address payable recipient, uint256 amount) internal {
        if (address(this).balance < amount) {
            revert Errors.InsufficientBalance(address(this).balance, amount);
        }

        (bool success, ) = recipient.call{value: amount}("");
        if (!success) {
            revert Errors.FailedCall();
        }
    }

    /**
     * @dev Performs a Solidity function call using a low level `call`. A
     * plain `call` is an unsafe replacement for a function call: use this
     * function instead.
     *
     * If `target` reverts with a revert reason or custom error, it is bubbled
     * up by this function (like regular Solidity function calls). However, if
     * the call reverted with no returned reason, this function reverts with a
     * {Errors.FailedCall} error.
     *
     * Returns the raw returned data. To convert to the expected return value,
     * use https://solidity.readthedocs.io/en/latest/units-and-global-variables.html?highlight=abi.decode#abi-encoding-and-decoding-functions[`abi.decode`].
     *
     * Requirements:
     *
     * - `target` must be a contract.
     * - calling `target` with `data` must not revert.
     */
    function functionCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but also transferring `value` wei to `target`.
     *
     * Requirements:
     *
     * - the calling contract must have an ETH balance of at least `value`.
     * - the called Solidity function must be `payable`.
     */
    function functionCallWithValue(address target, bytes memory data, uint256 value) internal returns (bytes memory) {
        if (address(this).balance < value) {
            revert Errors.InsufficientBalance(address(this).balance, value);
        }
        (bool success, bytes memory returndata) = target.call{value: value}(data);
        return verifyCallResultFromTarget(target, success, returndata);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a static call.
     */
    function functionStaticCall(address target, bytes memory data) internal view returns (bytes memory) {
        (bool success, bytes memory returndata) = target.staticcall(data);
        return verifyCallResultFromTarget(target, success, returndata);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a delegate call.
     */
    function functionDelegateCall(address target, bytes memory data) internal returns (bytes memory) {
        (bool success, bytes memory returndata) = target.delegatecall(data);
        return verifyCallResultFromTarget(target, success, returndata);
    }

    /**
     * @dev Tool to verify that a low level call to smart-contract was successful, and reverts if the target
     * was not a contract or bubbling up the revert reason (falling back to {Errors.FailedCall}) in case
     * of an unsuccessful call.
     */
    function verifyCallResultFromTarget(
        address target,
        bool success,
        bytes memory returndata
    ) internal view returns (bytes memory) {
        if (!success) {
            _revert(returndata);
        } else {
            // only check if target is a contract if the call was successful and the return data is empty
            // otherwise we already know that it was a contract
            if (returndata.length == 0 && target.code.length == 0) {
                revert AddressEmptyCode(target);
            }
            return returndata;
        }
    }

    /**
     * @dev Tool to verify that a low level call was successful, and reverts if it wasn't, either by bubbling the
     * revert reason or with a default {Errors.FailedCall} error.
     */
    function verifyCallResult(bool success, bytes memory returndata) internal pure returns (bytes memory) {
        if (!success) {
            _revert(returndata);
        } else {
            return returndata;
        }
    }

    /**
     * @dev Reverts with returndata if present. Otherwise reverts with {Errors.FailedCall}.
     */
    function _revert(bytes memory returndata) private pure {
        // Look for revert reason and bubble it up if present
        if (returndata.length > 0) {
            // The easiest way to bubble the revert reason is using memory via assembly
            assembly ("memory-safe") {
                let returndata_size := mload(returndata)
                revert(add(32, returndata), returndata_size)
            }
        } else {
            revert Errors.FailedCall();
        }
    }
}

// lib/openzeppelin-contracts/contracts/interfaces/IERC165.sol

// OpenZeppelin Contracts (last updated v5.0.0) (interfaces/IERC165.sol)

// lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol

// OpenZeppelin Contracts (last updated v5.0.0) (interfaces/IERC20.sol)

// lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol

// OpenZeppelin Contracts (last updated v5.1.0) (token/ERC721/IERC721.sol)

/**
 * @dev Required interface of an ERC-721 compliant contract.
 */
interface IERC721 is IERC165 {
    /**
     * @dev Emitted when `tokenId` token is transferred from `from` to `to`.
     */
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    /**
     * @dev Emitted when `owner` enables `approved` to manage the `tokenId` token.
     */
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);

    /**
     * @dev Emitted when `owner` enables or disables (`approved`) `operator` to manage all of its assets.
     */
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    /**
     * @dev Returns the number of tokens in ``owner``'s account.
     */
    function balanceOf(address owner) external view returns (uint256 balance);

    /**
     * @dev Returns the owner of the `tokenId` token.
     *
     * Requirements:
     *
     * - `tokenId` must exist.
     */
    function ownerOf(uint256 tokenId) external view returns (address owner);

    /**
     * @dev Safely transfers `tokenId` token from `from` to `to`.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `tokenId` token must exist and be owned by `from`.
     * - If the caller is not `from`, it must be approved to move this token by either {approve} or {setApprovalForAll}.
     * - If `to` refers to a smart contract, it must implement {IERC721Receiver-onERC721Received}, which is called upon
     *   a safe transfer.
     *
     * Emits a {Transfer} event.
     */
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;

    /**
     * @dev Safely transfers `tokenId` token from `from` to `to`, checking first that contract recipients
     * are aware of the ERC-721 protocol to prevent tokens from being forever locked.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `tokenId` token must exist and be owned by `from`.
     * - If the caller is not `from`, it must have been allowed to move this token by either {approve} or
     *   {setApprovalForAll}.
     * - If `to` refers to a smart contract, it must implement {IERC721Receiver-onERC721Received}, which is called upon
     *   a safe transfer.
     *
     * Emits a {Transfer} event.
     */
    function safeTransferFrom(address from, address to, uint256 tokenId) external;

    /**
     * @dev Transfers `tokenId` token from `from` to `to`.
     *
     * WARNING: Note that the caller is responsible to confirm that the recipient is capable of receiving ERC-721
     * or else they may be permanently lost. Usage of {safeTransferFrom} prevents loss, though the caller must
     * understand this adds an external call which potentially creates a reentrancy vulnerability.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `tokenId` token must be owned by `from`.
     * - If the caller is not `from`, it must be approved to move this token by either {approve} or {setApprovalForAll}.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 tokenId) external;

    /**
     * @dev Gives permission to `to` to transfer `tokenId` token to another account.
     * The approval is cleared when the token is transferred.
     *
     * Only a single account can be approved at a time, so approving the zero address clears previous approvals.
     *
     * Requirements:
     *
     * - The caller must own the token or be an approved operator.
     * - `tokenId` must exist.
     *
     * Emits an {Approval} event.
     */
    function approve(address to, uint256 tokenId) external;

    /**
     * @dev Approve or remove `operator` as an operator for the caller.
     * Operators can call {transferFrom} or {safeTransferFrom} for any token owned by the caller.
     *
     * Requirements:
     *
     * - The `operator` cannot be the address zero.
     *
     * Emits an {ApprovalForAll} event.
     */
    function setApprovalForAll(address operator, bool approved) external;

    /**
     * @dev Returns the account approved for `tokenId` token.
     *
     * Requirements:
     *
     * - `tokenId` must exist.
     */
    function getApproved(uint256 tokenId) external view returns (address operator);

    /**
     * @dev Returns if the `operator` is allowed to manage all of the assets of `owner`.
     *
     * See {setApprovalForAll}
     */
    function isApprovedForAll(address owner, address operator) external view returns (bool);
}

// lib/openzeppelin-contracts/contracts/access/Ownable.sol

// OpenZeppelin Contracts (last updated v5.0.0) (access/Ownable.sol)

/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * The initial owner is set to the address provided by the deployer. This can
 * later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract Ownable is Context {
    address private _owner;

    /**
     * @dev The caller account is not authorized to perform an operation.
     */
    error OwnableUnauthorizedAccount(address account);

    /**
     * @dev The owner is not a valid owner account. (eg. `address(0)`)
     */
    error OwnableInvalidOwner(address owner);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the address provided by the deployer as the initial owner.
     */
    constructor(address initialOwner) {
        if (initialOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(initialOwner);
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if the sender is not the owner.
     */
    function _checkOwner() internal view virtual {
        if (owner() != _msgSender()) {
            revert OwnableUnauthorizedAccount(_msgSender());
        }
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby disabling any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        if (newOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

// lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol

// OpenZeppelin Contracts (last updated v5.1.0) (access/Ownable2Step.sol)

/**
 * @dev Contract module which provides access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * This extension of the {Ownable} contract includes a two-step mechanism to transfer
 * ownership, where the new owner must call {acceptOwnership} in order to replace the
 * old one. This can help prevent common mistakes, such as transfers of ownership to
 * incorrect accounts, or to contracts that are unable to interact with the
 * permission system.
 *
 * The initial owner is specified at deployment time in the constructor for `Ownable`. This
 * can later be changed with {transferOwnership} and {acceptOwnership}.
 *
 * This module is used through inheritance. It will make available all functions
 * from parent (Ownable).
 */
abstract contract Ownable2Step is Ownable {
    address private _pendingOwner;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Returns the address of the pending owner.
     */
    function pendingOwner() public view virtual returns (address) {
        return _pendingOwner;
    }

    /**
     * @dev Starts the ownership transfer of the contract to a new account. Replaces the pending transfer if there is one.
     * Can only be called by the current owner.
     *
     * Setting `newOwner` to the zero address is allowed; this can be used to cancel an initiated ownership transfer.
     */
    function transferOwnership(address newOwner) public virtual override onlyOwner {
        _pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner(), newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`) and deletes any pending owner.
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual override {
        delete _pendingOwner;
        super._transferOwnership(newOwner);
    }

    /**
     * @dev The new owner accepts the ownership transfer.
     */
    function acceptOwnership() public virtual {
        address sender = _msgSender();
        if (pendingOwner() != sender) {
            revert OwnableUnauthorizedAccount(sender);
        }
        _transferOwnership(sender);
    }
}

// lib/openzeppelin-contracts/contracts/interfaces/IERC1363.sol

// OpenZeppelin Contracts (last updated v5.1.0) (interfaces/IERC1363.sol)

/**
 * @title IERC1363
 * @dev Interface of the ERC-1363 standard as defined in the https://eips.ethereum.org/EIPS/eip-1363[ERC-1363].
 *
 * Defines an extension interface for ERC-20 tokens that supports executing code on a recipient contract
 * after `transfer` or `transferFrom`, or code on a spender contract after `approve`, in a single transaction.
 */
interface IERC1363 is IERC20, IERC165 {
    /*
     * Note: the ERC-165 identifier for this interface is 0xb0202a11.
     * 0xb0202a11 ===
     *   bytes4(keccak256('transferAndCall(address,uint256)')) ^
     *   bytes4(keccak256('transferAndCall(address,uint256,bytes)')) ^
     *   bytes4(keccak256('transferFromAndCall(address,address,uint256)')) ^
     *   bytes4(keccak256('transferFromAndCall(address,address,uint256,bytes)')) ^
     *   bytes4(keccak256('approveAndCall(address,uint256)')) ^
     *   bytes4(keccak256('approveAndCall(address,uint256,bytes)'))
     */

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferAndCall(address to, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @param data Additional data with no specified format, sent in call to `to`.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferAndCall(address to, uint256 value, bytes calldata data) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the allowance mechanism
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param from The address which you want to send tokens from.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferFromAndCall(address from, address to, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the allowance mechanism
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param from The address which you want to send tokens from.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @param data Additional data with no specified format, sent in call to `to`.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferFromAndCall(address from, address to, uint256 value, bytes calldata data) external returns (bool);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens and then calls {IERC1363Spender-onApprovalReceived} on `spender`.
     * @param spender The address which will spend the funds.
     * @param value The amount of tokens to be spent.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function approveAndCall(address spender, uint256 value) external returns (bool);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens and then calls {IERC1363Spender-onApprovalReceived} on `spender`.
     * @param spender The address which will spend the funds.
     * @param value The amount of tokens to be spent.
     * @param data Additional data with no specified format, sent in call to `spender`.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function approveAndCall(address spender, uint256 value, bytes calldata data) external returns (bool);
}

// lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol

// OpenZeppelin Contracts (last updated v5.1.0) (token/ERC20/utils/SafeERC20.sol)

/**
 * @title SafeERC20
 * @dev Wrappers around ERC-20 operations that throw on failure (when the token
 * contract returns false). Tokens that return no value (and instead revert or
 * throw on failure) are also supported, non-reverting calls are assumed to be
 * successful.
 * To use this library you can add a `using SafeERC20 for IERC20;` statement to your contract,
 * which allows you to call the safe operations as `token.safeTransfer(...)`, etc.
 */
library SafeERC20 {
    /**
     * @dev An operation with an ERC-20 token failed.
     */
    error SafeERC20FailedOperation(address token);

    /**
     * @dev Indicates a failed `decreaseAllowance` request.
     */
    error SafeERC20FailedDecreaseAllowance(address spender, uint256 currentAllowance, uint256 requestedDecrease);

    /**
     * @dev Transfer `value` amount of `token` from the calling contract to `to`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     */
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeCall(token.transfer, (to, value)));
    }

    /**
     * @dev Transfer `value` amount of `token` from `from` to `to`, spending the approval given by `from` to the
     * calling contract. If `token` returns no value, non-reverting calls are assumed to be successful.
     */
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeCall(token.transferFrom, (from, to, value)));
    }

    /**
     * @dev Increase the calling contract's allowance toward `spender` by `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     *
     * IMPORTANT: If the token implements ERC-7674 (ERC-20 with temporary allowance), and if the "client"
     * smart contract uses ERC-7674 to set temporary allowances, then the "client" smart contract should avoid using
     * this function. Performing a {safeIncreaseAllowance} or {safeDecreaseAllowance} operation on a token contract
     * that has a non-zero temporary allowance (for that particular owner-spender) will result in unexpected behavior.
     */
    function safeIncreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 oldAllowance = token.allowance(address(this), spender);
        forceApprove(token, spender, oldAllowance + value);
    }

    /**
     * @dev Decrease the calling contract's allowance toward `spender` by `requestedDecrease`. If `token` returns no
     * value, non-reverting calls are assumed to be successful.
     *
     * IMPORTANT: If the token implements ERC-7674 (ERC-20 with temporary allowance), and if the "client"
     * smart contract uses ERC-7674 to set temporary allowances, then the "client" smart contract should avoid using
     * this function. Performing a {safeIncreaseAllowance} or {safeDecreaseAllowance} operation on a token contract
     * that has a non-zero temporary allowance (for that particular owner-spender) will result in unexpected behavior.
     */
    function safeDecreaseAllowance(IERC20 token, address spender, uint256 requestedDecrease) internal {
        unchecked {
            uint256 currentAllowance = token.allowance(address(this), spender);
            if (currentAllowance < requestedDecrease) {
                revert SafeERC20FailedDecreaseAllowance(spender, currentAllowance, requestedDecrease);
            }
            forceApprove(token, spender, currentAllowance - requestedDecrease);
        }
    }

    /**
     * @dev Set the calling contract's allowance toward `spender` to `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful. Meant to be used with tokens that require the approval
     * to be set to zero before setting it to a non-zero value, such as USDT.
     *
     * NOTE: If the token implements ERC-7674, this function will not modify any temporary allowance. This function
     * only sets the "standard" allowance. Any temporary allowance will remain active, in addition to the value being
     * set here.
     */
    function forceApprove(IERC20 token, address spender, uint256 value) internal {
        bytes memory approvalCall = abi.encodeCall(token.approve, (spender, value));

        if (!_callOptionalReturnBool(token, approvalCall)) {
            _callOptionalReturn(token, abi.encodeCall(token.approve, (spender, 0)));
            _callOptionalReturn(token, approvalCall);
        }
    }

    /**
     * @dev Performs an {ERC1363} transferAndCall, with a fallback to the simple {ERC20} transfer if the target has no
     * code. This can be used to implement an {ERC721}-like safe transfer that rely on {ERC1363} checks when
     * targeting contracts.
     *
     * Reverts if the returned value is other than `true`.
     */
    function transferAndCallRelaxed(IERC1363 token, address to, uint256 value, bytes memory data) internal {
        if (to.code.length == 0) {
            safeTransfer(token, to, value);
        } else if (!token.transferAndCall(to, value, data)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Performs an {ERC1363} transferFromAndCall, with a fallback to the simple {ERC20} transferFrom if the target
     * has no code. This can be used to implement an {ERC721}-like safe transfer that rely on {ERC1363} checks when
     * targeting contracts.
     *
     * Reverts if the returned value is other than `true`.
     */
    function transferFromAndCallRelaxed(
        IERC1363 token,
        address from,
        address to,
        uint256 value,
        bytes memory data
    ) internal {
        if (to.code.length == 0) {
            safeTransferFrom(token, from, to, value);
        } else if (!token.transferFromAndCall(from, to, value, data)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Performs an {ERC1363} approveAndCall, with a fallback to the simple {ERC20} approve if the target has no
     * code. This can be used to implement an {ERC721}-like safe transfer that rely on {ERC1363} checks when
     * targeting contracts.
     *
     * NOTE: When the recipient address (`to`) has no code (i.e. is an EOA), this function behaves as {forceApprove}.
     * Opposedly, when the recipient address (`to`) has code, this function only attempts to call {ERC1363-approveAndCall}
     * once without retrying, and relies on the returned value to be true.
     *
     * Reverts if the returned value is other than `true`.
     */
    function approveAndCallRelaxed(IERC1363 token, address to, uint256 value, bytes memory data) internal {
        if (to.code.length == 0) {
            forceApprove(token, to, value);
        } else if (!token.approveAndCall(to, value, data)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     *
     * This is a variant of {_callOptionalReturnBool} that reverts if call fails to meet the requirements.
     */
    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        uint256 returnSize;
        uint256 returnValue;
        assembly ("memory-safe") {
            let success := call(gas(), token, 0, add(data, 0x20), mload(data), 0, 0x20)
            // bubble errors
            if iszero(success) {
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
            returnSize := returndatasize()
            returnValue := mload(0)
        }

        if (returnSize == 0 ? address(token).code.length == 0 : returnValue != 1) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     *
     * This is a variant of {_callOptionalReturn} that silently catches all reverts and returns a bool instead.
     */
    function _callOptionalReturnBool(IERC20 token, bytes memory data) private returns (bool) {
        bool success;
        uint256 returnSize;
        uint256 returnValue;
        assembly ("memory-safe") {
            success := call(gas(), token, 0, add(data, 0x20), mload(data), 0, 0x20)
            returnSize := returndatasize()
            returnValue := mload(0)
        }
        return success && (returnSize == 0 ? address(token).code.length > 0 : returnValue == 1);
    }
}

// src/loans/NounLoans.sol

/// @title NounLoans
/// @notice Borrow $CHIP against a Noun, at a fixed fee for a fixed term — and keep earning
///         on it the whole time.
///
/// @dev THE HEADLINE PRODUCT RULE IS THAT COLLATERAL KEEPS EARNING, FOR THE BORROWER.
///
///      This contract is the first registered {IActivationCustodian}. It holds the Noun, and
///      {ChipActivation} asks it who the deposit is for; the answer is the borrower, for as
///      long as the loan is open. So:
///
///        - a chipped Noun can be deposited and keeps its tier — borrowing is not a sale;
///        - a deposited Noun can be chipped and upgraded from inside the vault;
///        - weekly claims go to the borrower, not to this contract, which cannot claim;
///        - repaying changes nothing, because nothing was ever lost;
///        - liquidation ends it, because the loan ended it.
///
///      Nothing in this file implements any of that. It implements {beneficiaryOf} and keeps
///      it truthful; ChipActivation does the rest. That split is deliberate — this contract
///      cannot mint weight, cannot reach a credit, and cannot pay itself a reward.
///
///      REPAYMENT ENDS AT LIQUIDATION, NOT AT A DEADLINE. Past maturity plus grace a loan is
///      seizable by anyone, but the borrower may still repay — with a late fee — right up
///      until somebody actually does. A late borrower races a liquidator rather than being
///      told the money they are holding is no longer wanted. See {repay}.
///
///      SHORT TERMS BY DESIGN. 7 / 14 / 30 / 90 / 180 days, all configurable behind the 48h
///      timelock. The short end is the product — fast churn and fast liquidations — which is
///      also why the grace period is derived from the term rather than fixed: see {graceFor}.
///
///      FIXED FEE, NOT INTEREST. The fee is a flat percentage of principal per term, taken
///      out of the disbursement: borrow 1,000 and receive 1,000 minus the fee. Repayment is
///      principal only, so the amount owed never moves and there is no accrual to compute,
///      no rate oracle, no compounding, and nothing that grows while a borrower is not
///      looking. Fees go to the FeeSplitter, which means a loan funds the next round like
///      every other fee stream.
///
///      V1 IS A SEEDED POOL, NOT A LENDING MARKET. The multisig funds it and the multisig
///      withdraws from it; there are no public lenders, no LP shares and nothing to price.
///      That keeps the entire contract free of the hardest problem in lending — solvency
///      between depositors — because there is exactly one depositor and it is the protocol.
///
///      THE PARITY INVARIANT, WHICH IS OPERATIONAL AND NOT ENFORCEABLE HERE.
///      `maxPrincipal` per collection must be set BELOW what the Noun would fetch in the
///      Anvil, so borrowing is never a better exit than selling and nobody is incentivised
///      to default on purpose. The Anvil does not exist as a contract on Base, so there is
///      nothing to read and this cannot be a require(). It is a number the multisig sets and
///      must keep reviewing. See OPEN_ITEMS.
contract NounLoans is IActivationCustodian, Ownable2Step, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;

    /// @notice Terms offered: 7 / 14 / 30 / 90 / 180 days by default, all configurable.
    /// @dev The product wants SHORT terms — fast churn, fast liquidations — so the ladder
    ///      starts at a week rather than a month.
    uint256 public constant TERM_COUNT = 5;

    /// @notice Longest grace period after maturity, for any term.
    /// @dev See {graceFor}. A loan's own grace is derived from its term and snapshotted at
    ///      borrow, so this is a ceiling rather than the value itself.
    uint64 public constant MAX_GRACE_PERIOD = 7 days;

    /// @notice Notice period on every economic parameter. Same shape as ChipActivation.
    uint64 public constant CONFIG_TIMELOCK = 48 hours;

    /// @notice Immutable ceilings. A compromised multisig cannot exceed them.
    uint32 public constant MAX_FEE_BPS = 5_000; // 50% of principal
    uint32 public constant MAX_BOUNTY_BPS = 1_000; // 10% of principal
    uint64 public constant MAX_TERM = 730 days;

    struct Loan {
        address borrower;
        address collection;
        uint256 tokenId;
        uint256 principal;
        uint256 feePaid;
        uint64 startedAt;
        uint64 dueAt;
        /// @dev Snapshotted at borrow, so a later terms change cannot move a live loan's
        ///      deadline in either direction. See {graceFor}.
        uint64 gracePeriod;
        /// @dev Snapshotted with everything else, so a terms change cannot re-price a
        ///      borrower who is already late.
        uint32 lateFeeBps;
        uint8 termIndex;
        bool closed;
        bool liquidated;
    }

    struct Terms {
        uint64[TERM_COUNT] length;
        uint32[TERM_COUNT] feeBps;
        uint32 bountyBps;
        /// @notice Extra fee, in bps of principal, for repaying after the deadline.
        /// @dev See {repay}. Zero is a valid setting and makes lateness free.
        uint32 lateFeeBps;
    }

    struct PendingTerms {
        bool queued;
        uint64 executableAt;
        Terms terms;
    }

    /// @notice $CHIP. Immutable: the lending asset is not a governance lever.
    IERC20 public immutable chipToken;

    /// @notice Where fees go. The splitter routes them to the Pot, ops and POL like any
    ///         other inflow, so a loan funds the next round.
    address public feeSplitter;

    /// @notice Where liquidated collateral goes.
    address public treasury;

    /// @notice The activation vault. Read to enforce the chip gate, and nothing else.
    /// @dev Repointable because {ChipActivation} is a swappable implementation of
    ///      {IActivationSource}; this contract only ever reads from it.
    IActivationSource public activationSource;

    Terms internal _terms;
    PendingTerms internal _pendingTerms;

    /// @notice Largest principal this collection may borrow. Zero means "cannot borrow",
    ///         which is how an unconfigured collection fails closed.
    mapping(address collection => uint256) public maxPrincipal;

    /// @notice $CHIP the pool actually holds and may lend. Tracked explicitly so the rescue
    ///         can exclude it: see {recoverExcess}.
    uint256 public poolBalance;

    /// @notice $CHIP set aside purely to pay liquidation bounties.
    ///
    /// @dev SEC-LN-002. The bounty used to come out of `poolBalance` and was capped at it, so
    ///      a drained pool paid nothing — exactly when liquidation matters most. A protocol
    ///      whose pool is empty is one with bad loans outstanding, and that is the worst
    ///      possible moment for searchers to lose interest in seizing the collateral.
    ///
    ///      This buffer is separate and **`withdrawPool` cannot touch it**. Emptying it takes
    ///      the deliberate, separately-named {withdrawBountyReserve}, so it cannot be drained
    ///      as a side effect of taking lending capital back out.
    uint256 public bountyReserve;

    /// @notice New borrowing can be halted immediately. Repay and liquidate never can.
    bool public borrowingPaused;

    Loan[] internal _loans;

    /// @notice (collection, tokenId) => loanId + 1 while a loan is open. Zero means none.
    mapping(address collection => mapping(uint256 tokenId => uint256)) internal _openLoanOf;

    /// @notice Running totals, for the site.
    uint256 public totalBorrowed;
    uint256 public totalRepaid;
    uint256 public totalFees;
    uint256 public totalLiquidations;
    uint256 public openLoanCount;

    event LoanOpened(
        uint256 indexed loanId,
        address indexed borrower,
        address indexed collection,
        uint256 tokenId,
        uint8 termIndex,
        uint256 principal,
        uint256 fee,
        uint256 payout,
        uint64 dueAt
    );
    event LoanRepaid(
        uint256 indexed loanId, address indexed borrower, address indexed payer, uint256 principal, uint64 repaidAt
    );
    event LoanLiquidated(
        uint256 indexed loanId,
        address indexed borrower,
        address indexed liquidator,
        uint256 bounty,
        address collateralTo
    );
    event PoolDeposited(address indexed from, uint256 amount, uint256 poolBalance);
    event PoolWithdrawn(address indexed to, uint256 amount, uint256 poolBalance);
    event BountyReserveFunded(address indexed from, uint256 amount, uint256 reserve);
    event BountyReserveWithdrawn(address indexed to, uint256 amount, uint256 reserve);
    event LateFeeCharged(uint256 indexed loanId, address indexed borrower, uint256 lateFee);
    event TermsQueued(uint64[TERM_COUNT] length, uint32[TERM_COUNT] feeBps, uint32 bountyBps, uint64 executableAt);
    event TermsExecuted(uint64[TERM_COUNT] length, uint32[TERM_COUNT] feeBps, uint32 bountyBps);
    event TermsCancelled();
    event MaxPrincipalSet(address indexed collection, uint256 previous, uint256 current);
    event TreasurySet(address indexed previous, address indexed current);
    event FeeSplitterSet(address indexed previous, address indexed current);
    event ActivationSourceSet(address indexed previous, address indexed current);
    event BorrowingPaused(bool paused);
    event Recovered(address indexed token, address indexed to, uint256 amount);
    event RecoveredNFT(address indexed collection, uint256 indexed tokenId, address indexed to);

    error ZeroAddress();
    error BadConfig();
    error BorrowingIsPaused();
    error CollectionNotLendable(address collection);
    error BadTerm(uint8 termIndex);
    error PrincipalTooLarge(uint256 requested, uint256 max);
    error ZeroPrincipal();
    error NotNounOwner(address collection, uint256 tokenId, address caller);
    error AlreadyCollateral(address collection, uint256 tokenId);
    error PoolTooSmall(uint256 needed, uint256 available);
    error NoSuchLoan(uint256 loanId);
    error LoanClosed(uint256 loanId);
    error RepayWindowOver(uint256 loanId, uint64 deadline);
    error NotYetLiquidatable(uint256 loanId, uint64 liquidatableAt);
    error ChipShortfall(uint256 delivered, uint256 required);
    error NothingQueued();
    error TimelockNotElapsed(uint64 nowTs, uint64 executableAt);
    error IsLiveCollateral(address collection, uint256 tokenId);
    error NotChipped(address collection, uint256 tokenId);

    /// @param multisig     Owner. Two-step ownership transfer.
    /// @param chipToken_   $CHIP.
    /// @param feeSplitter_ Where fees go.
    /// @param treasury_    Where liquidated collateral goes.
    /// @param terms_       Term lengths, per-term fees and the liquidation bounty.
    /// @param activation_  {ChipActivation}. Read to enforce the chip gate on {borrow}.
    constructor(
        address multisig,
        address chipToken_,
        address feeSplitter_,
        address treasury_,
        address activation_,
        Terms memory terms_
    ) Ownable(multisig) {
        if (
            multisig == address(0) || chipToken_ == address(0) || feeSplitter_ == address(0) || treasury_ == address(0)
                || activation_ == address(0)
        ) {
            revert ZeroAddress();
        }
        chipToken = IERC20(chipToken_);
        feeSplitter = feeSplitter_;
        treasury = treasury_;
        activationSource = IActivationSource(activation_);
        emit ActivationSourceSet(address(0), activation_);
        _validateTerms(terms_);
        _terms = terms_;
        emit TermsExecuted(terms_.length, terms_.feeBps, terms_.bountyBps);
    }

    /* ------------------------------------------------------------------ */
    /*                              BORROWING                               */
    /* ------------------------------------------------------------------ */

    /// @notice Lock a Noun and receive `principal` minus the term's fee, in $CHIP.
    /// @dev The caller must actually hold the Noun: this takes custody, so a Noun already
    ///      deposited somewhere else cannot be borrowed against here.
    ///
    ///      Everything about the loan is fixed at this moment — principal, fee, due date —
    ///      and no later configuration change reaches it. A borrower's obligation is a
    ///      constant from the block they took it.
    function borrow(address collection, uint256 tokenId, uint8 termIndex, uint256 principal)
        external
        nonReentrant
        returns (uint256 loanId)
    {
        if (borrowingPaused) revert BorrowingIsPaused();
        if (termIndex >= TERM_COUNT) revert BadTerm(termIndex);
        if (principal == 0) revert ZeroPrincipal();

        uint256 cap = maxPrincipal[collection];
        if (cap == 0) revert CollectionNotLendable(collection);
        if (principal > cap) revert PrincipalTooLarge(principal, cap);

        if (_openLoanOf[collection][tokenId] != 0) revert AlreadyCollateral(collection, tokenId);
        if (IERC721(collection).ownerOf(tokenId) != msg.sender) revert NotNounOwner(collection, tokenId, msg.sender);

        // THE CHIP GATE. The Noun must be actively chipped, to this borrower, right now.
        //
        // Lending is a holder benefit, not a standalone product: the whole proposition is
        // "your collateral keeps earning", which is meaningless for a Noun that was not
        // earning to begin with. Gating here also means the pool's collateral is drawn from
        // holders with $CHIP already burned against that exact token, rather than from
        // anyone who happens to hold a Noun.
        //
        // Read from the activation source, not from a flag of our own, so it is the SAME
        // effective-owner computation that decides weight in a round — there is no second
        // notion of "chipped" to drift out of step. The chip then rides through custody by
        // the custodian design: this contract names the borrower as beneficiary, so
        // depositing is not a sale and the activation survives the loan untouched.
        (bool chipped,, address chipOwner) = activationSource.activation(collection, tokenId);
        if (!chipped || chipOwner != msg.sender) revert NotChipped(collection, tokenId);

        // The whole principal leaves the pool: the payout to the borrower plus the fee.
        if (principal > poolBalance) revert PoolTooSmall(principal, poolBalance);

        uint256 fee = (principal * _terms.feeBps[termIndex]) / BPS;
        uint256 payout = principal - fee;
        uint64 termLength = _terms.length[termIndex];
        uint64 dueAt = uint64(block.timestamp) + termLength;
        uint64 grace = _graceFrom(termLength);

        // ---- effects ----
        loanId = _loans.length;
        _loans.push(
            Loan({
                borrower: msg.sender,
                collection: collection,
                tokenId: tokenId,
                principal: principal,
                feePaid: fee,
                startedAt: uint64(block.timestamp),
                dueAt: dueAt,
                gracePeriod: grace,
                lateFeeBps: _terms.lateFeeBps,
                termIndex: termIndex,
                closed: false,
                liquidated: false
            })
        );
        _openLoanOf[collection][tokenId] = loanId + 1;
        poolBalance -= principal;
        totalBorrowed += principal;
        totalFees += fee;
        openLoanCount += 1;

        // ---- interactions ----
        // Take the collateral FIRST. If this fails nothing has been paid out.
        IERC721(collection).transferFrom(msg.sender, address(this), tokenId);
        if (payout != 0) chipToken.safeTransfer(msg.sender, payout);
        if (fee != 0) chipToken.safeTransfer(feeSplitter, fee);

        emit LoanOpened(loanId, msg.sender, collection, tokenId, termIndex, principal, fee, payout, dueAt);
    }

    /// @notice Repay a loan's principal and get the Noun back.
    ///
    /// @dev PERMISSIONLESS, and the Noun always returns to the BORROWER rather than to the
    ///      caller. A stranger repaying can therefore only help, exactly like
    ///      `ChipClaims.claimFor`. It also means a borrower can be bailed out by a friend
    ///      without handing over a key.
    ///
    ///      REPAYMENT STAYS OPEN UNTIL SOMEBODY ACTUALLY LIQUIDATES, not until a deadline.
    ///
    ///      This used to close at maturity plus grace, and that was a bad rule. A borrower who
    ///      turned up on day 8 of a 7-day loan holding the full principal was refused — and
    ///      then kept waiting, still owning the Noun, until a liquidator happened to appear.
    ///      The protocol gained nothing from that window: it was refusing money it was owed on
    ///      collateral it had not seized. Raised by external review as SEC-LN-003.
    ///
    ///      Now the only thing that ends the right to repay is the thing that actually takes
    ///      the Noun away. Past the deadline a `lateFeeBps` surcharge applies, so lateness has
    ///      a price and the term structure still means something — without it, a term would be
    ///      advisory and the cheapest strategy would be to never repay on time.
    ///
    ///      The deadline still governs LIQUIDATION: past it anyone may seize the collateral,
    ///      and whoever moves first wins. A late borrower is racing a liquidator, which is the
    ///      honest description of their position.
    function repay(uint256 loanId) external nonReentrant returns (uint256 paid) {
        Loan storage l = _loanAt(loanId);
        if (l.closed) revert LoanClosed(loanId);

        uint256 principal = l.principal;
        address borrower = l.borrower;
        address collection = l.collection;
        uint256 tokenId = l.tokenId;

        uint256 lateFee = _lateFeeOn(l);
        paid = principal + lateFee;

        // ---- effects ----
        l.closed = true;
        delete _openLoanOf[collection][tokenId];
        poolBalance += principal;
        totalRepaid += principal;
        totalFees += lateFee;
        openLoanCount -= 1;

        // ---- interactions ----
        // Measured, so a $CHIP that reports a transfer it did not make cannot free a Noun.
        uint256 before = chipToken.balanceOf(address(this));
        chipToken.safeTransferFrom(msg.sender, address(this), paid);
        uint256 delivered = chipToken.balanceOf(address(this)) - before;
        if (delivered < paid) revert ChipShortfall(delivered, paid);

        // The late fee follows the origination fee: out to the FeeSplitter, never into the
        // pool, so a late repayment funds the next round rather than quietly growing the pool.
        if (lateFee != 0) chipToken.safeTransfer(feeSplitter, lateFee);

        IERC721(collection).transferFrom(address(this), borrower, tokenId);

        emit LoanRepaid(loanId, borrower, msg.sender, principal, uint64(block.timestamp));
        if (lateFee != 0) emit LateFeeCharged(loanId, borrower, lateFee);
    }

    /// @dev Zero until the deadline passes, then a flat percentage of principal. Flat rather
    ///      than accruing, for the same reason the origination fee is: nothing in this
    ///      contract should grow while a borrower is not looking.
    function _lateFeeOn(Loan storage l) internal view returns (uint256) {
        if (block.timestamp <= l.dueAt + l.gracePeriod) return 0;
        return (l.principal * l.lateFeeBps) / BPS;
    }

    /// @notice What repaying `loanId` costs right now, principal plus any late fee.
    function repayAmount(uint256 loanId) external view returns (uint256 principal, uint256 lateFee) {
        Loan storage l = _loanAt(loanId);
        principal = l.principal;
        lateFee = _lateFeeOn(l);
    }

    /// @notice Seize the collateral of a loan that ran past its grace period.
    ///
    /// @dev PERMISSIONLESS, with a bounty, because a loan nobody closes is a Noun nobody can
    ///      use and a pool that never learns it lost money. The bounty is paid from the pool
    ///      and capped by what the pool actually holds, so an empty pool means liquidation
    ///      still works and simply pays nothing — the collateral must be recoverable even
    ///      when there is no money left to pay a bounty with.
    function liquidate(uint256 loanId) external nonReentrant returns (uint256 bounty) {
        Loan storage l = _loanAt(loanId);
        if (l.closed) revert LoanClosed(loanId);

        uint64 liquidatableAt = l.dueAt + l.gracePeriod;
        if (block.timestamp <= liquidatableAt) revert NotYetLiquidatable(loanId, liquidatableAt);

        address borrower = l.borrower;
        address collection = l.collection;
        uint256 tokenId = l.tokenId;
        address to = treasury;

        // SEC-LN-002: the reserve pays first, so a drained pool still rewards a liquidator.
        bounty = (l.principal * _terms.bountyBps) / BPS;
        uint256 fromReserve = bounty <= bountyReserve ? bounty : bountyReserve;
        uint256 fromPool = bounty - fromReserve;
        if (fromPool > poolBalance) fromPool = poolBalance;
        bounty = fromReserve + fromPool;

        // ---- effects ----
        l.closed = true;
        l.liquidated = true;
        delete _openLoanOf[collection][tokenId];
        bountyReserve -= fromReserve;
        poolBalance -= fromPool;
        totalLiquidations += 1;
        openLoanCount -= 1;

        // ---- interactions ----
        IERC721(collection).transferFrom(address(this), to, tokenId);
        if (bounty != 0) chipToken.safeTransfer(msg.sender, bounty);

        emit LoanLiquidated(loanId, borrower, msg.sender, bounty, to);
    }

    /* ------------------------------------------------------------------ */
    /*                       IActivationCustodian                           */
    /* ------------------------------------------------------------------ */

    /// @inheritdoc IActivationCustodian
    /// @dev THE ONE FUNCTION THAT MAKES COLLATERAL KEEP EARNING. It names the borrower while
    ///      the loan is open and nobody once it is not, so a liquidation ends the activation
    ///      by the same act that ends the loan — there is no second thing to remember to do.
    ///
    ///      It answers only for Nouns this contract is actually holding under an open loan.
    ///      That is what bounds the trust ChipActivation places in it: see
    ///      {IActivationCustodian}.
    function beneficiaryOf(address collection, uint256 tokenId) external view override returns (address) {
        uint256 slot = _openLoanOf[collection][tokenId];
        if (slot == 0) return address(0);
        Loan storage l = _loans[slot - 1];
        if (l.closed) return address(0);
        return l.borrower;
    }

    /* ------------------------------------------------------------------ */
    /*                               VIEWS                                  */
    /* ------------------------------------------------------------------ */

    function loanCount() external view returns (uint256) {
        return _loans.length;
    }

    function getLoan(uint256 loanId) external view returns (Loan memory) {
        return _loanAt(loanId);
    }

    /// @notice The open loan against a Noun, if any.
    function openLoanIdOf(address collection, uint256 tokenId) external view returns (bool exists, uint256 loanId) {
        uint256 slot = _openLoanOf[collection][tokenId];
        if (slot == 0) return (false, 0);
        return (true, slot - 1);
    }

    /// @notice Whether `tokenId` would pass the chip gate for `who` right now.
    /// @dev So the site can grey out "Borrow" with a reason rather than letting someone
    ///      discover the rule from a reverted transaction.
    function isChippedFor(address collection, uint256 tokenId, address who) external view returns (bool) {
        (bool chipped,, address chipOwner) = activationSource.activation(collection, tokenId);
        return chipped && chipOwner == who;
    }

    function isCollateral(address collection, uint256 tokenId) public view returns (bool) {
        return _openLoanOf[collection][tokenId] != 0;
    }

    /// @notice Grace period a loan on `termIndex` would get: `min(7 days, term / 2)`.
    ///
    /// @dev A FLAT SEVEN DAYS DOES NOT SURVIVE THE SHORT END. On the old 30/90/180 ladder a
    ///      week of grace was a modest tail. On a 7-day loan it is another 100% of the term —
    ///      the borrower gets a fortnight to repay a one-week loan, the liquidator waits
    ///      twice as long as the product promises, and "fast churn" stops being true.
    ///
    ///      Halving the term instead keeps grace proportionate where it matters and identical
    ///      where it already worked: 7d gives 3.5d, 14d gives 7d, and everything from 30d up
    ///      is capped at the same 7 days it always had. Nothing on the long end changes.
    ///
    ///      DERIVED, NOT CONFIGURED, and that is the point. Five more settable numbers would
    ///      be five more ways for the grace to drift out of step with the term it belongs to —
    ///      a 7-day term with a 30-day grace is a configuration nobody would notice until a
    ///      liquidator complained. This cannot be set wrong because it cannot be set.
    function graceFor(uint8 termIndex) public view returns (uint64) {
        if (termIndex >= TERM_COUNT) revert BadTerm(termIndex);
        return _graceFrom(_terms.length[termIndex]);
    }

    function _graceFrom(uint64 termLength) internal pure returns (uint64) {
        uint64 half = termLength / 2;
        return half < MAX_GRACE_PERIOD ? half : MAX_GRACE_PERIOD;
    }

    /// @notice What a loan would look like, before taking it.
    function quote(uint8 termIndex, uint256 principal)
        external
        view
        returns (uint256 fee, uint256 payout, uint64 dueAt, uint64 deadline)
    {
        if (termIndex >= TERM_COUNT) revert BadTerm(termIndex);
        fee = (principal * _terms.feeBps[termIndex]) / BPS;
        payout = principal - fee;
        uint64 length = _terms.length[termIndex];
        dueAt = uint64(block.timestamp) + length;
        deadline = dueAt + _graceFrom(length);
    }

    function terms() external view returns (Terms memory) {
        return _terms;
    }

    function pendingTerms() external view returns (PendingTerms memory) {
        return _pendingTerms;
    }

    function isLiquidatable(uint256 loanId) external view returns (bool) {
        Loan storage l = _loanAt(loanId);
        return !l.closed && block.timestamp > l.dueAt + l.gracePeriod;
    }

    /// @notice When this loan stops being repayable and starts being liquidatable.
    function deadlineOf(uint256 loanId) external view returns (uint64) {
        Loan storage l = _loanAt(loanId);
        return l.dueAt + l.gracePeriod;
    }

    function _loanAt(uint256 loanId) internal view returns (Loan storage) {
        if (loanId >= _loans.length) revert NoSuchLoan(loanId);
        return _loans[loanId];
    }

    /* ------------------------------------------------------------------ */
    /*                          GOVERNANCE: POOL                            */
    /* ------------------------------------------------------------------ */

    /// @notice Fund the lending pool. Multisig only in v1.
    /// @dev Measured, so the pool never believes it holds more than it does.
    function depositPool(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroPrincipal();
        uint256 before = chipToken.balanceOf(address(this));
        chipToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 delivered = chipToken.balanceOf(address(this)) - before;
        if (delivered < amount) revert ChipShortfall(delivered, amount);

        poolBalance += amount;
        emit PoolDeposited(msg.sender, amount, poolBalance);
    }

    /// @notice Top up the liquidation bounty buffer. Multisig only.
    /// @dev Measured, like every other inbound transfer here.
    function fundBountyReserve(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroPrincipal();
        uint256 before = chipToken.balanceOf(address(this));
        chipToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 delivered = chipToken.balanceOf(address(this)) - before;
        if (delivered < amount) revert ChipShortfall(delivered, amount);

        bountyReserve += amount;
        emit BountyReserveFunded(msg.sender, amount, bountyReserve);
    }

    /// @notice Take $CHIP back out of the bounty buffer. Multisig only.
    /// @dev DELIBERATELY SEPARATE FROM {withdrawPool}. Draining the buffer should be an
    ///      explicit decision to stop paying liquidators, never a side effect of pulling
    ///      lending capital.
    function withdrawBountyReserve(uint256 amount, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0 || amount > bountyReserve) revert PoolTooSmall(amount, bountyReserve);
        bountyReserve -= amount;
        chipToken.safeTransfer(to, amount);
        emit BountyReserveWithdrawn(to, amount, bountyReserve);
    }

    /// @notice Take $CHIP back out of the pool. Multisig only.
    /// @dev Bounded by `poolBalance`, which already excludes every principal that is out on
    ///      loan, so this cannot spend money that is not there. It CAN drain the pool below
    ///      what pending liquidation bounties would cost, which is why {liquidate} caps the
    ///      bounty at the balance rather than reverting.
    function withdrawPool(uint256 amount, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0 || amount > poolBalance) revert PoolTooSmall(amount, poolBalance);
        poolBalance -= amount;
        chipToken.safeTransfer(to, amount);
        emit PoolWithdrawn(to, amount, poolBalance);
    }

    /* ------------------------------------------------------------------ */
    /*                        GOVERNANCE: SETTINGS                          */
    /* ------------------------------------------------------------------ */

    /// @notice Set how much a collection may borrow. Zero disables it.
    /// @dev NOT timelocked, in either direction, and deliberately so: this only ever affects
    ///      loans not yet taken, so notice buys a borrower nothing, and being able to set it
    ///      to zero immediately is the switch to pull if a collection's floor collapses.
    ///      MUST be kept below Anvil parity — see the contract header.
    function setMaxPrincipal(address collection, uint256 amount) external onlyOwner {
        if (collection == address(0)) revert ZeroAddress();
        emit MaxPrincipalSet(collection, maxPrincipal[collection], amount);
        maxPrincipal[collection] = amount;
    }

    /// @notice Halt or resume new borrowing. Immediate: it is a safety action.
    /// @dev Repay and liquidate are never pausable. A borrower must always be able to get
    ///      their Noun back, and collateral must always be recoverable.
    function setBorrowingPaused(bool paused) external onlyOwner {
        borrowingPaused = paused;
        emit BorrowingPaused(paused);
    }

    function setTreasury(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        emit TreasurySet(treasury, v);
        treasury = v;
    }

    function setFeeSplitter(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        emit FeeSplitterSet(feeSplitter, v);
        feeSplitter = v;
    }

    /// @notice Repoint at a new activation vault. Multisig only.
    /// @dev Only affects NEW borrows. An open loan is never re-checked against the gate:
    ///      a borrower who lets their chip lapse mid-loan keeps their loan, they simply stop
    ///      earning. Losing a Noun over a lapsed chip would be a wildly disproportionate
    ///      penalty, and would hand a liquidation trigger to whoever controls the vault.
    function setActivationSource(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        emit ActivationSourceSet(address(activationSource), v);
        activationSource = IActivationSource(v);
    }

    /* ------------------------------------------------------------------ */
    /*                    GOVERNANCE: TERMS (48h TIMELOCK)                  */
    /* ------------------------------------------------------------------ */

    /// @notice Queue new term lengths, fees and liquidation bounty. 48h notice.
    /// @dev Existing loans are untouched whatever this does: principal, fee and due date are
    ///      all snapshotted at `borrow`.
    function queueTerms(Terms calldata terms_) external onlyOwner {
        _validateTerms(terms_);
        uint64 executableAt = uint64(block.timestamp) + CONFIG_TIMELOCK;
        _pendingTerms = PendingTerms({queued: true, executableAt: executableAt, terms: terms_});
        emit TermsQueued(terms_.length, terms_.feeBps, terms_.bountyBps, executableAt);
    }

    function executeTerms() external onlyOwner {
        PendingTerms memory p = _pendingTerms;
        if (!p.queued) revert NothingQueued();
        if (block.timestamp < p.executableAt) revert TimelockNotElapsed(uint64(block.timestamp), p.executableAt);

        _terms = p.terms;
        delete _pendingTerms;
        emit TermsExecuted(p.terms.length, p.terms.feeBps, p.terms.bountyBps);
    }

    function cancelTerms() external onlyOwner {
        if (!_pendingTerms.queued) revert NothingQueued();
        delete _pendingTerms;
        emit TermsCancelled();
    }

    function _validateTerms(Terms memory t) internal pure {
        if (t.bountyBps > MAX_BOUNTY_BPS) revert BadConfig();
        if (t.lateFeeBps > MAX_FEE_BPS) revert BadConfig();
        for (uint256 i; i < TERM_COUNT; ++i) {
            if (t.length[i] == 0 || t.length[i] > MAX_TERM) revert BadConfig();
            if (t.feeBps[i] > MAX_FEE_BPS) revert BadConfig();
            // Longer terms must not be cheaper: a fee curve that inverts would price a
            // 180-day loan below a 30-day one and make the short terms pointless.
            if (i != 0) {
                if (t.length[i] <= t.length[i - 1]) revert BadConfig();
                if (t.feeBps[i] < t.feeBps[i - 1]) revert BadConfig();
            }
        }
    }

    /* ------------------------------------------------------------------ */
    /*                               RESCUE                                 */
    /* ------------------------------------------------------------------ */

    /// @notice Sweep a token that ended up here. Multisig only.
    ///
    /// @dev EXCLUSION-STYLE, and $CHIP is the exclusion that matters. For $CHIP only the
    ///      surplus above `poolBalance` can move, so the lending pool — and therefore every
    ///      borrower's ability to be repaid into and every liquidator's bounty — is out of
    ///      reach of this function by arithmetic rather than by policy. Any other token is
    ///      swept whole, because this contract has no legitimate reason to hold one.
    function recoverExcess(address token, address to) external onlyOwner nonReentrant {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 amount = balance;
        if (token == address(chipToken)) {
            uint256 reserved = poolBalance + bountyReserve;
            amount = balance > reserved ? balance - reserved : 0;
        }
        if (amount != 0) {
            IERC20(token).safeTransfer(to, amount);
            emit Recovered(token, to, amount);
        }
    }

    /// @notice Return an NFT that is not collateral. Multisig only.
    /// @dev REVERTS ON LIVE COLLATERAL. A borrower's Noun can leave this contract in exactly
    ///      two ways — {repay} returns it to them, {liquidate} sends it to the treasury —
    ///      and the multisig has no third path. Anything else here arrived by accident,
    ///      including via {onERC721Received}, and this is how it goes home.
    function recoverNFT(address collection, uint256 tokenId, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (isCollateral(collection, tokenId)) revert IsLiveCollateral(collection, tokenId);
        IERC721(collection).transferFrom(address(this), to, tokenId);
        emit RecoveredNFT(collection, tokenId, to);
    }

    /// @notice Accept NFTs so a `safeTransferFrom` does not revert.
    /// @dev Does NOT create a loan. {borrow} is the only thing that does, and it pulls with
    ///      `transferFrom`, so a Noun pushed here is collateral for nothing, earns nothing,
    ///      and is recoverable with {recoverNFT}.
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
