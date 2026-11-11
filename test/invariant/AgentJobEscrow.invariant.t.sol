// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentJobEscrow} from "../../src/AgentJobEscrow.sol";
import {MockERC20, ToggleReceiver} from "../mocks/Mocks.sol";
import {Handler} from "./Handler.sol";

contract AgentJobEscrowInvariantTest is Test {
    AgentJobEscrow internal escrow;
    MockERC20 internal token;
    Handler internal handler;

    function setUp() public {
        vm.warp(1_700_000_000);
        address owner = makeAddr("owner");
        ToggleReceiver feeWallet = new ToggleReceiver(true);
        escrow = new AgentJobEscrow(owner, address(feeWallet), 250);
        token = new MockERC20("Mock USD", "mUSD");
        handler = new Handler(escrow, token, owner, makeAddr("arbiter"), address(feeWallet));

        targetContract(address(handler));
        excludeSender(address(escrow));
    }

    /// @dev Escrow balance of each token == open job amounts + uncollected credits.
    function invariant_BalanceEqualsOwed() public view {
        address[2] memory tkns = handler.tokens();
        assertEq(address(escrow).balance, handler.totalOwed(tkns[0]), "ETH balance != owed");
        assertEq(token.balanceOf(address(escrow)), handler.totalOwed(tkns[1]), "token balance != owed");
    }

    /// @dev Neither the global fee nor any job's snapshot can exceed 10%.
    function invariant_FeeCapped() public view {
        assertLe(escrow.feeBps(), escrow.MAX_FEE_BPS());
        for (uint256 i; i < handler.jobCount(); i++) {
            assertLe(escrow.getJob(handler.jobIds(i)).feeBps, escrow.MAX_FEE_BPS());
        }
    }
}
