// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AgentJobEscrow} from "../../src/AgentJobEscrow.sol";

/// @notice Plain mintable ERC-20.
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice ERC-20 that can block transfers to specific addresses (USDC-style blocklist).
contract MockBlocklistERC20 is MockERC20 {
    mapping(address => bool) public blocked;

    constructor() MockERC20("Blocklist", "BLK") {}

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[to] && !blocked[from], "blocked");
        super._update(from, to, value);
    }
}

/// @notice ERC-20 that burns 1% on every transfer.
contract MockFeeOnTransferERC20 is MockERC20 {
    constructor() MockERC20("FeeOnTransfer", "FOT") {}

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 burnt = value / 100;
            super._update(from, address(0), burnt);
            value -= burnt;
        }
        super._update(from, to, value);
    }
}

/// @notice USDT-style token: transfer / transferFrom / approve return nothing.
contract MockNoReturnERC20 {
    string public constant name = "NoReturn";
    string public constant symbol = "NRT";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        require(balanceOf[from] >= amount, "balance");
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice Contract wallet that can be switched to reject ETH.
contract ToggleReceiver {
    bool public acceptEth;

    constructor(bool acceptEth_) {
        acceptEth = acceptEth_;
    }

    function setAcceptEth(bool accept) external {
        acceptEth = accept;
    }

    function exec(address target, uint256 value, bytes calldata data) external payable returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }

    receive() external payable {
        require(acceptEth, "no eth");
    }
}

/// @notice Receiver that burns all gas it is given (gas griefing).
contract GasBurner {
    receive() external payable {
        while (true) {}
    }
}

/// @notice Provider contract that tries to re-enter the escrow when it receives ETH.
contract ReentrantProvider {
    AgentJobEscrow public immutable escrow;
    uint256 public targetJob;
    bytes public lastRevert;
    uint256 public attempts;

    constructor(AgentJobEscrow escrow_) {
        escrow = escrow_;
    }

    function submit(uint256 jobId, bytes32 hash) external {
        escrow.submitDelivery(jobId, hash);
    }

    function claim(uint256 jobId) external {
        targetJob = jobId;
        escrow.claimAfterReview(jobId);
    }

    function withdraw() external {
        escrow.withdraw(address(0));
    }

    receive() external payable {
        attempts++;
        try escrow.claimAfterReview(targetJob) {}
        catch (bytes memory reason) {
            lastRevert = reason;
        }
        try escrow.withdraw(address(0)) {} catch {}
    }
}
