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

// src/interfaces/IChipClaims.sol

/// @notice The minimal surface {ChipRounds} needs on {ChipClaims}.
/// @dev Four writes and two reads. None of the writes can move a token out of the ledger,
///      which is the whole point of the split: the engine can create entitlements and hand
///      over assets, but only the ledger can pay anyone.
interface IChipClaims {
    function creditWeight(uint256 roundId, address stock, address owner, uint256 weight) external;
    function recordAcquired(uint256 roundId, address stock, uint256 amount) external;
    function freezeSchedule(uint256 roundId) external returns (uint64 roundExpiresAt);

    function totalWeight(uint256 roundId, address stock) external view returns (uint256);
    function isFinalized(uint256 roundId) external view returns (bool);
}

// src/interfaces/IChipRounds.sol

/// @notice Round lifecycle states, shared so tooling and tests can read them.
enum RoundState {
    None,
    Accumulating,
    Buying,
    Finalized
}

/// @notice A round's budget and progress. The claim schedule lives in {ChipClaims}.
struct Round {
    RoundState state;
    uint64 openedAt;
    uint64 finalizedAt;
    uint128 budget; // quote-token budget taken from the Pot
    uint128 spent; // quote token actually deployed
    uint256 totalWeight; // sum of all per-stock weights in this round
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

// src/interfaces/IPot.sol

interface IPot {
    function quoteToken() external view returns (address);
    function available() external view returns (uint256);
    function pullBudget(uint256 amount) external returns (uint256);
    function noteReturned(uint256 amount) external;
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

// src/ChipRounds.sol

/// @title ChipRounds
/// @notice The engine. Every 24h it takes a budget from the Pot, works out how much each
///         activated Noun is owed, buys the stocks they chose, and hands the results to
///         {ChipClaims}.
///
/// @dev THE SPLIT. This contract SPENDS money; {ChipClaims} OWES it. Everything with
///      moving parts lives here — routers, Chainlink bounds, venue selection, weights,
///      splits, the POL holdback — and none of it can pay a holder. The engine's only
///      reach into the ledger is four calls that create entitlements and hand over assets.
///      There is no proxy and no delegatecall: two plain contracts, wired at deploy.
///
///      NO MASTERCHEF ACCUMULATOR, DELIBERATELY. An accumulator cannot express "this credit
///      expires 30 days after round 42", and we must iterate Nouns anyway because the
///      Clutch vault cannot enumerate activated tokens (ASSUMPTIONS A-10). Per-round weight
///      shares give exact expiry and exact sweeps with no second pass.
///
///      EVERYTHING IS PER-STOCK AND PERMISSIONLESS, SO FAILURES STAY ISOLATED. Buying is one
///      call per stock. A stock that is frozen, paused or policy-blocked by its issuer fails
///      only its own call; the others still buy. This is a structural consequence of the
///      shape, not a check anyone has to remember.
///
///      ROUNDS ARE FILLED PERMISSIONLESSLY. `contributeWeights` can be called by anyone for
///      anyone's Nouns, and a round cannot close until `accumulationWindow` has passed. That
///      combination stops a griefer opening a round, adding only their own Noun and closing
///      it: anybody left out can add themselves before the window ends.
contract ChipRounds is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;

    /// @notice Gas cap on calls into foreign contracts. See ASSUMPTIONS.md A-17.
    uint256 public constant PROBE_GAS = 100_000;

    /// @notice Hard ceiling on the POL holdback. Spec section 6 allows 0-25%.
    uint32 public constant MAX_HOLDBACK_BPS = 2_500;

    /// @notice Floor on {maxFeedAge} when it is switched on at all.
    /// @dev B20 equity feeds have NO heartbeat when equity markets are closed; they hold the
    ///      last close (ASSUMPTIONS A-14). An ordinary weekend is already about 65 hours from
    ///      Friday's close to Monday's open, and a holiday weekend runs past 110. A staleness
    ///      limit tighter than this would not catch a dead feed, it would skip every Monday
    ///      round on a healthy one — a liveness bug that would be very easy to miss, because
    ///      skipping is silent and safe. So the floor exists to stop a well-meaning
    ///      "tighten it up" from quietly switching the protocol off two days a week.
    uint64 public constant MIN_FEED_AGE = 72 hours;

    struct Split {
        bool set;
        uint8 count;
        address[3] stocks;
        uint8[3] pcts;
    }

    /* ----------------------------- wiring ----------------------------- */

    IStockRegistry public immutable registry;
    address public immutable quoteToken;
    IChipClaims public claims;
    IPot public pot;
    IActivationSource public activationSource;
    address public polTreasury;
    address public chipToken;
    address public chipBurnAddress;

    IUniswapV3SwapRouter public uniswapRouter;
    ISlipstreamSwapRouter public slipstreamRouter;

    /* --------------------------- tunables ----------------------------- */

    uint64 public roundDuration;
    uint64 public accumulationWindow;
    /// @notice Smallest pot that may open a round. The only size bound that remains.
    /// @dev THERE IS NO MAXIMUM. A round distributes whatever the Pot holds.
    ///
    ///      `maxRoundBudget` existed as a pre-audit blast radius: while the contracts were
    ///      unreviewed, a bug could only ever reach one capped round's worth of value. The
    ///      audit is complete and the cap is gone. A floor is a different thing and stays —
    ///      it stops a round firing on dust, where the per-stock slices round to zero and
    ///      the round spends gas to distribute nothing.
    ///
    ///      **What removing the cap does NOT change: what a single buy is allowed to fill.**
    ///      That bound is per stock, per buy, and lives in `_minOutFor` — a buy must clear
    ///      the Chainlink mark less `maxSlippageBps` or it does not execute at all. A larger
    ///      round makes each slice larger; it does not make a bad fill acceptable. See the
    ///      note on {settleStock} for how a slice too large for its pool behaves now.
    uint128 public minPotToOpen;
    uint256 public splitChangeFeeChip;
    uint32 public defaultMaxSlippageBps;

    /// @notice Skip a stock whose Chainlink feed has not updated in this long. 0 disables.
    /// @dev Not a price check — a skip, and the slice carries to the next round. See
    ///      {setMaxFeedAge}.
    uint64 public maxFeedAge;
    uint32 public holdbackBps;

