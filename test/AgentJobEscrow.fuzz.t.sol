// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAgentJobEscrow} from "../src/interfaces/IAgentJobEscrow.sol";
import {BaseTest} from "./BaseTest.sol";

contract AgentJobEscrowFuzzTest is BaseTest {
    function testFuzz_ComputeSplit_ConservesValue(uint256 amount, uint256 providerBps, uint256 feeBps) public view {
        providerBps = bound(providerBps, 0, 10_000);
        feeBps = bound(feeBps, 0, 1_000);

        (uint256 providerAmount, uint256 clientAmount, uint256 fee) = escrow.computeSplit(amount, providerBps, feeBps);
        uint256 providerGross = providerAmount + fee;

        assertEq(providerAmount + clientAmount + fee, amount, "value not conserved");
        assertLe(fee, providerGross / 10, "fee above 10%");
        // floor(amount * providerBps / 10_000), computed without overflowing.
        assertEq(providerGross, amount / 10_000 * providerBps + (amount % 10_000) * providerBps / 10_000);
    }

    function testFuzz_SetFeeBps_NeverAboveCap(uint16 newFeeBps) public {
        vm.prank(owner);
        if (newFeeBps > 1_000) {
            vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.FeeTooHigh.selector, newFeeBps, 1_000));
        }
        escrow.setFeeBps(newFeeBps);
        assertLe(escrow.feeBps(), 1_000);
    }

    function testFuzz_Approve_PaysExactly(uint256 amount, uint16 feeBps, bool useEth) public {
        amount = bound(amount, 1, 1_000 ether);
        feeBps = uint16(bound(feeBps, 0, 1_000));
        vm.prank(owner);
        escrow.setFeeBps(feeBps);

        vm.prank(client);
        uint256 jobId = useEth
            ? escrow.createJob{value: amount}(provider, ETH, amount, _deadline(), address(0))
            : escrow.createJob(provider, address(usdc), amount, _deadline(), address(0));
        _deliver(jobId);
        vm.prank(client);
        escrow.approve(jobId);

        uint256 fee = amount * feeBps / 10_000;
        assertEq(_balance(useEth, provider), amount - fee);
        assertEq(_balance(useEth, feeRecipient), fee);
        assertEq(_balance(useEth, address(escrow)), 0);
    }

    function testFuzz_Resolve_DistributesExactly(uint256 amount, uint16 providerBps, uint16 feeBps, bool useEth)
        public
    {
        amount = bound(amount, 1, 1_000 ether);
        providerBps = uint16(bound(providerBps, 0, 10_000));
        feeBps = uint16(bound(feeBps, 0, 1_000));
        vm.prank(owner);
        escrow.setFeeBps(feeBps);

        uint256 clientStart = _balance(useEth, client);
        vm.prank(client);
        uint256 jobId = useEth
            ? escrow.createJob{value: amount}(provider, ETH, amount, _deadline(), arbiter)
            : escrow.createJob(provider, address(usdc), amount, _deadline(), arbiter);
        _deliverAndDispute(jobId);
        vm.prank(arbiter);
        escrow.resolve(jobId, providerBps);

        uint256 toProvider = _balance(useEth, provider);
        uint256 toPlatform = _balance(useEth, feeRecipient);
        uint256 toClient = _balance(useEth, client) - (clientStart - amount);

        assertEq(toProvider + toPlatform + toClient, amount);
        assertEq(_balance(useEth, address(escrow)), 0);
        assertLe(toPlatform, (toProvider + toPlatform) / 10);
    }

    /// Delivery is accepted up to and including the deadline; refund only strictly after it.
    function testFuzz_DeadlineBoundary(uint256 elapsed) public {
        uint256 jobId = _createEthJob(address(0));
        uint64 deadline = escrow.getJob(jobId).deadline;
        vm.warp(block.timestamp + bound(elapsed, 0, 30 days));

        if (block.timestamp <= deadline) {
            vm.prank(client);
            vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.DeadlineNotPassed.selector, jobId, deadline));
            escrow.refund(jobId);
            _deliver(jobId);
        } else {
            vm.prank(provider);
            vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.DeadlinePassed.selector, jobId, deadline));
            escrow.submitDelivery(jobId, DELIVERY);
            vm.prank(client);
            escrow.refund(jobId);
        }
    }

    /// Dispute and claim windows never overlap, so a provider can't claim around a pending dispute.
    function testFuzz_ReviewWindowBoundary(uint256 elapsed) public {
        uint256 jobId = _createEthJob(arbiter);
        _deliver(jobId);
        uint64 reviewEndsAt = escrow.getJob(jobId).reviewEndsAt;
        vm.warp(block.timestamp + bound(elapsed, 0, 10 days));

        if (block.timestamp <= reviewEndsAt) {
            vm.prank(provider);
            vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.ReviewWindowOpen.selector, jobId, reviewEndsAt));
            escrow.claimAfterReview(jobId);
            vm.prank(client);
            escrow.dispute(jobId);
        } else {
            vm.prank(client);
            vm.expectRevert(abi.encodeWithSelector(IAgentJobEscrow.ReviewWindowClosed.selector, jobId, reviewEndsAt));
            escrow.dispute(jobId);
            vm.prank(provider);
            escrow.claimAfterReview(jobId);
        }
    }
}
