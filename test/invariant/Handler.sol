// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentJobEscrow} from "../../src/AgentJobEscrow.sol";
import {IAgentJobEscrow} from "../../src/interfaces/IAgentJobEscrow.sol";
import {MockERC20, ToggleReceiver} from "../mocks/Mocks.sol";

/// @dev Some clients/providers and the fee recipient are wallets that can be toggled to reject ETH, so the
///      deferred-payout path is exercised alongside the happy path.
contract Handler is Test {
    AgentJobEscrow public immutable escrow;
    MockERC20 public immutable token;
    address public immutable owner;
    address public immutable arbiter;

    address[] internal _clients;
    address[] internal _providers;
    address[] internal _accounts;
    ToggleReceiver[] internal _wallets;
    address[2] internal _tokens;

    uint256[] public jobIds;

    constructor(AgentJobEscrow escrow_, MockERC20 token_, address owner_, address arbiter_, address feeRecipient_) {
        escrow = escrow_;
        token = token_;
        owner = owner_;
        arbiter = arbiter_;
        _tokens = [address(0), address(token_)];

        ToggleReceiver walletClient = new ToggleReceiver(true);
        ToggleReceiver walletProvider = new ToggleReceiver(true);
        _wallets.push(walletClient);
        _wallets.push(walletProvider);
        _wallets.push(ToggleReceiver(payable(feeRecipient_)));

        _clients.push(makeAddr("client1"));
        _clients.push(makeAddr("client2"));
        _clients.push(address(walletClient));
        _providers.push(makeAddr("provider1"));
        _providers.push(makeAddr("provider2"));
        _providers.push(address(walletProvider));

        for (uint256 i; i < _clients.length; i++) {
            _accounts.push(_clients[i]);
            _accounts.push(_providers[i]);
        }
        _accounts.push(feeRecipient_);
    }

    function createJob(uint256 clientSeed, uint256 providerSeed, uint256 amount, bool useEth, bool withArbiter)
        external
    {
        address client = _clients[clientSeed % _clients.length];
        address provider = _providers[providerSeed % _providers.length];
        amount = bound(amount, 1, 100 ether);
        address tkn = useEth ? address(0) : address(token);
        uint64 deadline = uint64(block.timestamp + bound(amount, 1 hours, 14 days));

        vm.startPrank(client);
        uint256 jobId;
        if (useEth) {
            vm.deal(client, client.balance + amount);
            jobId = escrow.createJob{value: amount}(provider, tkn, amount, deadline, withArbiter ? arbiter : address(0));
        } else {
            token.mint(client, amount);
            token.approve(address(escrow), amount);
            jobId = escrow.createJob(provider, tkn, amount, deadline, withArbiter ? arbiter : address(0));
        }
        vm.stopPrank();
        jobIds.push(jobId);
    }

    function submitDelivery(uint256 jobSeed, bytes32 hash) external {
        (uint256 jobId, IAgentJobEscrow.Job memory job) = _pick(jobSeed, IAgentJobEscrow.State.Funded);
        if (hash == bytes32(0)) hash = keccak256("work");
        vm.prank(job.provider);
        escrow.submitDelivery(jobId, hash);
    }

    function approve(uint256 jobSeed) external {
        (uint256 jobId, IAgentJobEscrow.Job memory job) = _pick(jobSeed, IAgentJobEscrow.State.Delivered);
        vm.prank(job.client);
        escrow.approve(jobId);
    }

    function claimAfterReview(uint256 jobSeed) external {
        (uint256 jobId, IAgentJobEscrow.Job memory job) = _pick(jobSeed, IAgentJobEscrow.State.Delivered);
        if (job.state == IAgentJobEscrow.State.Delivered && block.timestamp <= job.reviewEndsAt) {
            vm.warp(uint256(job.reviewEndsAt) + 1);
        }
        vm.prank(job.provider);
        escrow.claimAfterReview(jobId);
    }

    function refund(uint256 jobSeed) external {
        (uint256 jobId, IAgentJobEscrow.Job memory job) = _pick(jobSeed, IAgentJobEscrow.State.Funded);
        if (job.state == IAgentJobEscrow.State.Funded && block.timestamp <= job.deadline) {
            vm.warp(uint256(job.deadline) + 1);
        }
        vm.prank(job.client);
        escrow.refund(jobId);
    }

    function dispute(uint256 jobSeed, bool byClient) external {
        (uint256 jobId, IAgentJobEscrow.Job memory job) = _pick(jobSeed, IAgentJobEscrow.State.Delivered);
        vm.prank(byClient ? job.client : job.provider);
        escrow.dispute(jobId);
    }

    function resolve(uint256 jobSeed, uint16 providerBps) external {
        (uint256 jobId,) = _pick(jobSeed, IAgentJobEscrow.State.Disputed);
        providerBps = uint16(bound(providerBps, 0, 10_000));
        vm.prank(arbiter);
        escrow.resolve(jobId, providerBps);
    }

    /// @dev Prefers an account that actually has a credit, otherwise the call is almost always a no-op revert.
    function withdraw(uint256 accountSeed, bool useEth) external {
        address tkn = useEth ? address(0) : address(token);
        address account = _accounts[accountSeed % _accounts.length];
        for (uint256 i; i < _accounts.length; i++) {
            address candidate = _accounts[(accountSeed + i) % _accounts.length];
            if (escrow.pendingWithdrawals(candidate, tkn) > 0) {
                account = candidate;
                break;
            }
        }
        vm.prank(account);
        escrow.withdraw(tkn);
    }

    function toggleWallet(uint256 walletSeed, bool accept) external {
        _wallets[walletSeed % _wallets.length].setAcceptEth(accept);
    }

    function setFeeBps(uint16 bps) external {
        vm.prank(owner);
        escrow.setFeeBps(uint16(bound(bps, 0, 1_000)));
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 5 days));
    }

    /// @notice Open job amounts plus uncollected credits for `tkn`.
    function totalOwed(address tkn) external view returns (uint256 owed) {
        for (uint256 i; i < jobIds.length; i++) {
            IAgentJobEscrow.Job memory job = escrow.getJob(jobIds[i]);
            if (job.token != tkn) continue;
            if (
                job.state == IAgentJobEscrow.State.Funded || job.state == IAgentJobEscrow.State.Delivered
                    || job.state == IAgentJobEscrow.State.Disputed
            ) owed += job.amount;
        }
        for (uint256 i; i < _accounts.length; i++) {
            owed += escrow.pendingWithdrawals(_accounts[i], tkn);
        }
    }

    function jobCount() external view returns (uint256) {
        return jobIds.length;
    }

    function tokens() external view returns (address[2] memory) {
        return _tokens;
    }

    /// @dev Biased towards jobs in `preferred` state; one call in ten uses an arbitrary job so wrong-state
    ///      calls are exercised too.
    function _pick(uint256 seed, IAgentJobEscrow.State preferred)
        internal
        view
        returns (uint256 jobId, IAgentJobEscrow.Job memory job)
    {
        uint256 n = jobIds.length;
        require(n > 0, "no jobs");
        jobId = jobIds[seed % n];
        if (seed % 10 == 0) return (jobId, escrow.getJob(jobId));
        for (uint256 i; i < n; i++) {
            uint256 candidate = jobIds[(seed + i) % n];
            if (escrow.getJob(candidate).state == preferred) {
                jobId = candidate;
                break;
            }
        }
        job = escrow.getJob(jobId);
    }
}