    mapping(address collection => uint32 bps) public collectionBaseBps;
    mapping(address stock => uint32 bps) internal _maxSlippageBpsOverride;

    /// @notice Largest share of a stock's MEASURED POOL DEPTH one buy may spend, in bps.
    ///
    /// @dev THIS IS THE BOUND THAT SCALES. `maxSlippageBps` is a fixed percentage: it decides
    ///      whether a fill is acceptable, and its value does not move when the round gets
    ///      bigger. That is what made the old `maxRoundBudget` load-bearing for EXT-R-L-1 and
    ///      SEC-POT-002 — a sandwicher's take is bounded by the slippage tolerance and grows
    ///      linearly with the slice, so the cap was the only thing keeping the attack
    ///      uneconomic. Both findings named "dynamic slippage derived from measured pool
    ///      depth" as the precondition for lifting it. This is that.
    ///
    ///      A buy now spends at most `poolLiquidityUsd(stock) * maxImpactBps / BPS`, so the
    ///      exposure per buy is a function of the pool, not of the round. Doubling the round
    ///      does not double what an attacker can extract from any single stock; it spreads
    ///      the same bounded buys over more rounds.
    ///
    ///      WHY THE DEFAULT IS DELIBERATELY SMALL. For a constant-product pool holding equal
    ///      value each side, spending `k` bps of total TVL moves the price by roughly `2k`
    ///      bps, and moves SPOT by roughly `2k` bps afterwards. The default of 25 bps
    ///      therefore costs about 0.5% on the fill and leaves the pool about 0.5% richer than
    ///      the mark — inside the 2% `maxSlippageBps` tolerance with room to spare, which is
    ///      what makes the trimmed buy actually EXECUTE rather than trim and still revert.
    ///
    ///      That headroom is not decoration. A buy sized at the bound moves the pool AWAY
    ///      from the Chainlink mark, so the next round's buy starts from a worse price. At 50
    ///      bps two consecutive rounds against a thin pool push it past the tolerance and the
    ///      second one fails — measured, not theorised. Arbitrage restores the peg between
    ///      rounds in practice, but the default should not depend on that being prompt.
    ///
    ///      AND `poolLiquidityUsd` IS HEADLINE TVL, NOT TRADEABLE DEPTH. Uniswap v3 and
    ///      Slipstream are concentrated; the amount buyable near spot is a fraction of the
    ///      figure this reads. The bound is therefore conservative by construction, and it
    ///      should stay that way — see `StockRegistry.poolLiquidityUsd`.
    uint32 public defaultMaxImpactBps;

    mapping(address stock => uint32 bps) internal _maxImpactBpsOverride;

    /// @notice Hard ceiling on any impact bound. A compromised multisig cannot widen the
    ///         trim past the point where it stops bounding anything.
    uint32 public constant MAX_IMPACT_CEILING_BPS = 500;

    /// @notice Gas cap on the depth probe. Bounds a precompile that consumes everything.
    uint256 public constant DEPTH_PROBE_GAS = 120_000;

    /* ----------------------------- state ------------------------------ */

    uint256 public roundCount;
    uint64 public lastRoundOpenedAt;
    uint256 public totalPaidUsd;
    uint256 public committedQuote;

    mapping(uint256 roundId => Round) internal _rounds;
    mapping(uint256 roundId => address[]) internal _roundStocks;
    mapping(uint256 roundId => mapping(address stock => bool)) internal _roundHasStock;
    mapping(uint256 roundId => mapping(address stock => bool)) public stockSkipped;
    mapping(uint256 roundId => mapping(address stock => bool)) public stockSettled;
    mapping(uint256 roundId => mapping(address collection => mapping(uint256 tokenId => bool))) public counted;

    mapping(address collection => mapping(uint256 tokenId => Split)) internal _splits;

    /* ----------------------------- events ----------------------------- */

    event RoundOpened(uint256 indexed roundId, uint256 budget, address indexed opener);
    /// @notice A slice was larger than its stock's pool could absorb; `spent` was bought and
    ///         `slice - spent` returns to the Pot at finalize.
    event SliceTrimmed(uint256 indexed roundId, address indexed stock, uint256 slice, uint256 spent);
    event WeightsContributed(uint256 indexed roundId, address indexed collection, uint256 count, uint256 weightAdded);
    event AccumulationClosed(uint256 indexed roundId, uint256 totalWeight);
    event StockBought(uint256 indexed roundId, address indexed stock, uint256 spent, uint256 received);
    event HoldbackSent(uint256 indexed roundId, address indexed stock, uint256 amount);
    /// @dev The swap consumed input but delivered less than the Chainlink-derived floor.
    ///      A well-behaved router cannot do this; a misbehaving token can. Loud on purpose.
    event StockUnderdelivered(uint256 indexed roundId, address indexed stock, uint256 spent, uint256 received);
    /// @dev Stock was bought but the ledger could not receive it. It sits in the engine,
    ///      credited to nobody, recoverable by the multisig. Loud on purpose.
    event StockStranded(uint256 indexed roundId, address indexed stock, uint256 amount);
    /// @notice Stock reached the ledger but the ledger refused to book it. The tokens are at
    ///         `ChipClaims`, owed to nobody, and recoverable there via `recoverExcess`.
    event LedgerRefusedBooking(uint256 indexed roundId, address indexed stock, uint256 amount);
    /// @notice A stock's feed could not be read at finalize, so `amount` of it is missing from
    ///         this round's reported USD value. The credit itself is unaffected.
    event RoundValueUnpriced(uint256 indexed roundId, address indexed stock, uint256 amount);
    event StockSkipped(uint256 indexed roundId, address indexed stock, uint256 wouldHaveSpent, bytes reason);
    event RoundFinalized(uint256 indexed roundId, uint256 spent, uint256 returned, uint256 valueUsd);
    event SplitSet(address indexed collection, uint256 indexed tokenId, address[3] stocks, uint8[3] pcts, uint256 fee);
    event ExcessRecovered(address indexed token, address indexed to, uint256 amount);
    event ConfigUpdated(bytes32 indexed key, uint256 value);
    event AddressUpdated(bytes32 indexed key, address value);

