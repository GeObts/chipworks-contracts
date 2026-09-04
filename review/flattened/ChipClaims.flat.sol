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

// src/interfaces/IStockRegistry.sol

/// @notice Which AMM a stock is bought on. Stored per stock so depth can migrate
///         between venues without redeploying anything.
enum Venue {
    None, // not configured yet
    UniswapV3, // uses `fee`
    Slipstream // Aerodrome concentrated liquidity, uses `tickSpacing`
}

/// @notice Everything Chipworks knows about one tokenized stock.
struct Stock {
    // --- slot 0 ---
    address pool; // AMM pool against the registry quote token
    uint24 fee; // UniswapV3 fee tier, e.g. 3000 == 0.3%
    int24 tickSpacing; // Slipstream tick spacing
    bool registered;
    bool enabled;
    Venue venue;
    // --- slot 1 ---
    address feed; // Chainlink aggregator, USD-denominated
    uint8 tokenDecimals; // cached, B20 stocks are 8
    uint8 feedDecimals; // cached, Chainlink USD feeds are typically 8
    // --- slot 2 ---
    uint128 minLiquidityUsd; // 18-decimal USD, gate for enabling
}

interface IStockRegistry {
    function quoteToken() external view returns (address);
    function quoteDecimals() external view returns (uint8);
    function isEnabled(address token) external view returns (bool);
    function getStock(address token) external view returns (Stock memory);
    function enabledTokens() external view returns (address[] memory);
    function allTokens() external view returns (address[] memory);
    function priceUsd(address token) external view returns (uint256 price1e18, uint256 updatedAt);
    function poolLiquidityUsd(address token) external view returns (uint256);
    function clearsMinLiquidity(address token) external view returns (bool);
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

// src/ChipClaims.sol

/// @title ChipClaims
/// @notice The ledger. Every token a holder is owed lives here, and this is the only
///         contract that can pay one out.
///
/// @dev SPLIT FROM ChipRounds ON PURPOSE, AND THIS IS THE SMALLER HALF.
///
///      Chipworks used to be one contract. It grew past the EIP-170 code size limit, and
///      rather than shave bytes it was split along the line that matters: the machinery
///      that SPENDS money (opening rounds, pricing swaps, buying stock) is in
///      {ChipRounds}; the ledger that OWES money is here.
///
///      That boundary was chosen so this file can stay small enough to hold in your head.
///      It has no swap logic, no router, no price bounds, no venue handling — none of the
///      moving parts that make the engine complicated. What it does is arithmetic on
///      recorded weights, a time gate, and transfers out. An auditor reading only this
///      file can decide whether holders can be paid what they are owed and nothing more.
///
///      NO PROXY, NO DELEGATECALL. Two plain contracts wired at deploy. `rounds` is a
///      single trusted caller set by the multisig; everything it can do is enumerated in
///      the four `onlyRounds` functions below, and none of them can move a token out.
///
///      THE CREDIT MODEL, unchanged by the split: per-round weight shares, converted to
///      token amounts lazily at claim time.
///
///          claimable = acquired[round][stock] * weightOf[round][stock][you]
///                                             / totalWeight[round][stock]
contract ChipClaims is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Minimum full claim windows a round must offer before it can expire.
    uint256 public constant MIN_WINDOWS_BEFORE_EXPIRY = 3;

    uint32 public constant MIN_WINDOW_LENGTH = 1 days;
    uint32 public constant MAX_WINDOW_LENGTH = 30 days;
    uint32 public constant MIN_OPEN_DURATION = 1 hours;
    uint32 public constant MAX_CREDIT_EXPIRY = 365 days;

    /// @notice Gas cap on calls into foreign contracts. See ASSUMPTIONS.md A-17.
    uint256 public constant PROBE_GAS = 100_000;

    /// @notice A round's claim schedule, frozen when the round finalizes.
    struct Schedule {
        uint64 finalizedAt;
        uint64 expiresAt;
        uint32 windowLengthAt;
        uint32 openDurationAt;
    }

    /* ----------------------------- wiring ----------------------------- */

    IStockRegistry public immutable registry;
    address public immutable quoteToken;

    /// @notice Timestamp all claim windows are counted from. Set at deploy, never changeable.
    /// @dev Immutable on purpose: if governance could move the anchor it could slide the
    ///      windows forward indefinitely and block claims without changing a duration.
    uint64 public immutable windowAnchor;

    /// @notice The round engine. The only contract allowed to write credits.
    address public rounds;

