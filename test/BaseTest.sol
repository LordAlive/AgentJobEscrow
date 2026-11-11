// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentJobEscrow} from "../src/AgentJobEscrow.sol";
import {IAgentJobEscrow} from "../src/interfaces/IAgentJobEscrow.sol";
import {MockERC20} from "./mocks/Mocks.sol";

abstract contract BaseTest is Test {
    address internal constant ETH = address(0);
    uint16 internal constant FEE_BPS = 250;
    uint256 internal constant AMOUNT = 1 ether;
    bytes32 internal constant DELIVERY = keccak256("ipfs://bafy-delivery");

    AgentJobEscrow internal escrow;
    MockERC20 internal usdc;

    address internal owner = makeAddr("owner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal client = makeAddr("client");
    address internal provider = makeAddr("provider");
    address internal arbiter = makeAddr("arbiter");
    address internal stranger = makeAddr("stranger");

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        escrow = new AgentJobEscrow(owner, feeRecipient, FEE_BPS);
        usdc = new MockERC20("Mock USD", "mUSD");

        vm.deal(client, 1_000 ether);
        usdc.mint(client, 1_000_000e18);
        vm.prank(client);
        usdc.approve(address(escrow), type(uint256).max);
    }

    function _deadline() internal view returns (uint64) {
        return uint64(block.timestamp + 7 days);
    }

    function _createJob(bool useEth, address jobArbiter) internal returns (uint256 jobId) {
        vm.prank(client);
        jobId = useEth
            ? escrow.createJob{value: AMOUNT}(provider, ETH, AMOUNT, _deadline(), jobArbiter)
            : escrow.createJob(provider, address(usdc), AMOUNT, _deadline(), jobArbiter);
    }

    function _createEthJob(address jobArbiter) internal returns (uint256) {
        return _createJob(true, jobArbiter);
    }

    function _deliver(uint256 jobId) internal {
        vm.prank(provider);
        escrow.submitDelivery(jobId, DELIVERY);
    }

    function _deliverAndDispute(uint256 jobId) internal {
        _deliver(jobId);
        vm.prank(client);
        escrow.dispute(jobId);
    }

    function _assertState(uint256 jobId, IAgentJobEscrow.State expected) internal view {
        assertEq(uint8(escrow.getJob(jobId).state), uint8(expected), "job state");
    }

    function _balance(bool useEth, address account) internal view returns (uint256) {
        return useEth ? account.balance : usdc.balanceOf(account);
    }

    function _fee(uint256 amount) internal pure returns (uint256) {
        return amount * FEE_BPS / 10_000;
    }

    function _invalidState(uint256 jobId, IAgentJobEscrow.State current) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAgentJobEscrow.InvalidState.selector, jobId, current);
    }
}