    /* ----------------------------- errors ----------------------------- */

    error ZeroAddress();
    error TooSoon(uint64 nowTs, uint64 openableAt);
    error PotTooSmall(uint256 available, uint256 required);
    error WrongState(uint256 roundId, RoundState actual, RoundState expected);
    error AccumulationStillOpen(uint64 nowTs, uint64 closesAt);
    error NoWeight(uint256 roundId);
    error BadSplit();
    error StockNotEnabled(address stock);
    error NotNounOwner(address caller);
    error AlreadySettled(uint256 roundId, address stock);
    error NotSettled(uint256 roundId, address stock);
    error InsufficientExcess(address token, uint256 requested, uint256 available);
    error Insolvent(address token);
    error BadConfig();

    /// @param multisig  Owner.
    /// @param registry_ StockRegistry.
    /// @param pot_      Pot.
    /// @param source_   Activation source (the Clutch adapter).
    /// @param claims_   The claims ledger.
    /// @param splitChangeFeeChip_ Flat $CHIP burned to change an already-set split. The
    ///                  first split is always free. Spec value is 5,000 CHIP: cheap enough
    ///                  not to punish a genuine re-pick, dear enough that flipping weekly
    ///                  to chase the cheapest stock costs more than it gains.
    constructor(
        address multisig,
        address registry_,
        address pot_,
        address source_,
        address claims_,
        uint256 splitChangeFeeChip_
    ) Ownable(multisig) {
        if (
            multisig == address(0) || registry_ == address(0) || pot_ == address(0) || source_ == address(0)
                || claims_ == address(0)
        ) revert ZeroAddress();

        registry = IStockRegistry(registry_);
        quoteToken = IStockRegistry(registry_).quoteToken();
        pot = IPot(pot_);
        activationSource = IActivationSource(source_);
        claims = IChipClaims(claims_);

        roundDuration = 24 hours;
        accumulationWindow = 2 hours;
        defaultMaxSlippageBps = 200; // 2%
        defaultMaxImpactBps = 25; // 0.25% of measured pool depth per buy
        splitChangeFeeChip = splitChangeFeeChip_;
    }

    /* ------------------------------------------------------------------ */
    /*                            GOVERNANCE                                */
    /* ------------------------------------------------------------------ */

    function setClaims(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        claims = IChipClaims(v);
        emit AddressUpdated("claims", v);
    }

    function setPot(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        pot = IPot(v);
        emit AddressUpdated("pot", v);
    }

    function setActivationSource(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        activationSource = IActivationSource(v);
        emit AddressUpdated("activationSource", v);
    }

    function setPolTreasury(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        polTreasury = v;
        emit AddressUpdated("polTreasury", v);
    }

    function setChip(address token, address burnAddress) external onlyOwner {
        chipToken = token;
        chipBurnAddress = burnAddress;
        emit AddressUpdated("chipToken", token);
    }

    function setRouters(address uni, address slip) external onlyOwner {
        uniswapRouter = IUniswapV3SwapRouter(uni);
        slipstreamRouter = ISlipstreamSwapRouter(slip);
        emit AddressUpdated("uniswapRouter", uni);
        emit AddressUpdated("slipstreamRouter", slip);
    }

    function setCollectionBaseBps(address collection, uint32 bps) external onlyOwner {
        if (collection == address(0)) revert ZeroAddress();
        collectionBaseBps[collection] = bps;
        emit ConfigUpdated(bytes32(uint256(uint160(collection))), bps);
    }

    /// @notice Round timing and the minimum pot to open. There is no maximum.
    /// @dev The `maxBudget` argument was removed rather than accepted-and-ignored: a
    ///      parameter that silently does nothing is the failure mode this repo has already
    ///      been bitten by twice (the `setCustodian` trap, and the `callerMinOut` that
    ///      existed but was never passed). Callers of the old four-argument form will fail to
    ///      compile, which is the intended way to find them.
    function setRoundParams(uint64 duration, uint64 window, uint128 minPot) external onlyOwner {
        if (duration == 0 || window >= duration) revert BadConfig();
        roundDuration = duration;
        accumulationWindow = window;
        minPotToOpen = minPot;
        emit ConfigUpdated("roundDuration", duration);
        emit ConfigUpdated("minPotToOpen", minPot);
    }

    function setSplitChangeFeeChip(uint256 v) external onlyOwner {
        splitChangeFeeChip = v;
        emit ConfigUpdated("splitChangeFeeChip", v);
    }

    function setMaxSlippageBps(address stock, uint32 bps) external onlyOwner {
        if (bps >= BPS) revert BadConfig();
        _maxSlippageBpsOverride[stock] = bps;
        emit ConfigUpdated(bytes32(uint256(uint160(stock))), bps);
    }

    function setDefaultMaxSlippageBps(uint32 bps) external onlyOwner {
        if (bps >= BPS) revert BadConfig();
        defaultMaxSlippageBps = bps;
        emit ConfigUpdated("defaultMaxSlippageBps", bps);
    }

    /// @notice Per-stock impact bound. Zero clears the override back to the default.
    function setMaxImpactBps(address stock, uint32 bps) external onlyOwner {
        if (bps > MAX_IMPACT_CEILING_BPS) revert BadConfig();
        _maxImpactBpsOverride[stock] = bps;
        emit ConfigUpdated(bytes32(uint256(uint160(stock))), bps);
    }

    function setDefaultMaxImpactBps(uint32 bps) external onlyOwner {
        if (bps == 0 || bps > MAX_IMPACT_CEILING_BPS) revert BadConfig();
        defaultMaxImpactBps = bps;
        emit ConfigUpdated("defaultMaxImpactBps", bps);
    }

