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

// src/FeeSplitter.sol

/// @title FeeSplitter
/// @notice Single collection point for every Chipworks fee stream: CHIP/ETH pool
///         fees via the LP locker, secondary royalties, POL income (Aerodrome fees
///         plus AERO), and arcade rake. Splits everything it holds between the Pot
///         (which funds the 24h rounds), the ops wallet, and optionally the POL treasury.
///
/// @dev Design notes:
///      - PULL, NOT PUSH. Nothing is split inside receive(). Fee sources vary
///        wildly in how much gas they forward (some LP lockers still use the
///        2300-gas transfer), so receive() here is deliberately empty and cheap.
///        Splitting happens when someone calls distributeETH or distributeToken,
///        which is permissionless: the keeper bot, the website, or any passer-by
///        can trigger it.
///      - The split is CONFIGURED, never hardcoded. opsBps is a constructor
///        argument and the multisig can change it later, but only within
///        maxOpsBps, which is immutable. That bound is the holder protection:
///        even a compromised multisig cannot route more than maxOpsBps to ops.
///      - Rounding dust always favours the Pot (holders), never ops or POL.
///      - ONE BAD RECIPIENT CANNOT FREEZE THE OTHER TWO. ETH legs are paid with a bounded
///        gas stipend and, on failure, credited to a claimable escrow instead of reverting
///        the batch. A paused Pot, an ops wallet that becomes a contract without a payable
///        fallback, or a POL treasury mid-upgrade therefore costs that recipient a delay and
///        costs everybody else nothing. See {withdrawEth}. Raised by external review as
///        SEC-FEE-001.
///      - THE POT IS THE RESIDUAL CLAIMANT. Ops and POL are paid their exact computed
///        shares; the Pot takes whatever is left. That is what makes rounding dust land on
///        holders, and it is also what stops a token that takes a cut in transit from making
///        the final transfer exceed the balance. See {_splitToken} and SEC-FEE-003.
///      - The POL leg is OPT-IN and defaults to zero. It exists so protocol-owned
///        liquidity can pair its stock holdback with quote token of its own, rather than
///        depending on expired reward credits or manual transfers out of ops. It is capped
///        at MAX_POL_SHARE_BPS, which is a constant, not a setting.
contract FeeSplitter is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Basis-point denominator. 10_000 bps equals 100 percent.
    uint32 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Hard ceiling on the ops share, fixed forever at deploy time.
    uint32 public immutable maxOpsBps;

    /// @notice Gas handed to each ETH leg.
    ///
    /// @dev SIZED TO HONOUR TWO OPPOSING REQUIREMENTS, so the number is not arbitrary.
    ///
    ///      Too low and the escrow stops being a safety net and becomes the normal path: the
    ///      2300-gas `transfer()` stipend is famously too small for a Safe, a proxy, or any
    ///      recipient that writes a slot on receipt, and this contract has always
    ///      deliberately forwarded more than that.
    ///
    ///      Too high — unbounded, say — and a hostile recipient burns 63/64 of the remaining
    ///      gas under EIP-150 and starves the legs after it, which is the wedge the escrow
    ///      exists to prevent.
    ///
    ///      150,000 clears a recipient doing real work on receipt (several cold storage
    ///      writes is ~110k) while bounding a worst case of three legs to under half a
    ///      million — comfortable in any block. Both real recipients, `Pot` and
    ///      `POLTreasury`, have an empty `receive()` and use a few hundred.
    uint256 public constant PAYOUT_GAS = 150_000;

    /// @notice Largest number of tokens one batched call may touch. SEC-FEE-004.
    /// @dev The batch entry points are permissionless, so an unbounded array is a way for a
    ///      caller to build a transaction that cannot fit in a block and then blame the
    ///      protocol. The keeper pages; nothing here needs a hundred tokens at once.
    uint256 public constant MAX_BATCH = 32;

    /// @notice ETH owed to a recipient whose payment failed, claimable via {withdrawEth}.
    mapping(address recipient => uint256) public owedEth;

    /// @notice Sum of {owedEth}. Held back from every split so escrow is never re-split.
    uint256 public totalOwedEth;

    /// @notice Hard ceiling on the POL share. Fixed in code, not configurable.
    /// @dev POL is protocol-owned, so a slice routed there is not lost to holders the way
    ///      the ops share is. It is still capped, because a large POL share delays rewards
    ///      in favour of liquidity and that trade-off should be bounded by something other
    ///      than a multisig vote.
    uint32 public constant MAX_POL_SHARE_BPS = 2_000;

    /// @notice Current ops share in basis points. The Pot receives the remainder.
    uint32 public opsBps;

    /// @notice Contract that funds the 24h reward rounds.
    address public pot;

    /// @notice Operations wallet.
    address public ops;

    /// @notice Share of every inflow routed to protocol-owned liquidity, in basis points.
    /// @dev Defaults to zero: the three-way split is opt-in. This exists so POL can pair
    ///      its stock holdback with quote token of its own, instead of depending on
    ///      expired credits or manual transfers from ops. See OPEN_ITEMS.md item 2.
    uint32 public polShareBps;

    /// @notice Protocol-owned liquidity treasury. May be unset while `polShareBps` is zero.
    address public polTreasury;

    event Distributed(
        address indexed asset, uint256 potAmount, uint256 opsAmount, uint256 polAmount, address indexed caller
    );
    event OpsUpdated(address indexed previousOps, address indexed newOps);
    event PotUpdated(address indexed previousPot, address indexed newPot);
    event OpsBpsUpdated(uint32 previousOpsBps, uint32 newOpsBps);
    event PolTreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event PolShareBpsUpdated(uint32 previousBps, uint32 newBps);
    /// @notice An ETH leg could not be paid and is now claimable by `recipient`.
    event EthEscrowed(address indexed recipient, uint256 amount, uint256 totalOwed);
    event EthWithdrawn(address indexed recipient, uint256 amount);

    error ZeroAddress();
    error OpsBpsTooHigh(uint32 provided, uint32 maximum);
    error MaxOpsBpsTooHigh(uint32 provided, uint32 maximum);
    error NothingToDistribute(address asset);
    error PolShareTooHigh(uint32 provided, uint32 maximum);
    error PolTreasuryNotSet();
    error SharesExceedTotal(uint32 opsBps, uint32 polBps);
    error NothingOwed(address recipient);
    error BatchTooLarge(uint256 provided, uint256 maximum);

    /// @param multisig   Owner. Governs ops, pot and opsBps. Must be the multisig.
    /// @param pot_       Pot contract address (round budget).
    /// @param ops_       Operations wallet.
    /// @param opsBps_    Initial ops share in bps. Spec calls for 2000 (20 percent).
    /// @param maxOpsBps_ Immutable ceiling for opsBps. Recommend 2000 unless you
    ///                   deliberately want headroom to raise the ops share later.
    constructor(address multisig, address pot_, address ops_, uint32 opsBps_, uint32 maxOpsBps_) Ownable(multisig) {
        if (multisig == address(0) || pot_ == address(0) || ops_ == address(0)) revert ZeroAddress();
        if (maxOpsBps_ > BPS_DENOMINATOR) revert MaxOpsBpsTooHigh(maxOpsBps_, BPS_DENOMINATOR);
        if (opsBps_ > maxOpsBps_) revert OpsBpsTooHigh(opsBps_, maxOpsBps_);

        maxOpsBps = maxOpsBps_;
        opsBps = opsBps_;
        pot = pot_;
        ops = ops_;

        emit PotUpdated(address(0), pot_);
        emit OpsUpdated(address(0), ops_);
        emit OpsBpsUpdated(0, opsBps_);
    }

    /// @notice Accept ETH from any fee source. Intentionally does no work and emits
    ///         no event, so that senders forwarding only 2300 gas still succeed.
    receive() external payable {}

    /* ------------------------------------------------------------------ */
    /*                               VIEWS                                  */
    /* ------------------------------------------------------------------ */

    /// @notice ETH available to split: the balance minus anything already owed to a
    ///         recipient whose payment failed.
    /// @dev THIS IS THE NUMBER EVERY ETH SPLIT USES, not `address(this).balance`. Escrowed
    ///      ETH is already allocated to somebody; re-splitting it would pay it out twice and
    ///      leave the escrow unbacked.
    function distributableEth() public view returns (uint256) {
        uint256 balance = address(this).balance;
        uint256 owed = totalOwedEth;
        return balance > owed ? balance - owed : 0;
    }

    /// @notice Pot share in basis points. Whatever ops and POL do not take.
    function potBps() public view returns (uint32) {
        return BPS_DENOMINATOR - opsBps - polShareBps;
    }

    /// @notice Preview how amount would be split, without moving anything.
    /// @dev Rounding dust always lands on the Pot, never on ops or POL.
    function previewSplit(uint256 amount)
        public
        view
        returns (uint256 potAmount, uint256 opsAmount, uint256 polAmount)
    {
        opsAmount = (amount * opsBps) / BPS_DENOMINATOR;
        polAmount = (amount * polShareBps) / BPS_DENOMINATOR;
        potAmount = amount - opsAmount - polAmount;
    }

    /* ------------------------------------------------------------------ */
    /*                          DISTRIBUTION                                */
    /* ------------------------------------------------------------------ */

    /// @notice Split the full ETH balance. Permissionless.
    function distributeETH() external nonReentrant returns (uint256 potAmount, uint256 opsAmount, uint256 polAmount) {
        uint256 balance = distributableEth();
        if (balance == 0) revert NothingToDistribute(address(0));
        (potAmount, opsAmount, polAmount) = _splitETH(balance);
    }

    /// @notice Split the full balance of one ERC-20. Permissionless.
    function distributeToken(IERC20 token)
        external
        nonReentrant
        returns (uint256 potAmount, uint256 opsAmount, uint256 polAmount)
    {
        if (address(token) == address(0)) revert ZeroAddress();
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) revert NothingToDistribute(address(token));
        (potAmount, opsAmount, polAmount) = _splitToken(token, balance);
    }

    /// @notice Split several ERC-20s in one transaction. Zero balances are skipped
    ///         rather than reverting, so one empty token cannot brick a batch.
    function distributeTokens(IERC20[] calldata tokens) external nonReentrant {
        if (tokens.length > MAX_BATCH) revert BatchTooLarge(tokens.length, MAX_BATCH);
        for (uint256 i; i < tokens.length; ++i) {
            IERC20 token = tokens[i];
            if (address(token) == address(0)) continue;
            uint256 balance = token.balanceOf(address(this));
            if (balance == 0) continue;
            _splitToken(token, balance);
        }
    }

    /// @notice Split ETH and a list of ERC-20s in one transaction. Nothing reverts
    ///         on an empty balance; this is the keeper bot default entry point.
    function distributeAll(IERC20[] calldata tokens) external nonReentrant {
        if (tokens.length > MAX_BATCH) revert BatchTooLarge(tokens.length, MAX_BATCH);
        uint256 balance = distributableEth();
        if (balance != 0) _splitETH(balance);
        for (uint256 i; i < tokens.length; ++i) {
            IERC20 token = tokens[i];
            if (address(token) == address(0)) continue;
            uint256 tokenBalance = token.balanceOf(address(this));
            if (tokenBalance == 0) continue;
            _splitToken(token, tokenBalance);
        }
    }

    /// @notice Pay out ETH escrowed for `recipient` after a failed distribution leg.
    ///
    /// @dev PERMISSIONLESS, and it always pays the recipient rather than the caller — same
    ///      rule as `ChipClaims.claimFor`, for the same reason: a stranger calling it can
    ///      only help, so a keeper can clear a stuck balance without anybody handing over a
    ///      key. Full gas is forwarded here, unlike the bounded stipend during a split,
    ///      because at this point one recipient's failure can only cost that recipient.
    ///
    ///      A failure reverts the whole call, which rolls the bookkeeping back — the escrow
    ///      is not consumed by a payment that did not land.
    function withdrawEth(address recipient) external nonReentrant returns (uint256 amount) {
        amount = owedEth[recipient];
        if (amount == 0) revert NothingOwed(recipient);

        owedEth[recipient] = 0;
        totalOwedEth -= amount;

        Address.sendValue(payable(recipient), amount);
        emit EthWithdrawn(recipient, amount);
    }

    /* ------------------------------------------------------------------ */
    /*                          GOVERNANCE                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Change the operations wallet. Multisig only.
    function setOps(address newOps) external onlyOwner {
        if (newOps == address(0)) revert ZeroAddress();
        emit OpsUpdated(ops, newOps);
        ops = newOps;
    }

    /// @notice Point at a new Pot, for example after a Pot redeploy. Multisig only.
    function setPot(address newPot) external onlyOwner {
        if (newPot == address(0)) revert ZeroAddress();
        emit PotUpdated(pot, newPot);
        pot = newPot;
    }

    /// @notice Change the ops share. Multisig only, capped by the immutable maxOpsBps.
    function setOpsBps(uint32 newOpsBps) external onlyOwner {
        if (newOpsBps > maxOpsBps) revert OpsBpsTooHigh(newOpsBps, maxOpsBps);
        if (uint256(newOpsBps) + polShareBps > BPS_DENOMINATOR) revert SharesExceedTotal(newOpsBps, polShareBps);
        emit OpsBpsUpdated(opsBps, newOpsBps);
        opsBps = newOpsBps;
    }

    /// @notice Set the protocol-owned liquidity treasury. Multisig only.
    function setPolTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit PolTreasuryUpdated(polTreasury, newTreasury);
        polTreasury = newTreasury;
    }

    /// @notice Route a slice of every inflow to POL. Multisig only, capped at
    ///         {MAX_POL_SHARE_BPS}. Defaults to zero, so the split stays two-way until
    ///         someone deliberately turns this on.
    /// @dev Requires a treasury to be set first, so a non-zero share can never be
    ///      configured with nowhere to send it.
    function setPolShareBps(uint32 newPolShareBps) external onlyOwner {
        if (newPolShareBps > MAX_POL_SHARE_BPS) revert PolShareTooHigh(newPolShareBps, MAX_POL_SHARE_BPS);
        if (newPolShareBps != 0 && polTreasury == address(0)) revert PolTreasuryNotSet();
        if (uint256(opsBps) + newPolShareBps > BPS_DENOMINATOR) revert SharesExceedTotal(opsBps, newPolShareBps);
        emit PolShareBpsUpdated(polShareBps, newPolShareBps);
        polShareBps = newPolShareBps;
    }

    /* ------------------------------------------------------------------ */
    /*                           INTERNALS                                  */
    /* ------------------------------------------------------------------ */

    /// @dev SEC-FEE-001. Each leg is attempted with a bounded stipend and escrowed on
    ///      failure, so the split ALWAYS completes. The amounts in {Distributed} are the
    ///      allocation, not proof of receipt — check {EthEscrowed} for what did not land.
    function _splitETH(uint256 amount) internal returns (uint256 potAmount, uint256 opsAmount, uint256 polAmount) {
        (potAmount, opsAmount, polAmount) = previewSplit(amount);
        emit Distributed(address(0), potAmount, opsAmount, polAmount, msg.sender);
        _payEth(pot, potAmount);
        _payEth(ops, opsAmount);
        if (polAmount != 0) _payEth(polTreasury, polAmount);
    }

    /// @dev Attempt, then escrow. Never reverts, which is the whole point: a recipient that
    ///      cannot accept ETH must not be able to hold the other two hostage, nor to stop
    ///      new fees being split as they arrive.
    function _payEth(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = payable(to).call{value: amount, gas: PAYOUT_GAS}("");
        if (ok) return;

        owedEth[to] += amount;
        totalOwedEth += amount;
        emit EthEscrowed(to, amount, totalOwedEth);
    }

    /// @dev SEC-FEE-003. Ops and POL are paid their exact shares; THE POT TAKES WHAT IS LEFT.
    ///
    ///      The ordering is the fix. Paying the Pot first and the others from a precomputed
    ///      remainder means a token that takes a cut in transit leaves the final transfer
    ///      larger than the balance, and `safeTransfer` reverts — freezing that token's fees
    ///      entirely. Paying the Pot last, from the measured remaining balance, cannot
    ///      overdraw by construction.
    ///
    ///      It also keeps the existing promise: with a well-behaved token the Pot receives
    ///      exactly `potAmount` plus every wei of rounding dust, because ops and POL take
    ///      their floors and the remainder is the Pot's share. The Pot is simply the residual
    ///      claimant in both directions — it gains the dust and absorbs any transit
    ///      shortfall, which is the honest place to put it, since holders are also the ones
    ///      the token was collected for.
    ///
    ///      No fee token Chipworks routes today behaves this way (WETH, USDC, AERO, $CHIP).
    ///      This is the same "measure, never assume" discipline `ChipRounds._deliver` and
    ///      `ChipClaims.recordAcquired` already apply, made consistent here.
    function _splitToken(IERC20 token, uint256 amount)
        internal
        returns (uint256 potAmount, uint256 opsAmount, uint256 polAmount)
    {
        (potAmount, opsAmount, polAmount) = previewSplit(amount);

        opsAmount = _payToken(token, ops, opsAmount);
        if (polAmount != 0) polAmount = _payToken(token, polTreasury, polAmount);

        uint256 remaining = token.balanceOf(address(this));
        if (remaining < potAmount) potAmount = remaining;
        potAmount = _payToken(token, pot, potAmount);

        emit Distributed(address(token), potAmount, opsAmount, polAmount, msg.sender);
    }

    /// @dev Moves `amount` and reports what actually left this contract.
    function _payToken(IERC20 token, address to, uint256 amount) internal returns (uint256 moved) {
        if (amount == 0) return 0;
        uint256 before = token.balanceOf(address(this));
        token.safeTransfer(to, amount);
        uint256 remaining = token.balanceOf(address(this));
        moved = before > remaining ? before - remaining : 0;
    }
}
