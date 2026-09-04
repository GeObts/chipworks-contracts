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

// src/interfaces/IAggregatorV3.sol

/// @notice Chainlink AggregatorV3 read surface.
/// @dev Base tokenized-equity feeds use this standard interface. Note they have no
///      heartbeat while equity markets are closed and hold the last close instead,
///      so `updatedAt` going stale on a weekend is expected, not a fault.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
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

// src/interfaces/ISwapRouters.sol

/// @notice Uniswap v3 SwapRouter02 exact-input-single.
interface IUniswapV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice Aerodrome Slipstream router. Same shape as Uniswap v3 except it keys pools by
///         tick spacing rather than fee tier, and carries a deadline.
interface ISlipstreamSwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        int24 tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

// src/interfaces/IWETH.sol

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
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

// src/base/ConversionRoutes.sol

/// @title ConversionRoutes
/// @notice Shared machinery for turning an arbitrary asset into the quote token, with the
///         minimum output bounded by that asset's own Chainlink mark.
///
/// @dev Both {Pot} and {POLTreasury} need this and there is exactly ONE implementation of
///      it on purpose. A Chainlink-bounded swap is the most security-sensitive code in the
///      repo; having two copies would double the surface an auditor has to check and
///      guarantee they drift. Everything here is configuration — route, fee tier, slippage
///      bound, per-call cap, staleness limit — so adding an asset is a multisig call.
///
///      THREE PROPERTIES EVERY CONVERSION HAS:
///      1. Bounded by Chainlink. `amountOutMinimum` comes from the feed, never from a quote.
///      2. Capped per call, so a large balance cannot be walked through the pool in one
///         swap. Verified on a Base fork: an uncapped 500 ETH breached its bound and was
///         refused, while capped conversions landed comfortably inside it.
///      3. Measured by balance delta, never by the router's return value, so a token that
///         lies about transferring cannot inflate what we think we received.
abstract contract ConversionRoutes {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;

    /// @notice Gas cap on the one-off `decimals()` probe when registering a route.
    uint256 public constant PROBE_GAS = 50_000;

    /// @notice Asset every route converts into.
    address public immutable quoteToken;

    /// @notice Cached decimals of `quoteToken`.
    uint8 public immutable quoteDecimals;

    /// @notice Wrapped native token. Native ETH is wrapped into this on the way through.
    address public weth;

    struct Route {
        bool enabled;
        address feed; // Chainlink <token>/USD aggregator
        address router; // Uniswap v3 style router
        uint24 fee; // pool fee tier
        uint32 maxSlippageBps; // how far below the Chainlink mark execution may land
        uint128 maxPerCall; // largest amount one convert() may push through the pool
        uint64 maxFeedAge; // reject a feed older than this. 0 disables the check
        uint8 tokenDecimals; // cached
        uint8 feedDecimals; // cached
    }

    mapping(address token => Route) internal _routes;
    address[] internal _routedTokens;

    event Converted(address indexed token, uint256 amountIn, uint256 quoteOut, uint256 minOut, address indexed caller);
    event RouteSet(
        address indexed token,
        address feed,
        address router,
        uint24 fee,
        uint32 slippageBps,
        uint128 cap,
        uint64 maxFeedAge
    );
    event RouteDisabled(address indexed token);
    event WethUpdated(address indexed previousWeth, address indexed newWeth);

    error RouteZeroAddress();
    error RouteBadConfig();
    error StaleFeed(uint256 updatedAt, uint256 maxAge);
    error BadFeedAnswer();
    error UnderMinOut(uint256 received, uint256 minOut);
    error NoRoute(address token);
    error CannotRouteQuoteToken();
    error NothingToConvert();

    /// @dev Raised when the amount is so small that the Chainlink-derived minimum output
    ///      rounds to zero. Swapping then would be an unbounded swap, so it is refused.
    ///      Dust simply waits until enough accumulates to be priced.
    error AmountTooSmall(uint256 amountIn);

    constructor(address quoteToken_) {
        if (quoteToken_ == address(0)) revert RouteZeroAddress();
        quoteToken = quoteToken_;
        quoteDecimals = IDecimals(quoteToken_).decimals();
    }

    /* ------------------------------------------------------------------ */
    /*                               VIEWS                                  */
    /* ------------------------------------------------------------------ */

    function routeOf(address token) external view returns (Route memory) {
        return _routes[token];
    }

    function routedTokens() external view returns (address[] memory) {
        return _routedTokens;
    }

    /// @notice ETH plus WETH waiting to be converted, before the per-call cap.
    function convertibleBalance() public view returns (uint256) {
        uint256 wethBalance = weth == address(0) ? 0 : IERC20(weth).balanceOf(address(this));
        return address(this).balance + wethBalance;
    }

    /// @notice Balance of `token` waiting to be converted, before the per-call cap.
    /// @dev For WETH this includes native ETH, since ETH is wrapped on the way through.
    function convertibleBalance(address token) public view returns (uint256) {
        if (token == weth) return convertibleBalance();
        return IERC20(token).balanceOf(address(this));
    }

    /// @notice How much the next conversion of `token` would push through the pool.
    function nextConversionAmount(address token) public view returns (uint256) {
        uint256 total = convertibleBalance(token);
        uint256 cap = _routes[token].maxPerCall;
        return (cap != 0 && total > cap) ? cap : total;
    }

    /// @notice Minimum quote-token output a conversion of `amount` would insist on.
    function minOutFor(address token, uint256 amount) public view returns (uint256) {
        Route storage r = _routes[token];
        if (!r.enabled) revert NoRoute(token);

        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(r.feed).latestRoundData();
        if (answer <= 0) revert BadFeedAnswer();
        if (r.maxFeedAge != 0 && block.timestamp > updatedAt + r.maxFeedAge) {
            revert StaleFeed(updatedAt, r.maxFeedAge);
        }

        // amount (tokenDecimals) x USD per token -> quote units, then the slippage haircut.
        uint256 gross =
            (amount * uint256(answer) * (10 ** quoteDecimals)) / (10 ** r.feedDecimals) / (10 ** r.tokenDecimals);
        return (gross * (BPS - r.maxSlippageBps)) / BPS;
    }

    /* ------------------------------------------------------------------ */
    /*                            INTERNALS                                 */
    /* ------------------------------------------------------------------ */

    function _convert(address token) internal returns (uint256 amountIn, uint256 quoteOut) {
        Route storage r = _routes[token];

        amountIn = nextConversionAmount(token);
        if (amountIn == 0) revert NothingToConvert();

        uint256 minOut = minOutFor(token, amountIn);
        if (minOut == 0) revert AmountTooSmall(amountIn);

        // Wrap only the shortfall: WETH already held is used as-is.
        if (token == weth) {
            uint256 wethBalance = IERC20(weth).balanceOf(address(this));
            if (wethBalance < amountIn) IWETH(weth).deposit{value: amountIn - wethBalance}();
        }

        uint256 before = IERC20(quoteToken).balanceOf(address(this));

        IERC20(token).forceApprove(r.router, amountIn);
        IUniswapV3SwapRouter(r.router)
            .exactInputSingle(
                IUniswapV3SwapRouter.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: quoteToken,
                fee: r.fee,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
            );
        IERC20(token).forceApprove(r.router, 0);

        // Trust the measured delta, never the router's return value.
        quoteOut = IERC20(quoteToken).balanceOf(address(this)) - before;
        if (quoteOut < minOut) revert UnderMinOut(quoteOut, minOut);

        emit Converted(token, amountIn, quoteOut, minOut, msg.sender);
    }

    function _setWeth(address weth_) internal {
        if (weth_ == address(0)) revert RouteZeroAddress();
        emit WethUpdated(weth, weth_);
        weth = weth_;
    }

    function _setRoute(
        address token,
        address feed,
        address router,
        uint24 fee,
        uint32 maxSlippageBps,
        uint128 maxPerCall,
        uint64 maxFeedAge
    ) internal {
        if (token == address(0) || feed == address(0) || router == address(0)) {
            revert RouteZeroAddress();
        }
        if (token == quoteToken) revert CannotRouteQuoteToken();
        if (fee == 0 || maxSlippageBps >= BPS || maxPerCall == 0) revert RouteBadConfig();

        uint8 tokenDecimals = _probeDecimals(token);
        uint8 feedDecimals = IAggregatorV3(feed).decimals();
        if (feedDecimals == 0 || feedDecimals > 18) revert RouteBadConfig();

        if (_routes[token].feed == address(0)) _routedTokens.push(token);

        _routes[token] = Route({
            enabled: true,
            feed: feed,
            router: router,
            fee: fee,
            maxSlippageBps: maxSlippageBps,
            maxPerCall: maxPerCall,
            maxFeedAge: maxFeedAge,
            tokenDecimals: tokenDecimals,
            feedDecimals: feedDecimals
        });

        emit RouteSet(token, feed, router, fee, maxSlippageBps, maxPerCall, maxFeedAge);
    }

    function _disableRoute(address token) internal {
        _routes[token].enabled = false;
        emit RouteDisabled(token);
    }

    /// @dev Gas-capped, per ASSUMPTIONS.md A-17. A token whose decimals cannot be read is
    ///      rejected rather than guessed at: getting this wrong silently mis-prices every
    ///      conversion of that token.
    function _probeDecimals(address token) internal view returns (uint8) {
        (bool ok, bytes memory ret) = token.staticcall{gas: PROBE_GAS}(abi.encodeWithSignature("decimals()"));
        if (!ok || ret.length != 32) revert RouteBadConfig();
        uint256 d = abi.decode(ret, (uint256));
        if (d == 0 || d > 36) revert RouteBadConfig();
        return uint8(d);
    }
}

