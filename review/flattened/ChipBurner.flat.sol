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

// src/ChipBurner.sol

/// @title ChipBurner
/// @notice Owns the $CHIP token so that burning it is a REAL burn, and owns nothing else that
///         anyone can take.
///
/// @dev WHY THIS CONTRACT EXISTS. Bankr's Doppler $CHIP has no public `burn` — only an
///      owner-gated one. Until now every "burn" in this protocol was a transfer to `0xdead`:
///      unreachable, but still counted in `totalSupply`, so every aggregator overstated
///      circulating supply and the gap grew with every activation. Making this contract the
///      token's owner turns that into a true burn — `totalSupply` falls, on chain, everywhere.
///
///      THE TRAP THIS AVOIDS, WHICH IS THE WHOLE DESIGN. `transferOwnership` moves **every**
///      `onlyOwner` power, not just `burn`: `updateTokenURI`, `updateMintRate`,
///      `lockPool`/`unlockPool`, `mintInflation`, and `transferOwnership` itself. A burn-only
///      sink would therefore be a one-way door — the token's metadata could never be updated
///      again and ownership could never be moved, forever, by anyone. So this is an owner
///      **wrapper**, not a sink: burning is permissionless, and the remaining owner powers we
///      must keep pass through to the multisig.
///
///      TWO ROLES, AND THE ASYMMETRY IS THE POINT.
///        - **Anyone** may call {burnAll}. Burning is the one thing that should never need
///          permission, and it can only ever destroy this contract's own balance.
///        - **`adminOwner`** — the multisig — may call the pass-throughs. Those touch the
///          token's other admin surface. They cannot move a single $CHIP.
///
///      $CHIP IS STRUCTURALLY BURN-ONLY HERE. There is no `transfer`, no `sweep`, no rescue
///      for $CHIP, and no generic `call` to smuggle one through. The only instruction this
///      contract can give about its own $CHIP balance is "destroy it". A token that arrives
///      here is gone; the only question is when somebody calls {burnAll}.
///
///      **`mintInflation` IS DELIBERATELY NOT EXPOSED.** A permissionless burner that can also
///      mint is a contradiction, and "gated behind the multisig with an event" still means the
///      capability exists and has to be trusted. It is not here. If inflation is ever genuinely
///      needed, {transferTokenOwnership} is the escape hatch: move the token to a new wrapper
///      that implements it, deliberately and visibly. That is the reason the ownership
///      pass-through exists at all, and it is why leaving it out would have been the mistake.
contract ChipBurner is Ownable2Step {
    /// @notice The token this contract owns and burns.
    IERC20 public immutable chipToken;

    /// @notice Running total of $CHIP destroyed by this contract, in wei.
    /// @dev Measured by the fall in `totalSupply`, never by the amount requested — a token
    ///      that under-burns or lies would otherwise inflate the figure the site publishes.
    uint256 public totalBurned;

    /// @notice How many times {burnAll} has actually destroyed something.
    uint256 public burnCount;

    event Burned(address indexed caller, uint256 amount, uint256 supplyBefore, uint256 supplyAfter);
    event TokenUriUpdated(string uri);
    event TokenOwnershipTransferred(address indexed to);

    error NothingToBurn();
    error BurnDidNotReduceSupply(uint256 before, uint256 nowSupply);
    error PassThroughFailed(bytes reason);
    error ZeroAddress();

    /// @param multisig The `adminOwner`: may use the pass-throughs, may never move $CHIP.
    /// @param chipToken_ $CHIP. Immutable — the token this wrapper owns is not a setting.
    constructor(address multisig, address chipToken_) Ownable(multisig) {
        if (multisig == address(0) || chipToken_ == address(0)) revert ZeroAddress();
        chipToken = IERC20(chipToken_);
    }

    /* ------------------------------------------------------------------ */
    /*                        THE BURN, PERMISSIONLESS                      */
    /* ------------------------------------------------------------------ */

    /// @notice Destroy every $CHIP this contract holds. Anyone may call it.
    ///
    /// @dev Permissionless on purpose. The app's burn paths transfer $CHIP here and then this
    ///      is triggered — atomically in the same transaction, or in a batch by a keeper — and
    ///      neither should depend on a privileged caller being awake. There is no argument to
    ///      get wrong and no way to direct the outcome: it burns the whole balance, to nowhere.
    ///
    ///      VERIFIED BY THE SUPPLY, NOT BY THE RETURN VALUE. `totalSupply` is read before and
    ///      after, and the call reverts unless it actually fell. That is what makes
    ///      {totalBurned} a number the site can publish: it counts what left existence, not
    ///      what we asked to leave. A token that silently no-ops its own burn cannot quietly
    ///      turn this contract into the `0xdead` address with extra steps.
    /// @return burned How much $CHIP ceased to exist.
    function burnAll() external returns (uint256 burned) {
        uint256 balance = chipToken.balanceOf(address(this));
        if (balance == 0) revert NothingToBurn();

        uint256 supplyBefore = chipToken.totalSupply();
        IChipOwnable(address(chipToken)).burn(balance);
        uint256 supplyAfter = chipToken.totalSupply();

        if (supplyAfter >= supplyBefore) revert BurnDidNotReduceSupply(supplyBefore, supplyAfter);

        burned = supplyBefore - supplyAfter;
        totalBurned += burned;
        ++burnCount;

        emit Burned(msg.sender, burned, supplyBefore, supplyAfter);
    }

    /// @notice $CHIP sitting here waiting to be destroyed.
    function pending() external view returns (uint256) {
        return chipToken.balanceOf(address(this));
    }

    /* ------------------------------------------------------------------ */
    /*                  PASS-THROUGHS, MULTISIG ONLY                        */
    /* ------------------------------------------------------------------ */

    /// @notice Update the token's metadata URI. Multisig only.
    /// @dev One of the powers `transferOwnership` swept up. Without this pass-through the
    ///      token's metadata would be frozen forever the moment this contract took ownership.
    function updateTokenUri(string calldata uri) external onlyOwner {
        _passThrough(abi.encodeWithSignature("updateTokenURI(string)", uri));
        emit TokenUriUpdated(uri);
    }

    /// @notice Hand the TOKEN's ownership to somebody else. Multisig only.
    ///
    /// @dev THE ESCAPE HATCH, AND THE REASON IT IS SAFE TO OMIT EVERYTHING ELSE. Any owner
    ///      power this wrapper does not expose — `mintInflation`, `updateMintRate`,
    ///      `lockPool` — is not lost, only made deliberate: move the token's ownership to a
    ///      contract that does expose it, in a transaction anybody can see.
    ///
    ///      It is also the thing that stops this contract being a permanent trap. Note it
    ///      transfers ownership of the TOKEN, not of this contract; this contract's own
    ///      `adminOwner` moves through `Ownable2Step` as usual.
    function transferTokenOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        _passThrough(abi.encodeWithSignature("transferOwnership(address)", newOwner));
        emit TokenOwnershipTransferred(newOwner);
    }

    /// @dev Calls the token and bubbles its revert reason rather than swallowing it.
    ///
    ///      Deliberately NOT a generic `execute(bytes)`. The whole value of this contract is
    ///      that its authority over $CHIP is enumerable from its own source: burn, and two
    ///      named admin calls. A generic call would make that unknowable, and would put
    ///      `mintInflation` back within reach of whoever holds the multisig.
    function _passThrough(bytes memory data) internal {
        (bool ok, bytes memory ret) = address(chipToken).call(data);
        if (!ok) revert PassThroughFailed(ret);
    }
}

/// @notice The owner-gated surface of Bankr's Doppler $CHIP that this wrapper uses.
/// @dev VERIFY THESE SIGNATURES AGAINST THE DEPLOYED TOKEN BEFORE HANDING IT OVER. They are
///      encoded by string here, so a mismatch is a one-line fix — but it is also a mismatch
///      that would not be discovered until the first burn, which is far too late. LAUNCH_CONFIG
///      carries the check.
interface IChipOwnable {
    function burn(uint256 amount) external;
    function updateTokenURI(string calldata uri) external;
    function transferOwnership(address newOwner) external;
}