    /// @notice Skip any stock whose feed is older than `v` seconds, carrying its budget.
    ///         Zero switches the check off entirely.
    ///
    /// @dev THIS IS A LIVENESS SETTING, NOT A SAFETY ONE, AND IT CUTS BOTH WAYS.
    ///
    ///      The risk it addresses: a feed that has genuinely died still returns its last
    ///      answer forever, so a round would keep pricing purchases off a number nobody is
    ///      updating. The Chainlink bound would still be enforced — against a stale mark,
    ///      which is worse than useless if the real price has moved.
    ///
    ///      The risk it creates: these feeds legitimately look stale. They have no off-hours
    ///      heartbeat (ASSUMPTIONS A-14), so on a Monday morning every equity feed is ~65
    ///      hours old and after a holiday weekend past 110. Set this too tight and every
    ///      round of the working week's first day silently buys nothing.
    ///
    ///      Hence {MIN_FEED_AGE}, a 72-hour floor on any non-zero value, and a recommended
    ///      setting of 120 hours in DEPLOY.md. A skip is cheap — the slice carries to the
    ///      next round and nobody loses a cent — so erring generous costs almost nothing,
    ///      while erring tight costs a day of rounds a week.
    function setMaxFeedAge(uint64 v) external onlyOwner {
        if (v != 0 && v < MIN_FEED_AGE) revert BadConfig();
        maxFeedAge = v;
        emit ConfigUpdated("maxFeedAge", v);
    }

    /// @notice Share of each stock purchase held back for protocol-owned liquidity.
    function setHoldbackBps(uint32 bps) external onlyOwner {
        if (bps > MAX_HOLDBACK_BPS) revert BadConfig();
        holdbackBps = bps;
        emit ConfigUpdated("holdbackBps", bps);
    }

    /// @notice Effective slippage bound for a stock: its override, else the default.
    function maxSlippageBps(address stock) public view returns (uint32) {
        uint32 o = _maxSlippageBpsOverride[stock];
        return o == 0 ? defaultMaxSlippageBps : o;
    }

    /// @notice Effective impact bound for a stock: its override, else the default.
    function maxImpactBps(address stock) public view returns (uint32) {
        uint32 o = _maxImpactBpsOverride[stock];
        return o == 0 ? defaultMaxImpactBps : o;
    }

    /// @notice The most one buy of `stock` may spend right now, in quote units.
    /// @dev Exposed so a keeper can see why a round trimmed, and so the site can show a
    ///      stock's per-round ceiling. Returns 0 when depth cannot be read, which is the
    ///      same thing {settleStock} treats as "do not buy".
    function maxSpendFor(address stock) public view returns (uint256) {
        return _maxSpendFor(stock);
    }

    /* ------------------------------------------------------------------ */
    /*                              SPLITS                                  */
    /* ------------------------------------------------------------------ */

    function splitOf(address collection, uint256 tokenId) external view returns (Split memory) {
        return _splits[collection][tokenId];
    }

    /// @notice Choose up to three stocks and the whole-percent split between them.
    /// @dev Callable by the Noun's EFFECTIVE owner. The first set is free; every later change
    ///      burns a flat amount of $CHIP, which is what stops split-flipping right before a
    ///      round to chase whichever stock happens to be cheapest.
    ///
    ///      EFFECTIVE, NOT `ownerOf`, and that difference is the whole point of custody
    ///      support. A Noun locked as loan collateral keeps earning for the borrower, so the
    ///      borrower must also keep the ability to re-pick what it earns — a raw `ownerOf`
    ///      check would hand that right to the loan vault, which cannot use it. The
    ///      activation source resolves through a registered custodian to the beneficiary;
    ///      for a Noun in an ordinary wallet the two answers are identical.
    ///
    ///      This does put `setSplit` authorisation behind the multisig-set activation source.
    ///      That is not a new power: the same contract already decides whose weight counts in
    ///      every round, which is strictly more than deciding whose split may change, and it
    ///      still cannot move a token.
    function setSplit(address collection, uint256 tokenId, address[] calldata stocks, uint8[] calldata pcts)
        external
        nonReentrant
    {
        address effective = activationSource.effectiveOwner(collection, tokenId);
        if (effective == address(0) || effective != msg.sender) revert NotNounOwner(msg.sender);
        if (stocks.length == 0 || stocks.length > 3 || stocks.length != pcts.length) revert BadSplit();

        uint256 sum;
        address[3] memory s;
        uint8[3] memory p;
        for (uint256 i; i < stocks.length; ++i) {
            if (pcts[i] == 0) revert BadSplit();
            if (!registry.isEnabled(stocks[i])) revert StockNotEnabled(stocks[i]);
            for (uint256 j; j < i; ++j) {
                if (stocks[j] == stocks[i]) revert BadSplit();
            }
            s[i] = stocks[i];
            p[i] = pcts[i];
            sum += pcts[i];
        }
        if (sum != 100) revert BadSplit();

        Split storage existing = _splits[collection][tokenId];
        uint256 fee;
        if (existing.set && splitChangeFeeChip != 0 && chipToken != address(0)) {
            fee = splitChangeFeeChip;
            IERC20(chipToken).safeTransferFrom(msg.sender, chipBurnAddress, fee);
        }

        _splits[collection][tokenId] = Split({set: true, count: uint8(stocks.length), stocks: s, pcts: p});
        emit SplitSet(collection, tokenId, s, p, fee);
    }

    /* ------------------------------------------------------------------ */
    /*                              ROUNDS                                  */
    /* ------------------------------------------------------------------ */

    function getRound(uint256 roundId) external view returns (Round memory) {
        return _rounds[roundId];
    }

    function roundStocks(uint256 roundId) external view returns (address[] memory) {
        return _roundStocks[roundId];
    }

    /// @notice When a new round may be opened.
    function nextRoundOpensAt() public view returns (uint64) {
        return lastRoundOpenedAt == 0 ? uint64(block.timestamp) : lastRoundOpenedAt + roundDuration;
    }

