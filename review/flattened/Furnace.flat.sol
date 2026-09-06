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

// src/furnace/Furnace.sol

/// @title Furnace
/// @notice Burn a fuel NFT and $CHIP to forge a Based Noun or a DarkNOUN out of stock the
///         protocol has deposited.
///
/// @dev ISOLATED FROM THE MONEY PATH ON PURPOSE. This contract shares no storage, no
///      inheritance and no call path with ChipRounds, ChipClaims, Pot or POLTreasury. It
///      cannot move a holder's credits and it is not referenced by anything in the audited
///      set. A bug here loses forge stock; it cannot lose a reward.
///
///      BURNED MEANS BURNED — STRUCTURALLY, NOT BY POLICY. Inputs are transferred straight
///      to `0xdead` inside `forge`, so the Furnace never holds a single fuel token or a single
///      $CHIP at rest. There is no admin function that could reach them because there is
///      nothing to reach: the balance is always zero between transactions. `withdrawStock`
///      touches only deposited OUTPUT NFTs.
///
///      FIFO, AND THE ADMIN CANNOT JUMP THE QUEUE. Forging always takes the oldest unforged
///      token. `withdrawStock` removes from the TAIL, the most recently deposited end, so
///      the multisig can reduce stock but can never pull the specific token a user is about
///      to forge out from under them.
///
///      RECIPE CHANGES ARE TIMELOCKED. Amounts move only through queue → 48h → execute,
///      each step emitting an event, so a change is visible long before it bites. Pausing
///      is NOT timelocked: stopping a recipe is a safety action and must be immediate.
contract Furnace is Ownable2Step, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    /// @notice Where burned inputs go. Not a contract, so nothing can be recovered from it.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Delay between queueing a recipe change and being able to execute it.
    uint64 public constant RECIPE_TIMELOCK = 48 hours;

    /// @notice Most fuel tokens one recipe may ever demand. Bounds a mis-keyed config.
    uint16 public constant MAX_FUEL_COST = 100;

    struct Recipe {
        bool exists;
        bool paused;
        address outputCollection;
        uint16 fuelCost;
        uint256 chipCost;
    }

    struct PendingChange {
        bool queued;
        uint16 fuelCost;
        uint256 chipCost;
        uint64 executableAt;
    }

    /// @notice The token burned alongside the fuel.
    IERC20 public immutable chipToken;

    /// @notice The collection whose tokens are consumed as fuel.
    ///
    /// @dev A CONSTRUCTOR ARGUMENT, NOT A HARDCODED COLLECTION. The Furnace shipped assuming
    ///      Lil Based Nouns would be the fuel, and that assumption lived only in the naming —
    ///      never in the logic. It is now named for what it is.
    ///
    ///      Swapping the fuel is a deploy-time decision: pass a different address and both
    ///      recipes carry on unchanged, because the fuel is an INPUT to every recipe rather
    ///      than a recipe of its own. There is no "Lil recipe" to remove.
    ///
    ///      **Immutable on purpose.** The fuel is the thing holders are asked to destroy;
    ///      being able to repoint it after launch would let governance change what a forge
    ///      costs people without the 48h notice that guards every other economic parameter
    ///      here. Changing it means a redeploy, which is the right amount of friction.
    ///
    ///      THE FUEL IS CHIPLETS, A PLAIN ERC-721. That was an open question for a while
    ///      and it is now closed: Chiplets ships as a standard ERC-721, not a DN404 hybrid.
    ///      The interface this contract uses — `ownerOf`, then `transferFrom` to `0xdead` —
    ///      is exactly the right one, with no adapter and no mirror to reason about.
    ///
    ///      WHAT THE HYBRID WOULD HAVE COST, recorded because it is why this reads as a
    ///      relief rather than a non-event: a DN404 has an ERC-20 base and an ERC-721 mirror,
    ///      so this would have had to point at the mirror, and three things would have
    ///      stopped being obvious — token ids may be reassigned when the fungible side moves,
    ///      `ownerOf` may not be stable between a user's approval and their forge, and
    ///      "burned means burned" would need re-proving because sending a mirror token to
    ///      `0xdead` also moves the underlying balance. None of that applies now.
    ///
    ///      **So review this against a plain ERC-721 and nothing more.**
    IERC721 public immutable fuelCollection;

    mapping(uint8 recipeId => Recipe) internal _recipes;
    mapping(uint8 recipeId => PendingChange) internal _pending;

    /// @notice Deposited output NFTs, oldest first, keyed by collection.
    mapping(address collection => uint256[]) internal _stock;

    /// @notice How far through `_stock` forging has consumed. Never decreases.
    mapping(address collection => uint256) public forgedFrom;

    /// @notice Running totals, for the site.
    uint256 public totalFuelBurned;
    uint256 public totalChipBurned;
    uint256 public totalForged;
    mapping(uint8 recipeId => uint256) public forgedByRecipe;

    event Forged(
        address indexed caller,
        uint8 indexed recipeId,
        uint256[] fuelIds,
        uint256 chipBurned,
        address indexed outputCollection,
        uint256 outputTokenId
    );
    event StockDeposited(address indexed collection, uint256 tokenId, uint256 remaining);
    event StockWithdrawn(address indexed collection, uint256 tokenId, address indexed to, uint256 remaining);
    event RecipeSet(uint8 indexed recipeId, address outputCollection, uint16 fuelCost, uint256 chipCost);
    event RecipeChangeQueued(uint8 indexed recipeId, uint16 fuelCost, uint256 chipCost, uint64 executableAt);
    event RecipeChangeExecuted(uint8 indexed recipeId, uint16 fuelCost, uint256 chipCost);
    event RecipeChangeCancelled(uint8 indexed recipeId);
    event RecipePaused(uint8 indexed recipeId, bool paused);

    error ZeroAddress();
    error BadRecipe(uint8 recipeId);
    error RecipeIsPaused(uint8 recipeId);
    error WrongFuelCount(uint256 provided, uint16 required);
    error DuplicateFuelToken(uint256 tokenId);
    error NotFuelOwner(uint256 tokenId, address caller);
    error OutOfStock(uint8 recipeId, address outputCollection);
    error NothingQueued(uint8 recipeId);
    error TimelockNotElapsed(uint64 nowTs, uint64 executableAt);
    error BadConfig();
    error NotEnoughStock(uint256 requested, uint256 available);
    error ChipBurnShortfall(uint256 delivered, uint256 required);

    /// @param multisig       Owner.
    /// @param chipToken_     $CHIP.
    /// @param fuelCollection_ The collection consumed as fuel. **NOT hardcoded** — see the
    ///        note on the fuel collection above.
    /// @param basedRecipe    FORGE_BASED: output collection, fuel cost, $CHIP cost.
    /// @param darkRecipe     FORGE_DARK: output collection, fuel cost, $CHIP cost.
    /// @dev Recipe ids are fixed at 0 (Based) and 1 (Dark). Both are configured here so the
    ///      deployed contract is immediately usable and every amount is a deploy argument.
    constructor(
        address multisig,
        address chipToken_,
        address fuelCollection_,
        Recipe memory basedRecipe,
        Recipe memory darkRecipe
    ) Ownable(multisig) {
        if (multisig == address(0) || chipToken_ == address(0) || fuelCollection_ == address(0)) revert ZeroAddress();
        chipToken = IERC20(chipToken_);
        fuelCollection = IERC721(fuelCollection_);

        _setRecipe(FORGE_BASED, basedRecipe);
        _setRecipe(FORGE_DARK, darkRecipe);
    }

    uint8 public constant FORGE_BASED = 0;
    uint8 public constant FORGE_DARK = 1;

    function _setRecipe(uint8 id, Recipe memory r) internal {
        if (r.outputCollection == address(0)) revert ZeroAddress();
        if (r.fuelCost == 0 || r.fuelCost > MAX_FUEL_COST) revert BadConfig();
        _recipes[id] = Recipe({
            exists: true,
            paused: false,
            outputCollection: r.outputCollection,
            fuelCost: r.fuelCost,
            chipCost: r.chipCost
        });
        emit RecipeSet(id, r.outputCollection, r.fuelCost, r.chipCost);
    }

    /* ------------------------------------------------------------------ */
    /*                               FORGE                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Burn `fuelIds` and the recipe's $CHIP cost, receive the oldest token in stock.
    ///
    /// @dev Order is checks → effects → interactions, and the output NFT leaves last, so the
    ///      `onERC721Received` hook on a contract recipient cannot re-enter into a second
    ///      forge against stock this call has already claimed. `nonReentrant` belts it.
    function forge(uint8 recipeId, uint256[] calldata fuelIds) external nonReentrant returns (uint256 outputTokenId) {
        Recipe memory r = _recipes[recipeId];
        if (!r.exists) revert BadRecipe(recipeId);
        if (r.paused) revert RecipeIsPaused(recipeId);
        if (fuelIds.length != r.fuelCost) revert WrongFuelCount(fuelIds.length, r.fuelCost);

        // ---- checks: stock first, so a doomed forge burns nothing ----
        uint256 cursor = forgedFrom[r.outputCollection];
        uint256[] storage stock = _stock[r.outputCollection];
        if (cursor >= stock.length) revert OutOfStock(recipeId, r.outputCollection);
        outputTokenId = stock[cursor];

        // ---- checks: inputs are the caller's, and distinct ----
        for (uint256 i; i < fuelIds.length; ++i) {
            if (fuelCollection.ownerOf(fuelIds[i]) != msg.sender) revert NotFuelOwner(fuelIds[i], msg.sender);
            for (uint256 j; j < i; ++j) {
                if (fuelIds[j] == fuelIds[i]) revert DuplicateFuelToken(fuelIds[i]);
            }
        }

        // ---- effects ----
        forgedFrom[r.outputCollection] = cursor + 1;
        totalFuelBurned += fuelIds.length;
        totalChipBurned += r.chipCost;
        totalForged += 1;
        forgedByRecipe[recipeId] += 1;

        // ---- interactions: burn the inputs ----
        // transferFrom, not safeTransferFrom: 0xdead has no code, so the receiver hook would
        // be a no-op, and transferFrom cannot be made to call back into anything.
        for (uint256 i; i < fuelIds.length; ++i) {
            fuelCollection.transferFrom(msg.sender, BURN_ADDRESS, fuelIds[i]);
        }

        if (r.chipCost != 0) {
            // Measure what actually reached the burn address. A $CHIP that taxes transfers
            // or lies about them would otherwise let a forge through under-paid. Failing
            // closed is the right direction: the forge reverts, nothing is consumed.
            uint256 before = chipToken.balanceOf(BURN_ADDRESS);
            chipToken.safeTransferFrom(msg.sender, BURN_ADDRESS, r.chipCost);
            uint256 delivered = chipToken.balanceOf(BURN_ADDRESS) - before;
            if (delivered < r.chipCost) revert ChipBurnShortfall(delivered, r.chipCost);
        }

        // ---- interactions: hand over the output, last ----
        IERC721(r.outputCollection).transferFrom(address(this), msg.sender, outputTokenId);

        emit Forged(msg.sender, recipeId, fuelIds, r.chipCost, r.outputCollection, outputTokenId);
    }

    /* ------------------------------------------------------------------ */
    /*                               VIEWS                                  */
    /* ------------------------------------------------------------------ */

    function recipe(uint8 recipeId) external view returns (Recipe memory) {
        return _recipes[recipeId];
    }

    function pendingChange(uint8 recipeId) external view returns (PendingChange memory) {
        return _pending[recipeId];
    }

    /// @notice Output NFTs still available to forge for this recipe.
    function stockRemaining(uint8 recipeId) public view returns (uint256) {
        Recipe storage r = _recipes[recipeId];
        if (!r.exists) return 0;
        return stockRemainingFor(r.outputCollection);
    }

    function stockRemainingFor(address collection) public view returns (uint256) {
        return _stock[collection].length - forgedFrom[collection];
    }

    /// @notice The token the next forge of this recipe would hand out.
    function nextOutput(uint8 recipeId) external view returns (bool available, uint256 tokenId) {
        Recipe storage r = _recipes[recipeId];
        if (!r.exists) return (false, 0);
        uint256 cursor = forgedFrom[r.outputCollection];
        uint256[] storage stock = _stock[r.outputCollection];
        if (cursor >= stock.length) return (false, 0);
        return (true, stock[cursor]);
    }

    /// @notice The unforged queue for a collection, oldest first.
    function stockQueue(address collection) external view returns (uint256[] memory out) {
        uint256[] storage stock = _stock[collection];
        uint256 cursor = forgedFrom[collection];
        out = new uint256[](stock.length - cursor);
        for (uint256 i; i < out.length; ++i) {
            out[i] = stock[cursor + i];
        }
    }

    /// @notice What a forge would cost right now.
    function costOf(uint8 recipeId) external view returns (uint16 fuelCost, uint256 chipCost) {
        Recipe storage r = _recipes[recipeId];
        return (r.fuelCost, r.chipCost);
    }

    /* ------------------------------------------------------------------ */
    /*                          ADMIN: STOCK                                */
    /* ------------------------------------------------------------------ */

    /// @notice Deposit output NFTs. Multisig only. They queue behind existing stock.
    /// @dev Pulls with transferFrom, so the multisig must have approved this contract.
    /// @dev `nonReentrant` for consistency with every other NFT-moving function here, not
    ///      because a path exists: a callback from a hostile collection arrives with
    ///      `msg.sender == collection`, which `onlyOwner` already rejects. Raised by static
    ///      analysis (TRIAGE SLI-001); added because the inconsistency was an omission rather
    ///      than a decision, and the next reader should not have to re-derive that.
    function depositStock(address collection, uint256[] calldata tokenIds) external onlyOwner nonReentrant {
        if (collection == address(0)) revert ZeroAddress();
        for (uint256 i; i < tokenIds.length; ++i) {
            IERC721(collection).transferFrom(msg.sender, address(this), tokenIds[i]);
            _stock[collection].push(tokenIds[i]);
            emit StockDeposited(collection, tokenIds[i], stockRemainingFor(collection));
        }
    }

    /// @notice Withdraw unforged stock. Multisig only.
    /// @dev Removes from the TAIL — the most recently deposited end — so the multisig can
    ///      shrink the pool but can never take the specific token a user is about to forge.
    ///      Only ever touches deposited outputs; burned inputs are at `0xdead` and are not
    ///      reachable from anywhere in this contract.
    function withdrawStock(address collection, uint256 count, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 available = stockRemainingFor(collection);
        if (count == 0 || count > available) revert NotEnoughStock(count, available);

        uint256[] storage stock = _stock[collection];
        for (uint256 i; i < count; ++i) {
            uint256 tokenId = stock[stock.length - 1];
            stock.pop();
            IERC721(collection).transferFrom(address(this), to, tokenId);
            emit StockWithdrawn(collection, tokenId, to, stockRemainingFor(collection));
        }
    }

    /* ------------------------------------------------------------------ */
    /*                        ADMIN: RECIPES                                */
    /* ------------------------------------------------------------------ */

    /// @notice Stop or resume a recipe. Multisig only, and deliberately NOT timelocked:
    ///         halting a recipe is a safety action that must be able to happen now.
    function setPaused(uint8 recipeId, bool paused) external onlyOwner {
        if (!_recipes[recipeId].exists) revert BadRecipe(recipeId);
        _recipes[recipeId].paused = paused;
        emit RecipePaused(recipeId, paused);
    }

    /// @notice Queue a change to a recipe's costs. Multisig only. Executable after 48h.
    /// @dev The delay and the event exist so a price change is public well before it binds,
    ///      rather than landing on someone mid-transaction.
    function queueRecipeChange(uint8 recipeId, uint16 fuelCost, uint256 chipCost) external onlyOwner {
        if (!_recipes[recipeId].exists) revert BadRecipe(recipeId);
        if (fuelCost == 0 || fuelCost > MAX_FUEL_COST) revert BadConfig();

        uint64 executableAt = uint64(block.timestamp) + RECIPE_TIMELOCK;
        _pending[recipeId] =
            PendingChange({queued: true, fuelCost: fuelCost, chipCost: chipCost, executableAt: executableAt});
        emit RecipeChangeQueued(recipeId, fuelCost, chipCost, executableAt);
    }

    /// @notice Apply a queued change once its timelock has elapsed. Multisig only.
    function executeRecipeChange(uint8 recipeId) external onlyOwner {
        PendingChange memory p = _pending[recipeId];
        if (!p.queued) revert NothingQueued(recipeId);
        if (block.timestamp < p.executableAt) revert TimelockNotElapsed(uint64(block.timestamp), p.executableAt);

        _recipes[recipeId].fuelCost = p.fuelCost;
        _recipes[recipeId].chipCost = p.chipCost;
        delete _pending[recipeId];

        emit RecipeChangeExecuted(recipeId, p.fuelCost, p.chipCost);
    }

    /// @notice Drop a queued change. Multisig only.
    function cancelRecipeChange(uint8 recipeId) external onlyOwner {
        if (!_pending[recipeId].queued) revert NothingQueued(recipeId);
        delete _pending[recipeId];
        emit RecipeChangeCancelled(recipeId);
    }

    /* ------------------------------------------------------------------ */
    /*                              ERC721                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Accept NFTs so `safeTransferFrom` deposits work.
    /// @dev Does NOT register stock. Stock is only ever created by {depositStock}, so an NFT
    ///      pushed here by accident is invisible to forging and can be recovered with
    ///      {rescueStrayNFT} — it never silently becomes someone's output.
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Recover an NFT that arrived without going through {depositStock}.
    /// @dev Cannot touch registered stock: reverts if the token is in the unforged queue.
    ///      Note this can reclaim an ALREADY-FORGED-PAST token id only if it is not in the
    ///      queue, which by definition means it has already left the contract.
    function rescueStrayNFT(address collection, uint256 tokenId, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256[] storage stock = _stock[collection];
        for (uint256 i = forgedFrom[collection]; i < stock.length; ++i) {
            if (stock[i] == tokenId) revert NotEnoughStock(0, 0); // it is live stock, not stray
        }
        IERC721(collection).transferFrom(address(this), to, tokenId);
    }
}