    /// @notice Where expired credits and auto-compounded claims are sent.
    address public polTreasury;

    /* --------------------------- tunables ----------------------------- */

    uint32 public windowLength;
    uint32 public windowOpenDuration;
    uint64 public creditExpiry;

    /* ----------------------------- ledger ----------------------------- */

    mapping(uint256 roundId => Schedule) internal _schedules;

    mapping(uint256 roundId => mapping(address stock => uint256)) public totalWeight;
    mapping(uint256 roundId => mapping(address stock => mapping(address owner => uint256))) public weightOf;
    mapping(uint256 roundId => mapping(address stock => uint256)) public acquired;
    mapping(uint256 roundId => mapping(address stock => uint256)) public claimedTotal;
    mapping(uint256 roundId => mapping(address stock => uint256)) public sweptTotal;
    mapping(uint256 roundId => mapping(address stock => bool)) public stockSwept;
    mapping(uint256 roundId => mapping(address stock => uint256)) public sweepCursor;
    mapping(uint256 roundId => mapping(address stock => mapping(address owner => bool))) public hasClaimed;

    /// @notice Everyone credited in a (round, stock), in credit order.
    mapping(uint256 roundId => mapping(address stock => address[])) internal _holders;

    mapping(address owner => bool) public autoCompound;
    mapping(address owner => uint256) public polCreditUsd;

    /// @notice Token units owed to claimants across every unexpired round.
    /// @dev The rescue can never touch this.
    mapping(address token => uint256) public totalOwed;

    /* ----------------------------- events ----------------------------- */

    event Claimed(uint256 indexed roundId, address indexed stock, address indexed owner, uint256 amount);
    event Compounded(uint256 indexed roundId, address indexed stock, address indexed owner, uint256 amount);
    event Swept(uint256 indexed roundId, address indexed stock, uint256 amount, bool complete);
    event CreditExpired(uint256 indexed roundId, address indexed stock, address indexed owner, uint256 amount);
    event WeightCredited(uint256 indexed roundId, address indexed stock, address indexed owner, uint256 weight);
    event AcquiredRecorded(uint256 indexed roundId, address indexed stock, uint256 amount);
    event ScheduleFrozen(uint256 indexed roundId, uint64 expiresAt, uint32 windowLength, uint32 openDuration);
    event ClaimScheduleUpdated(uint32 windowLength, uint32 openDuration, uint64 creditExpiry);
    event AutoCompoundSet(address indexed owner, bool enabled);
    event ExcessRecovered(address indexed token, address indexed to, uint256 amount);
    event RoundsUpdated(address indexed previous, address indexed current);
    event PolTreasuryUpdated(address indexed previous, address indexed current);

    /* ----------------------------- errors ----------------------------- */

    error ZeroAddress();
    error NotRounds(address caller);
    error RoundNotFinalized(uint256 roundId);
    error AlreadyFinalized(uint256 roundId);
    error AlreadyClaimed(uint256 roundId, address stock, address owner);
    error NothingToClaim();
    error CreditsExpired(uint256 roundId, uint64 expiredAt);
    /// @dev Carries the next opening so a caller knows exactly when to return.
    error ClaimsClosed(uint64 nowTs, uint64 nextOpenAt);
    error NotExpiredYet(uint256 roundId, uint64 expiresAt);
    error AlreadySwept(uint256 roundId, address stock);
    error InsufficientExcess(address token, uint256 requested, uint256 available);
    error Insolvent(address token);
    error BadConfig();
    error LengthMismatch();
    error Underfunded(address stock, uint256 held, uint256 needed);

    modifier onlyRounds() {
        if (msg.sender != rounds) revert NotRounds(msg.sender);
        _;
    }

    /// @param multisig  Owner.
    /// @param registry_ StockRegistry, used only to mark compounded claims in USD.
    constructor(address multisig, address registry_) Ownable(multisig) {
        if (multisig == address(0) || registry_ == address(0)) revert ZeroAddress();
        registry = IStockRegistry(registry_);
        quoteToken = IStockRegistry(registry_).quoteToken();

        windowAnchor = uint64(block.timestamp);
        windowLength = 7 days;
        windowOpenDuration = 48 hours;
        creditExpiry = 30 days;
    }

    /* ------------------------------------------------------------------ */
    /*                     WRITES, ENGINE ONLY (4 of them)                  */
    /* ------------------------------------------------------------------ */

