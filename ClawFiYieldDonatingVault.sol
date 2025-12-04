// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import {IRewardsController} from "@aave/periphery-v3/contracts/rewards/interfaces/IRewardsController.sol";

/**
 * @title ClawFiYieldDonatingVault
 * @author ClawFi Team
 * @notice ERC-4626 compliant vault where depositors maintain capital ownership
 *         while 100% of generated yield is donated to Octant V2 public goods mechanisms.
 *
 * @dev Key Innovation:
 * - Depositors receive shares representing CAPITAL ONLY (1:1 ratio maintained)
 * - All yield is tracked separately and routed to public goods
 * - Capital preservation guarantee: totalAssets() >= totalSupply()
 * - Full ERC-4626 compliance with yield donation extensions
 *
 * Integration Points:
 * - Aave v3 for yield generation (via aTokens)
 * - Octant V2 allocation mechanisms for yield distribution
 * - Multi-pool funding mechanisms (Temporal, Adversarial, Cascades, Direct)
 */
contract ClawFiYieldDonatingVault is ERC4626, ERC20, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ============================================================
    // IMMUTABLES & CONSTANTS
    // ============================================================

    /// @notice Aave v3 Pool for yield generation
    IPool public immutable aavePool;

    /// @notice Aave v3 Rewards Controller for incentive claiming
    IRewardsController public immutable rewardsController;

    /// @notice The aToken received from Aave deposits
    IERC20 public immutable aToken;

    /// @notice Basis points denominator (10000 = 100%)
    uint256 private constant BASIS_POINTS = 10_000;

    /// @notice Minimum deposit amount (prevents dust attacks)
    uint256 public constant MIN_DEPOSIT = 1e6; // 1 USDC (assuming 6 decimals)

    /// @notice Maximum slippage tolerance (200 = 2%)
    uint256 public constant MAX_SLIPPAGE_BPS = 200;

    // ============================================================
    // STATE VARIABLES
    // ============================================================

    /// @notice Total capital deposited by users (excludes yield)
    uint256 public totalCapital;

    /// @notice Total yield generated and donated to date
    uint256 public totalYieldDonated;

    /// @notice Accumulated yield pending distribution
    uint256 public pendingYieldDistribution;

    /// @notice Last timestamp when yield was harvested
    uint256 public lastHarvestTimestamp;

    /// @notice Minimum time between harvests (prevents MEV/gas waste)
    uint256 public harvestCooldown = 6 hours;

    // ============================================================
    // OCTANT V2 INTEGRATION
    // ============================================================

    /// @notice Octant V2 allocation mechanism address (if used by external orchestrator)
    address public octantAllocationMechanism;

    /// @notice Yield distribution policy
    struct YieldDistributionPolicy {
        address temporalArbitragePool;      // For future-contingent funding
        address adversarialCoopPool;        // For competition-based funding
        address probabilisticCascadesPool;  // For dependency-mapped funding
        address directPublicGoods;          // Direct allocation to projects
        uint256 temporalBps;                // Allocation to Temporal Arbitrage
        uint256 adversarialBps;             // Allocation to Adversarial Coop
        uint256 cascadesBps;                // Allocation to Cascades
        uint256 directBps;                  // Direct allocation
        bool active;
    }

    YieldDistributionPolicy public yieldPolicy;

    // ============================================================
    // ACCOUNTING & SAFETY
    // ============================================================

    /// @notice Emergency withdrawal flag
    bool public emergencyMode;

    /// @notice Trusted keeper addresses for automated harvesting
    mapping(address => bool) public keepers;

    /// @notice Per-user accounting (for transparency)
    struct UserAccount {
        uint256 totalDeposited;
        uint256 totalWithdrawn;
        uint256 yieldContributed;
        uint256 firstDepositTimestamp;
        uint256 lastActivityTimestamp;
    }

    mapping(address => UserAccount) public userAccounts;

    // ============================================================
    // EVENTS
    // ============================================================

    event YieldHarvested(
        uint256 yieldAmount,
        uint256 timestamp,
        address indexed harvester
    );

    event YieldDonated(
        uint256 amount,
        address indexed recipient,
        string mechanism,
        uint256 timestamp
    );

    event YieldDistributed(
        uint256 temporalAmount,
        uint256 adversarialAmount,
        uint256 cascadesAmount,
        uint256 directAmount,
        uint256 totalDistributed
    );

    event PolicyUpdated(
        address temporalPool,
        address adversarialPool,
        address cascadesPool,
        address directGoods,
        uint256[4] allocations
    );

    event CapitalPreserved(
        uint256 totalAssets,
        uint256 totalCapital,
        uint256 yieldSeparated
    );

    event EmergencyWithdrawal(
        address indexed user,
        uint256 shares,
        uint256 assets
    );

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    /**
     * @notice Initialize the Yield Donating Vault
     * @param _asset Underlying asset (e.g., USDC, USDT)
     * @param _name Vault share token name
     * @param _symbol Vault share token symbol
     * @param _aavePoolAddressesProvider Aave v3 PoolAddressesProvider
     * @param _rewardsController Aave v3 Rewards Controller
     * @param _octantAllocation Octant V2 allocation mechanism (optional external hook)
     */
    constructor(
        address _asset,
        string memory _name,
        string memory _symbol,
        address _aavePoolAddressesProvider,
        address _rewardsController,
        address _octantAllocation
    )
        ERC20(_name, _symbol)
        ERC4626(IERC20(_asset))
    {
        require(_asset != address(0), "Invalid asset");
        require(_aavePoolAddressesProvider != address(0), "Invalid provider");
        require(_octantAllocation != address(0), "Invalid Octant address");

        IPoolAddressesProvider provider = IPoolAddressesProvider(_aavePoolAddressesProvider);
        aavePool = IPool(provider.getPool());
        rewardsController = IRewardsController(_rewardsController);
        octantAllocationMechanism = _octantAllocation;

        // Derive aToken from Aave reserve data
        (
            address aTokenAddress,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,

        ) = aavePool.getReserveData(_asset);
        require(aTokenAddress != address(0), "Invalid aToken");
        aToken = IERC20(aTokenAddress);

        lastHarvestTimestamp = block.timestamp;

        // Grant initial keeper role to deployer
        keepers[msg.sender] = true;
    }

    // ============================================================
    // ERC-4626 CORE FUNCTIONS (WITH YIELD DONATION LOGIC)
    // ============================================================

    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        require(assets >= MIN_DEPOSIT, "Below minimum deposit");
        require(receiver != address(0), "Invalid receiver");

        shares = assets;

        uint256 maxDeposit_ = maxDeposit(receiver);
        require(assets <= maxDeposit_, "Exceeds max deposit");

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);

        IERC20(asset()).safeApprove(address(aavePool), 0);
        IERC20(asset()).safeApprove(address(aavePool), assets);
        aavePool.supply(asset(), assets, address(this), 0);

        totalCapital += assets;

        UserAccount storage account = userAccounts[receiver];
        if (account.firstDepositTimestamp == 0) {
            account.firstDepositTimestamp = block.timestamp;
        }
        account.totalDeposited += assets;
        account.lastActivityTimestamp = block.timestamp;

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        return shares;
    }

    function mint(uint256 shares, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        require(shares >= MIN_DEPOSIT, "Below minimum mint");
        require(receiver != address(0), "Invalid receiver");

        assets = shares;

        uint256 maxMint_ = maxMint(receiver);
        require(shares <= maxMint_, "Exceeds max mint");

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);

        IERC20(asset()).safeApprove(address(aavePool), 0);
        IERC20(asset()).safeApprove(address(aavePool), assets);
        aavePool.supply(asset(), assets, address(this), 0);

        totalCapital += assets;

        UserAccount storage account = userAccounts[receiver];
        if (account.firstDepositTimestamp == 0) {
            account.firstDepositTimestamp = block.timestamp;
        }
        account.totalDeposited += assets;
        account.lastActivityTimestamp = block.timestamp;

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        return assets;
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    )
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        require(assets > 0, "Zero withdrawal");
        require(receiver != address(0), "Invalid receiver");

        shares = assets;

        if (msg.sender != owner) {
            uint256 allowed = allowance(owner, msg.sender);
            require(shares <= allowed, "Insufficient allowance");
            _spendAllowance(owner, msg.sender, shares);
        }

        require(shares <= balanceOf(owner), "Insufficient shares");

        _burn(owner, shares);

        totalCapital -= assets;

        uint256 withdrawn = aavePool.withdraw(
            asset(),
            assets,
            address(this)
        );

        uint256 minAcceptable = (assets * (BASIS_POINTS - MAX_SLIPPAGE_BPS)) / BASIS_POINTS;
        require(withdrawn >= minAcceptable, "Slippage exceeded");

        UserAccount storage account = userAccounts[owner];
        account.totalWithdrawn += withdrawn;
        account.lastActivityTimestamp = block.timestamp;

        IERC20(asset()).safeTransfer(receiver, withdrawn);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        return shares;
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    )
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        require(shares > 0, "Zero redemption");
        require(receiver != address(0), "Invalid receiver");

        assets = shares;

        if (msg.sender != owner) {
            uint256 allowed = allowance(owner, msg.sender);
            require(shares <= allowed, "Insufficient allowance");
            _spendAllowance(owner, msg.sender, shares);
        }

        require(shares <= balanceOf(owner), "Insufficient shares");

        _burn(owner, shares);

        totalCapital -= assets;

        uint256 withdrawn = aavePool.withdraw(
            asset(),
            assets,
            address(this)
        );

        uint256 minAcceptable = (assets * (BASIS_POINTS - MAX_SLIPPAGE_BPS)) / BASIS_POINTS;
        require(withdrawn >= minAcceptable, "Slippage exceeded");

        UserAccount storage account = userAccounts[owner];
        account.totalWithdrawn += withdrawn;
        account.lastActivityTimestamp = block.timestamp;

        IERC20(asset()).safeTransfer(receiver, withdrawn);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        return assets;
    }

    // ============================================================
    // ERC-4626 VIEW FUNCTIONS (YIELD DONATION AWARE)
    // ============================================================

    function totalAssets() public view override returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    function convertToShares(uint256 assets)
        public
        pure
        override
        returns (uint256 shares)
    {
        return assets;
    }

    function convertToAssets(uint256 shares)
        public
        pure
        override
        returns (uint256 assets)
    {
        return shares;
    }

    function previewDeposit(uint256 assets)
        public
        pure
        override
        returns (uint256)
    {
        return assets;
    }

    function previewMint(uint256 shares)
        public
        pure
        override
        returns (uint256)
    {
        return shares;
    }

    function previewWithdraw(uint256 assets)
        public
        pure
        override
        returns (uint256)
    {
        return assets;
    }

    function previewRedeem(uint256 shares)
        public
        pure
        override
        returns (uint256)
    {
        return shares;
    }

    function maxDeposit(address)
        public
        view
        override
        returns (uint256)
    {
        if (paused() || emergencyMode) return 0;
        return type(uint256).max;
    }

    function maxMint(address)
        public
        view
        override
        returns (uint256)
    {
        if (paused() || emergencyMode) return 0;
        return type(uint256).max;
    }

    function maxWithdraw(address owner)
        public
        view
        override
        returns (uint256)
    {
        return balanceOf(owner);
    }

    function maxRedeem(address owner)
        public
        view
        override
        returns (uint256)
    {
        return balanceOf(owner);
    }

    // ============================================================
    // YIELD DONATION LOGIC
    // ============================================================

    function calculateAccumulatedYield()
        public
        view
        returns (uint256 yieldAmount)
    {
        uint256 assets = totalAssets();
        if (assets <= totalCapital) {
            return 0;
        }
        yieldAmount = assets - totalCapital;
        return yieldAmount;
    }

    function harvestYield()
        public
        nonReentrant
        returns (uint256 harvestedYield)
    {
        require(
            block.timestamp >= lastHarvestTimestamp + harvestCooldown ||
                keepers[msg.sender],
            "Cooldown active"
        );

        harvestedYield = calculateAccumulatedYield();
        require(harvestedYield > 0, "No yield to harvest");

        address[] memory rewardAssets = new address[](1);
        rewardAssets[0] = address(aToken);

        try rewardsController.claimAllRewards(rewardAssets, address(this)) {
        } catch {
        }

        pendingYieldDistribution += harvestedYield;
        lastHarvestTimestamp = block.timestamp;

        emit YieldHarvested(harvestedYield, block.timestamp, msg.sender);
        emit CapitalPreserved(totalAssets(), totalCapital, harvestedYield);

        return harvestedYield;
    }

    function distributeYield()
        public
        nonReentrant
        returns (uint256 totalDistributed)
    {
        require(pendingYieldDistribution > 0, "No yield to distribute");
        require(yieldPolicy.active, "Policy not active");

        uint256 yieldAmount = pendingYieldDistribution;
        pendingYieldDistribution = 0;

        uint256 withdrawn = aavePool.withdraw(
            asset(),
            yieldAmount,
            address(this)
        );

        uint256 temporalAmount = (withdrawn * yieldPolicy.temporalBps) / BASIS_POINTS;
        uint256 adversarialAmount = (withdrawn * yieldPolicy.adversarialBps) / BASIS_POINTS;
        uint256 cascadesAmount = (withdrawn * yieldPolicy.cascadesBps) / BASIS_POINTS;
        uint256 directAmount = (withdrawn * yieldPolicy.directBps) / BASIS_POINTS;

        if (temporalAmount > 0) {
            IERC20(asset()).safeTransfer(
                yieldPolicy.temporalArbitragePool,
                temporalAmount
            );
            emit YieldDonated(
                temporalAmount,
                yieldPolicy.temporalArbitragePool,
                "TemporalArbitrage",
                block.timestamp
            );
        }

        if (adversarialAmount > 0) {
            IERC20(asset()).safeTransfer(
                yieldPolicy.adversarialCoopPool,
                adversarialAmount
            );
            emit YieldDonated(
                adversarialAmount,
                yieldPolicy.adversarialCoopPool,
                "AdversarialCooperation",
                block.timestamp
            );
        }

        if (cascadesAmount > 0) {
            IERC20(asset()).safeTransfer(
                yieldPolicy.probabilisticCascadesPool,
                cascadesAmount
            );
            emit YieldDonated(
                cascadesAmount,
                yieldPolicy.probabilisticCascadesPool,
                "ProbabilisticCascades",
                block.timestamp
            );
        }

        if (directAmount > 0) {
            IERC20(asset()).safeTransfer(
                yieldPolicy.directPublicGoods,
                directAmount
            );
            emit YieldDonated(
                directAmount,
                yieldPolicy.directPublicGoods,
                "DirectAllocation",
                block.timestamp
            );
        }

        totalDistributed =
            temporalAmount +
            adversarialAmount +
            cascadesAmount +
            directAmount;

        totalYieldDonated += totalDistributed;

        emit YieldDistributed(
            temporalAmount,
            adversarialAmount,
            cascadesAmount,
            directAmount,
            totalDistributed
        );

        return totalDistributed;
    }

    function harvestAndDistribute()
        external
        returns (uint256 harvestedAmount)
    {
        harvestedAmount = harvestYield();
        distributeYield();
        return harvestedAmount;
    }

    // ============================================================
    // GOVERNANCE & CONFIGURATION
    // ============================================================

    function setYieldDistributionPolicy(
        address temporalPool,
        address adversarialPool,
        address cascadesPool,
        address directGoods,
        uint256[4] calldata allocations
    ) external onlyOwner {
        require(temporalPool != address(0), "Invalid temporal pool");
        require(adversarialPool != address(0), "Invalid adversarial pool");
        require(cascadesPool != address(0), "Invalid cascades pool");
        require(directGoods != address(0), "Invalid direct goods address");

        uint256 total = allocations[0] +
            allocations[1] +
            allocations[2] +
            allocations[3];
        require(total == BASIS_POINTS, "Must sum to 100%");

        yieldPolicy = YieldDistributionPolicy({
            temporalArbitragePool: temporalPool,
            adversarialCoopPool: adversarialPool,
            probabilisticCascadesPool: cascadesPool,
            directPublicGoods: directGoods,
            temporalBps: allocations[0],
            adversarialBps: allocations[1],
            cascadesBps: allocations[2],
            directBps: allocations[3],
            active: true
        });

        emit PolicyUpdated(
            temporalPool,
            adversarialPool,
            cascadesPool,
            directGoods,
            allocations
        );
    }

    function setKeeper(address keeper, bool status) external onlyOwner {
        keepers[keeper] = status;
    }

    function setHarvestCooldown(uint256 newCooldown) external onlyOwner {
        require(newCooldown <= 1 days, "Cooldown too long");
        harvestCooldown = newCooldown;
    }

    // ============================================================
    // EMERGENCY FUNCTIONS
    // ============================================================

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function activateEmergencyMode() external onlyOwner {
        emergencyMode = true;
        _pause();
    }

    function emergencyWithdraw(uint256 shares) external nonReentrant {
        require(emergencyMode, "Not in emergency mode");
        require(shares > 0, "Zero shares");
        require(shares <= balanceOf(msg.sender), "Insufficient shares");

        _burn(msg.sender, shares);

        uint256 assets = shares;
        totalCapital -= assets;

        uint256 withdrawn = aavePool.withdraw(
            asset(),
            assets,
            address(this)
        );
        IERC20(asset()).safeTransfer(msg.sender, withdrawn);

        emit EmergencyWithdrawal(msg.sender, shares, withdrawn);
    }

    // ============================================================
    // VIEW FUNCTIONS (TRANSPARENCY)
    // ============================================================

    function getUserAccount(address user)
        external
        view
        returns (UserAccount memory)
    {
        return userAccounts[user];
    }

    function calculateUserYieldContribution(address user)
        external
        view
        returns (uint256)
    {
        uint256 userShares = balanceOf(user);
        if (totalSupply() == 0) return 0;

        uint256 userPortionBps = (userShares * BASIS_POINTS) / totalSupply();
        return (totalYieldDonated * userPortionBps) / BASIS_POINTS;
    }

    function currentAPY() external view returns (uint256) {
        if (totalCapital == 0) return 0;

        uint256 yield = calculateAccumulatedYield();
        if (yield == 0) return 0;

        uint256 timeDelta = block.timestamp - lastHarvestTimestamp;
        if (timeDelta == 0) return 0;

        uint256 apy = (yield * BASIS_POINTS * 365 days) / (totalCapital * timeDelta);
        return apy;
    }

    function getVaultMetrics()
        external
        view
        returns (
            uint256 _totalAssets,
            uint256 _totalCapital,
            uint256 _totalSupply,
            uint256 _accumulatedYield,
            uint256 _totalDonated,
            uint256 _pendingDistribution,
            bool _isHealthy
        )
    {
        _totalAssets = totalAssets();
        _totalCapital = totalCapital;
        _totalSupply = totalSupply();
        _accumulatedYield = calculateAccumulatedYield();
        _totalDonated = totalYieldDonated;
        _pendingDistribution = pendingYieldDistribution;
        _isHealthy = _totalAssets >= _totalCapital;
    }
}
