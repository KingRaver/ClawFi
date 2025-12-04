// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract OctantYieldRouter is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    struct AllocationPolicy {
        address[] recipients;
        uint256[] percentages;
        bool active;
    }

    mapping(address => AllocationPolicy) public vaultPolicies;
    uint256 public totalYieldRouted;
    mapping(address => uint256) public yieldPerToken;

    event YieldRouted(address indexed vault, address indexed token, uint256 amount, address[] recipients, uint256[] amounts);
    event PolicyUpdated(address indexed vault, uint256 recipientCount);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function routeYield(
        address token,
        uint256 amount,
        address defaultRecipient,
        bytes calldata metadata
    ) external whenNotPaused nonReentrant onlyRole(VAULT_ROLE) returns (bool) {
        require(amount > 0, "Zero amount");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        AllocationPolicy storage policy = vaultPolicies[msg.sender];
        address[] memory recipients;
        uint256[] memory amounts;

        if (!policy.active || policy.recipients.length == 0) {
            recipients = new address[](1);
            recipients[0] = defaultRecipient;
            amounts = new uint256[](1);
            amounts[0] = amount;
            IERC20(token).safeTransfer(defaultRecipient, amount);
        } else {
            recipients = policy.recipients;
            amounts = new uint256[](policy.recipients.length);
            
            for (uint256 i = 0; i < policy.recipients.length; i++) {
                uint256 share = amount * policy.percentages[i] / 10000;
                amounts[i] = share;
                IERC20(token).safeTransfer(policy.recipients[i], share);
            }
        }

        totalYieldRouted += amount;
        yieldPerToken[token] += amount;

        emit YieldRouted(msg.sender, token, amount, recipients, amounts);
        return true;
    }

    function setAllocationPolicy(
        address vault,
        uint256[] calldata percentages,
        address[] calldata recipients
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(percentages.length == recipients.length && percentages.length > 0, "Invalid arrays");
        
        uint256 total = 0;
        for (uint256 i = 0; i < percentages.length; i++) {
            total += percentages[i];
            require(recipients[i] != address(0), "Zero address");
        }
        require(total == 10000, "Must sum to 100%");

        vaultPolicies[vault] = AllocationPolicy({
            recipients: recipients,
            percentages: percentages,
            active: true
        });
        emit PolicyUpdated(vault, recipients.length);
    }

    function authorizeVault(address vault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(VAULT_ROLE, vault);
    }

    function emergencyPause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
