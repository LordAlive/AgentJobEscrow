// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAgentJobEscrow} from "./interfaces/IAgentJobEscrow.sol";

/// @title AgentJobEscrow
/// @notice Escrows a client's payment (ETH or ERC-20) for a job performed by an agent wallet.
/// @dev Payouts are pushed when possible. A failed push (reverting receiver, blocklisted recipient, paused
///      token, ...) is credited to `pendingWithdrawals` instead of reverting, so no single recipient can block
///      a settlement. Fee-on-transfer tokens are rejected at deposit; rebasing tokens are unsupported.
contract AgentJobEscrow is IAgentJobEscrow, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant NATIVE_TOKEN = address(0);
    uint256 public constant BPS = 10_000;
    uint16 public constant MAX_FEE_BPS = 1_000;
    uint32 public constant DEFAULT_REVIEW_PERIOD = 3 days;
    uint32 public constant MIN_REVIEW_PERIOD = 1 hours;
    uint32 public constant MAX_REVIEW_PERIOD = 30 days;

    /// @dev Gas forwarded on ETH pushes. Covers Safe / ERC-4337 receive hooks while capping how much gas a
    ///      hostile receiver can burn. Receivers needing more are credited and can pull with full gas.
    uint256 public constant ETH_PUSH_GAS = 50_000;

    uint16 public feeBps;
    uint32 public reviewPeriod;
    address public feeRecipient;
    uint256 public nextJobId = 1;

    mapping(uint256 jobId => Job) private _jobs;
    mapping(address account => mapping(address token => uint256 amount)) public pendingWithdrawals;

    constructor(address initialOwner, address initialFeeRecipient, uint16 initialFeeBps) Ownable(initialOwner) {
        _setFeeRecipient(initialFeeRecipient);
        _setFeeBps(initialFeeBps);
        _setReviewPeriod(DEFAULT_REVIEW_PERIOD);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Admin. Changes only apply to jobs created afterwards.
    // ---------------------------------------------------------------------------------------------------------

    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        _setFeeBps(newFeeBps);
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        _setFeeRecipient(newRecipient);
    }

    function setReviewPeriod(uint32 newPeriod) external onlyOwner {
        _setReviewPeriod(newPeriod);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Job lifecycle
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Funds a new job; the caller becomes the client.
    /// @param token `NATIVE_TOKEN` to pay in ETH (send `amount` as value), otherwise a pre-approved ERC-20.
    /// @param deadline Last timestamp at which the provider may deliver.
    /// @param arbiter Dispute resolver, or address(0) to opt out of disputes.
    function createJob(address provider, address token, uint256 amount, uint64 deadline, address arbiter)
        external
        payable
        nonReentrant
        returns (uint256 jobId)
    {
        if (provider == address(0)) revert ZeroAddress();
        if (provider == address(this)) revert InvalidRecipient(provider);
        if (provider == msg.sender) revert InvalidProvider();
        if (arbiter != address(0) && (arbiter == msg.sender || arbiter == provider || arbiter == address(this))) {
            revert InvalidArbiter();
        }
        if (amount == 0) revert ZeroAmount();
        if (deadline <= block.timestamp) revert InvalidDeadline(deadline);

        uint16 jobFeeBps = feeBps;
        uint32 jobReviewPeriod = reviewPeriod;

        jobId = nextJobId++;
        Job storage job = _jobs[jobId];
        job.client = msg.sender;
        job.deadline = deadline;
        job.feeBps = jobFeeBps;
        job.state = State.Funded;
        job.provider = provider;
        job.token = token;
        job.reviewPeriod = jobReviewPeriod;
        job.arbiter = arbiter;
        job.amount = amount;

        if (token == NATIVE_TOKEN) {
            if (msg.value != amount) revert IncorrectEthAmount(amount, msg.value);
        } else {
            if (msg.value != 0) revert UnexpectedEth();
            uint256 balanceBefore = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
            if (received != amount) revert FeeOnTransferNotSupported(amount, received);
        }

        emit JobCreated(jobId, msg.sender, provider, token, amount, deadline, arbiter, jobFeeBps, jobReviewPeriod);
    }

    function submitDelivery(uint256 jobId, bytes32 deliveryHash) external nonReentrant {
        Job storage job = _getJob(jobId);
        if (msg.sender != job.provider) revert NotProvider(jobId, msg.sender);
        _requireState(jobId, job, State.Funded);
        if (block.timestamp > job.deadline) revert DeadlinePassed(jobId, job.deadline);
        if (deliveryHash == bytes32(0)) revert InvalidDeliveryHash();

        uint64 reviewEndsAt = uint64(block.timestamp) + job.reviewPeriod;
        job.state = State.Delivered;
        job.reviewEndsAt = reviewEndsAt;
        job.deliveryHash = deliveryHash;

        emit DeliverySubmitted(jobId, deliveryHash, reviewEndsAt);
    }

    function approve(uint256 jobId) external nonReentrant {
        Job storage job = _getJob(jobId);
        if (msg.sender != job.client) revert NotClient(jobId, msg.sender);
        _requireState(jobId, job, State.Delivered);

        _release(jobId, job, false);
    }

    function claimAfterReview(uint256 jobId) external nonReentrant {
        Job storage job = _getJob(jobId);
        if (msg.sender != job.provider) revert NotProvider(jobId, msg.sender);
        _requireState(jobId, job, State.Delivered);
        if (block.timestamp <= job.reviewEndsAt) revert ReviewWindowOpen(jobId, job.reviewEndsAt);

        _release(jobId, job, true);
    }

    function refund(uint256 jobId) external nonReentrant {
        Job storage job = _getJob(jobId);
        if (msg.sender != job.client) revert NotClient(jobId, msg.sender);
        _requireState(jobId, job, State.Funded);
        if (block.timestamp <= job.deadline) revert DeadlineNotPassed(jobId, job.deadline);

        job.state = State.Refunded;
        uint256 amount = job.amount;
        emit JobRefunded(jobId, amount);

        _payout(jobId, job.token, job.client, amount);
    }

    function dispute(uint256 jobId) external nonReentrant {
        Job storage job = _getJob(jobId);
        if (msg.sender != job.client && msg.sender != job.provider) revert NotParty(jobId, msg.sender);
        _requireState(jobId, job, State.Delivered);
        if (job.arbiter == address(0)) revert NoArbiter(jobId);
        if (block.timestamp > job.reviewEndsAt) revert ReviewWindowClosed(jobId, job.reviewEndsAt);

        job.state = State.Disputed;
        emit JobDisputed(jobId, msg.sender);
    }

    /// @param providerBps Share of the escrow awarded to the provider. The platform fee is taken from that
    ///        share only; the remainder is returned to the client.
    function resolve(uint256 jobId, uint16 providerBps) external nonReentrant {
        Job storage job = _getJob(jobId);
        if (msg.sender != job.arbiter) revert NotArbiter(jobId, msg.sender);
        _requireState(jobId, job, State.Disputed);

        (uint256 providerAmount, uint256 clientAmount, uint256 fee) = computeSplit(job.amount, providerBps, job.feeBps);

        job.state = State.Resolved;
        emit JobResolved(jobId, providerBps, providerAmount, clientAmount, fee);

        address token = job.token;
        _payout(jobId, token, job.provider, providerAmount);
        _payout(jobId, token, job.client, clientAmount);
        _payout(jobId, token, feeRecipient, fee);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Deferred payouts
    // ---------------------------------------------------------------------------------------------------------

    function withdraw(address token) external nonReentrant {
        _withdraw(token, msg.sender);
    }

    /// @notice Lets an account that cannot receive (non-payable contract, blocklisted address) redirect its
    ///         credit elsewhere.
    function withdrawTo(address token, address to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this)) revert InvalidRecipient(to);
        _withdraw(token, to);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------

    function getJob(uint256 jobId) external view returns (Job memory) {
        return _jobs[jobId];
    }

    /// @notice Splits `amount` between provider, client and platform. Rounds down in favour of the parties and
    ///         assigns remainders by subtraction, so the three outputs always sum to `amount`.
    function computeSplit(uint256 amount, uint256 providerBps, uint256 feeBps_)
        public
        pure
        returns (uint256 providerAmount, uint256 clientAmount, uint256 fee)
    {
        if (providerBps > BPS) revert InvalidBps(providerBps);
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh(feeBps_, MAX_FEE_BPS);

        uint256 providerGross = Math.mulDiv(amount, providerBps, BPS);
        fee = Math.mulDiv(providerGross, feeBps_, BPS);
        providerAmount = providerGross - fee;
        clientAmount = amount - providerGross;
    }

    // ---------------------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------------------

    function _release(uint256 jobId, Job storage job, bool claimedByProvider) private {
        (uint256 providerAmount,, uint256 fee) = computeSplit(job.amount, BPS, job.feeBps);

        job.state = State.Released;
        emit JobReleased(jobId, providerAmount, fee, claimedByProvider);

        address token = job.token;
        _payout(jobId, token, job.provider, providerAmount);
        _payout(jobId, token, feeRecipient, fee);
    }

    /// @dev Never reverts on a failed transfer; credits the recipient instead. Callers must finalise job state
    ///      before calling.
    function _payout(uint256 jobId, address token, address to, uint256 amount) private {
        if (amount == 0) return;

        bool success;
        if (token == NATIVE_TOKEN) {
            uint256 gasLimit = ETH_PUSH_GAS;
            // Return data is deliberately not copied to rule out return-bomb griefing.
            assembly ("memory-safe") {
                success := call(gasLimit, to, amount, 0, 0, 0, 0)
            }
        } else {
            success = IERC20(token).trySafeTransfer(to, amount);
        }

        if (!success) {
            pendingWithdrawals[to][token] += amount;
            emit PayoutDeferred(jobId, to, token, amount);
        }
    }

    function _withdraw(address token, address to) private {
        uint256 amount = pendingWithdrawals[msg.sender][token];
        if (amount == 0) revert NothingToWithdraw();

        pendingWithdrawals[msg.sender][token] = 0;
        emit Withdrawn(msg.sender, token, to, amount);

        if (token == NATIVE_TOKEN) {
            (bool success,) = to.call{value: amount}("");
            if (!success) revert EthTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    function _getJob(uint256 jobId) private view returns (Job storage job) {
        job = _jobs[jobId];
        if (job.state == State.None) revert JobNotFound(jobId);
    }

    function _requireState(uint256 jobId, Job storage job, State expected) private view {
        if (job.state != expected) revert InvalidState(jobId, job.state);
    }

    function _setFeeBps(uint16 newFeeBps) private {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh(newFeeBps, MAX_FEE_BPS);
        emit FeeBpsUpdated(feeBps, newFeeBps);
        feeBps = newFeeBps;
    }

    function _setFeeRecipient(address newRecipient) private {
        if (newRecipient == address(0)) revert ZeroAddress();
        if (newRecipient == address(this)) revert InvalidRecipient(newRecipient);
        emit FeeRecipientUpdated(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    function _setReviewPeriod(uint32 newPeriod) private {
        if (newPeriod < MIN_REVIEW_PERIOD || newPeriod > MAX_REVIEW_PERIOD) revert InvalidReviewPeriod(newPeriod);
        emit ReviewPeriodUpdated(reviewPeriod, newPeriod);
        reviewPeriod = newPeriod;
    }
}
