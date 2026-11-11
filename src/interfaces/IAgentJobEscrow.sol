// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAgentJobEscrow {
    enum State {
        None,
        Funded,
        Delivered,
        Released,
        Refunded,
        Disputed,
        Resolved
    }

    /// @dev Packed into 6 slots. `feeBps` and `reviewPeriod` are snapshotted at creation so later admin
    ///      changes never alter the terms of a funded job.
    struct Job {
        address client;
        uint64 deadline; // inclusive: delivery accepted while block.timestamp <= deadline
        uint16 feeBps;
        State state;
        address provider;
        uint64 reviewEndsAt; // inclusive, zero until delivered
        address token; // address(0) for native ETH
        uint32 reviewPeriod;
        address arbiter; // address(0) means the job cannot be disputed
        uint256 amount;
        bytes32 deliveryHash;
    }

    event JobCreated(
        uint256 indexed jobId,
        address indexed client,
        address indexed provider,
        address token,
        uint256 amount,
        uint64 deadline,
        address arbiter,
        uint16 feeBps,
        uint32 reviewPeriod
    );
    event DeliverySubmitted(uint256 indexed jobId, bytes32 deliveryHash, uint64 reviewEndsAt);
    event JobReleased(uint256 indexed jobId, uint256 providerAmount, uint256 fee, bool claimedByProvider);
    event JobRefunded(uint256 indexed jobId, uint256 amount);
    event JobDisputed(uint256 indexed jobId, address indexed disputedBy);
    event JobResolved(
        uint256 indexed jobId, uint16 providerBps, uint256 providerAmount, uint256 clientAmount, uint256 fee
    );
    event PayoutDeferred(uint256 indexed jobId, address indexed account, address indexed token, uint256 amount);
    event Withdrawn(address indexed account, address indexed token, address to, uint256 amount);
    event FeeBpsUpdated(uint16 oldFeeBps, uint16 newFeeBps);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);
    event ReviewPeriodUpdated(uint32 oldPeriod, uint32 newPeriod);

    error ZeroAddress();
    error ZeroAmount();
    error InvalidRecipient(address account);
    error FeeTooHigh(uint256 feeBps, uint256 maxFeeBps);
    error InvalidReviewPeriod(uint256 period);
    error InvalidDeadline(uint256 deadline);
    error InvalidProvider();
    error InvalidArbiter();
    error InvalidDeliveryHash();
    error InvalidBps(uint256 bps);
    error IncorrectEthAmount(uint256 expected, uint256 received);
    error UnexpectedEth();
    error FeeOnTransferNotSupported(uint256 expected, uint256 received);
    error JobNotFound(uint256 jobId);
    error InvalidState(uint256 jobId, State current);
    error NotClient(uint256 jobId, address caller);
    error NotProvider(uint256 jobId, address caller);
    error NotParty(uint256 jobId, address caller);
    error NotArbiter(uint256 jobId, address caller);
    error NoArbiter(uint256 jobId);
    error DeadlinePassed(uint256 jobId, uint256 deadline);
    error DeadlineNotPassed(uint256 jobId, uint256 deadline);
    error ReviewWindowOpen(uint256 jobId, uint256 reviewEndsAt);
    error ReviewWindowClosed(uint256 jobId, uint256 reviewEndsAt);
    error NothingToWithdraw();
    error EthTransferFailed();

    function createJob(address provider, address token, uint256 amount, uint64 deadline, address arbiter)
        external
        payable
        returns (uint256 jobId);
    function submitDelivery(uint256 jobId, bytes32 deliveryHash) external;
    function approve(uint256 jobId) external;
    function claimAfterReview(uint256 jobId) external;
    function refund(uint256 jobId) external;
    function dispute(uint256 jobId) external;
    function resolve(uint256 jobId, uint16 providerBps) external;
    function withdraw(address token) external;
    function withdrawTo(address token, address to) external;

    function getJob(uint256 jobId) external view returns (Job memory);
    function pendingWithdrawals(address account, address token) external view returns (uint256);
    function computeSplit(uint256 amount, uint256 providerBps, uint256 feeBps_)
        external
        pure
        returns (uint256 providerAmount, uint256 clientAmount, uint256 fee);
}
