// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {DeployClawFi} from "../script/DeployClawFi.s.sol";
import {TemporalArbitrageVault} from "../src/TemporalArbitrageVault.sol";
import {AdversarialCooperationHook} from "../src/AdversarialCooperationHook.sol";
import {ProbabilisticCascadesVault} from "../src/ProbabilisticCascadesVault.sol";
import {OctantYieldRouter} from "../src/OctantYieldRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockAavePool} from "./mocks/MockAavePool.sol";

contract ClawFiTest is Test {
    DeployClawFi deployer;
    TemporalArbitrageVault temporalVault;
    ProbabilisticCascadesVault cascadesVault;
    OctantYieldRouter router;
    MockERC20 usdc;
    MockAavePool aavePool;
    
    address public user = makeAddr("user");
    address public publicGoods = makeAddr("publicGoods");
    address public octantFund = makeAddr("octantFund");

    function setUp() public {
        // Deploy all contracts
        deployer = new DeployClawFi();
        (router, temporalVault, cascadesVault) = deployer.run();

        // Setup mock USDC (6 decimals)
        usdc = new MockERC20("USDC", "USDC", 6);
        usdc.mint(user, 1_000_000e6); // 1M USDC
        
        // Setup mock Aave pool
        aavePool = new MockAavePool(address(usdc));
        
        // Fund contracts
        deal(address(usdc), address(temporalVault), 10_000e6);
        deal(address(usdc), address(cascadesVault), 10_000e6);
        
        // Authorize vaults
        vm.prank(deployer.DEFAULT_ADMIN());
        router.authorizeVault(address(temporalVault));
        router.authorizeVault(address(cascadesVault));
    }

    ////////////////////////
    // TEMPORAL ARBITRAGE //
    ////////////////////////

    function testTemporalVaultDepositWithdraw() public {
        uint256 depositAmount = 10_000e6; // 10K USDC
        
        // User approves and deposits
        vm.prank(user);
        usdc.approve(address(temporalVault), depositAmount);
        vm.prank(user);
        uint256 shares = temporalVault.deposit(depositAmount, user);
        
        assertEq(temporalVault.balanceOf(user), shares);
        assertEq(temporalVault.totalCapitalDeposited(), depositAmount);
        assertEq(usdc.balanceOf(address(temporalVault)), depositAmount);
    }

    function testTemporalVaultYieldHarvest() public {
        uint256 initialYield = 1_500e6; // 1.5K yield (15%)
        
        // Simulate Aave yield
        aavePool.setATokenBalance(address(temporalVault), 11_500e6);
        
        // Harvest yield
        temporalVault.harvestAndRouteYield();
        
        uint256 expectedPublicGoods = 1_500e6 * 1500 / 10000; // 15%
        assertEq(temporalVault.totalYieldHarvested(), expectedPublicGoods);
        assertGt(usdc.balanceOf(publicGoods), 0);
    }

    function testTemporalVaultSlippageProtection() public {
        vm.expectRevert("Slippage exceeded");
        temporalVault.withdraw(10_000e6, user, user); // Will fail due to slippage
    }

    //////////////////////////
    // PROBABILISTIC CASCADES //
    //////////////////////////

    function testCascadesProjectRegistration() public {
        bytes32 projectId = keccak256("testProject");
        bytes32[] memory deps = new bytes32[](1);
        deps[0] = keccak256("depProject");
        
        vm.prank(deployer.DEFAULT_ADMIN());
        cascadesVault.registerProject(
            projectId,
            publicGoods,
            deps,
            2000 // 20% cascade
        );
        
        assertTrue(cascadesVault.projects(projectId).active);
        assertEq(cascadesVault.projects(projectId).fundingAddress, publicGoods);
    }

    function testCascadesTriggerCascade() public {
        bytes32 projectId = keccak256("testProject");
        bytes32 depId = keccak256("depProject");
        
        // Register projects
        vm.prank(deployer.DEFAULT_ADMIN());
        bytes32[] memory deps = new bytes32[](1);
        deps[0] = depId;
        cascadesVault.registerProject(projectId, publicGoods, deps, 2000);
        cascadesVault.registerProject(depId, octantFund, new bytes32[](0), 1000);
        
        uint256 primaryAmount = 5_000e6;
        uint256 balanceBefore = usdc.balanceOf(publicGoods);
        
        vm.prank(deployer.DEFAULT_ADMIN());
        uint256 totalFunded = cascadesVault.triggerCascade(projectId, primaryAmount);
        
        // Primary + cascade (20%) = 6K total
        assertApproxEqAbs(totalFunded, 6_000e6, 1e6);
        assertGt(usdc.balanceOf(publicGoods), balanceBefore);
    }

    /////////////////////
    // YIELD ROUTER //
    /////////////////////

    function testYieldRouterPolicy() public {
        address[] memory recipients = new address[](2);
        uint256[] memory percentages = new uint256[](2);
        recipients[0] = publicGoods;
        recipients[1] = octantFund;
        percentages[0] = 6000; // 60%
        percentages[1] = 4000; // 40%
        
        vm.prank(deployer.DEFAULT_ADMIN());
        router.setAllocationPolicy(address(temporalVault), percentages, recipients);
        
        // Test routing
        uint256 yieldAmount = 10_000e6;
        usdc.mint(address(temporalVault), yieldAmount);
        vm.prank(address(temporalVault));
        router.routeYield(address(usdc), yieldAmount, address(0), "");
        
        assertApproxEqAbs(usdc.balanceOf(publicGoods), 6_000e6, 1e6);
        assertApproxEqAbs(usdc.balanceOf(octantFund), 4_000e6, 1e6);
    }

    function testYieldRouterRoleRestriction() public {
        uint256 amount = 1_000e6;
        vm.prank(user);
        vm.expectRevert();
        router.routeYield(address(usdc), amount, publicGoods, "");
    }

    ///////////////////
    // SAFETY TESTS //
    ///////////////////

    function testEmergencyPause() public {
        vm.prank(deployer.DEFAULT_ADMIN());
        temporalVault.emergencyPause();
        
        vm.prank(user);
        vm.expectRevert("Contract paused");
        temporalVault.deposit(1_000e6, user);
    }

    function testZeroAddressProtection() public {
        vm.prank(deployer.DEFAULT_ADMIN());
        vm.expectRevert("Invalid address");
        cascadesVault.registerProject(keccak256("test"), address(0), new bytes32[](0), 1000);
    }

    ///////////////////////
    // END-TO-END FLOW //
    ///////////////////////

    function testEndToEndYieldFlow() public {
        // 1. User deposits
        uint256 depositAmount = 10_000e6;
        vm.prank(user);
        usdc.approve(address(temporalVault), depositAmount);
        vm.prank(user);
        temporalVault.deposit(depositAmount, user);
        
        // 2. Simulate yield
        aavePool.setATokenBalance(address(temporalVault), 11_500e6);
        
        // 3. Harvest and route
        temporalVault.harvestAndRouteYield();
        
        // 4. Verify public goods funding
        uint256 publicGoodsReceived = usdc.balanceOf(publicGoods);
        assertGt(publicGoodsReceived, 0);
        console2.log("Public Goods Funded:", publicGoodsReceived / 1e6, "USDC");
    }

    // Fuzz tests
    function testFuzzDeposit(uint256 amount) public {
        vm.assume(amount > 1e6 && amount < 100_000e6);
        
        vm.startPrank(user);
        usdc.approve(address(temporalVault), amount);
        uint256 shares = temporalVault.deposit(amount, user);
        assertEq(temporalVault.balanceOf(user), shares);
        vm.stopPrank();
    }
}