interface IDecimals {
    function decimals() external view returns (uint8);
}

// src/Pot.sol

/// @title Pot
/// @notice Holds the money the 24h rounds draw from, and realises whatever arrives into
///         the round currency itself.
///
/// @dev Fees reach this contract in several shapes: ETH from the LP locker and royalties,
///      WETH from some venues, AERO from protocol-owned liquidity. Rounds can only spend
///      the quote token, so anything else has to be converted or it just sits there. The
///      full-system fork test caught exactly that: recycled AERO landed in the Pot and no
///      round could spend a cent of it.
///
///      CONVERSION IS A PER-TOKEN ROUTE TABLE. Each convertible token has its own row:
///      Chainlink feed, router, pool fee tier, slippage bound, per-call cap and staleness
///      limit. `convert(token)` is permissionless for every registered token, with the
///      minimum output bounded by that token's own Chainlink mark. Adding an income token
///      is one multisig call, not a redeploy.
///
///      THE PER-CALL CAP IS THE POINT. Without it a pot that has accumulated a large
///      balance gets walked through the pool in a single swap. Verified on a Base fork:
///      2 ETH converted comfortably inside the Chainlink floor, while an uncapped 500 ETH
///      breached the bound and was refused outright. Rounds are capped for the same reason.
///
///      UNCONVERTED ASSETS DO NOT COUNT. `available()` reports quote-token balance only, so
///      a round can never open against money that has not actually been realised.
contract Pot is Ownable2Step, ReentrancyGuard, ConversionRoutes {
    using SafeERC20 for IERC20;

    /// @notice The only address allowed to pull a round budget.
    address public rewards;

    event RewardsUpdated(address indexed previousRewards, address indexed newRewards);
    event BudgetPulled(address indexed to, uint256 amount);
    event Returned(address indexed from, uint256 amount);
    event NonQuoteSwept(address indexed token, address indexed to, uint256 amount);
    event EthSwept(address indexed to, uint256 amount);

    error ZeroAddress();
    error NotRewards(address caller);
    error CannotSweepQuoteToken();
    error NothingToSweep();
    error ConversionNotConfigured();

    constructor(address multisig, address quoteToken_) Ownable(multisig) ConversionRoutes(quoteToken_) {
        if (multisig == address(0)) revert ZeroAddress();
    }

    /// @notice Accept ETH from the FeeSplitter. Cheap on purpose so 2300-gas senders succeed.
    receive() external payable {}

    modifier onlyRewards() {
        if (msg.sender != rewards) revert NotRewards(msg.sender);
        _;
    }

    /* ------------------------------------------------------------------ */
    /*                               VIEWS                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Round currency available to fund a round. Excludes anything unconverted.
    function available() public view returns (uint256) {
        return IERC20(quoteToken).balanceOf(address(this));
    }

    /// @notice How much the next ETH conversion would push through the pool.
    function nextConversionAmount() public view returns (uint256) {
        return nextConversionAmount(weth);
    }

    /// @notice Minimum quote-token output the ETH conversion would insist on.
    function conversionMinOut(uint256 ethAmount) public view returns (uint256) {
        return minOutFor(weth, ethAmount);
    }

    /* ------------------------------------------------------------------ */
    /*                            CONVERSION                                */
    /* ------------------------------------------------------------------ */

    /// @notice Turn accumulated ETH (and any WETH) into round currency. Permissionless.
    function convert() external nonReentrant returns (uint256 amountIn, uint256 quoteOut) {
        if (weth == address(0) || !_routes[weth].enabled) revert ConversionNotConfigured();
        return _convert(weth);
    }

    /// @notice Turn an accumulated income token into round currency. Permissionless.
    /// @dev This is how recycled POL income becomes budget a round can actually spend.
    ///      Same Chainlink-bounded, capped, permissionless shape as the ETH path.
    function convert(address token) external nonReentrant returns (uint256 amountIn, uint256 quoteOut) {
        if (!_routes[token].enabled) revert NoRoute(token);
        return _convert(token);
    }

    /* ------------------------------------------------------------------ */
    /*                            GOVERNANCE                                */
    /* ------------------------------------------------------------------ */

    /// @notice Point at the ChipRewards contract. Multisig only.
    function setRewards(address newRewards) external onlyOwner {
        if (newRewards == address(0)) revert ZeroAddress();
        emit RewardsUpdated(rewards, newRewards);
        rewards = newRewards;
    }

    /// @notice Set the wrapped-native token and its conversion route in one call.
    /// @dev Convenience wrapper over {setRoute} for the ETH path.
    function setConversionConfig(
        address weth_,
        address ethUsdFeed_,
        address swapRouter_,
        uint24 conversionFee_,
        uint32 maxSlippageBps_,
        uint128 maxConvertPerCall_,
        uint64 maxFeedAge_
    ) external onlyOwner {
        _setWeth(weth_);
        _setRoute(weth_, ethUsdFeed_, swapRouter_, conversionFee_, maxSlippageBps_, maxConvertPerCall_, maxFeedAge_);
    }

    /// @notice Register or update the conversion route for one token. Multisig only.
    function setRoute(
        address token,
        address feed,
        address router,
        uint24 fee,
        uint32 maxSlippageBps,
        uint128 maxPerCall,
        uint64 maxFeedAge
    ) external onlyOwner {
        _setRoute(token, feed, router, fee, maxSlippageBps, maxPerCall, maxFeedAge);
    }

    /// @notice Stop converting a token. Its balance stays put and can still be swept.
    function disableRoute(address token) external onlyOwner {
        _disableRoute(token);
    }

    /// @notice Send a round budget to ChipRewards. Callable only by ChipRewards.
    function pullBudget(uint256 amount) external onlyRewards returns (uint256) {
        uint256 balance = available();
        if (amount > balance) amount = balance;
        IERC20(quoteToken).safeTransfer(msg.sender, amount);
        emit BudgetPulled(msg.sender, amount);
        return amount;
    }

    /// @notice Logged when ChipRewards hands back budget a round could not spend.
    function noteReturned(uint256 amount) external {
        emit Returned(msg.sender, amount);
    }

    /// @notice Move a non-round-currency asset out. Multisig only.
    /// @dev Cannot touch the quote token: that is the round budget and belongs to holders.
    ///      Still useful for a token with no route, or one whose route is broken.
    function sweepNonQuote(address token, address to) external onlyOwner {
        if (token == quoteToken) revert CannotSweepQuoteToken();
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NothingToSweep();
        IERC20(token).safeTransfer(to, amount);
        emit NonQuoteSwept(token, to, amount);
    }

    /// @notice Escape hatch for ETH if the conversion route is broken. Multisig only.
    function sweepEth(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = address(this).balance;
        if (amount == 0) revert NothingToSweep();
        Address.sendValue(payable(to), amount);
        emit EthSwept(to, amount);
    }
}
