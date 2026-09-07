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

// src/activation/ChipActivation.sol

/// @title ChipActivation
/// @notice Chipworks' own non-custodial soft-staking vault. Burn $CHIP to activate a Noun at
///         a tier; the Noun never moves; the activation resets the moment it changes hands.
///
/// @dev THIS REPLACES CLUTCH. It is the production implementation behind the same
///      {IActivationSource} interface `ChipRounds` already reads, so nothing downstream
///      changed to adopt it: one multisig call to `setActivationSource`.
///      `ClutchVaultAdapter` stays in the repo as the retired alternative implementation
///      and is not deployed. See AUDIT_BRIEF section 7 for why Clutch is off the table.
///
///      FOUR PROPERTIES, IN THE ORDER THEY MATTER.
///
///      1. NON-CUSTODIAL, STRUCTURALLY. This contract never takes a Noun. It has no
///         `onERC721Received`, so `safeTransferFrom` into it reverts, and it holds no NFT to
///         lose. Activation is a record keyed by (collection, tokenId), nothing more.
///
///      2. RESET IS LAZY AND ATOMIC, WITH NO KEEPER. There is no `kick`, and no job that has
///         to run for correctness. Every read — the weight `ChipRounds` books, and every view
///         the site shows — recomputes the effective owner and compares it to the owner at
///         activation. They disagree, the token is inactive, that instant, for everybody.
///         A sold Noun stops earning in the same block it is sold, with nobody doing
///         anything. THIS IS THE BUG CLASS THAT SANK THE CLUTCH ROUTE: their vault records a
///         stale owner after a transfer and needs `kick` to catch up, so five of fourteen
///         sampled live activations on Robinhood are earning for sellers right now
///         (CLUTCH_RECON section 3). Nothing here can drift, because nothing here is stored
///         that could go stale.
///
///         NOTE ON "TIER 0". The spec says a transferred Noun "simply reads as tier 0",
///         meaning inactive. The tier TABLE says index 0 is the base tier worth 1.00x.
///         Those two collide (ASSUMPTIONS A-12) and this contract resolves it the only safe
///         way: activation status is `ownerAtActivation != 0` AND the owner check passing.
///         Tier is never used to infer whether a Noun is activated, so a reset returns
///         `active = false`, not `tierBps = 10000`. Do not "simplify" this by treating tier
///         index 0 as inactive — that would silently zero every base-tier Noun.
///
///      3. CUSTODY IS ALLOWLISTED, WHICH IS WHAT MAKES LENDING POSSIBLE. Plain soft staking
///         cannot tell a sale from a deposit: both are `ownerOf` changing. When `ownerOf` is
///         a registered custodian, the effective owner is whatever that custodian names as
///         beneficiary, so a Noun locked as loan collateral keeps earning FOR THE BORROWER.
///         Chip while collateralised works, borrow while chipped keeps earning, repay
///         changes nothing, liquidation resets. See {IActivationCustodian} for the trust
///         model and `NounLoans` for the first registered custodian.
///
///      4. 100% OF THE COST BURNS. Clutch took 5% of every activation. There is no cut here,
///         no treasury leg and no fee address: `activate` moves $CHIP from the caller
///         straight to `0xdead` and this contract holds no $CHIP between transactions. That
///         is structural, not policy — there is no code path that could route it elsewhere,
///         and `test_theContractNeverHoldsChip` asserts the balance is zero after every
///         operation. $CHIP is a standard ERC-20 from a Doppler/Bankr launch with no
///         `burn()`, so a transfer to `0xdead` is the burn.
///
///      THREE PROPERTIES REVIEWED AND KEPT AS INTENDED (TRIAGE SEC-ACT-002/003/004):
///
///      - **Revival on repurchase is free.** A holder who sells and later buys the same Noun
///        back has their tier restored at no cost, even if the table has risen. The "top up
///        the difference" alternative cannot be built without either deactivating continuous
///        holders on a price rise or adding a transfer hook this design deliberately avoids —
///        and the exploit is bounded to selling your own Noun and buying that exact token
///        back. Revival is bound to the original activator, so a tier can never be sold with
///        the Noun.
///      - **Upgrading credits the current table's lower tier**, not what was actually paid,
///        so an early adopter upgrades more cheaply after a price rise. Deliberate: the
///        alternative penalises early activation, which is the behaviour being rewarded.
///      - **Registering a custodian is immediate.** Its blast radius is bounded to tokens
///        physically held by that custodian, and it is not timelocked because
///        `setCustodian` is already the single most forgettable call in the deploy runbook —
///        splitting it into two transactions 48 hours apart would make the one step that
///        fails silently harder to complete, not safer.
///
///      COSTS AND WEIGHTS ARE CONFIGURATION, BEHIND A 48H TIMELOCK. Denominations are set at
///      token launch and nothing about them is hardcoded. Both the per-collection cost table
///      and the tier weight curve move only through queue -> 48h -> execute, each step
///      emitting an event, so a change is public long before it binds. This is deliberately
///      stricter than the retired adapter, which let the multisig retune tier weights in one
///      transaction: the weight curve decides what everybody earns, and it should not be
///      able to change without notice. Registering a collection for the first time uses the
///      same path — it costs 48h once, and keeps one code path instead of two.
contract ChipActivation is IActivationSource, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Tier indices 0..4.
    uint256 public constant TIER_COUNT = 5;

    /// @notice Notice period on every economic parameter. Same shape as the Furnace.
    uint64 public constant CONFIG_TIMELOCK = 48 hours;

    /// @notice Where activation costs go. Not a contract, so nothing is recoverable from it.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Gas cap on every call into a foreign collection or custodian.
    /// @dev A contract that reverts with an invalid opcode consumes every wei of gas handed
    ///      to it and would otherwise take a whole round down with it. See ASSUMPTIONS A-17.
    uint256 public constant PROBE_GAS = 100_000;

    /// @notice One activation. Absent when `ownerAtActivation` is zero.
    /// @dev `ownerAtActivation` is the address that paid, NOT a live owner. The live owner is
    ///      recomputed on every read; this is the value it is compared against.
    struct Activation {
        uint8 tier;
        address ownerAtActivation;
        uint64 activatedAt;
    }

    /// @notice $CHIP. Immutable: the burn asset is not a governance lever.
    IERC20 public immutable chipToken;

    mapping(address collection => mapping(uint256 tokenId => Activation)) internal _activations;

    /// @notice Whether a collection can be activated at all. False fails closed.
    mapping(address collection => bool) public collectionConfigured;

    /// @notice collection => cost in $CHIP to hold each tier outright. Non-decreasing.
    mapping(address collection => uint256[TIER_COUNT]) internal _tierCost;

    /// @notice Tier index => weight in basis points (10000 = 1.00x). Non-decreasing.
    uint32[TIER_COUNT] public tierBps;

    /// @notice Contracts allowed to hold a Noun without voiding its activation.
    mapping(address custodian => bool) public isCustodian;

    struct PendingCosts {
        bool queued;
        uint64 executableAt;
        uint256[TIER_COUNT] cost;
    }

    struct PendingTiers {
        bool queued;
        uint64 executableAt;
        uint32[TIER_COUNT] bps;
    }

    mapping(address collection => PendingCosts) internal _pendingCosts;
    PendingTiers internal _pendingTiers;

    /// @notice Running totals, for the site.
    uint256 public totalChipBurned;
    uint256 public totalActivations;
    uint256 public totalUpgrades;

    event Activated(
        address indexed collection, uint256 indexed tokenId, address indexed owner, uint8 tier, uint256 chipBurned
    );
    event Upgraded(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed owner,
        uint8 fromTier,
        uint8 toTier,
        uint256 chipBurned
    );
    event CostsQueued(address indexed collection, uint256[TIER_COUNT] cost, uint64 executableAt);
    event CostsExecuted(address indexed collection, uint256[TIER_COUNT] cost);
    event CostsCancelled(address indexed collection);
    event TiersQueued(uint32[TIER_COUNT] bps, uint64 executableAt);
    event TiersExecuted(uint32[TIER_COUNT] bps);
    event TiersCancelled();
    event CustodianSet(address indexed custodian, bool allowed);
    event Recovered(address indexed token, address indexed to, uint256 amount);
    event RecoveredNFT(address indexed collection, uint256 indexed tokenId, address indexed to);

    error ZeroAddress();
    error BadTier(uint256 tier);
    error BadConfig();
    error CollectionNotConfigured(address collection);
    error NotEffectiveOwner(address collection, uint256 tokenId, address caller);
    error AlreadyActive(address collection, uint256 tokenId);
    error NotActive(address collection, uint256 tokenId);
    error NotAnUpgrade(uint8 currentTier, uint8 requestedTier);
    error NothingQueued();
    error TimelockNotElapsed(uint64 nowTs, uint64 executableAt);
    error ChipBurnShortfall(uint256 delivered, uint256 required);

    /// @param multisig   Owner. Two-step ownership transfer.
    /// @param chipToken_ $CHIP.
    /// @param tierBps_   Weight curve, basis points. Chipworks ships 1.00 / 1.25 / 1.60 /
    ///                   2.00 / 3.33 as `[10000, 12500, 16000, 20000, 33300]`.
    /// @dev Collections are registered after deploy through the timelocked cost path, so a
    ///      freshly deployed ChipActivation accepts no activations at all until the multisig
    ///      configures at least one. That is the intended failure mode: forgetting a
    ///      collection makes it earn nothing rather than earn for free.
    constructor(address multisig, address chipToken_, uint32[TIER_COUNT] memory tierBps_) Ownable(multisig) {
        if (multisig == address(0) || chipToken_ == address(0)) revert ZeroAddress();
        chipToken = IERC20(chipToken_);
        _validateTiers(tierBps_);
        tierBps = tierBps_;
        emit TiersExecuted(tierBps_);
    }

    /* ------------------------------------------------------------------ */
    /*                             ACTIVATION                               */
    /* ------------------------------------------------------------------ */

    /// @notice Activate `tokenId` at `tier`, burning the tier's full cost in $CHIP.
    /// @dev The caller must be the EFFECTIVE owner, so a borrower whose Noun sits in a
    ///      registered custodian can activate it without withdrawing — "chip while
    ///      collateralised".
    ///
    ///      A token whose previous activation has lapsed (it changed hands) is simply
    ///      activated afresh at full price by its new owner. There is nothing to clear
    ///      first: the old record is dead the moment the owner check fails, and it is
    ///      overwritten here.
    function activate(address collection, uint256 tokenId, uint8 tier) external nonReentrant {
        if (!collectionConfigured[collection]) revert CollectionNotConfigured(collection);
        if (tier >= TIER_COUNT) revert BadTier(tier);

        address effective = _effectiveOwner(collection, tokenId);
        if (effective == address(0) || effective != msg.sender) {
            revert NotEffectiveOwner(collection, tokenId, msg.sender);
        }

        // A live activation is upgraded, never re-bought: paying full price for a tier you
        // already hold would be a silent loss.
        Activation storage a = _activations[collection][tokenId];
        if (a.ownerAtActivation == effective) revert AlreadyActive(collection, tokenId);

        uint256 cost = _tierCost[collection][tier];

        // ---- effects, before the burn ----
        a.tier = tier;
        a.ownerAtActivation = effective;
        a.activatedAt = uint64(block.timestamp);
        totalActivations += 1;

        _burnChip(cost);

        emit Activated(collection, tokenId, effective, tier, cost);
    }

    /// @notice Raise a live activation to `newTier`, paying only the difference.
    /// @dev Requires a live activation held by the caller. Tiers only ever go up: a
    ///      downgrade would owe a refund out of tokens that are already burned.
    function upgrade(address collection, uint256 tokenId, uint8 newTier) external nonReentrant {
        if (!collectionConfigured[collection]) revert CollectionNotConfigured(collection);
        if (newTier >= TIER_COUNT) revert BadTier(newTier);

        Activation storage a = _activations[collection][tokenId];
        address recorded = a.ownerAtActivation;
        if (recorded == address(0)) revert NotActive(collection, tokenId);

        address effective = _effectiveOwner(collection, tokenId);
        if (effective == address(0) || effective != recorded) revert NotActive(collection, tokenId);
        if (effective != msg.sender) revert NotEffectiveOwner(collection, tokenId, msg.sender);

        uint8 current = a.tier;
        if (newTier <= current) revert NotAnUpgrade(current, newTier);

        // Non-decreasing costs are enforced on every accepted table, so this cannot underflow.
        uint256 cost = _tierCost[collection][newTier] - _tierCost[collection][current];

        a.tier = newTier;
        totalUpgrades += 1;

        _burnChip(cost);

        emit Upgraded(collection, tokenId, effective, current, newTier, cost);
    }

    /// @dev Moves $CHIP from the caller straight to `0xdead` and MEASURES what arrived.
    ///      A $CHIP that taxes transfers, or lies about them, would otherwise buy an
    ///      activation under-paid. Failing closed is the right direction: the whole call
    ///      reverts and nothing is recorded.
    function _burnChip(uint256 amount) internal {
        if (amount == 0) return;
        uint256 before = chipToken.balanceOf(BURN_ADDRESS);
        chipToken.safeTransferFrom(msg.sender, BURN_ADDRESS, amount);
        uint256 delivered = chipToken.balanceOf(BURN_ADDRESS) - before;
        if (delivered < amount) revert ChipBurnShortfall(delivered, amount);
        totalChipBurned += amount;
    }

    /* ------------------------------------------------------------------ */
    /*                        $CHIP BURN VISIBILITY                         */
    /* ------------------------------------------------------------------ */

    /// @notice Every $CHIP ever sent to `0xdead`, by anyone, for any reason.
    ///
    /// @dev THIS IS THE AUTHORITATIVE NUMBER, and it is deliberately not our own counter.
    ///      {totalChipBurned} on this contract counts only what THIS contract burned;
    ///      `ChipRounds` and `Furnace` keep their own. Summing three counters would miss a
    ///      fourth contract added later, and would miss anyone who burned $CHIP by sending it
    ///      to `0xdead` directly. The dead address's balance misses nothing.
    function chipBurnedToDead() public view returns (uint256) {
        return chipToken.balanceOf(BURN_ADDRESS);
    }

    /// @notice $CHIP actually in circulation: total supply less everything burned.
    ///
    /// @dev **$CHIP CANNOT BE TRULY BURNED, AND THIS IS THE WORKAROUND.** Bankr's Doppler
    ///      token exposes no `burn`, so `totalSupply()` does not fall when the protocol burns
    ///      — the tokens sit at `0xdead` forever, unreachable but still counted. That is a
    ///      limitation of a contract we do not own, not a shortcut in this one.
    ///
    ///      So the honest circulating figure is this subtraction, and it has to be surfaced
    ///      deliberately: by the site, and by filing `0x…dEaD` with CoinGecko and CMC as an
    ///      excluded burn address after launch. Until that filing lands, aggregators will
    ///      overstate $CHIP supply by exactly {chipBurnedToDead}. See README and DEPLOY.
    ///
    ///      Contrast the Furnace's fuel, which IS truly burned: Chiplets is OpenSea's
    ///      `ERC721SeaDrop` (ERC721A), which exposes `burn`, so forging genuinely reduces that
    ///      collection's supply.
    function effectiveChipSupply() external view returns (uint256) {
        uint256 supply = chipToken.totalSupply();
        uint256 burned = chipBurnedToDead();
        return burned >= supply ? 0 : supply - burned;
    }

    /* ------------------------------------------------------------------ */
    /*                          IActivationSource                           */
    /* ------------------------------------------------------------------ */

    /// @inheritdoc IActivationSource
    /// @dev NEVER REVERTS. An unconfigured collection, a token that has changed hands, a
    ///      collection or custodian that fails any probe — all report as simply inactive, so
    ///      one broken entry can never take a whole round down.
    ///
    ///      This is where the lazy reset happens. There is no stored "active" flag to go
    ///      stale: the answer is recomputed from the live owner every single time.
    function activation(address collection, uint256 tokenId)
        external
        view
        override
        returns (bool active, uint32 tierBps_, address owner)
    {
        Activation storage a = _activations[collection][tokenId];
        address recorded = a.ownerAtActivation;
        if (recorded == address(0)) return (false, 0, address(0));

        address effective = _effectiveOwner(collection, tokenId);
        if (effective == address(0) || effective != recorded) return (false, 0, address(0));

        uint32 bps = tierBps[a.tier];
        if (bps == 0) return (false, 0, address(0));

        return (true, bps, recorded);
    }

    /// @inheritdoc IActivationSource
    function isSupportedCollection(address collection) external view override returns (bool) {
        return collectionConfigured[collection];
    }

    /* ------------------------------------------------------------------ */
    /*                          EFFECTIVE OWNER                             */
    /* ------------------------------------------------------------------ */

    /// @notice Who really owns `tokenId` for activation purposes.
    /// @dev `ownerOf`, except that a registered custodian is asked who it holds the token
    ///      for. Both calls are gas-capped staticcalls and any failure returns zero, which
    ///      reads as "no effective owner" and resets the activation.
    ///
    ///      A custodian is only ever consulted about tokens `ownerOf` says it holds, so a
    ///      hostile custodian's blast radius is exactly its own custody — it cannot name a
    ///      beneficiary for a Noun it does not hold, in this collection or any other.
    function effectiveOwner(address collection, uint256 tokenId) external view override returns (address) {
        return _effectiveOwner(collection, tokenId);
    }

    function _effectiveOwner(address collection, uint256 tokenId) internal view returns (address) {
        (bool ok, bytes memory ret) = collection.staticcall{gas: PROBE_GAS}(abi.encodeCall(IERC721.ownerOf, (tokenId)));
        if (!ok || ret.length < 32) return address(0);
        address holder = abi.decode(ret, (address));
        if (holder == address(0)) return address(0);

        if (!isCustodian[holder]) return holder;

        (bool okB, bytes memory retB) =
            holder.staticcall{gas: PROBE_GAS}(abi.encodeCall(IActivationCustodian.beneficiaryOf, (collection, tokenId)));
        if (!okB || retB.length < 32) return address(0);
        return abi.decode(retB, (address));
    }

    /* ------------------------------------------------------------------ */
    /*                               VIEWS                                  */
    /* ------------------------------------------------------------------ */

    /// @notice The raw stored record, whether or not it is still live.
    /// @dev For the site's "this used to be active" display and for debugging. Do NOT use it
    ///      to decide whether a Noun earns — use {activation}, which applies the owner check.
    function activationOf(address collection, uint256 tokenId) external view returns (Activation memory) {
        return _activations[collection][tokenId];
    }

    function isActive(address collection, uint256 tokenId) external view returns (bool) {
        address recorded = _activations[collection][tokenId].ownerAtActivation;
        if (recorded == address(0)) return false;
        return _effectiveOwner(collection, tokenId) == recorded;
    }

    /// @notice Live tier, or zero weight if the activation has reset.
    function tierBpsOf(address collection, uint256 tokenId) external view returns (uint32) {
        Activation storage a = _activations[collection][tokenId];
        address recorded = a.ownerAtActivation;
        if (recorded == address(0)) return 0;
        if (_effectiveOwner(collection, tokenId) != recorded) return 0;
        return tierBps[a.tier];
    }

    /// @notice Cost in $CHIP to hold `tier` outright.
    function costOf(address collection, uint8 tier) external view returns (uint256) {
        if (tier >= TIER_COUNT) revert BadTier(tier);
        return _tierCost[collection][tier];
    }

    function tierCosts(address collection) external view returns (uint256[TIER_COUNT] memory) {
        return _tierCost[collection];
    }

    function allTierBps() external view returns (uint32[TIER_COUNT] memory) {
        return tierBps;
    }

    /// @notice What an upgrade to `newTier` would cost right now. Reverts exactly where
    ///         {upgrade} would, so the site can surface the reason instead of a failed tx.
    function upgradeCost(address collection, uint256 tokenId, uint8 newTier) external view returns (uint256) {
        if (newTier >= TIER_COUNT) revert BadTier(newTier);
        Activation storage a = _activations[collection][tokenId];
        address recorded = a.ownerAtActivation;
        if (recorded == address(0) || _effectiveOwner(collection, tokenId) != recorded) {
            revert NotActive(collection, tokenId);
        }
        if (newTier <= a.tier) revert NotAnUpgrade(a.tier, newTier);
        return _tierCost[collection][newTier] - _tierCost[collection][a.tier];
    }

    function pendingCosts(address collection) external view returns (PendingCosts memory) {
        return _pendingCosts[collection];
    }

    function pendingTiers() external view returns (PendingTiers memory) {
        return _pendingTiers;
    }

    /* ------------------------------------------------------------------ */
    /*                      GOVERNANCE: CUSTODIANS                          */
    /* ------------------------------------------------------------------ */

    /// @notice Allow or forbid a contract to hold Nouns without voiding their activations.
    ///
    /// @dev NOT TIMELOCKED, IN BOTH DIRECTIONS, AND THAT IS DELIBERATE. De-registering is a
    ///      safety action — a custodian discovered to be lying must stop being believed now,
    ///      not in 48 hours — and the same switch is what makes registering a new one
    ///      symmetric. The blast radius of registering is bounded by {IActivationCustodian}'s
    ///      trust model: a custodian can only speak for tokens it already holds.
    ///
    ///      REVOKING RESETS. Once de-registered, the custodian's own address becomes the
    ///      effective owner of everything it holds, which never matches an `ownerAtActivation`
    ///      that was set to a beneficiary — so every activation it was carrying goes inactive
    ///      immediately. Depositors re-activate after withdrawing. That is the correct
    ///      direction for a custodian that has gone bad, and the cost of the emergency stop.
    function setCustodian(address custodian, bool allowed) external onlyOwner {
        if (custodian == address(0)) revert ZeroAddress();
        isCustodian[custodian] = allowed;
        emit CustodianSet(custodian, allowed);
    }

    /* ------------------------------------------------------------------ */
    /*                    GOVERNANCE: COSTS (48h TIMELOCK)                  */
    /* ------------------------------------------------------------------ */

    /// @notice Queue a collection's cost table. Also how a collection is registered.
    /// @dev Costs must be non-decreasing across tiers, so an upgrade always costs something
    ///      and the difference can never underflow. Zero is allowed, including all zeros for
    ///      a free-activation collection.
    function queueCosts(address collection, uint256[TIER_COUNT] calldata cost) external onlyOwner {
        if (collection == address(0)) revert ZeroAddress();
        _validateCosts(cost);
        uint64 executableAt = uint64(block.timestamp) + CONFIG_TIMELOCK;
        _pendingCosts[collection] = PendingCosts({queued: true, executableAt: executableAt, cost: cost});
        emit CostsQueued(collection, cost, executableAt);
    }

    /// @notice Apply a queued cost table once its notice period has elapsed.
    /// @dev Executing also marks the collection configured, so registering a collection and
    ///      pricing it are the same action and a collection can never be live at zero cost
    ///      by accident.
    function executeCosts(address collection) external onlyOwner {
        PendingCosts memory p = _pendingCosts[collection];
        if (!p.queued) revert NothingQueued();
        if (block.timestamp < p.executableAt) revert TimelockNotElapsed(uint64(block.timestamp), p.executableAt);

        _tierCost[collection] = p.cost;
        collectionConfigured[collection] = true;
        delete _pendingCosts[collection];

        emit CostsExecuted(collection, p.cost);
    }

    function cancelCosts(address collection) external onlyOwner {
        if (!_pendingCosts[collection].queued) revert NothingQueued();
        delete _pendingCosts[collection];
        emit CostsCancelled(collection);
    }

    /* ------------------------------------------------------------------ */
    /*                    GOVERNANCE: TIERS (48h TIMELOCK)                  */
    /* ------------------------------------------------------------------ */

    /// @notice Queue a change to the weight curve. Multisig only, 48h notice.
    /// @dev Stricter than the retired Clutch adapter on purpose: this table decides what
    ///      every activated Noun earns, and it should not be able to move without notice.
    function queueTierBps(uint32[TIER_COUNT] calldata bps) external onlyOwner {
        _validateTiers(bps);
        uint64 executableAt = uint64(block.timestamp) + CONFIG_TIMELOCK;
        _pendingTiers = PendingTiers({queued: true, executableAt: executableAt, bps: bps});
        emit TiersQueued(bps, executableAt);
    }

    function executeTierBps() external onlyOwner {
        PendingTiers memory p = _pendingTiers;
        if (!p.queued) revert NothingQueued();
        if (block.timestamp < p.executableAt) revert TimelockNotElapsed(uint64(block.timestamp), p.executableAt);

        tierBps = p.bps;
        delete _pendingTiers;

        emit TiersExecuted(p.bps);
    }

    function cancelTierBps() external onlyOwner {
        if (!_pendingTiers.queued) revert NothingQueued();
        delete _pendingTiers;
        emit TiersCancelled();
    }

    /// @dev Non-decreasing and never zero. A zero would read as inactive in {activation},
    ///      silently un-chipping every Noun at that tier.
    function _validateTiers(uint32[TIER_COUNT] memory bps) internal pure {
        for (uint256 i; i < TIER_COUNT; ++i) {
            if (bps[i] == 0) revert BadConfig();
            if (i != 0 && bps[i] < bps[i - 1]) revert BadConfig();
        }
    }

    function _validateCosts(uint256[TIER_COUNT] memory cost) internal pure {
        for (uint256 i = 1; i < TIER_COUNT; ++i) {
            if (cost[i] < cost[i - 1]) revert BadConfig();
        }
    }

    /* ------------------------------------------------------------------ */
    /*                              RESCUE                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Sweep a token that ended up here. Multisig only.
    ///
    /// @dev NO EXCLUSION LIST IS NEEDED, BECAUSE THERE IS NOTHING TO EXCLUDE. This contract
    ///      holds no user asset at any point: activation costs go straight to `0xdead` inside
    ///      the same call, and it never takes custody of a Noun. Its $CHIP balance is zero
    ///      between transactions, which `test_theContractNeverHoldsChip` asserts across every
    ///      operation, so sweeping $CHIP can only ever move a stray donation.
    ///      That is a stronger guarantee than an exclusion list, not a weaker one: an
    ///      exclusion list protects a balance that exists, and here none does.
    function recoverExcess(address token, address to) external onlyOwner nonReentrant {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount != 0) {
            IERC20(token).safeTransfer(to, amount);
            emit Recovered(token, to, amount);
        }
    }

    /// @notice Return an NFT that was pushed here. Multisig only.
    /// @dev Soft staking means this contract is never the legitimate owner of a Noun. There
    ///      is no `onERC721Received`, so `safeTransferFrom` into it reverts; a bare
    ///      `transferFrom` can still strand one, and this returns it. Nothing is protected
    ///      from this call because nothing here is supposed to exist — and a Noun sitting at
    ///      this address has already lost its activation, since this contract is not a
    ///      registered custodian of itself.
    function recoverNFT(address collection, uint256 tokenId, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        IERC721(collection).transferFrom(address(this), to, tokenId);
        emit RecoveredNFT(collection, tokenId, to);
    }
}
