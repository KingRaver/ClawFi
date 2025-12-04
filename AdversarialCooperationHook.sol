// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseHook} from "v4-periphery/src/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/types/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IOctantYieldRouter} from "./interfaces/IOctantYieldRouter.sol";

contract AdversarialCooperationHook is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    IOctantYieldRouter public immutable octantRouter;
    address public publicGoodsFundingAddress;

    uint256 public constant PUBLIC_GOODS_FEE = 500; // 5%
    uint256 public constant BASIS_POINTS = 10000;

    struct CompetitionSlot {
        bytes32 slotId;
        uint256 amplifierPool;
        uint256 attempts;
        address winner;
        bool completed;
    }

    mapping(bytes32 => CompetitionSlot) public competitionSlots;
    mapping(PoolId => uint256) public accumulatedFees;

    event SwapFeeCollected(PoolId indexed poolId, uint256 amount);
    event CompetitionWon(bytes32 indexed slotId, address winner, uint256 amplifiedAmount);

    constructor(
        IPoolManager _poolManager,
        address _octantRouter,
        address _publicGoodsFunding
    ) BaseHook(_poolManager) {
        octantRouter = IOctantYieldRouter(_octantRouter);
        publicGoodsFundingAddress = _publicGoodsFunding;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false,
            afterSwapReturnDelta: false
        });
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        if (hookData.length > 0) {
            bytes32 slotId = abi.decode(hookData, (bytes32));
            CompetitionSlot storage slot = competitionSlots[slotId];
            if (!slot.completed) {
                slot.attempts++;
                emit SwapFeeCollected(key.toId(), 0);
            }
        }
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        PoolId poolId = key.toId();
        uint256 swapAmount = uint128(delta.amount0() > 0 ? uint256(delta.amount0()) : uint256(delta.amount1()));
        uint256 feeAmount = swapAmount * PUBLIC_GOODS_FEE / BASIS_POINTS;
        
        accumulatedFees[poolId] += feeAmount;

        if (hookData.length > 0) {
            bytes32 slotId = abi.decode(hookData, (bytes32));
            competitionSlots[slotId].amplifierPool += feeAmount;
        }

        emit SwapFeeCollected(poolId, feeAmount);
        return (this.afterSwap.selector, 0);
    }

    function createCompetitionSlot(bytes32 slotId) external onlyOwner {
        require(competitionSlots[slotId].slotId == bytes32(0), "Slot exists");
        competitionSlots[slotId] = CompetitionSlot(slotId, 0, 0, address(0), false);
    }

    function declareWinner(bytes32 slotId, address winner) external onlyOwner {
        CompetitionSlot storage slot = competitionSlots[slotId];
        require(!slot.completed, "Already completed");
        require(slot.attempts > 0, "No attempts");

        slot.winner = winner;
        slot.completed = true;
        
        uint256 amplifiedAmount = slot.amplifierPool;
        emit CompetitionWon(slotId, winner, amplifiedAmount);
    }

    function harvestFees(PoolId poolId) external onlyOwner {
        uint256 amount = accumulatedFees[poolId];
        require(amount > 0, "No fees");
        accumulatedFees[poolId] = 0;
        
        Currency currency = poolId.currency0();
        _poolManager.take(currency, address(this), int128(uint128(amount)));
        IERC20(address(currency)).safeApprove(address(octantRouter), amount);
        octantRouter.routeYield(address(currency), amount, publicGoodsFundingAddress, "AdversarialCoop");
    }
}
