// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPool, DataTypes} from "@aave/core-v3/contracts/interfaces/IPool.sol";

contract MockAavePool is IPool {
    IERC20 public asset;
    mapping(address => uint256) public aTokenBalances;

    constructor(address _asset) {
        asset = IERC20(_asset);
    }

    function setATokenBalance(address account, uint256 amount) external {
        aTokenBalances[account] = amount;
    }

    function supply(address, uint256, address, uint16) external {
        // Mock supply
    }

    function withdraw(address asset_, uint256 amount, address to) external returns (uint256) {
        return amount;
    }

    function getReserveData(address) external pure returns (DataTypes.ReserveData memory) {
        return DataTypes.ReserveData({
            configuration: 0,
            liquidityIndex: 1e27,
            variableBorrowIndex: 1e27,
            currentLiquidityRate: 0,
            currentVariableBorrowRate: 0,
            currentStableBorrowRate: 0,
            lastUpdateTimestamp: 0,
            aTokenAddress: address(new ERC20("aUSDC", "aUSDC")),
            stableDebtTokenAddress: address(0),
            variableDebtTokenAddress: address(0),
            interestRateStrategyAddress: address(0),
            accruedToTreasury: 0,
            unbacked: 0,
            isolationModeTotalDebt: 0
        });
    }

    // Other interface stubs...
}
