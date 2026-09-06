// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {V4Swap, PoolKey, Currency, IERC20x} from "../../src/v4/V4Swap.sol";

// REAL swap through RH mainnet v4 (fork). Proves our code talks to RH's modified v4.
contract V4SwapTest is Test {
    address constant SPY  = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant POOLMANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    function testRealSwapUsdgToSpy() public {
        if (SPY.code.length == 0) { vm.skip(true); return; } // needs --fork-url

        V4Swap v4 = new V4Swap(POOLMANAGER);
        address user = address(0xBEEF);
        uint256 amountIn = 1000e6; // 1000 USDG (6 decimals)
        deal(USDG, user, amountIn);

        // SPY (currency0) < USDG (currency1). USDG->SPY = swapping currency1 for currency0 = !zeroForOne
        PoolKey memory key = PoolKey(Currency.wrap(SPY), Currency.wrap(USDG), 3000, 60, address(0));

        vm.startPrank(user);
        IERC20x(USDG).approve(address(v4), amountIn);
        uint256 out = v4.swap(key, false, amountIn, 0, user);
        vm.stopPrank();

        emit log_named_uint("USDG in (1e6)", amountIn);
        emit log_named_uint("SPY out (1e18)", out);
        emit log_named_uint("~SPY out (whole, /1e18)", out / 1e18);
        assertGt(out, 0, "no SPY received");
        assertEq(IERC20x(SPY).balanceOf(user), out, "SPY not delivered to user");
    }
}
