// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolKey, Currency, IERC20x} from "./V4Swap.sol";

struct ModifyLiquidityParams {
    int24  tickLower;
    int24  tickUpper;
    int256 liquidityDelta;
    bytes32 salt;
}

interface IPoolManagerL {
    function unlock(bytes calldata data) external returns (bytes memory);
    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) external returns (int24 tick);
    function modifyLiquidity(PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata hookData)
        external returns (int256 callerDelta, int256 feesAccrued);
    function sync(Currency currency) external;
    function settle() external payable returns (uint256);
    function take(Currency currency, address to, uint256 amount) external;
}

// Minimal v4 pool creator + liquidity provider (unlock -> modifyLiquidity -> settle both legs).
contract V4Pool {
    IPoolManagerL public immutable pm;
    constructor(address _pm) { pm = IPoolManagerL(_pm); }

    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) external {
        pm.initialize(key, sqrtPriceX96);
    }

    struct CB { PoolKey key; int24 tickLower; int24 tickUpper; int256 liquidityDelta; address payer; }

    function addLiquidity(PoolKey calldata key, int24 tickLower, int24 tickUpper, int256 liquidityDelta) external {
        pm.unlock(abi.encode(CB(key, tickLower, tickUpper, liquidityDelta, msg.sender)));
    }
    /// burn liquidity of THIS contract's position and pay the tokens out to msg.sender
    function removeLiquidity(PoolKey calldata key, int24 tickLower, int24 tickUpper, int256 liquidity) external {
        pm.unlock(abi.encode(CB(key, tickLower, tickUpper, -liquidity, msg.sender)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "!pm");
        CB memory c = abi.decode(data, (CB));
        (int256 callerDelta,) = pm.modifyLiquidity(
            c.key,
            ModifyLiquidityParams(c.tickLower, c.tickUpper, c.liquidityDelta, bytes32(0)),
            ""
        );
        int128 d0 = int128(callerDelta >> 128);
        int128 d1 = int128(callerDelta);
        if (d0 < 0) _pay(c.key.currency0, c.payer, uint256(int256(-d0)));
        if (d1 < 0) _pay(c.key.currency1, c.payer, uint256(int256(-d1)));
        if (d0 > 0) pm.take(c.key.currency0, c.payer, uint256(int256(d0)));   // withdrawals
        if (d1 > 0) pm.take(c.key.currency1, c.payer, uint256(int256(d1)));
        return "";
    }

    function _pay(Currency cur, address payer, uint256 amount) internal {
        pm.sync(cur);
        IERC20x(Currency.unwrap(cur)).transferFrom(payer, address(pm), amount);
        pm.settle();
    }
}
