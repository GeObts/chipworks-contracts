// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IActivationCustodian} from "../interfaces/IActivationCustodian.sol";
import {IActivationSource} from "../interfaces/IActivationSource.sol";

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

    /// @notice Terms offered: 30 / 90 / 180 days by default, all configurable.
    uint256 public constant TERM_COUNT = 3;

    /// @notice How long after maturity a borrower may still repay.
    uint64 public constant GRACE_PERIOD = 7 days;

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
        uint8 termIndex;
        bool closed;
        bool liquidated;
    }

    struct Terms {
        uint64[TERM_COUNT] length;
        uint32[TERM_COUNT] feeBps;
        uint32 bountyBps;
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
        uint64 dueAt = uint64(block.timestamp) + _terms.length[termIndex];

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
    ///      The window closes at maturity plus the grace period. After that the loan is
    ///      liquidatable and repayment is no longer accepted, even if nobody has liquidated
    ///      it yet — the deadline is the deadline, and leaving it open would make the grace
    ///      period unbounded in practice.
    function repay(uint256 loanId) external nonReentrant {
        Loan storage l = _loanAt(loanId);
        if (l.closed) revert LoanClosed(loanId);

        uint64 deadline = l.dueAt + GRACE_PERIOD;
        if (block.timestamp > deadline) revert RepayWindowOver(loanId, deadline);

        uint256 principal = l.principal;
        address borrower = l.borrower;
        address collection = l.collection;
        uint256 tokenId = l.tokenId;

        // ---- effects ----
        l.closed = true;
        delete _openLoanOf[collection][tokenId];
        poolBalance += principal;
        totalRepaid += principal;
        openLoanCount -= 1;

        // ---- interactions ----
        // Measured, so a $CHIP that reports a transfer it did not make cannot free a Noun.
        uint256 before = chipToken.balanceOf(address(this));
        chipToken.safeTransferFrom(msg.sender, address(this), principal);
        uint256 delivered = chipToken.balanceOf(address(this)) - before;
        if (delivered < principal) revert ChipShortfall(delivered, principal);

        IERC721(collection).transferFrom(address(this), borrower, tokenId);

        emit LoanRepaid(loanId, borrower, msg.sender, principal, uint64(block.timestamp));
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

        uint64 liquidatableAt = l.dueAt + GRACE_PERIOD;
        if (block.timestamp <= liquidatableAt) revert NotYetLiquidatable(loanId, liquidatableAt);

        address borrower = l.borrower;
        address collection = l.collection;
        uint256 tokenId = l.tokenId;
        address to = treasury;

        bounty = (l.principal * _terms.bountyBps) / BPS;
        if (bounty > poolBalance) bounty = poolBalance;

        // ---- effects ----
        l.closed = true;
        l.liquidated = true;
        delete _openLoanOf[collection][tokenId];
        poolBalance -= bounty;
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

    /// @notice What a loan would look like, before taking it.
    function quote(uint8 termIndex, uint256 principal)
        external
        view
        returns (uint256 fee, uint256 payout, uint64 dueAt)
    {
        if (termIndex >= TERM_COUNT) revert BadTerm(termIndex);
        fee = (principal * _terms.feeBps[termIndex]) / BPS;
        payout = principal - fee;
        dueAt = uint64(block.timestamp) + _terms.length[termIndex];
    }

    function terms() external view returns (Terms memory) {
        return _terms;
    }

    function pendingTerms() external view returns (PendingTerms memory) {
        return _pendingTerms;
    }

    function isLiquidatable(uint256 loanId) external view returns (bool) {
        Loan storage l = _loanAt(loanId);
        return !l.closed && block.timestamp > l.dueAt + GRACE_PERIOD;
    }

    /// @notice When this loan stops being repayable and starts being liquidatable.
    function deadlineOf(uint256 loanId) external view returns (uint64) {
        return _loanAt(loanId).dueAt + GRACE_PERIOD;
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
            uint256 reserved = poolBalance;
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