    /// @notice Record that `owner` is entitled to a share of a (round, stock).
    /// @dev Called during accumulation. Cannot move tokens, cannot pay anyone.
    function creditWeight(uint256 roundId, address stock, address owner, uint256 weight) external onlyRounds {
        if (_schedules[roundId].finalizedAt != 0) revert AlreadyFinalized(roundId);
        if (weight == 0) return;

        // First credit for this holder here: remember them so the expiry sweep can
        // report exactly what each person lost.
        if (weightOf[roundId][stock][owner] == 0) _holders[roundId][stock].push(owner);
        weightOf[roundId][stock][owner] += weight;
        totalWeight[roundId][stock] += weight;
        emit WeightCredited(roundId, stock, owner, weight);
    }

    /// @notice Record tokens the engine has already transferred in.
    /// @dev Checks the tokens are actually here before believing the number. The engine is
    ///      trusted to be the engine, not trusted to be correct: if it reports more than
    ///      this contract holds, the call reverts rather than booking a debt it cannot pay.
    function recordAcquired(uint256 roundId, address stock, uint256 amount) external onlyRounds {
        if (_schedules[roundId].finalizedAt != 0) revert AlreadyFinalized(roundId);
        if (amount == 0) return;

        uint256 held = IERC20(stock).balanceOf(address(this));
        uint256 needed = totalOwed[stock] + amount;
        if (held < needed) revert Underfunded(stock, held, needed);

        acquired[roundId][stock] += amount;
        totalOwed[stock] += amount;
        emit AcquiredRecorded(roundId, stock, amount);
    }

    /// @notice Freeze a round's claim schedule. Called once, when the round finalizes.
    /// @dev Snapshotting means a later governance change can never narrow or shorten a
    ///      round that already exists.
    function freezeSchedule(uint256 roundId) external onlyRounds returns (uint64 roundExpiresAt) {
        Schedule storage s = _schedules[roundId];
        if (s.finalizedAt != 0) revert AlreadyFinalized(roundId);

        s.finalizedAt = uint64(block.timestamp);
        roundExpiresAt = uint64(block.timestamp + creditExpiry);
        s.expiresAt = roundExpiresAt;
        s.windowLengthAt = windowLength;
        s.openDurationAt = windowOpenDuration;

        emit ScheduleFrozen(roundId, roundExpiresAt, windowLength, windowOpenDuration);
    }

    /* ------------------------------------------------------------------ */
    /*                              CLAIMS                                  */
    /* ------------------------------------------------------------------ */

    /// @notice What `owner` can still claim from one round for one stock.
    function claimable(uint256 roundId, address stock, address owner) public view returns (uint256) {
        if (hasClaimed[roundId][stock][owner]) return 0;
        uint256 tw = totalWeight[roundId][stock];
        if (tw == 0) return 0;
        uint256 got = acquired[roundId][stock];
        if (got == 0) return 0;
        return (got * weightOf[roundId][stock][owner]) / tw;
    }

    /// @notice Claim one stock from one round.
    /// @dev One stock per call: a frozen stock blocks only its own claim, never anyone
    ///      else's and never another stock in the same round.
    function claim(uint256 roundId, address stock) external nonReentrant returns (uint256 amount) {
        amount = _claim(roundId, stock, msg.sender);
    }

    /// @notice Claim on someone else's behalf. Proceeds always go to `owner`.
    /// @dev Safe to leave permissionless: a stranger calling it can only deliver the
    ///      owner's own credit to the owner, and protect them from expiry.
    function claimFor(address owner, uint256 roundId, address stock) external nonReentrant returns (uint256 amount) {
        if (owner == address(0)) revert ZeroAddress();
        amount = _claim(roundId, stock, owner);
    }

    /// @notice Claim many (round, stock) pairs in one transaction.
    /// @dev Pairs yielding nothing are skipped rather than reverting. A pair whose TOKEN is
    ///      frozen still reverts the batch: fall back to single `claim` calls.
    function claimMany(uint256[] calldata roundIds, address[] calldata stocks)
        external
        nonReentrant
        returns (uint256 total)
    {
        if (roundIds.length != stocks.length) revert LengthMismatch();
        for (uint256 i; i < roundIds.length; ++i) {
            if (claimable(roundIds[i], stocks[i], msg.sender) == 0) continue;
            total += _claim(roundIds[i], stocks[i], msg.sender);
        }
        if (total == 0) revert NothingToClaim();
    }