    /// @notice Open the next 24h round. Permissionless: site button, keeper bot, anyone.
    function openRound() external nonReentrant returns (uint256 roundId) {
        uint64 openableAt = nextRoundOpensAt();
        if (block.timestamp < openableAt) revert TooSoon(uint64(block.timestamp), openableAt);

        uint256 availableInPot = pot.available();
        if (availableInPot < minPotToOpen) revert PotTooSmall(availableInPot, minPotToOpen);

        // The whole pot, whatever it is. `pullBudget` is what bounds this against what the
        // Pot can actually pay, and `uint128` is what bounds it against the Round struct.
        uint256 got = pot.pullBudget(availableInPot);
        if (got > type(uint128).max) revert BadConfig();

        roundId = ++roundCount;
        _rounds[roundId] = Round({
            state: RoundState.Accumulating,
            openedAt: uint64(block.timestamp),
            finalizedAt: 0,
            budget: uint128(got),
            spent: 0,
            totalWeight: 0
        });
        lastRoundOpenedAt = uint64(block.timestamp);
        committedQuote += got;

        emit RoundOpened(roundId, got, msg.sender);
    }

    /// @notice Add Nouns to the open round. Permissionless and batched.
    /// @dev Anyone may submit anyone's token ids; the contract verifies each one against the
    ///      activation source, so a padded or wrong list cannot inflate a share.
    function contributeWeights(uint256 roundId, address collection, uint256[] calldata tokenIds) external nonReentrant {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Accumulating) revert WrongState(roundId, r.state, RoundState.Accumulating);

        uint256 added;
        uint256 accepted;
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            if (counted[roundId][collection][tokenId]) continue;

            (bool active, uint32 tierBps, address owner) = activationSource.activation(collection, tokenId);
            if (!active || owner == address(0)) continue;

            uint256 weight = _weight(collection, tierBps);
            if (weight == 0) continue;

