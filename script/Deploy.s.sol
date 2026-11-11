// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {AgentJobEscrow} from "../src/AgentJobEscrow.sol";

/// @notice Optional env: OWNER and FEE_RECIPIENT (default: broadcaster), FEE_BPS (default: 250).
///         The signer is picked on the CLI (`--unlocked --sender` on anvil, `--account` elsewhere).
contract Deploy is Script {
    function run() external returns (AgentJobEscrow escrow) {
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address owner = vm.envOr("OWNER", deployer);
        address feeRecipient = vm.envOr("FEE_RECIPIENT", deployer);
        uint256 feeBpsEnv = vm.envOr("FEE_BPS", uint256(250));
        require(feeBpsEnv <= type(uint16).max, "FEE_BPS out of range");
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 feeBps = uint16(feeBpsEnv);

        escrow = new AgentJobEscrow(owner, feeRecipient, feeBps);
        vm.stopBroadcast();

        console2.log("AgentJobEscrow deployed at:", address(escrow));
        console2.log("  chain id:     ", block.chainid);
        console2.log("  owner:        ", owner);
        console2.log("  feeRecipient: ", feeRecipient);
        console2.log("  feeBps:       ", feeBps);
    }
}
