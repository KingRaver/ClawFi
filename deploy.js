const { ethers } = require("hardhat");

async function main() {
    const [deployer] = await ethers.getSigners();
    
    // Deploy contracts
    const OctantYieldRouter = await ethers.getContractFactory("OctantYieldRouter");
    const router = await OctantYieldRouter.deploy();
    
    const TemporalVault = await ethers.getContractFactory("TemporalArbitrageVault");
    const temporalVault = await TemporalVault.deploy(
        "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", // USDC
        "0x...AAVE_POOL...", // Aave Pool
        "0x...REWARDS_CONTROLLER...",
        router.target,
        "0x...PUBLIC_GOODS..."
    );

    console.log("Router:", router.target);
    console.log("TemporalVault:", temporalVault.target);
    
    // Authorize vaults
    await router.authorizeVault(temporalVault.target);
}

main().catch(console.error);
