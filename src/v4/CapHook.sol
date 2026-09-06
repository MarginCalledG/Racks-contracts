// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolKey, Currency} from "./V4Swap.sol";

// v4 hook callback flags (standard). A hook contract MUST be deployed at an address whose low bits
// encode which callbacks it implements. beforeSwap = bit 7 (0x80), afterSwap = bit 6 (0x40).
// beforeAddLiquidity = bit 11, etc. For a wallet cap we need afterSwap (to see the recipient/amount)
// OR beforeSwap. We use a probe hook that just records that it was called.

struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }

interface IPoolManagerH {
    function unlock(bytes calldata) external returns (bytes memory);
    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) external returns (int24);
}

/// Minimal probe: implements beforeSwap + afterSwap, just flips a flag when called.
contract ProbeHook {
    bool public beforeSwapCalled;
    bool public afterSwapCalled;

    // beforeSwap(address,PoolKey,SwapParams,bytes) -> (bytes4, BeforeSwapDelta, uint24)
    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external returns (bytes4, int256, uint24)
    {
        beforeSwapCalled = true;
        return (this.beforeSwap.selector, int256(0), uint24(0));
    }
    // afterSwap(address,PoolKey,SwapParams,BalanceDelta,bytes) -> (bytes4, int128)
    function afterSwap(address, PoolKey calldata, SwapParams calldata, int256, bytes calldata)
        external returns (bytes4, int128)
    {
        afterSwapCalled = true;
        return (this.afterSwap.selector, int128(0));
    }
    // v4 calls this during initialize to validate the hook's permission bits vs its address
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return ProbeHook.beforeInitialize.selector;
    }
}
