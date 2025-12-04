// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {TemporalArbitrageVault} from "../src/TemporalArbitrageVault.sol";
import {ProbabilisticCascadesVault} from "../src/ProbabilisticCascadesVault.sol";
import {OctantYieldRouter} from "../src/OctantYieldRouter.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockAavePool} from "../test/mocks/MockAavePool.sol";

contract DeployClawFi is Script {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    
    function setUp() public {}

    function run() external returns (OctantYieldRouter router, TemporalArbitrageVault temporal, ProbabilisticCascadesVault cascades) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Deploy router first
        router = new OctantYieldRouter();
        console2.log("OctantYieldRouter deployed at:", address(router));

        // Deploy temporal vault
        MockAavePool mockPool = new MockAavePool(USDC);
        temporal = new TemporalArbitrageVault(
            USDC,
            address(mockPool),
            address(0x1), // Mock rewards controller
            address(router),
            0x123 // Mock public goods
        );

        // Deploy cascades vault
        cascades = new ProbabilisticCascadesVault(
            USDC,
            address(router),
            0x456 // Mock octant allocation
        );

        // Authorize vaults
        router.authorizeVault(address(temporal));
        router.authorizeVault(address(cascades));

        vm.stopBroadcast();
        return (router, temporal, cascades);
    }
}
