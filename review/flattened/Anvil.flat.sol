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

// src/anvil/Anvil.sol

/// @title Anvil
/// @notice Buy a Noun from the protocol's shelf at a fixed price, in ETH.
///
/// @dev ONE-DIRECTIONAL AT LAUNCH, AND THE CONTRACT SAYS SO OUT LOUD.
///
///      The Anvil is meant to be a two-way market: a fixed price to buy, and a guaranteed
///      exit to sell into. **Only the buy side ships now.** The sell side is a real product
///      commitment with real solvency questions — what backs the bid, what happens when the
///      backing runs out, who is left holding the floor — and it is not going out before an
///      audit. {sellToAnvil} exists as a stub that always reverts {SellNotOpen}, and
///      {sellEnabled} is readable so the site can show the state honestly rather than hiding
///      a feature that does not exist. **There is deliberately NO setter for that flag**: a
///      switch that exposes an unimplemented function is worse than no switch, so turning
///      the sell side on means deploying the version that implements it.
///
///      TWO WAYS TO BUY, AND THE DIFFERENCE IS THE POINT.
///
///      - {buyNext} — "the Box". Pays `queuePrice` for **the oldest Noun on the shelf**.
///        You do not choose. This is the cheap way in and it is FIFO **by design**: it is
///        next in line, not random, and not a lottery. Anyone can read exactly which token
///        they will receive before they call it ({nextOnShelf}), so it is a queue with a
///        known head rather than a gacha pull. Said plainly because "mystery box" invites
///        the opposite assumption, and the honest framing is the one that survives contact
///        with a disappointed buyer.
///      - {snipe} — pick any Noun on the shelf and pay `queuePrice x (1 + snipePremiumBps)`.
///        The premium is what the queue's head is worth to someone who wants a specific
///        token, and it is the only reason the FIFO order is not simply arbitraged away.
///
///      SNIPING DOES NOT DISTURB THE QUEUE. A sniped token has its shelf slot RETIRED in
///      place; the FIFO cursor skips the hole when it gets there. So sniping the tenth Noun
///      does not promote the eleventh past the second, and {buyNext} always returns the
///      oldest token still on the shelf.
///
///      RETIRED IS PERMANENT, AND THAT IS THE WHOLE OF EXTERNAL REVIEW M-1. The shelf used
///      to record availability against the TOKEN (`isListed[id]`) while ordering was recorded
///      against the SLOT. Those two disagree the moment a token comes back: buying a sniped
///      Noun on the open market and re-shelving it re-lit its original slot, and the Noun
///      reappeared at the position it left rather than at the tail — ahead of every Noun that
///      had been waiting longer. It was also counted twice until one of the two slots was
///      consumed. A slot now holds `tokenId + 1` and is zeroed on the way out, so retiring is
///      a property of the slot and a re-shelve is unambiguously a new arrival at the back.
///
///      EVERY LIVE SLOT IS AT OR AFTER `cursor`. The cursor only ever advances past zeroed
///      slots and past the slot it consumes, which it zeroes on the way. Several things
///      depend on that: the tail-removal rule in {unshelve}, and the fact that the views can
///      start scanning at the cursor rather than at zero.
///
///      REVENUE IS 100% FORWARDED. Every wei of a sale goes to the FeeSplitter in the same
///      transaction, which routes it to the Pot, ops and POL exactly like any other inflow —
///      so an Anvil sale funds the next round. This contract holds no ETH between
///      transactions and has no withdraw path for it. **Changing the destination is
///      timelocked** for exactly that reason: it redirects 100% of revenue, which is a larger
///      act than changing a price, and prices were already the thing that got 48 hours of
///      notice. See ASSUMPTIONS A-21 for the one way ETH can end up stuck here.
///
///      A PURCHASED NOUN ARRIVES UN-CHIPPED, structurally rather than by policy. This
///      contract is not a registered {IActivationCustodian}, so from {ChipActivation}'s point
///      of view a deposit here is a transfer to a stranger and any prior activation is void
///      the moment the Noun is shelved. The buyer receives a clean Noun and chips it
///      themselves. Nothing here calls the activation vault at all.
contract Anvil is Ownable2Step, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;

    /// @notice Notice period on every timelocked change. Same shape as ChipActivation.
    uint64 public constant CONFIG_TIMELOCK = 48 hours;

    /// @notice How long a matured change stays executable before it goes stale.
    /// @dev External review L-2. The point of the 48 hours is that the notice is FRESH. A
    ///      change queued and forgotten in March is not something anybody is still watching
    ///      for in September, and executing it then would be a surprise with a timelock's
    ///      reputation attached. After this window it must be re-queued, which restarts the
    ///      notice — so the cost of the rule is one extra transaction and the benefit is that
    ///      a queued change is never a dormant capability.
    uint64 public constant CONFIG_GRACE = 14 days;

    /// @notice Immutable ceiling on the snipe premium. A compromised multisig cannot make
    ///         picking a specific Noun cost more than three times the queue price.
    uint32 public constant MAX_SNIPE_PREMIUM_BPS = 20_000; // +200%

    /// @notice Where every wei of revenue goes.
    address public feeSplitter;

    /// @notice Price of the next Noun in line, in wei, per collection. Zero means the
    ///         collection is not for sale — which is how an unpriced shelf fails closed.
    mapping(address collection => uint256) public queuePrice;

    /// @notice Premium over `queuePrice` for choosing a specific Noun. 2500 = +25%.
    uint32 public snipePremiumBps;

    /// @notice Per-collection halt. Immediate, because stopping a sale is a safety action.
    mapping(address collection => bool) public paused;

    /// @notice THE SELL SIDE IS NOT BUILT. Readable so the site can say so; no setter.
    bool public constant sellEnabled = false;

    struct Shelf {
        uint256[] slots; // append-only. Each entry is `tokenId + 1`, or 0 once retired.
        uint256 cursor; // FIFO head; only ever moves forward
        uint256 listed; // live slots. Maintained, never counted — external review M-2.
    }

    mapping(address collection => Shelf) internal _shelf;

    /// @notice Which slot a token currently occupies, plus one. Zero means "not on the shelf".
    /// @dev The `+ 1` offset is what lets slot zero be a real position and lets zero mean
    ///      absent, in both this mapping and the `slots` array. Token id `type(uint256).max`
    ///      is refused by {shelve} rather than allowed to wrap.
    mapping(address collection => mapping(uint256 tokenId => uint256)) internal _slotOf;

    struct PendingPrice {
        bool queued;
        uint64 executableAt;
        uint256 price;
    }

    struct PendingPremium {
        bool queued;
        uint64 executableAt;
        uint32 bps;
    }

    struct PendingSplitter {
        bool queued;
        uint64 executableAt;
        address splitter;
    }

    mapping(address collection => PendingPrice) internal _pendingPrice;
    PendingPremium internal _pendingPremium;
    PendingSplitter internal _pendingSplitter;

    /// @notice Running totals, for the site.
    uint256 public totalSold;
    uint256 public totalSnipes;
    uint256 public totalRevenueWei;

    event Shelved(address indexed collection, uint256 indexed tokenId, uint256 shelfPosition, uint256 remaining);
    event Unshelved(address indexed collection, uint256 indexed tokenId, address indexed to, uint256 remaining);
    event Bought(
        address indexed collection, uint256 indexed tokenId, address indexed buyer, uint256 pricePaid, uint256 remaining
    );
    event Sniped(
        address indexed collection, uint256 indexed tokenId, address indexed buyer, uint256 pricePaid, uint256 remaining
    );
    event PriceQueued(address indexed collection, uint256 price, uint64 executableAt);
    event PriceExecuted(address indexed collection, uint256 previous, uint256 price);
    event PriceCancelled(address indexed collection);
    event PremiumQueued(uint32 bps, uint64 executableAt);
    event PremiumExecuted(uint32 previous, uint32 bps);
    event PremiumCancelled();
    event CollectionPaused(address indexed collection, bool paused);
    event FeeSplitterQueued(address indexed splitter, uint64 executableAt);
    event FeeSplitterSet(address indexed previous, address indexed current);
    event FeeSplitterCancelled();
    event Recovered(address indexed token, address indexed to, uint256 amount);
    event RecoveredNFT(address indexed collection, uint256 indexed tokenId, address indexed to);

    error ZeroAddress();
    error BadConfig();
    error CollectionPausedError(address collection);
    error NotForSale(address collection);
    error ShelfEmpty(address collection);
    error NotListed(address collection, uint256 tokenId);
    error Underpaid(uint256 sent, uint256 required);
    error RefundFailed();
    error FeeForwardFailed();
    error SellNotOpen();
    error NothingQueued();
    error TimelockNotElapsed(uint64 nowTs, uint64 executableAt);
    /// @notice The queued change matured but was left too long. Re-queue it. External review L-2.
    error TimelockExpired(uint64 nowTs, uint64 expiredAt);
    error NothingToWithdraw();
    error IsShelved(address collection, uint256 tokenId);
    /// @notice {unshelve} would have removed the Noun {buyNext} is about to hand out.
    ///         External review L-3.
    error WouldTakeTheHead(address collection, uint256 tokenId);

    /// @param multisig     Owner. Two-step ownership transfer.
    /// @param feeSplitter_ Where 100% of revenue goes.
    /// @param premiumBps   Snipe premium. Chipworks launches at 2500 (+25%).
    constructor(address multisig, address feeSplitter_, uint32 premiumBps) Ownable(multisig) {
        if (multisig == address(0) || feeSplitter_ == address(0)) revert ZeroAddress();
        if (premiumBps > MAX_SNIPE_PREMIUM_BPS) revert BadConfig();
        feeSplitter = feeSplitter_;
        snipePremiumBps = premiumBps;
        emit PremiumExecuted(0, premiumBps);
    }

    /* ------------------------------------------------------------------ */
    /*                              BUYING                                  */
    /* ------------------------------------------------------------------ */

    /// @notice THE BOX. Buy the oldest Noun on `collection`'s shelf at the queue price.
    /// @dev You do not choose which token. You CAN read which one you will get before
    ///      calling: {nextOnShelf} returns it, and it cannot change under you except by
    ///      somebody else buying first.
    /// @return tokenId The Noun bought.
    function buyNext(address collection) external payable nonReentrant returns (uint256 tokenId) {
        uint256 price = _requireSaleable(collection);

        tokenId = _takeNext(collection);
        totalSold += 1;

        _settle(collection, tokenId, price, false);
    }

    /// @notice Buy a SPECIFIC Noun from the shelf, at the queue price plus the premium.
    /// @dev The premium is what jumping the queue costs. Sniping unlists the token in place
    ///      and does not reorder anything: {buyNext} still returns the oldest token left.
    function snipe(address collection, uint256 tokenId) external payable nonReentrant {
        uint256 price = _requireSaleable(collection);
        uint256 slot = _slotOf[collection][tokenId];
        if (slot == 0) revert NotListed(collection, tokenId);

        uint256 snipePrice = _withPremium(price);

        _retire(collection, tokenId, slot);
        totalSold += 1;
        totalSnipes += 1;

        _settle(collection, tokenId, snipePrice, true);
    }

    /// @notice THE SELL SIDE IS NOT BUILT. Always reverts.
    /// @dev Present so the ABI and the site can be honest about what is coming rather than
    ///      silently omitting it. A guaranteed exit is a solvency commitment and ships after
    ///      the audit, in a deployment that actually implements it. {sellEnabled} is a
    ///      constant `false` with no setter, so this cannot be switched on by mistake.
    function sellToAnvil(address, uint256) external pure {
        revert SellNotOpen();
    }

    /// @dev Common tail: take the money, forward 100% of it, refund any excess, hand over
    ///      the Noun LAST.
    ///
    ///      `transferFrom`, NOT `safeTransferFrom`, and deliberately: there is then no
    ///      `onERC721Received` hook on the way out, so the buyer gets no callback at the one
    ///      moment the shelf has been debited. The remaining callback is the refund, which
    ///      only happens on an overpayment and is guarded by `nonReentrant` — a buyer who
    ///      re-enters from it reverts the whole purchase rather than getting two Nouns for
    ///      one. Both paths are tested.
    ///
    ///      The cost of `transferFrom` is that a contract buyer which cannot handle ERC-721s
    ///      would strand the Noun. They called `buyNext` to get it, so that is their choice
    ///      to make; the alternative is handing every buyer a reentrancy hook.
    function _settle(address collection, uint256 tokenId, uint256 price, bool isSnipe) internal {
        if (msg.value < price) revert Underpaid(msg.value, price);

        totalRevenueWei += price;

        // 100% to the FeeSplitter. Reverting rather than holding is deliberate: if the
        // revenue cannot be routed, the Noun does not leave. There is no withdraw path for
        // ETH on this contract, so a sale that could not forward would strand the money.
        (bool ok,) = feeSplitter.call{value: price}("");
        if (!ok) revert FeeForwardFailed();

        uint256 excess = msg.value - price;
        if (excess != 0) {
            (bool refunded,) = msg.sender.call{value: excess}("");
            if (!refunded) revert RefundFailed();
        }

        IERC721(collection).transferFrom(address(this), msg.sender, tokenId);

        uint256 remaining = shelfRemaining(collection);
        if (isSnipe) {
            emit Sniped(collection, tokenId, msg.sender, price, remaining);
        } else {
            emit Bought(collection, tokenId, msg.sender, price, remaining);
        }
    }

    function _requireSaleable(address collection) internal view returns (uint256 price) {
        if (paused[collection]) revert CollectionPausedError(collection);
        price = queuePrice[collection];
        if (price == 0) revert NotForSale(collection);
    }

    /// @dev Advances the FIFO cursor past anything already sniped or withdrawn and returns
    ///      the oldest token still listed. The cursor is PERSISTED as it advances, so the
    ///      total work across every call is linear in the shelf rather than quadratic.
    ///
    ///      The slot it lands on is zeroed on the way out even though the cursor has already
    ///      moved past it. That is not redundant: {unshelve} walks the tail and would
    ///      otherwise find a live-looking entry for a Noun this contract no longer owns.
    function _takeNext(address collection) internal returns (uint256 id) {
        Shelf storage sh = _shelf[collection];
        uint256 i = sh.cursor;
        uint256 n = sh.slots.length;

        while (i < n && sh.slots[i] == 0) {
            unchecked {
                ++i;
            }
        }
        if (i >= n) {
            sh.cursor = i;
            revert ShelfEmpty(collection);
        }

        unchecked {
            id = sh.slots[i] - 1;
        }
        sh.cursor = i + 1;
        _retire(collection, id, i + 1);
    }

    /// @dev Put a token on the shelf at a fresh slot at the tail. Always the tail: a Noun
    ///      that has been here before is a new arrival, not a returning one.
    ///
    ///      The {IsShelved} guard looks unreachable through {shelve}, because that pulls the
    ///      token with `transferFrom` and the multisig cannot send us something we already
    ///      hold. It is not: an ERC-721 whose `transferFrom` succeeds without moving anything
    ///      would let the same id be shelved twice, and two slots for one token is exactly
    ///      the shape of corruption external review M-1 was about. Cheap, and it keeps the
    ///      one-slot-per-token invariant a property of this function rather than of the
    ///      collection's honesty.
    function _list(address collection, uint256 id) internal {
        if (_slotOf[collection][id] != 0) revert IsShelved(collection, id);
        if (id == type(uint256).max) revert BadConfig(); // would wrap the `+ 1` encoding

        Shelf storage sh = _shelf[collection];
        sh.slots.push(id + 1);
        _slotOf[collection][id] = sh.slots.length; // index + 1
        unchecked {
            ++sh.listed;
        }
    }

    /// @dev Retire a token's slot permanently. `slotPlusOne` is the caller's already-read
    ///      `_slotOf` value, which every caller has to have checked for zero anyway.
    function _retire(address collection, uint256 id, uint256 slotPlusOne) internal {
        Shelf storage sh = _shelf[collection];
        sh.slots[slotPlusOne - 1] = 0;
        _slotOf[collection][id] = 0;
        unchecked {
            --sh.listed;
        }
    }

    function _withPremium(uint256 price) internal view returns (uint256) {
        return price + ((price * snipePremiumBps) / BPS);
    }

    /* ------------------------------------------------------------------ */
    /*                               VIEWS                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Whether a token is on this collection's shelf and available to buy.
    function isListed(address collection, uint256 tokenId) public view returns (bool) {
        return _slotOf[collection][tokenId] != 0;
    }

    /// @notice Nouns still available on this collection's shelf.
    /// @dev O(1). External review M-2: this is read inside {_settle} on every purchase, so
    ///      counting the shelf here made a sale cost more the bigger the shelf got — a gas
    ///      ceiling on a product whose whole point is to grow. It is now maintained by
    ///      {_list} and {_retire} instead.
    function shelfRemaining(address collection) public view returns (uint256) {
        return _shelf[collection].listed;
    }

    /// @notice The exact Noun {buyNext} would hand out right now.
    /// @dev The Box is a queue with a readable head, not a lottery. This is what makes that
    ///      claim checkable rather than a promise.
    function nextOnShelf(address collection) public view returns (bool available, uint256 tokenId) {
        Shelf storage sh = _shelf[collection];
        uint256 len = sh.slots.length;
        for (uint256 i = sh.cursor; i < len; ++i) {
            uint256 v = sh.slots[i];
            if (v != 0) return (true, v - 1);
        }
        return (false, 0);
    }

    /// @notice Every Noun still on the shelf, oldest first.
    function shelfQueue(address collection) external view returns (uint256[] memory out) {
        Shelf storage sh = _shelf[collection];
        uint256 len = sh.slots.length;
        uint256 n = sh.listed;
        out = new uint256[](n);
        uint256 k;
        for (uint256 i = sh.cursor; i < len && k < n; ++i) {
            uint256 v = sh.slots[i];
            if (v != 0) out[k++] = v - 1;
        }
    }

    /// @notice What each route costs right now.
    function prices(address collection) external view returns (uint256 boxPrice, uint256 snipePrice) {
        boxPrice = queuePrice[collection];
        snipePrice = _withPremium(boxPrice);
    }

    function snipePriceOf(address collection) external view returns (uint256) {
        return _withPremium(queuePrice[collection]);
    }

    /// @notice Everything the site needs to render a collection's shelf in one call.
    function shelfState(address collection)
        external
        view
        returns (bool forSale, bool isPaused, uint256 boxPrice, uint256 snipePrice, uint256 remaining, uint256 nextId)
    {
        boxPrice = queuePrice[collection];
        forSale = boxPrice != 0 && !paused[collection];
        isPaused = paused[collection];
        snipePrice = _withPremium(boxPrice);
        remaining = _shelf[collection].listed;
        (, nextId) = nextOnShelf(collection);
    }

    function pendingPrice(address collection) external view returns (PendingPrice memory) {
        return _pendingPrice[collection];
    }

    function pendingPremium() external view returns (PendingPremium memory) {
        return _pendingPremium;
    }

    function pendingFeeSplitter() external view returns (PendingSplitter memory) {
        return _pendingSplitter;
    }

    /* ------------------------------------------------------------------ */
    /*                          ADMIN: THE SHELF                            */
    /* ------------------------------------------------------------------ */

    /// @notice Put Nouns on a collection's shelf, in the order given. Multisig only.
    /// @dev Pulls with `transferFrom`, so the multisig must have approved this contract.
    ///      Deposit order IS sale order — the first token in this array is the first one
    ///      {buyNext} hands out.
    function shelve(address collection, uint256[] calldata tokenIds) external onlyOwner nonReentrant {
        if (collection == address(0)) revert ZeroAddress();
        Shelf storage sh = _shelf[collection];
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            IERC721(collection).transferFrom(msg.sender, address(this), id);
            _list(collection, id);
            emit Shelved(collection, id, sh.slots.length - 1, sh.listed);
        }
    }

    /// @notice Take Nouns back off the shelf. Multisig only.
    ///
    /// @dev Removes from the TAIL — the most recently shelved end — so the multisig can
    ///      shrink the shelf but can never take the specific Noun the next buyer is about to
    ///      receive out from under them. Same rule as the Furnace, for the same reason: the
    ///      queue's head is a promise the moment it is readable.
    ///
    ///      EXTERNAL REVIEW L-3: THE TAIL IS THE HEAD WHEN ONE IS LEFT. Every live slot sits
    ///      at or after the cursor, so the first live slot is the head and the last is the
    ///      tail — and with exactly one live slot they are the same Noun. The rule quietly
    ///      stopped holding at the only depth where a buyer is most likely to be racing for
    ///      it. Taking the last one is now refused.
    ///
    ///      Refused **while the shelf is live**, not absolutely, and the difference matters:
    ///      {recoverNFT} declines a shelved token, so an absolute rule would strand the final
    ///      Noun on the shelf forever with no path off it but a sale. Pausing the collection
    ///      is what says "nobody is about to buy anything here", and a paused shelf can be
    ///      emptied. So winding down is two deliberate transactions rather than one, which is
    ///      the right shape for it anyway.
    function unshelve(address collection, uint256 count, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (count == 0) revert NothingToWithdraw();

        Shelf storage sh = _shelf[collection];
        if (count > sh.listed) revert NothingToWithdraw();

        uint256 taken;
        while (taken < count) {
            uint256 len = sh.slots.length;
            if (len == 0 || len <= sh.cursor) revert NothingToWithdraw();

            uint256 v = sh.slots[len - 1];
            if (v == 0) {
                sh.slots.pop(); // a retired slot at the tail: drop the stale entry
                continue;
            }

            uint256 id;
            unchecked {
                id = v - 1;
            }
            if (sh.listed == 1 && !paused[collection]) revert WouldTakeTheHead(collection, id);

            sh.slots.pop();
            _slotOf[collection][id] = 0;
            unchecked {
                --sh.listed;
                ++taken;
            }

            IERC721(collection).transferFrom(address(this), to, id);
            emit Unshelved(collection, id, to, sh.listed);
        }
    }

    /* ------------------------------------------------------------------ */
    /*                        ADMIN: PAUSE + WIRING                         */
    /* ------------------------------------------------------------------ */

    /// @notice Halt or resume sales for one collection. Immediate, not timelocked.
    /// @dev Stopping a sale is a safety action and must be able to happen now. Note it does
    ///      NOT touch the shelf: paused Nouns stay put and resume at the same queue position.
    function setPaused(address collection, bool paused_) external onlyOwner {
        paused[collection] = paused_;
        emit CollectionPaused(collection, paused_);
    }

    /// @notice Queue a change of revenue destination. Multisig only, 48 hours of notice.
    /// @dev External review L-1. This redirects **100% of revenue**, which is strictly larger
    ///      than any price change — and price changes were already the timelocked thing while
    ///      this was instant. A compromised multisig should not be able to point the till at
    ///      itself with no warning; now it announces the move two days before it can make it,
    ///      which is time for anyone watching to notice and for the Nouns to be pulled.
    ///
    ///      Note the asymmetry with {setPaused}, which stays immediate: stopping sales is a
    ///      safety action and is the lever to reach for while this one is maturing.
    function queueFeeSplitter(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        uint64 executableAt = uint64(block.timestamp) + CONFIG_TIMELOCK;
        _pendingSplitter = PendingSplitter({queued: true, executableAt: executableAt, splitter: v});
        emit FeeSplitterQueued(v, executableAt);
    }

    function executeFeeSplitter() external onlyOwner {
        PendingSplitter memory p = _pendingSplitter;
        if (!p.queued) revert NothingQueued();
        _requireInWindow(p.executableAt);

        emit FeeSplitterSet(feeSplitter, p.splitter);
        feeSplitter = p.splitter;
        delete _pendingSplitter;
    }

    function cancelFeeSplitter() external onlyOwner {
        if (!_pendingSplitter.queued) revert NothingQueued();
        delete _pendingSplitter;
        emit FeeSplitterCancelled();
    }

    /// @dev The two halves of a timelock: matured, and not yet stale. External review L-2.
    function _requireInWindow(uint64 executableAt) internal view {
        if (block.timestamp < executableAt) revert TimelockNotElapsed(uint64(block.timestamp), executableAt);
        uint64 expiresAt = executableAt + CONFIG_GRACE;
        if (block.timestamp > expiresAt) revert TimelockExpired(uint64(block.timestamp), expiresAt);
    }

    /* ------------------------------------------------------------------ */
    /*                    ADMIN: PRICES (48h TIMELOCK)                      */
    /* ------------------------------------------------------------------ */

    /// @notice Queue a collection's queue price, in wei. Zero takes it off sale.
    /// @dev Timelocked because it is the number every buyer is deciding against. Pausing is
    ///      the immediate lever if a price is actively wrong; this is the considered one.
    function queueQueuePrice(address collection, uint256 priceWei) external onlyOwner {
        if (collection == address(0)) revert ZeroAddress();
        uint64 executableAt = uint64(block.timestamp) + CONFIG_TIMELOCK;
        _pendingPrice[collection] = PendingPrice({queued: true, executableAt: executableAt, price: priceWei});
        emit PriceQueued(collection, priceWei, executableAt);
    }

    function executeQueuePrice(address collection) external onlyOwner {
        PendingPrice memory p = _pendingPrice[collection];
        if (!p.queued) revert NothingQueued();
        _requireInWindow(p.executableAt);

        emit PriceExecuted(collection, queuePrice[collection], p.price);
        queuePrice[collection] = p.price;
        delete _pendingPrice[collection];
    }

    function cancelQueuePrice(address collection) external onlyOwner {
        if (!_pendingPrice[collection].queued) revert NothingQueued();
        delete _pendingPrice[collection];
        emit PriceCancelled(collection);
    }

    /// @notice Queue a change to the snipe premium. Capped at {MAX_SNIPE_PREMIUM_BPS}.
    function queueSnipePremium(uint32 bps) external onlyOwner {
        if (bps > MAX_SNIPE_PREMIUM_BPS) revert BadConfig();
        uint64 executableAt = uint64(block.timestamp) + CONFIG_TIMELOCK;
        _pendingPremium = PendingPremium({queued: true, executableAt: executableAt, bps: bps});
        emit PremiumQueued(bps, executableAt);
    }

    function executeSnipePremium() external onlyOwner {
        PendingPremium memory p = _pendingPremium;
        if (!p.queued) revert NothingQueued();
        _requireInWindow(p.executableAt);

        emit PremiumExecuted(snipePremiumBps, p.bps);
        snipePremiumBps = p.bps;
        delete _pendingPremium;
    }

    function cancelSnipePremium() external onlyOwner {
        if (!_pendingPremium.queued) revert NothingQueued();
        delete _pendingPremium;
        emit PremiumCancelled();
    }

    /* ------------------------------------------------------------------ */
    /*                               RESCUE                                 */
    /* ------------------------------------------------------------------ */

    /// @notice Sweep an ERC-20 that ended up here. Multisig only.
    /// @dev The Anvil trades in ETH and holds no token balance in any normal path, so there
    ///      is nothing to exclude. ETH deliberately has NO rescue: every wei of revenue is
    ///      forwarded to the FeeSplitter inside the same transaction, so a balance here
    ///      would mean something has already gone wrong, and a withdraw path would be a
    ///      standing way to take sale proceeds out of the protocol.
    ///
    ///      EXTERNAL REVIEW I-1, ACCEPTED AS DESIGNED. There is no `receive()`, so an ordinary
    ///      send bounces; the ways ETH can arrive anyway are `selfdestruct` and being named as
    ///      a block's coinbase, neither of which can be refused by any contract. Such a
    ///      balance is unrecoverable. That is the correct trade: the alternative is a standing
    ///      ETH withdraw path on the contract that handles every sale, to protect against
    ///      somebody choosing to destroy their own money. See ASSUMPTIONS A-21.
    function recoverExcess(address token, address to) external onlyOwner nonReentrant {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount != 0) {
            IERC20(token).safeTransfer(to, amount);
            emit Recovered(token, to, amount);
        }
    }

    /// @notice Return an NFT that is not on the shelf. Multisig only.
    /// @dev REVERTS ON A SHELVED NOUN. Stock leaves by exactly two paths — bought, or
    ///      withdrawn from the tail by {unshelve} — and the multisig has no third. Anything
    ///      else here arrived by accident, including via {onERC721Received}, and this is how
    ///      it goes home.
    function recoverNFT(address collection, uint256 tokenId, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (_slotOf[collection][tokenId] != 0) revert IsShelved(collection, tokenId);
        IERC721(collection).transferFrom(address(this), to, tokenId);
        emit RecoveredNFT(collection, tokenId, to);
    }

    /// @notice Accept NFTs so a `safeTransferFrom` does not revert.
    /// @dev Does NOT shelve. {shelve} is the only thing that lists a Noun for sale, and it
    ///      pulls with `transferFrom`, so a Noun pushed here is not for sale at any price and
    ///      is recoverable with {recoverNFT}.
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