    function _claim(uint256 roundId, address stock, address owner) internal returns (uint256 amount) {
        Schedule storage s = _schedules[roundId];
        if (s.finalizedAt == 0) revert RoundNotFinalized(roundId);
        if (block.timestamp > s.expiresAt) revert CreditsExpired(roundId, s.expiresAt);

        // Credits accrue continuously and are always visible via `claimable`, but they can
        // only be taken while a window is open. The round's own frozen cadence is used, so
        // a later governance change can never narrow a round that already exists.
        if (!_isOpenAt(uint64(block.timestamp), s.windowLengthAt, s.openDurationAt)) {
            (, uint64 opensAt,) = _windowStateAt(uint64(block.timestamp), s.windowLengthAt, s.openDurationAt);
            revert ClaimsClosed(uint64(block.timestamp), opensAt);
        }

        if (hasClaimed[roundId][stock][owner]) revert AlreadyClaimed(roundId, stock, owner);

        amount = claimable(roundId, stock, owner);
        if (amount == 0) revert NothingToClaim();

        hasClaimed[roundId][stock][owner] = true;
        claimedTotal[roundId][stock] += amount;
        totalOwed[stock] -= amount;

        if (autoCompound[owner] && polTreasury != address(0)) {
            IERC20(stock).safeTransfer(polTreasury, amount);
            uint256 usd = _usdValue(stock, amount);
            polCreditUsd[owner] += usd;
            // Best effort: the POL-side ledger is a mirror and must never block a claim.
            (bool noted,) = polTreasury.call{gas: PROBE_GAS}(
                abi.encodeWithSignature("notifyCompound(address,address,uint256,uint256)", owner, stock, amount, usd)
            );
            noted; // intentionally ignored
            emit Compounded(roundId, stock, owner, amount);
        } else {
            IERC20(stock).safeTransfer(owner, amount);
            emit Claimed(roundId, stock, owner, amount);
        }
    }

    function setAutoCompound(bool enabled) external {
        autoCompound[msg.sender] = enabled;
        emit AutoCompoundSet(msg.sender, enabled);
    }

    /* ------------------------------------------------------------------ */
    /*                              EXPIRY                                  */
    /* ------------------------------------------------------------------ */

    /// @notice After a round's credits expire, send what nobody claimed to the POL treasury.
    ///         Permissionless, one stock at a time, batched over holders.
    ///
    /// @param maxHolders How many holders to process this call. Zero means all remaining.
    /// @return moved     Tokens moved to POL by THIS call.
    /// @return complete  Whether the (round, stock) is now fully swept.
    ///
    /// @dev Emits a {CreditExpired} per holder so the site can show what each person lost.
    ///      NO LEDGER ENTRY IS MADE: an expired credit is forfeited, not compounded. The
    ///      opt-in `setAutoCompound` ledger is untouched and remains voluntary.
    function sweepExpired(uint256 roundId, address stock, uint256 maxHolders)
        public
        nonReentrant
        returns (uint256 moved, bool complete)
    {
        Schedule storage s = _schedules[roundId];
        if (s.finalizedAt == 0) revert RoundNotFinalized(roundId);
        if (block.timestamp <= s.expiresAt) revert NotExpiredYet(roundId, s.expiresAt);
        if (stockSwept[roundId][stock]) revert AlreadySwept(roundId, stock);
        if (polTreasury == address(0)) revert ZeroAddress();

        address[] storage list = _holders[roundId][stock];
        uint256 cursor = sweepCursor[roundId][stock];
        uint256 end = (maxHolders == 0 || cursor + maxHolders > list.length) ? list.length : cursor + maxHolders;

        for (uint256 i = cursor; i < end; ++i) {
            address owner = list[i];
            uint256 amount = claimable(roundId, stock, owner);
            if (amount == 0) continue; // already claimed, or nothing owed

            // Mark it taken so a holder can never be counted twice, even if the sweep is
            // re-run or interleaved with another batch.
            hasClaimed[roundId][stock][owner] = true;
            moved += amount;
            emit CreditExpired(roundId, stock, owner, amount);
        }

        sweepCursor[roundId][stock] = end;
        complete = end == list.length;

        if (complete) {
            // Settle rounding dust: per-holder shares are floored, so the sum can fall a
            // few units short of what the round actually still holds.
            uint256 accounted = sweptTotal[roundId][stock] + moved + claimedTotal[roundId][stock];
            uint256 total = acquired[roundId][stock];
            if (total > accounted) moved += total - accounted;
            stockSwept[roundId][stock] = true;
        }

        if (moved != 0) {
            sweptTotal[roundId][stock] += moved;
            totalOwed[stock] -= moved;
            IERC20(stock).safeTransfer(polTreasury, moved);
        }
        emit Swept(roundId, stock, moved, complete);
    }

