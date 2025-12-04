// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPool, DataTypes} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {IRewardsController} from "@aave/periphery-v3/contracts/rewards/interfaces/IRewardsController.sol";
import {IOctantYieldRouter} from "./interfaces/IOctantYieldRouter.sol";

contract TemporalArbitrageVault is ERC4626, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IPool public immutable aavePool;
    IRewardsController public immutable rewardsController;
    IOctantYieldRouter public immutable octantRouter;

    address public publicGoodsFundingAddress;
    uint256 public constant PUBLIC_GOODS_ALLOCATION = 1500; // 15%
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant SLIPPAGE_TOLERANCE = 200; // 2%

    IERC20 public immutable aToken;

    struct ImpactCondition {
        bytes32 projectId;
        uint256 threshold;
        uint256 multiplier;
        bool verified;
        uint256 unlockTime;
    }

    mapping(bytes32 => ImpactCondition) public impactConditions;
    mapping(address => mapping(bytes32 => uint256)) public userCommitments;

    uint256 public totalCapitalDeposited;
    uint256 public totalYieldHarvested;

    event YieldGenerated(uint256 amount, uint256 timestamp);
    event YieldRouted(uint256 amount, address indexed recipient);
    event ImpactConditionMet(bytes32 indexed projectId, uint256 multipliedAmount);

    constructor(
        address _asset,
        address _aavePool,
        address _rewardsController,
        address _octantRouter,
        address _publicGoodsFunding
    ) ERC4626(IERC20(_asset)) ERC20("ClawFi Temporal Arbitrage", "cfTAV") {
        require(_asset != address(0), "Invalid asset");
        require(_aavePool != address(0), "Invalid Aave pool");
        
        aavePool = IPool(_aavePool);
        rewardsController = IRewardsController(_rewardsController);
        octantRouter = IOctantYieldRouter(_octantRouter);
        publicGoodsFundingAddress = _publicGoodsFunding;

        // Get aToken address
        DataTypes.ReserveData memory reserveData = aavePool.getReserveData(_asset);
        aToken = IERC20(reserveData.aTokenAddress);
    }

    function deposit(uint256 assets, address receiver) 
        public 
        override 
        whenNotPaused 
        nonReentrant 
        returns (uint256 shares) 
    {
        require(assets > 0, "Zero deposit");
        shares = previewDeposit(assets);

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        IERC20(asset()).safeApprove(address(aavePool), assets);
        aavePool.supply(asset(), assets, address(this), 0);

        totalCapitalDeposited += assets;
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) 
        public 
        override 
        whenNotPaused 
        nonReentrant 
        returns (uint256 shares) 
    {
        shares = previewWithdraw(assets);
        if (msg.sender != owner) {
            uint256 allowed = allowance(owner, msg.sender);
            require(shares <= allowed, "Insufficient allowance");
            _spendAllowance(owner, msg.sender, shares);
        }

        _burn(owner, shares);
        
        uint256 withdrawn = aavePool.withdraw(asset(), assets, address(this));
        uint256 minExpected = assets * (BASIS_POINTS - SLIPPAGE_TOLERANCE) / BASIS_POINTS;
        require(withdrawn >= minExpected, "Slippage exceeded");

        IERC20(asset()).safeTransfer(receiver, withdrawn);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function totalAssets() public view override returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? assets : assets * supply / totalAssets();
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? assets : assets * totalSupply() / totalAssets();
    }

    function harvestAndRouteYield() external nonReentrant whenNotPaused {
        // Claim Aave rewards
        address[] memory assets = new address[](1);
        assets[0] = address(aToken);
        try rewardsController.claimAllRewards(assets, address(this)) returns (uint256) {} catch {}

        uint256 currentAssets = totalAssets();
        uint256 capital = totalCapitalDeposited;
        uint256 yieldGenerated = currentAssets > capital ? currentAssets - capital : 0;

        if (yieldGenerated == 0) return;

        uint256 publicGoodsAmount = yieldGenerated * PUBLIC_GOODS_ALLOCATION / BASIS_POINTS;
        aavePool.withdraw(asset(), publicGoodsAmount, address(this));

        IERC20(asset()).safeApprove(address(octantRouter), publicGoodsAmount);
        octantRouter.routeYield(asset(), publicGoodsAmount, publicGoodsFundingAddress, "TemporalArbitrage");

        totalYieldHarvested += publicGoodsAmount;
        emit YieldGenerated(yieldGenerated, block.timestamp);
        emit YieldRouted(publicGoodsAmount, publicGoodsFundingAddress);
    }

    function createImpactCondition(bytes32 projectId, uint256 threshold, uint256 multiplier, uint256 unlockTime) 
        external onlyOwner 
    {
        impactConditions[projectId] = ImpactCondition({
            projectId: projectId,
            threshold: threshold,
            multiplier: multiplier,
            verified: false,
            unlockTime: unlockTime
        });
    }

    function emergencyPause() external onlyOwner {
        _pause();
    }
}
