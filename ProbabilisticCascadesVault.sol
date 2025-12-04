// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IOctantYieldRouter} from "./interfaces/IOctantYieldRouter.sol";

contract ProbabilisticCascadesVault is ERC4626, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IOctantYieldRouter public immutable octantRouter;
    address public octantAllocationMechanism;

    struct Project {
        bytes32 projectId;
        address fundingAddress;
        bytes32[] dependencies;
        uint256 cascadeMultiplier; // basis points
        bool active;
    }

    mapping(bytes32 => Project) public projects;
    mapping(bytes32 => uint256) public failedPotentialPools;

    uint256 public totalYieldGenerated;
    uint256 public totalCascadesFunded;
    uint256 public constant MAX_CASCADE_DEPTH = 3;

    event ProjectRegistered(bytes32 indexed projectId, address fundingAddress);
    event CascadeTriggered(bytes32 indexed projectId, uint256 primaryAmount, uint256 cascadeAmount);
    event FailedPotentialDistributed(bytes32 indexed projectId, uint256 amount);

    constructor(
        address _asset,
        address _octantRouter,
        address _allocationMechanism
    ) ERC4626(IERC20(_asset)) ERC20("ClawFi Probabilistic Cascades", "cfPCV") {
        octantRouter = IOctantYieldRouter(_octantRouter);
        octantAllocationMechanism = _allocationMechanism;
    }

    function registerProject(
        bytes32 projectId,
        address fundingAddress,
        bytes32[] calldata dependencies,
        uint256 cascadeMultiplier
    ) external onlyOwner {
        require(fundingAddress != address(0), "Invalid address");
        require(cascadeMultiplier <= 5000, "Multiplier too high"); // max 50%

        projects[projectId] = Project({
            projectId: projectId,
            fundingAddress: fundingAddress,
            dependencies: dependencies,
            cascadeMultiplier: cascadeMultiplier,
            active: true
        });
        emit ProjectRegistered(projectId, fundingAddress);
    }

    function triggerCascade(bytes32 projectId, uint256 primaryAmount) 
        external 
        onlyOwner 
        nonReentrant 
        returns (uint256 totalFunded) 
    {
        Project storage project = projects[projectId];
        require(project.active, "Inactive project");

        IERC20(asset()).safeTransfer(project.fundingAddress, primaryAmount);
        totalFunded = primaryAmount;

        uint256 cascadeAmount = primaryAmount * project.cascadeMultiplier / 10000;
        
        if (project.dependencies.length > 0 && cascadeAmount > 0) {
            uint256 perDep = cascadeAmount / project.dependencies.length;
            for (uint256 i = 0; i < project.dependencies.length; i++) {
                bytes32 depId = project.dependencies[i];
                Project storage dep = projects[depId];
                if (dep.active && dep.fundingAddress != address(0)) {
                    IERC20(asset()).safeTransfer(dep.fundingAddress, perDep);
                    totalFunded += perDep;
                }
            }
        }

        totalCascadesFunded += totalFunded;
        emit CascadeTriggered(projectId, primaryAmount, cascadeAmount);
    }

    function accumulateFailedPotential(bytes32 projectId, uint256 amount) external onlyOwner {
        failedPotentialPools[projectId] += amount;
    }

    function distributeFailedPotential(bytes32 projectId) external onlyOwner nonReentrant {
        uint256 amount = failedPotentialPools[projectId];
        require(amount > 0, "No funds");

        Project storage project = projects[projectId];
        failedPotentialPools[projectId] = 0;

        IERC20(asset()).safeApprove(address(octantRouter), amount);
        octantRouter.routeYield(asset(), amount, project.fundingAddress, abi.encode("FailedPotential", projectId));
        emit FailedPotentialDistributed(projectId, amount);
    }

    function harvestYield() external onlyOwner nonReentrant {
        uint256 assets = totalAssets();
        uint256 shares = totalSupply();
        if (assets <= shares) return;

        uint256 yieldAmount = assets - shares;
        totalYieldGenerated += yieldAmount;

        IERC20(asset()).safeApprove(address(octantRouter), yieldAmount);
        octantRouter.routeYield(asset(), yieldAmount, octantAllocationMechanism, "ProbabilisticCascades");
    }
}