    /// @notice Sweep every holder of a (round, stock) in one call.
    function sweepExpired(uint256 roundId, address stock) external returns (uint256 moved) {
        (moved,) = sweepExpired(roundId, stock, 0);
    }

    /* ------------------------------------------------------------------ */
    /*                          WINDOW SCHEDULE                             */
    /* ------------------------------------------------------------------ */

    function scheduleOf(uint256 roundId) external view returns (Schedule memory) {
        return _schedules[roundId];
    }

    function expiresAt(uint256 roundId) external view returns (uint64) {
        return _schedules[roundId].expiresAt;
    }

    function isFinalized(uint256 roundId) external view returns (bool) {
        return _schedules[roundId].finalizedAt != 0;
    }

    /// @notice Whether claims are open right now, under the CURRENT configuration.
    function isClaimOpen() public view returns (bool) {
        return _isOpenAt(uint64(block.timestamp), windowLength, windowOpenDuration);
    }

    /// @notice Whether claims are open for a specific round, under ITS frozen schedule.
    function isClaimOpenFor(uint256 roundId) external view returns (bool) {
        Schedule storage s = _schedules[roundId];
        if (s.finalizedAt == 0) return false;
        return _isOpenAt(uint64(block.timestamp), s.windowLengthAt, s.openDurationAt);
    }

    /// @notice When the current or next claim window opens and closes.
    function claimWindowState() public view returns (bool open, uint64 opensAt, uint64 closesAt) {
        return _windowStateAt(uint64(block.timestamp), windowLength, windowOpenDuration);
    }

    /// @notice The next moment claims open. Equals now if a window is already open.
    function nextWindowOpensAt() external view returns (uint64) {
        (bool open, uint64 opensAt,) = claimWindowState();
        return open ? uint64(block.timestamp) : opensAt;
    }

    /// @notice How many full claim windows a finalized round still has before it expires.
    function windowsRemaining(uint256 roundId) external view returns (uint256) {
        Schedule storage s = _schedules[roundId];
        if (s.finalizedAt == 0 || s.windowLengthAt == 0) return 0;
        if (block.timestamp >= s.expiresAt) return 0;
        return _openingsIn(uint64(block.timestamp), s.expiresAt, s.windowLengthAt);
    }

    /// @notice Full window openings a round was guaranteed when it was finalized.
    /// @dev Must always be at least {MIN_WINDOWS_BEFORE_EXPIRY}.
    function guaranteedWindows(uint256 roundId) public view returns (uint256) {
        Schedule storage s = _schedules[roundId];
        if (s.finalizedAt == 0 || s.windowLengthAt == 0) return 0;
        return _openingsIn(s.finalizedAt, s.expiresAt, s.windowLengthAt);
    }

    /// @notice Window openings strictly after `from` and at or before `to`, for cadence `w`.
    function openingsInFor(uint64 from, uint64 to, uint32 w) external view returns (uint256) {
        return _openingsIn(from, to, w);
    }

    function holders(uint256 roundId, address stock) external view returns (address[] memory) {
        return _holders[roundId][stock];
    }

    function holderCount(uint256 roundId, address stock) external view returns (uint256) {
        return _holders[roundId][stock].length;
    }

    /// @dev Number of window openings strictly after `from` and at or before `to`.
    function _openingsIn(uint64 from, uint64 to, uint32 w) internal view returns (uint256) {
        if (to <= from || w == 0) return 0;
        uint64 anchor = windowAnchor;
        uint256 toIdx = to <= anchor ? 0 : (uint256(to - anchor) / w) + 1;
        uint256 fromIdx = from <= anchor ? 0 : (uint256(from - anchor) / w) + 1;
        return toIdx > fromIdx ? toIdx - fromIdx : 0;
    }

    function _isOpenAt(uint64 ts, uint32 w, uint32 d) internal view returns (bool) {
        if (w == 0 || d == 0) return false;
        if (ts < windowAnchor) return false;
        if (d >= w) return true; // permanently open, a legal configuration
        return (uint256(ts - windowAnchor) % w) < d;
    }