            counted[roundId][collection][tokenId] = true;
            added += _allocate(roundId, collection, tokenId, owner, weight);
            ++accepted;
        }
        r.totalWeight += added;
        emit WeightsContributed(roundId, collection, accepted, added);
    }

    /// @notice A Noun's weight: tier multiplier x collection base, in basis points.
    ///
    /// @dev THERE IS NO THIRD TERM, AND THERE USED TO BE.
    ///
    ///      A 1.10x "hoodie boost" — an external NFT collection whose holders scored extra —
    ///      was carried over from the pre-Clutch v0.1 spec and removed before launch. That
    ///      collection is not part of this project and is not on Base, so the term was
    ///      configuration pointing at nothing, priced into nobody's expectations, and
    ///      carrying a live sybil: the boost read ownership at contribution time while
    ///      `counted` tracked Nouns rather than boost tokens, so one NFT passed between
    ///      addresses inside the 2-hour accumulation window could boost unlimited Nouns.
    ///
    ///      Removed rather than fixed. See TRIAGE.md EXT-R-M-2.
    function _weight(address collection, uint32 tierBps) internal view returns (uint256) {
        uint256 base = collectionBaseBps[collection];
        if (base == 0) return 0;
        return (uint256(tierBps) * base) / BPS;
    }

    /// @dev Books a Noun's weight across its chosen stocks. A Noun with no split, or whose
    ///      chosen stock has since been disabled, routes that slice to the quote token,
    ///      exactly as the spec's "existing slices route to USDC until re-picked".
    function _allocate(uint256 roundId, address collection, uint256 tokenId, address owner, uint256 weight)
        internal
        returns (uint256 added)
    {
        Split storage sp = _splits[collection][tokenId];

        if (!sp.set) {
            _credit(roundId, quoteToken, owner, weight);
            return weight;
        }

        for (uint256 i; i < sp.count; ++i) {
            uint256 slice = (weight * sp.pcts[i]) / 100;
            if (slice == 0) continue;
            address stock = registry.isEnabled(sp.stocks[i]) ? sp.stocks[i] : quoteToken;
            _credit(roundId, stock, owner, slice);
            added += slice;
        }
    }

    function _credit(uint256 roundId, address stock, address owner, uint256 weight) internal {
        if (!_roundHasStock[roundId][stock]) {
            _roundHasStock[roundId][stock] = true;
            _roundStocks[roundId].push(stock);
        }
        claims.creditWeight(roundId, stock, owner, weight);
    }

    /// @notice Close contributions and move the round to buying. Permissionless, but only
    ///         after `accumulationWindow`, so nobody can close a round out from under the
    ///         Nouns that have not been submitted yet.
    function closeAccumulation(uint256 roundId) external nonReentrant {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Accumulating) revert WrongState(roundId, r.state, RoundState.Accumulating);
        uint64 closesAt = r.openedAt + accumulationWindow;
        if (block.timestamp < closesAt) revert AccumulationStillOpen(uint64(block.timestamp), closesAt);
        if (r.totalWeight == 0) revert NoWeight(roundId);

        r.state = RoundState.Buying;
        emit AccumulationClosed(roundId, r.totalWeight);
    }

    /// @notice Buy one stock for a round. Permissionless, one stock per call.
    /// @dev ONE CALL PER STOCK IS THE ISOLATION MECHANISM. A stock whose token is frozen,
    ///      paused or policy-blocked fails only this call; every other stock proceeds. The
    ///      failed stock is marked skipped and its slice carries back to the Pot at finalize.
    ///
    ///      A SLICE TOO LARGE FOR ITS POOL IS ALL-OR-NOTHING, AND THAT IS WORTH KNOWING
    ///      PRECISELY NOW THAT ROUNDS ARE UNCAPPED. `_buy` asks the router for the whole
    ///      slice with a Chainlink-derived `amountOutMinimum`. Against a pool too thin to
    ///      fill it at that price the swap reverts inside the router, `_buy` reports
    ///      `executed == false`, nothing moved, and the ENTIRE slice is marked skipped and
    ///      carried. It does not partially fill.
    ///
    ///      So the guarantees a large round has are: **the round never reverts**, **no funds
    ///      are lost**, and **the unfilled value returns to the Pot and is re-split by the
    ///      next round**. What it does NOT have is a partial fill — a thin stock in a big
    ///      round buys nothing rather than buying what it safely can. That is the safe
    ///      direction, and it is a real limitation: see OPEN_ITEMS 26.
    function settleStock(uint256 roundId, address stock) external nonReentrant {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Buying) revert WrongState(roundId, r.state, RoundState.Buying);
        if (stockSettled[roundId][stock]) revert AlreadySettled(roundId, stock);

        uint256 stockWeight = claims.totalWeight(roundId, stock);
        if (stockWeight == 0) revert NoWeight(roundId);

        stockSettled[roundId][stock] = true;
        uint256 slice = (uint256(r.budget) * stockWeight) / r.totalWeight;
        if (slice == 0) {
            stockSkipped[roundId][stock] = true;
            emit StockSkipped(roundId, stock, 0, "zero slice");
            return;
        }

        // The quote token needs no swap: hand it straight to the ledger.
        if (stock == quoteToken) {
            committedQuote -= slice;
            r.spent += uint128(slice);
            IERC20(quoteToken).safeTransfer(address(claims), slice);
            claims.recordAcquired(roundId, stock, slice);
            emit StockBought(roundId, stock, slice, slice);
            return;
        }

        // THE TRIM. Spend at most what this stock's pool can absorb inside its impact
        // bound; whatever is left of the slice is simply not spent, and `finalizeRound`
        // returns it to the Pot with the rest of the unspent budget. There is deliberately
        // NO per-stock earmark: the remainder re-enters the general Pot and is re-split by
        // the next round's weights. Earmarking would be new money-path storage for a
        // marginal gain, and holders who keep their splits get it back anyway.
        uint256 ceiling = _maxSpendFor(stock);
        if (ceiling == 0) {
            stockSkipped[roundId][stock] = true;
            emit StockSkipped(roundId, stock, slice, "no depth");
            return;
        }

        uint256 spend = slice > ceiling ? ceiling : slice;
        if (spend < slice) emit SliceTrimmed(roundId, stock, slice, spend);

        (bool executed, uint256 received, uint256 quoteSpent, bytes memory reason) = _buy(stock, spend);

        // Not executed means the swap reverted atomically: nothing left the contract, so the
        // slice is untouched and carries to the next round.
        if (!executed) {
            stockSkipped[roundId][stock] = true;
            emit StockSkipped(roundId, stock, spend, reason);
            return;
        }

        // Executed. Book what ACTUALLY moved in both directions, never the intent. A swap
        // that consumed the input but under-delivered is a real loss that has already
        // happened; recording it as a skip would leave the round claiming to hold quote
        // token it no longer has, and finalize would then be unable to return the balance.
        uint256 heldBack = _sendHoldback(stock, received);
        uint256 credited = received - heldBack;

        committedQuote -= quoteSpent;
        r.spent += uint128(quoteSpent);

        // Handing the stock to the ledger is its own failure point, and it must not take
        // the round down with it. A stock whose issuer has blocked the LEDGER (rather than
        // this engine) would otherwise revert settleStock and leave the round unfinishable
        // — the split would have created a new way to break isolation. Instead the transfer
        // is attempted, measured, and any shortfall is stranded here and reported. The
        // quote token was genuinely spent either way, so the budget records that honestly.
        uint256 delivered = _deliver(roundId, stock, credited);

        emit StockBought(roundId, stock, quoteSpent, delivered);
        if (heldBack != 0) emit HoldbackSent(roundId, stock, heldBack);
        if (received < _minOutFor(stock, quoteSpent)) {
            emit StockUnderdelivered(roundId, stock, quoteSpent, received);
        }
    }

    /// @dev Hands purchased stock to the ledger and books exactly what arrived. NEVER
    ///      REVERTS — and that promise has two halves, because the handover can fail in two
    ///      independent places.
    ///
    ///      1. THE TRANSFER FAILS. A ledger the stock's issuer has policy-blocked cannot
    ///         receive it. `ok` is false, nothing moved, the tokens stay in this contract and
    ///         are reported by {StockStranded}. Recoverable through this contract's
    ///         `recoverExcess`, which cannot reach committed budget.
    ///
    ///      2. THE TRANSFER SUCCEEDS AND THE LEDGER REFUSES TO BOOK IT. This is the one that
    ///         used to wedge the round, and it is subtler: `recordAcquired` verifies against
    ///         the LEDGER's own balance before believing us, so a stock that taxes transfers
    ///         makes the two disagree — this contract's balance falls by the full amount
    ///         while the ledger receives less — and the ledger reverts `Underfunded`. An
    ///         unprotected call meant that revert propagated: `settleStock` reverted, so the
    ///         stock could never be settled, `finalizeRound` requires every stock settled and
    ///         could never succeed, `cancelRound` is blocked by the `Buying` state, and
    ///         `committedQuote` stranded permanently. One misbehaving stock froze every
    ///         holder in the round. Found by external review (TRIAGE EXT-R-M-1); reproduced
    ///         by `test_aLedgerThatRefusesToBookDoesNotWedgeTheRound`.
    ///
    ///         Now caught. The tokens are at the LEDGER, unbooked, and reported by
    ///         {LedgerRefusedBooking} rather than by {StockStranded} — a different address
    ///         holds them, so a different event names them and a different rescue reaches
    ///         them. Because `totalOwed` never rose, they are *excess* by the ledger's own
    ///         definition, so `ChipClaims.recoverExcess` can take them and, by construction,
    ///         cannot touch a single booked credit on the way.
    ///
    ///      NO REDELIVERY, DELIBERATELY. It would have to re-enter `recordAcquired` after the
    ///      round finalized, which reverts `AlreadyFinalized` — and rightly, since the round's
    ///      shares are fixed at finalize and re-opening them is a far larger hole than the one
    ///      it would close. Recovery plus manual distribution is the honest path, and it is a
    ///      multisig action against tokens nobody is owed.
    function _deliver(uint256 roundId, address stock, uint256 amount) internal returns (uint256 delivered) {
        if (amount == 0) return 0;

        uint256 before = _balanceOf(stock, address(this));
        (bool ok,) = stock.call(abi.encodeCall(IERC20.transfer, (address(claims), amount)));

        uint256 sent;
        if (ok) {
            uint256 remaining = _balanceOf(stock, address(this));
            sent = before > remaining ? before - remaining : 0;
            if (sent > amount) sent = amount;
        }

        if (sent != 0) {
            try claims.recordAcquired(roundId, stock, sent) {
                delivered = sent;
            } catch {
                // The tokens left this contract and the ledger would not book them. Say so,
                // with the amount and where it is, and let the round finish.
                emit LedgerRefusedBooking(roundId, stock, sent);
            }
        }

        // Only what never left THIS contract is stranded here.
        if (sent < amount) emit StockStranded(roundId, stock, amount - sent);
    }

    /// @dev Moves the POL share of a purchase to the treasury and reports how much ACTUALLY
    ///      left, measured by balance delta rather than trusted from a return value. A token
    ///      that lies about transferring, or refuses because the treasury is policy-blocked,
    ///      simply results in a smaller (or zero) holdback and a larger credit to holders. It
    ///      can never make the round fail, and never causes stock to be credited that this
    ///      contract does not hold.
    function _sendHoldback(address stock, uint256 received) internal returns (uint256 moved) {
        uint32 bps = holdbackBps;
        address treasury = polTreasury;
        if (bps == 0 || treasury == address(0) || received == 0) return 0;

        uint256 target = (received * bps) / BPS;
        if (target == 0) return 0;

        uint256 before = _balanceOf(stock, address(this));
        (bool ok,) = stock.call(abi.encodeCall(IERC20.transfer, (treasury, target)));
        if (!ok) return 0;
        uint256 remaining = _balanceOf(stock, address(this));
        moved = before > remaining ? before - remaining : 0;
        if (moved > target) moved = target;
    }

    /// @notice Whether this stock's feed is currently too old to buy against.
    /// @dev Exposed so the keeper and the site can explain a skip before it happens rather
    ///      than after. Always false when the check is switched off.
    function isFeedStale(address stock) public view returns (bool) {
        uint64 maxAge = maxFeedAge;
        if (maxAge == 0) return false;
        try registry.priceUsd(stock) returns (uint256, uint256 updatedAt) {
            if (updatedAt == 0) return true;
            return block.timestamp > updatedAt + maxAge;
        } catch {
            // No readable price at all. Not this check's business: `_minOutFor` returns zero
            // and the buy is skipped as "no price", which is the more accurate reason.
            return false;
        }
    }

    /// @notice Chainlink-derived minimum acceptable output for spending `spendAmount`.
    /// @dev Returns 0 when the price is unavailable, so callers treat it as "no floor".
    function _minOutFor(address stock, uint256 spendAmount) internal view returns (uint256) {
        uint8 dec = registry.getStock(stock).tokenDecimals;
        uint256 price1e18;
        try registry.priceUsd(stock) returns (uint256 p, uint256) {
            price1e18 = p;
        } catch {
            return 0;
        }
        if (price1e18 == 0) return 0;
        uint256 spendUsd = (spendAmount * 1e18) / (10 ** registry.quoteDecimals());
        uint256 expectedOut = (spendUsd * (10 ** dec)) / price1e18;
        return (expectedOut * (BPS - maxSlippageBps(stock))) / BPS;
    }

    /// @dev The most one buy of `stock` may spend, in quote units, from its measured pool
    ///      depth and its impact bound.
    ///
    ///      FAILS CLOSED. `poolLiquidityUsd` reads the stock's balance in its pool, and a B20
    ///      stock is a node-native precompile (ASSUMPTIONS A-15/A-17) — a call that cannot be
    ///      answered must not be read as "unlimited". A gas-capped staticcall that fails, or
    ///      a pool with no measurable depth, both return zero, and {settleStock} treats zero
    ///      as "do not buy this stock at all this round".
    function _maxSpendFor(address stock) internal view returns (uint256) {
        (bool ok, bytes memory ret) =
            address(registry).staticcall{gas: DEPTH_PROBE_GAS}(abi.encodeCall(IStockRegistry.poolLiquidityUsd, (stock)));
        if (!ok || ret.length < 32) return 0;

        uint256 depthUsd = abi.decode(ret, (uint256)); // 18dp USD
        if (depthUsd == 0) return 0;

        // depth (18dp USD) x impact bps -> quote units.
        return (depthUsd * maxImpactBps(stock) * (10 ** registry.quoteDecimals())) / BPS / 1e18;
    }

    /// @dev Buys `stock` with up to `spendAmount` of quote token, bounded by the Chainlink
    ///      mark. Reports whether the swap EXECUTED, and how much actually moved in each
    ///      direction, measured by balance deltas rather than trusted from return values.
    ///      `executed == false` means the call reverted atomically and nothing moved.
    function _buy(address stock, uint256 spendAmount)
        internal
        returns (bool executed, uint256 received, uint256 quoteSpent, bytes memory why)
    {
        Stock memory s = registry.getStock(stock);
        if (!s.enabled) return (false, 0, 0, "stock disabled");

        // A frozen feed prices the buy off a number nobody is updating any more. Skip and
        // carry: the slice is untouched and goes to the next round. See {setMaxFeedAge}.
        if (isFeedStale(stock)) return (false, 0, 0, "stale feed");

        uint256 minOut = _minOutFor(stock, spendAmount);
        if (minOut == 0) return (false, 0, 0, "no price");

        address router = s.venue == Venue.UniswapV3
            ? address(uniswapRouter)
            : (s.venue == Venue.Slipstream ? address(slipstreamRouter) : address(0));
        if (router == address(0)) return (false, 0, 0, "no router");

        uint256 stockBefore = _balanceOf(stock, address(this));
        uint256 quoteBefore = _balanceOf(quoteToken, address(this));

        IERC20(quoteToken).forceApprove(router, spendAmount);

        bool ok;
        if (s.venue == Venue.UniswapV3) {
            try uniswapRouter.exactInputSingle(
                IUniswapV3SwapRouter.ExactInputSingleParams({
                    tokenIn: quoteToken,
                    tokenOut: stock,
                    fee: s.fee,
                    recipient: address(this),
                    amountIn: spendAmount,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            ) {
                ok = true;
            } catch (bytes memory err) {
                why = err.length == 0 ? bytes("swap failed") : err;
            }
        } else {
            try slipstreamRouter.exactInputSingle(
                ISlipstreamSwapRouter.ExactInputSingleParams({
                    tokenIn: quoteToken,
                    tokenOut: stock,
                    tickSpacing: s.tickSpacing,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: spendAmount,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            ) {
                ok = true;
            } catch (bytes memory err) {
                why = err.length == 0 ? bytes("swap failed") : err;
            }
        }

        IERC20(quoteToken).forceApprove(router, 0);

        uint256 quoteAfter = _balanceOf(quoteToken, address(this));
        quoteSpent = quoteBefore > quoteAfter ? quoteBefore - quoteAfter : 0;

        // A reverted swap must not have moved anything. If it somehow did, treat the round
        // as executed so the accounting still matches reality.
        if (!ok && quoteSpent == 0) return (false, 0, 0, why);

        received = _balanceOf(stock, address(this)) - stockBefore;
        return (true, received, quoteSpent, why);
    }

    /// @notice Finish a round: return everything unspent to the Pot and start the claim
    ///         clock in the ledger. Permissionless. Every stock with weight must be settled.
    function finalizeRound(uint256 roundId) external nonReentrant {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Buying) revert WrongState(roundId, r.state, RoundState.Buying);

        address[] memory stocks = _roundStocks[roundId];
        for (uint256 i; i < stocks.length; ++i) {
            if (!stockSettled[roundId][stocks[i]]) revert NotSettled(roundId, stocks[i]);
        }

        r.state = RoundState.Finalized;
        r.finalizedAt = uint64(block.timestamp);

        uint256 unspent = uint256(r.budget) - uint256(r.spent);
        if (unspent != 0) {
            committedQuote -= unspent;
            IERC20(quoteToken).safeTransfer(address(pot), unspent);
            pot.noteReturned(unspent);
        }

        // Freezes expiry and the window cadence for this round, in the ledger.
        claims.freezeSchedule(roundId);

        uint256 valueUsd = _roundValueUsd(roundId, stocks);
        totalPaidUsd += valueUsd;

        emit RoundFinalized(roundId, r.spent, unspent, valueUsd);
    }

    /// @notice Abandon a round that was opened but never closed, returning its whole budget
    ///         to the Pot. Permissionless, once a full round period has passed.
    /// @dev A round's budget is committed the moment it opens, and committed funds are
    ///      deliberately out of reach of {recoverExcess}. Without this an abandoned round
    ///      would strand its budget permanently. No credits exist yet in this state.
    function cancelRound(uint256 roundId) external nonReentrant {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Accumulating) revert WrongState(roundId, r.state, RoundState.Accumulating);
        uint64 abandonedAt = r.openedAt + roundDuration;
        if (block.timestamp < abandonedAt) revert AccumulationStillOpen(uint64(block.timestamp), abandonedAt);

        r.state = RoundState.Finalized;
        r.finalizedAt = uint64(block.timestamp);

        uint256 budget = r.budget;
        if (budget != 0) {
            committedQuote -= budget;
            IERC20(quoteToken).safeTransfer(address(pot), budget);
            pot.noteReturned(budget);
        }
        emit RoundFinalized(roundId, 0, budget, 0);
    }

    /// @dev Marks the round at Chainlink prices. Never reverts on a bad feed: a stock whose
    ///      feed is down contributes zero to the headline counter rather than blocking the
    ///      whole round from finalizing.
    /// @dev NOT `view`, so the unpriceable case can say so. A stock whose feed reverts at
    ///      finalize is simply omitted from the round's USD figure — the tokens are bought and
    ///      credited either way, and refusing to finalize over a reporting number would be
    ///      the wrong trade. But an omission that leaves no trace is a lie by rounding:
    ///      `totalPaidUsd` under-reports, and neither the site nor anyone reading the chain
    ///      can tell "this round paid less" from "this round could not be priced".
    ///
    ///      {RoundValueUnpriced} names each stock it happened to, so the site can show the
    ///      round as partially priced and re-derive it later from a working feed. Raised by
    ///      external review as I-1.
    function _roundValueUsd(uint256 roundId, address[] memory stocks) internal returns (uint256 valueUsd) {
        for (uint256 i; i < stocks.length; ++i) {
            address stock = stocks[i];
            uint256 amount = IChipClaimsView(address(claims)).acquired(roundId, stock);
            if (amount == 0) continue;
            if (stock == quoteToken) {
                valueUsd += (amount * 1e18) / (10 ** registry.quoteDecimals());
                continue;
            }
            try registry.priceUsd(stock) returns (uint256 price1e18, uint256) {
                uint8 dec = registry.getStock(stock).tokenDecimals;
                valueUsd += (amount * price1e18) / (10 ** dec);
            } catch {
                emit RoundValueUnpriced(roundId, stock, amount);
            }
        }
    }

    /* ------------------------------------------------------------------ */
    /*                              RESCUE                                  */
    /* ------------------------------------------------------------------ */

    /// @notice Token balance not backing a live round's committed budget.
    /// @dev The engine holds quote token only transiently. Committed budget belongs to a
    ///      round in flight and is deliberately out of reach, which is what stops a rescue
    ///      leaving a settlement unable to pay. Booked credits are not here at all: they
    ///      live in {ChipClaims}, behind its own rescue.
    function excess(address token) public view returns (uint256) {
        uint256 balance = _balanceOf(token, address(this));
        uint256 reserved = token == quoteToken ? committedQuote : 0;
        return balance > reserved ? balance - reserved : 0;
    }

    function recoverExcess(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 avail = excess(token);
        if (amount == 0 || amount > avail) revert InsufficientExcess(token, amount, avail);

        IERC20(token).safeTransfer(to, amount);

        uint256 mustKeep = token == quoteToken ? committedQuote : 0;
        if (_balanceOf(token, address(this)) < mustKeep) revert Insolvent(token);
        emit ExcessRecovered(token, to, amount);
    }

    /// @dev Gas-capped balance read. See ASSUMPTIONS.md A-17.
    function _balanceOf(address token, address who) internal view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall{gas: PROBE_GAS}(abi.encodeCall(IERC20.balanceOf, (who)));
        if (!ok || ret.length < 32) return 0;
        return abi.decode(ret, (uint256));
    }
}

/// @dev The one extra read the engine needs for its USD marks.
interface IChipClaimsView {
    function acquired(uint256 roundId, address stock) external view returns (uint256);
}
