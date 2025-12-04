// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IOctantYieldRouter {
    function routeYield(
        address token,
        uint256 amount,
        address defaultRecipient,
        bytes calldata metadata
    ) external returns (bool);

    function setAllocationPolicy(
        address vault,
        uint256[] calldata percentages,
        address[] calldata recipients
    ) external;
}
