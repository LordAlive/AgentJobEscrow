// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {AgentJobEscrow} from "../src/AgentJobEscrow.sol";

/// @notice Runs create -> submitDelivery -> approve for one ETH job and prints balances before and after.
/// @dev Env: ESCROW_ADDRESS (required), CLIENT / PROVIDER (default: anvil accounts 1 and 2), JOB_AMOUNT (wei).
///      Anvil's dev accounts are unlocked, so the script runs with `--unlocked` and no private keys.
contract FullJob is Script {
    address internal constant ANVIL_ACCOUNT_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address internal constant ANVIL_ACCOUNT_2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

    function run() external {
        AgentJobEscrow escrow = AgentJobEscrow(vm.envAddress("ESCROW_ADDRESS"));
        address client = vm.envOr("CLIENT", ANVIL_ACCOUNT_1);
        address provider = vm.envOr("PROVIDER", ANVIL_ACCOUNT_2);
        uint256 amount = vm.envOr("JOB_AMOUNT", uint256(0.1 ether));
        address feeRecipient = escrow.feeRecipient();

        console2.log("== Before ==");
        _log(escrow, client, provider, feeRecipient);

        vm.startBroadcast(client);
        uint256 jobId = escrow.createJob{value: amount}(
            provider, escrow.NATIVE_TOKEN(), amount, uint64(block.timestamp + 1 days), address(0)
        );
        vm.stopBroadcast();
        console2.log("Created job", jobId);

        vm.startBroadcast(provider);
        escrow.submitDelivery(jobId, keccak256("ipfs://bafy-example-deliverable"));
        vm.stopBroadcast();
        console2.log("Delivery submitted");

        vm.startBroadcast(client);
        escrow.approve(jobId);
        vm.stopBroadcast();
        console2.log("Approved and released");

        (uint256 providerAmount,, uint256 fee) = escrow.computeSplit(amount, 10_000, escrow.getJob(jobId).feeBps);
        console2.log("== After ==");
        _log(escrow, client, provider, feeRecipient);
        console2.log("provider received (wei):", providerAmount);
        console2.log("platform fee (wei):     ", fee);
    }

    function _log(AgentJobEscrow escrow, address client, address provider, address feeRecipient) internal view {
        console2.log("  client       ", client, client.balance);
        console2.log("  provider     ", provider, provider.balance);
        console2.log("  feeRecipient ", feeRecipient, feeRecipient.balance);
        console2.log("  escrow       ", address(escrow), address(escrow).balance);
    }
}