    function _windowStateAt(uint64 ts, uint32 w, uint32 d)
        internal
        view
        returns (bool open, uint64 opensAt, uint64 closesAt)
    {
        if (w == 0 || d == 0) return (false, 0, 0);
        if (ts < windowAnchor) return (false, windowAnchor, windowAnchor + d);

        uint256 elapsed = uint256(ts - windowAnchor);
        uint256 into = elapsed % w;
        uint64 thisOpen = uint64(uint256(windowAnchor) + (elapsed - into));

        if (into < d || d >= w) return (true, thisOpen, uint64(uint256(thisOpen) + d));
        uint64 next = uint64(uint256(thisOpen) + w);
        return (false, next, uint64(uint256(next) + d));
    }

    /* ------------------------------------------------------------------ */
    /*                            GOVERNANCE                                */
    /* ------------------------------------------------------------------ */

    /// @notice Point at the round engine. Multisig only.
    function setRounds(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        emit RoundsUpdated(rounds, v);
        rounds = v;
    }

    function setPolTreasury(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        emit PolTreasuryUpdated(polTreasury, v);
        polTreasury = v;
    }

    /// @notice Set the claim cadence and how long each window stays open. Multisig only.
    function setClaimSchedule(uint32 newWindowLength, uint32 newOpenDuration) external onlyOwner {
        _requireScheduleSane(newWindowLength, newOpenDuration, creditExpiry);
        windowLength = newWindowLength;
        windowOpenDuration = newOpenDuration;
        emit ClaimScheduleUpdated(newWindowLength, newOpenDuration, creditExpiry);
    }

    /// @notice Set how long credits survive before they can be swept. Multisig only.
    function setCreditExpiry(uint64 newExpiry) external onlyOwner {
        _requireScheduleSane(windowLength, windowOpenDuration, newExpiry);
        creditExpiry = newExpiry;
        emit ClaimScheduleUpdated(windowLength, windowOpenDuration, newExpiry);
    }

    /// @dev THE SCHEDULE RULE. Every accepted configuration must guarantee a round at least
    ///      {MIN_WINDOWS_BEFORE_EXPIRY} full claim windows before its credits can be swept.
    ///      Openings fall on a fixed cadence, so an interval of length `expiry` always
    ///      contains at least `floor(expiry / windowLength)` of them; requiring
    ///      `expiry >= MIN * windowLength` therefore makes the guarantee unconditional,
    ///      whatever moment a round happens to finalize at.
    function _requireScheduleSane(uint32 w, uint32 d, uint64 expiry) internal pure {
        if (w < MIN_WINDOW_LENGTH || w > MAX_WINDOW_LENGTH) revert BadConfig();
        if (d < MIN_OPEN_DURATION || d > w) revert BadConfig();
        if (expiry > MAX_CREDIT_EXPIRY) revert BadConfig();
        if (expiry < MIN_WINDOWS_BEFORE_EXPIRY * uint256(w)) revert BadConfig();
    }

    /* ------------------------------------------------------------------ */
    /*                              RESCUE                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Token balance not backing any live claim.
    function excess(address token) public view returns (uint256) {
        uint256 balance = _balanceOf(token, address(this));
        uint256 owed = totalOwed[token];
        return balance > owed ? balance - owed : 0;
    }

    /// @notice Recover only tokens provably in excess of every unexpired claim.
    /// @dev THE INVARIANT: this can never reduce the balance below `totalOwed`. Checked
    ///      before the transfer and again afterwards against the real balance.
    function recoverExcess(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 avail = excess(token);
        if (amount == 0 || amount > avail) revert InsufficientExcess(token, amount, avail);

        IERC20(token).safeTransfer(to, amount);

        if (_balanceOf(token, address(this)) < totalOwed[token]) revert Insolvent(token);
        emit ExcessRecovered(token, to, amount);
    }

    /* ------------------------------------------------------------------ */
    /*                             INTERNALS                                */
    /* ------------------------------------------------------------------ */

    function _usdValue(address token, uint256 amount) internal view returns (uint256) {
        if (token == quoteToken) return (amount * 1e18) / (10 ** registry.quoteDecimals());
        try registry.priceUsd(token) returns (uint256 price1e18, uint256) {
            return (amount * price1e18) / (10 ** registry.getStock(token).tokenDecimals);
        } catch {
            return 0;
        }
    }

    /// @dev Gas-capped balance read. See ASSUMPTIONS.md A-17.
    function _balanceOf(address token, address who) internal view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall{gas: PROBE_GAS}(abi.encodeCall(IERC20.balanceOf, (who)));
        if (!ok || ret.length < 32) return 0;
        return abi.decode(ret, (uint256));
    }
}
