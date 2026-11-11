// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AgentJobEscrow} from "../src/AgentJobEscrow.sol";
import {IAgentJobEscrow} from "../src/interfaces/IAgentJobEscrow.sol";
import {BaseTest} from "./BaseTest.sol";
import {
    MockBlocklistERC20,
    MockFeeOnTransferERC20,
    MockNoReturnERC20,
    ToggleReceiver,
    GasBurner,
    ReentrantProvider
} from "./mocks/Mocks.sol";

contract AgentJobEscrowTest is BaseTest {
    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_SetsConfig() public view {
        assertEq(escrow.owner(), owner);
        assertEq(escrow.feeRecipient(), feeRecipient);
        assertEq(escrow.feeBps(), FEE_BPS);
        assertEq(escrow.reviewPeriod(), 3 days);
        assertEq(escrow.nextJobId(), 1);
    }

    function test_RevertWhen_ConstructorConfigInvalid() public {
        vm.expectRevert(IAgentJobEscrow.ZeroAddress.selector);
        new AgentJobEscrow(owner, address(0), FEE_BPS);

        vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.FeeTooHigh.selector, 1001, 1000));
        new AgentJobEscrow(owner, feeRecipient, 1001);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new AgentJobEscrow(address(0), feeRecipient, FEE_BPS);
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/

    function test_SetFeeBps() public {
        vm.expectEmit(address(escrow));
        emit IAgentJobEscrow.FeeBpsUpdated(FEE_BPS, 1000);
        vm.prank(owner);
        escrow.setFeeBps(1000);
        assertEq(escrow.feeBps(), 1000);
    }

    function test_RevertWhen_FeeBpsAboveCap() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.FeeTooHigh.selector, 1001, 1000));
        escrow.setFeeBps(1001);
    }

    function test_SetFeeRecipient() public {
        address newRecipient = makeAddr("newRecipient");
        vm.expectEmit(address(escrow));
        emit IAgentJobEscrow.FeeRecipientUpdated(feeRecipient, newRecipient);
        vm.prank(owner);
        escrow.setFeeRecipient(newRecipient);
        assertEq(escrow.feeRecipient(), newRecipient);
    }

    function test_RevertWhen_FeeRecipientInvalid() public {
        vm.startPrank(owner);
        vm.expectRevert(IAgentJobEscrow.ZeroAddress.selector);
        escrow.setFeeRecipient(address(0));

        vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.InvalidRecipient.selector, address(escrow)));
        escrow.setFeeRecipient(address(escrow));
        vm.stopPrank();
    }

    function test_SetReviewPeriod() public {
        vm.expectEmit(address(escrow));
        emit IAgentJobEscrow.ReviewPeriodUpdated(3 days, 1 days);
        vm.prank(owner);
        escrow.setReviewPeriod(1 days);
        assertEq(escrow.reviewPeriod(), 1 days);
    }

    function test_RevertWhen_ReviewPeriodOutOfBounds() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.InvalidReviewPeriod.selector, 59 minutes));
        escrow.setReviewPeriod(59 minutes);
        vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.InvalidReviewPeriod.selector, 31 days));
        escrow.setReviewPeriod(31 days);
        vm.stopPrank();
    }

    function test_RevertWhen_AdminCalledByNonOwner() public {
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger);
        vm.startPrank(stranger);
        vm.expectRevert(err);
        escrow.setFeeBps(100);
        vm.expectRevert(err);
        escrow.setFeeRecipient(stranger);
        vm.expectRevert(err);
        escrow.setReviewPeriod(1 days);
        vm.stopPrank();
    }

    function test_OwnershipTransferIsTwoStep() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        escrow.transferOwnership(newOwner);
        assertEq(escrow.owner(), owner);

        vm.prank(newOwner);
        escrow.acceptOwnership();
        assertEq(escrow.owner(), newOwner);
    }

    function test_AdminChangesDoNotAffectExistingJobs() public {
        uint256 jobId = _createEthJob(address(0));
        vm.startPrank(owner);
        escrow.setFeeBps(1000);
        escrow.setReviewPeriod(1 hours);
        vm.stopPrank();

        IAgentJobEscrow.Job memory job = escrow.getJob(jobId);
        assertEq(job.feeBps, FEE_BPS);
        assertEq(job.reviewPeriod, 3 days);

        _deliver(jobId);
        assertEq(escrow.getJob(jobId).reviewEndsAt, block.timestamp + 3 days);

        vm.prank(client);
        escrow.approve(jobId);
        assertEq(feeRecipient.balance, _fee(AMOUNT));
    }

    /*//////////////////////////////////////////////////////////////
                               CREATE JOB
    //////////////////////////////////////////////////////////////*/

    function test_CreateJob_Eth() public {
        uint64 deadline = _deadline();
        vm.expectEmit(address(escrow));
        emit IAgentJobEscrow.JobCreated(1, client, provider, ETH, AMOUNT, deadline, arbiter, FEE_BPS, 3 days);
        vm.prank(client);
        uint256 jobId = escrow.createJob{value: AMOUNT}(provider, ETH, AMOUNT, deadline, arbiter);

        assertEq(jobId, 1);
        assertEq(escrow.nextJobId(), 2);
        assertEq(address(escrow).balance, AMOUNT);

        IAgentJobEscrow.Job memory job = escrow.getJob(jobId);
        assertEq(job.client, client);
        assertEq(job.provider, provider);
        assertEq(job.token, ETH);
        assertEq(job.amount, AMOUNT);
        assertEq(job.deadline, deadline);
        assertEq(job.arbiter, arbiter);
        assertEq(job.feeBps, FEE_BPS);
        assertEq(job.reviewPeriod, 3 days);
        assertEq(job.reviewEndsAt, 0);
        assertEq(job.deliveryHash, bytes32(0));
        _assertState(jobId, IAgentJobEscrow.State.Funded);
    }

    function test_CreateJob_Erc20() public {
        uint256 balanceBefore = usdc.balanceOf(client);
        uint256 jobId = _createJob(false, address(0));

        assertEq(usdc.balanceOf(address(escrow)), AMOUNT);
        assertEq(balanceBefore - usdc.balanceOf(client), AMOUNT);
        assertEq(escrow.getJob(jobId).token, address(usdc));
    }

    function test_CreateJob_IdsAreSequential() public {
        assertEq(_createEthJob(address(0)), 1);
        assertEq(_createJob(false, address(0)), 2);
        assertEq(_createEthJob(arbiter), 3);
    }

    function test_FullFlow_TokenWithoutReturnValue() public {
        MockNoReturnERC20 token = new MockNoReturnERC20();
        token.mint(client, AMOUNT);
        vm.startPrank(client);
        token.approve(address(escrow), AMOUNT);
        uint256 jobId = escrow.createJob(provider, address(token), AMOUNT, _deadline(), address(0));
        vm.stopPrank();
        assertEq(token.balanceOf(address(escrow)), AMOUNT);

        _deliver(jobId);
        vm.prank(client);
        escrow.approve(jobId);

        assertEq(token.balanceOf(provider), AMOUNT - _fee(AMOUNT));
        assertEq(token.balanceOf(feeRecipient), _fee(AMOUNT));
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_RevertWhen_TokenTakesFeeOnTransfer() public {
        MockFeeOnTransferERC20 token = new MockFeeOnTransferERC20();
        token.mint(client, AMOUNT);
        vm.startPrank(client);
        token.approve(address(escrow), AMOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentJobEscrow.FeeOnTransferNotSupported.selector, AMOUNT, AMOUNT - AMOUNT / 100)
        );
        escrow.createJob(provider, address(token), AMOUNT, _deadline(), address(0));
        vm.stopPrank();
    }

    function test_RevertWhen_TokenHasNoCode() public {
        address notAToken = makeAddr("notAToken");
        vm.prank(client);
        vm.expectRevert();
        escrow.createJob(provider, notAToken, AMOUNT, _deadline(), address(0));
    }

    function test_RevertWhen_TokenAllowanceMissing() public {
        usdc.mint(stranger, AMOUNT);
        vm.prank(stranger);
        vm.expectRevert();
        escrow.createJob(provider, address(usdc), AMOUNT, _deadline(), address(0));
    }

    function test_RevertWhen_CreateJobParamsInvalid() public {
        uint64 deadline = _deadline();
        vm.startPrank(client);

        vm.expectRevert(IAgentJobEscrow.ZeroAddress.selector);
        escrow.createJob{value: AMOUNT}(address(0), ETH, AMOUNT, deadline, arbiter);

        vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.InvalidRecipient.selector, address(escrow)));
        escrow.createJob{value: AMOUNT}(address(escrow), ETH, AMOUNT, deadline, arbiter);

        vm.expectRevert(IAgentJobEscrow.InvalidProvider.selector);
        escrow.createJob{value: AMOUNT}(client, ETH, AMOUNT, deadline, arbiter);

        vm.expectRevert(IAgentJobEscrow.InvalidArbiter.selector);
        escrow.createJob{value: AMOUNT}(provider, ETH, AMOUNT, deadline, client);

        vm.expectRevert(IAgentJobEscrow.InvalidArbiter.selector);
        escrow.createJob{value: AMOUNT}(provider, ETH, AMOUNT, deadline, provider);

        vm.expectRevert(IAgentJobEscrow.InvalidArbiter.selector);
        escrow.createJob{value: AMOUNT}(provider, ETH, AMOUNT, deadline, address(escrow));

        vm.expectRevert(IAgentJobEscrow.ZeroAmount.selector);
        escrow.createJob(provider, ETH, 0, deadline, arbiter);

        vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.InvalidDeadline.selector, block.timestamp));
        escrow.createJob{value: AMOUNT}(provider, ETH, AMOUNT, uint64(block.timestamp), arbiter);

        vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.IncorrectEthAmount.selector, AMOUNT, AMOUNT - 1));
        escrow.createJob{value: AMOUNT - 1}(provider, ETH, AMOUNT, deadline, arbiter);

        vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.IncorrectEthAmount.selector, AMOUNT, AMOUNT + 1));
        escrow.createJob{value: AMOUNT + 1}(provider, ETH, AMOUNT, deadline, arbiter);

        vm.expectRevert(IAgentJobEscrow.UnexpectedEth.selector);
        escrow.createJob{value: 1}(provider, address(usdc), AMOUNT, deadline, arbiter);

        vm.stopPrank();
    }

    function test_RevertWhen_EthSentDirectly() public {
        vm.prank(client);
        (bool ok,) = address(escrow).call{value: 1}("");
        assertFalse(ok);
    }

    /*//////////////////////////////////////////////////////////////
                            SUBMIT DELIVERY
    //////////////////////////////////////////////////////////////*/

    function test_SubmitDelivery() public {
        uint256 jobId = _createEthJob(arbiter);
        vm.expectEmit(address(escrow));
        emit IAgentJobEscrow.DeliverySubmitted(jobId, DELIVERY, uint64(block.timestamp + 3 days));
        _deliver(jobId);

        IAgentJobEscrow.Job memory job = escrow.getJob(jobId);
        assertEq(job.deliveryHash, DELIVERY);
        assertEq(job.reviewEndsAt, block.timestamp + 3 days);
        _assertState(jobId, IAgentJobEscrow.State.Delivered);
    }

    function test_SubmitDelivery_AtDeadline() public {
        uint256 jobId = _createEthJob(arbiter);
        vm.warp(escrow.getJob(jobId).deadline);
        _deliver(jobId);
        _assertState(jobId, IAgentJobEscrow.State.Delivered);
    }

    function test_RevertWhen_SubmitDeliveryInvalid() public {
        uint256 jobId = _createEthJob(arbiter);

        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.JobNotFound.selector, 999));
        escrow.submitDelivery(999, DELIVERY);

        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.NotProvider.selector, jobId, client));
        escrow.submitDelivery(jobId, DELIVERY);

        vm.prank(provider);
        vm.expectRevert(IAgentJobEscrow.InvalidDeliveryHash.selector);
        escrow.submitDelivery(jobId, bytes32(0));
    }

    function test_RevertWhen_SubmitDeliveryAfterDeadline() public {
        uint256 jobId = _createEthJob(arbiter);
        uint64 deadline = escrow.getJob(jobId).deadline;
        vm.warp(uint256(deadline) + 1);

        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.DeadlinePassed.selector, jobId, deadline));
        escrow.submitDelivery(jobId, DELIVERY);
    }

    function test_RevertWhen_SubmitDeliveryTwice() public {
        uint256 jobId = _createEthJob(arbiter);
        _deliver(jobId);

        vm.prank(provider);
        vm.expectRevert(_invalidState(jobId, IAgentJobEscrow.State.Delivered));
        escrow.submitDelivery(jobId, keccak256("other"));
    }

    /*//////////////////////////////////////////////////////////////
                                APPROVE
    //////////////////////////////////////////////////////////////*/

    function test_Approve_Eth() public {
        _checkApprove(true);
    }

    function test_Approve_Erc20() public {
        _checkApprove(false);
    }

    function _checkApprove(bool useEth) private {
        uint256 jobId = _createJob(useEth, arbiter);
        _deliver(jobId);

        vm.expectEmit(address(escrow));
        emit IAgentJobEscrow.JobReleased(jobId, AMOUNT - _fee(AMOUNT), _fee(AMOUNT), false);
        vm.prank(client);
        escrow.approve(jobId);

        assertEq(_balance(useEth, provider), AMOUNT - _fee(AMOUNT));
        assertEq(_balance(useEth, feeRecipient), _fee(AMOUNT));
        assertEq(_balance(useEth, address(escrow)), 0);
        _assertState(jobId, IAgentJobEscrow.State.Released);
    }

    function test_Approve_AfterReviewWindow() public {
        uint256 jobId = _createEthJob(address(0));
        _deliver(jobId);
        vm.warp(block.timestamp + 10 days);

        vm.prank(client);
        escrow.approve(jobId);
        _assertState(jobId, IAgentJobEscrow.State.Released);
    }

    function test_Approve_ZeroFee() public {
        vm.prank(owner);
        escrow.setFeeBps(0);
        uint256 jobId = _createEthJob(address(0));
        _deliver(jobId);

        vm.prank(client);
        escrow.approve(jobId);
        assertEq(provider.balance, AMOUNT);
        assertEq(feeRecipient.balance, 0);
    }

    function test_RevertWhen_ApproveInvalid() public {
        uint256 jobId = _createEthJob(arbiter);

        vm.prank(client);
        vm.expectRevert(_invalidState(jobId, IAgentJobEscrow.State.Funded));
        escrow.approve(jobId);

        _deliver(jobId);

        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.NotClient.selector, jobId, provider));
        escrow.approve(jobId);

        vm.prank(client);
        escrow.approve(jobId);

        vm.prank(client);
        vm.expectRevert(_invalidState(jobId, IAgentJobEscrow.State.Released));
        escrow.approve(jobId);
    }

    /*//////////////////////////////////////////////////////////////
                           CLAIM AFTER REVIEW
    //////////////////////////////////////////////////////////////*/

    function test_ClaimAfterReview_Eth() public {
        _checkClaim(true);
    }

    function test_ClaimAfterReview_Erc20() public {
        _checkClaim(false);
    }

    function _checkClaim(bool useEth) private {
        uint256 jobId = _createJob(useEth, arbiter);
        _deliver(jobId);
        vm.warp(uint256(escrow.getJob(jobId).reviewEndsAt) + 1);

        vm.expectEmit(address(escrow));
        emit IAgentJobEscrow.JobReleased(jobId, AMOUNT - _fee(AMOUNT), _fee(AMOUNT), true);
        vm.prank(provider);
        escrow.claimAfterReview(jobId);

        assertEq(_balance(useEth, provider), AMOUNT - _fee(AMOUNT));
        assertEq(_balance(useEth, feeRecipient), _fee(AMOUNT));
        assertEq(_balance(useEth, address(escrow)), 0);
        _assertState(jobId, IAgentJobEscrow.State.Released);
    }

    function test_RevertWhen_ClaimAfterReviewInvalid() public {
        uint256 jobId = _createEthJob(arbiter);

        vm.prank(provider);
        vm.expectRevert(_invalidState(jobId, IAgentJobEscrow.State.Funded));
        escrow.claimAfterReview(jobId);

        _deliver(jobId);
        uint64 reviewEndsAt = escrow.getJob(jobId).reviewEndsAt;

        vm.warp(reviewEndsAt);
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.ReviewWindowOpen.selector, jobId, reviewEndsAt));
        escrow.claimAfterReview(jobId);

        vm.warp(uint256(reviewEndsAt) + 1);
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.NotProvider.selector, jobId, client));
        escrow.claimAfterReview(jobId);

        vm.prank(provider);
        escrow.claimAfterReview(jobId);

        vm.prank(provider);
        vm.expectRevert(_invalidState(jobId, IAgentJobEscrow.State.Released));
        escrow.claimAfterReview(jobId);
    }

    /*//////////////////////////////////////////////////////////////
                                 REFUND
    //////////////////////////////////////////////////////////////*/

    function test_Refund_Eth() public {
        _checkRefund(true);
    }

    function test_Refund_Erc20() public {
        _checkRefund(false);
    }

    function _checkRefund(bool useEth) private {
        uint256 clientBefore = _balance(useEth, client);
        uint256 jobId = _createJob(useEth, arbiter);
        vm.warp(uint256(escrow.getJob(jobId).deadline) + 1);

        vm.expectEmit(address(escrow));
        emit IAgentJobEscrow.JobRefunded(jobId, AMOUNT);
        vm.prank(client);
        escrow.refund(jobId);

        assertEq(_balance(useEth, client), clientBefore);
        assertEq(_balance(useEth, feeRecipient), 0);
        assertEq(_balance(useEth, address(escrow)), 0);
        _assertState(jobId, IAgentJobEscrow.State.Refunded);
    }

    function test_RevertWhen_RefundInvalid() public {
        uint256 jobId = _createEthJob(arbiter);
        uint64 deadline = escrow.getJob(jobId).deadline;

        vm.warp(deadline);
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.DeadlineNotPassed.selector, jobId, deadline));
        escrow.refund(jobId);

        vm.warp(uint256(deadline) + 1);
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.NotClient.selector, jobId, provider));
        escrow.refund(jobId);

        vm.prank(client);
        escrow.refund(jobId);

        vm.prank(client);
        vm.expectRevert(_invalidState(jobId, IAgentJobEscrow.State.Refunded));
        escrow.refund(jobId);
    }

    function test_RevertWhen_RefundAfterDelivery() public {
        uint256 jobId = _createEthJob(arbiter);
        _deliver(jobId);
        vm.warp(uint256(escrow.getJob(jobId).deadline) + 1);

        vm.prank(client);
        vm.expectRevert(_invalidState(jobId, IAgentJobEscrow.State.Delivered));
        escrow.refund(jobId);
    }

    /*//////////////////////////////////////////////////////////////
                                DISPUTE
    //////////////////////////////////////////////////////////////*/

    function test_Dispute_ByClient() public {
        uint256 jobId = _createEthJob(arbiter);
        _deliver(jobId);

        vm.expectEmit(address(escrow));
        emit IAgentJobEscrow.JobDisputed(jobId, client);
        vm.prank(client);
        escrow.dispute(jobId);
        _assertState(jobId, IAgentJobEscrow.State.Disputed);
    }

    function test_Dispute_ByProviderAtWindowEnd() public {
        uint256 jobId = _createEthJob(arbiter);
        _deliver(jobId);
        vm.warp(escrow.getJob(jobId).reviewEndsAt);

        vm.prank(provider);
        escrow.dispute(jobId);
        _assertState(jobId, IAgentJobEscrow.State.Disputed);
    }

    function test_Dispute_FreezesJob() public {
        uint256 jobId = _createEthJob(arbiter);
        _deliverAndDispute(jobId);
        bytes memory err = _invalidState(jobId, IAgentJobEscrow.State.Disputed);

        vm.prank(client);
        vm.expectRevert(err);
        escrow.approve(jobId);

        vm.warp(block.timestamp + 30 days);
        vm.prank(provider);
        vm.expectRevert(err);
        escrow.claimAfterReview(jobId);

        vm.prank(client);
        vm.expectRevert(err);
        escrow.refund(jobId);

        vm.prank(provider);
        vm.expectRevert(err);
        escrow.dispute(jobId);
    }

    function test_RevertWhen_DisputeWithoutArbiter() public {
        uint256 jobId = _createEthJob(address(0));
        _deliver(jobId);

        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.NoArbiter.selector, jobId));
        escrow.dispute(jobId);
    }

    function test_RevertWhen_DisputeInvalid() public {
        uint256 jobId = _createEthJob(arbiter);

        vm.prank(client);
        vm.expectRevert(_invalidState(jobId, IAgentJobEscrow.State.Funded));
        escrow.dispute(jobId);

        _deliver(jobId);

        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.NotParty.selector, jobId, arbiter));
        escrow.dispute(jobId);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.NotParty.selector, jobId, stranger));
        escrow.dispute(jobId);

        uint64 reviewEndsAt = escrow.getJob(jobId).reviewEndsAt;
        vm.warp(uint256(reviewEndsAt) + 1);
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.ReviewWindowClosed.selector, jobId, reviewEndsAt));
        escrow.dispute(jobId);
    }

    /*//////////////////////////////////////////////////////////////
                                RESOLVE
    //////////////////////////////////////////////////////////////*/

    function test_Resolve_Split_Eth() public {
        _checkResolve(true, 6_000);
    }

    function test_Resolve_Split_Erc20() public {
        _checkResolve(false, 6_000);
    }

    function test_Resolve_AllToProvider() public {
        _checkResolve(true, 10_000);
    }

    function test_Resolve_AllToClient() public {
        _checkResolve(false, 0);
    }

    function _checkResolve(bool useEth, uint16 providerBps) private {
        uint256 clientStart = _balance(useEth, client);
        uint256 jobId = _createJob(useEth, arbiter);
        _deliverAndDispute(jobId);

        uint256 providerGross = AMOUNT * providerBps / 10_000;
        uint256 fee = _fee(providerGross);

        vm.expectEmit(address(escrow));
        emit IAgentJobEscrow.JobResolved(jobId, providerBps, providerGross - fee, AMOUNT - providerGross, fee);
        vm.prank(arbiter);
        escrow.resolve(jobId, providerBps);

        assertEq(_balance(useEth, provider), providerGross - fee);
        assertEq(_balance(useEth, feeRecipient), fee);
        assertEq(clientStart - _balance(useEth, client), providerGross);
        assertEq(_balance(useEth, address(escrow)), 0);
        _assertState(jobId, IAgentJobEscrow.State.Resolved);
    }

    function test_RevertWhen_ResolveInvalid() public {
        uint256 jobId = _createEthJob(arbiter);
        _deliver(jobId);

        vm.prank(arbiter);
        vm.expectRevert(_invalidState(jobId, IAgentJobEscrow.State.Delivered));
        escrow.resolve(jobId, 5_000);

        vm.prank(client);
        escrow.dispute(jobId);

        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.NotArbiter.selector, jobId, client));
        escrow.resolve(jobId, 5_000);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.NotArbiter.selector, jobId, owner));
        escrow.resolve(jobId, 5_000);

        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.InvalidBps.selector, 10_001));
        escrow.resolve(jobId, 10_001);

        vm.prank(arbiter);
        escrow.resolve(jobId, 5_000);

        vm.prank(arbiter);
        vm.expectRevert(_invalidState(jobId, IAgentJobEscrow.State.Resolved));
        escrow.resolve(jobId, 5_000);
    }

    function test_RevertWhen_ArbiterOfAnotherJob() public {
        address otherArbiter = makeAddr("otherArbiter");
        uint256 jobId = _createEthJob(arbiter);
        _createEthJob(otherArbiter);
        _deliverAndDispute(jobId);

        vm.prank(otherArbiter);
        vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.NotArbiter.selector, jobId, otherArbiter));
        escrow.resolve(jobId, 10_000);
    }

    /*//////////////////////////////////////////////////////////////
                       FAILED PAYOUTS AND WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function test_ProviderRejectingEth_IsCreditedAndWithdrawsLater() public {
        ToggleReceiver wallet = new ToggleReceiver(false);
        vm.prank(client);
        uint256 jobId = escrow.createJob{value: AMOUNT}(address(wallet), ETH, AMOUNT, _deadline(), address(0));
        wallet.exec(address(escrow), 0, abi.encodeCall(IAgentJobEscrow.submitDelivery, (jobId, DELIVERY)));

        uint256 net = AMOUNT - _fee(AMOUNT);
        vm.expectEmit(address(escrow));
        emit IAgentJobEscrow.PayoutDeferred(jobId, address(wallet), ETH, net);
        vm.prank(client);
        escrow.approve(jobId);

        assertEq(escrow.pendingWithdrawals(address(wallet), ETH), net);
        assertEq(feeRecipient.balance, _fee(AMOUNT));
        assertEq(address(escrow).balance, net);

        // A withdraw that fails keeps the credit intact.
        vm.expectRevert(IAgentJobEscrow.EthTransferFailed.selector);
        wallet.exec(address(escrow), 0, abi.encodeCall(IAgentJobEscrow.withdraw, (ETH)));
        assertEq(escrow.pendingWithdrawals(address(wallet), ETH), net);

        wallet.setAcceptEth(true);
        vm.expectEmit(address(escrow));
        emit IAgentJobEscrow.Withdrawn(address(wallet), ETH, address(wallet), net);
        wallet.exec(address(escrow), 0, abi.encodeCall(IAgentJobEscrow.withdraw, (ETH)));

        assertEq(address(wallet).balance, net);
        assertEq(escrow.pendingWithdrawals(address(wallet), ETH), 0);
        assertEq(address(escrow).balance, 0);

        vm.expectRevert(IAgentJobEscrow.NothingToWithdraw.selector);
        wallet.exec(address(escrow), 0, abi.encodeCall(IAgentJobEscrow.withdraw, (ETH)));
    }

    function test_ClientRejectingEth_WithdrawsToOtherAddress() public {
        ToggleReceiver wallet = new ToggleReceiver(false);
        vm.deal(address(wallet), AMOUNT);
        bytes memory create =
            abi.encodeCall(IAgentJobEscrow.createJob, (provider, ETH, AMOUNT, _deadline(), address(0)));
        uint256 jobId = abi.decode(wallet.exec(address(escrow), AMOUNT, create), (uint256));

        vm.warp(uint256(escrow.getJob(jobId).deadline) + 1);
        wallet.exec(address(escrow), 0, abi.encodeCall(IAgentJobEscrow.refund, (jobId)));
        assertEq(escrow.pendingWithdrawals(address(wallet), ETH), AMOUNT);

        address treasury = makeAddr("treasury");
        wallet.exec(address(escrow), 0, abi.encodeCall(IAgentJobEscrow.withdrawTo, (ETH, treasury)));
        assertEq(treasury.balance, AMOUNT);
        assertEq(escrow.pendingWithdrawals(address(wallet), ETH), 0);
        assertEq(address(escrow).balance, 0);
    }

    function test_Resolve_RejectingClientAndFeeRecipient_DoNotBlockProvider() public {
        ToggleReceiver feeWallet = new ToggleReceiver(false);
        vm.prank(owner);
        escrow.setFeeRecipient(address(feeWallet));

        ToggleReceiver clientWallet = new ToggleReceiver(false);
        vm.deal(address(clientWallet), AMOUNT);
        bytes memory create = abi.encodeCall(IAgentJobEscrow.createJob, (provider, ETH, AMOUNT, _deadline(), arbiter));
        uint256 jobId = abi.decode(clientWallet.exec(address(escrow), AMOUNT, create), (uint256));
        _deliver(jobId);
        clientWallet.exec(address(escrow), 0, abi.encodeCall(IAgentJobEscrow.dispute, (jobId)));

        vm.prank(arbiter);
        escrow.resolve(jobId, 5_000);

        (uint256 providerAmount, uint256 clientAmount, uint256 fee) = escrow.computeSplit(AMOUNT, 5_000, FEE_BPS);
        assertEq(provider.balance, providerAmount);
        assertEq(escrow.pendingWithdrawals(address(clientWallet), ETH), clientAmount);
        assertEq(escrow.pendingWithdrawals(address(feeWallet), ETH), fee);
        assertEq(address(escrow).balance, clientAmount + fee);
    }

    function test_GasBurningReceiver_CannotBlockSettlement() public {
        GasBurner burner = new GasBurner();
        vm.prank(client);
        uint256 jobId = escrow.createJob{value: AMOUNT}(address(burner), ETH, AMOUNT, _deadline(), address(0));
        vm.prank(address(burner));
        escrow.submitDelivery(jobId, DELIVERY);

        vm.prank(client);
        escrow.approve{gas: 300_000}(jobId);

        assertEq(escrow.pendingWithdrawals(address(burner), ETH), AMOUNT - _fee(AMOUNT));
        _assertState(jobId, IAgentJobEscrow.State.Released);
    }

    function test_BlocklistedProvider_IsCreditedAndWithdrawsToOtherAddress() public {
        MockBlocklistERC20 token = new MockBlocklistERC20();
        token.mint(client, AMOUNT);
        vm.startPrank(client);
        token.approve(address(escrow), AMOUNT);
        uint256 jobId = escrow.createJob(provider, address(token), AMOUNT, _deadline(), address(0));
        vm.stopPrank();
        _deliver(jobId);

        token.setBlocked(provider, true);
        vm.prank(client);
        escrow.approve(jobId);

        uint256 net = AMOUNT - _fee(AMOUNT);
        assertEq(escrow.pendingWithdrawals(provider, address(token)), net);
        assertEq(token.balanceOf(feeRecipient), _fee(AMOUNT));

        vm.prank(provider);
        vm.expectRevert("blocked");
        escrow.withdraw(address(token));
        assertEq(escrow.pendingWithdrawals(provider, address(token)), net);

        address fresh = makeAddr("fresh");
        vm.prank(provider);
        escrow.withdrawTo(address(token), fresh);
        assertEq(token.balanceOf(fresh), net);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_CreditsAreIsolatedPerToken() public {
        ToggleReceiver wallet = new ToggleReceiver(false);
        vm.prank(client);
        uint256 jobId = escrow.createJob{value: AMOUNT}(address(wallet), ETH, AMOUNT, _deadline(), address(0));
        vm.prank(address(wallet));
        escrow.submitDelivery(jobId, DELIVERY);
        vm.prank(client);
        escrow.approve(jobId);

        vm.prank(address(wallet));
        vm.expectRevert(IAgentJobEscrow.NothingToWithdraw.selector);
        escrow.withdraw(address(usdc));
    }

    function test_RevertWhen_WithdrawInvalid() public {
        vm.startPrank(stranger);
        vm.expectRevert(IAgentJobEscrow.NothingToWithdraw.selector);
        escrow.withdraw(ETH);

        vm.expectRevert(IAgentJobEscrow.NothingToWithdraw.selector);
        escrow.withdrawTo(ETH, stranger);

        vm.expectRevert(IAgentJobEscrow.ZeroAddress.selector);
        escrow.withdrawTo(ETH, address(0));

        vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.InvalidRecipient.selector, address(escrow)));
        escrow.withdrawTo(ETH, address(escrow));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                               REENTRANCY
    //////////////////////////////////////////////////////////////*/

    function test_ReentrantProvider_CannotGetPaidTwice() public {
        ReentrantProvider attacker = new ReentrantProvider(escrow);
        vm.prank(client);
        uint256 jobId = escrow.createJob{value: AMOUNT}(address(attacker), ETH, AMOUNT, _deadline(), address(0));
        attacker.submit(jobId, DELIVERY);
        vm.warp(block.timestamp + 4 days);

        attacker.claim(jobId);
        if (escrow.pendingWithdrawals(address(attacker), ETH) > 0) attacker.withdraw();

        uint256 net = AMOUNT - _fee(AMOUNT);
        assertGt(attacker.attempts(), 0);
        assertEq(address(attacker).balance, net);
        assertEq(escrow.pendingWithdrawals(address(attacker), ETH), 0);
        assertEq(address(escrow).balance, 0);
        assertEq(feeRecipient.balance, _fee(AMOUNT));
        _assertState(jobId, IAgentJobEscrow.State.Released);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function test_ComputeSplit() public view {
        (uint256 providerAmount, uint256 clientAmount, uint256 fee) = escrow.computeSplit(10_000, 10_000, 1_000);
        assertEq(providerAmount, 9_000);
        assertEq(clientAmount, 0);
        assertEq(fee, 1_000);

        // 1 wei cannot be split; rounding favours the client, never the platform.
        (providerAmount, clientAmount, fee) = escrow.computeSplit(1, 5_000, 1_000);
        assertEq(providerAmount, 0);
        assertEq(clientAmount, 1);
        assertEq(fee, 0);
    }

    function test_RevertWhen_ComputeSplitParamsInvalid() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.InvalidBps.selector, 10_001));
        escrow.computeSplit(AMOUNT, 10_001, 0);

        vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.FeeTooHigh.selector, 1_001, 1_000));
        escrow.computeSplit(AMOUNT, 10_000, 1_001);
    }

    function test_GetJob_UnknownIdIsEmpty() public view {
        IAgentJobEscrow.Job memory job = escrow.getJob(42);
        assertEq(job.client, address(0));
        assertEq(uint8(job.state), uint8(IAgentJobEscrow.State.None));
    }
}
