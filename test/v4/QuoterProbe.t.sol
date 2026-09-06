// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PoolKey, Currency} from "../../src/v4/V4Swap.sol";

struct QuoteExactSingleParams { PoolKey poolKey; bool zeroForOne; uint128 exactAmount; bytes hookData; }
interface IV4Quoter {
    function quoteExactOutputSingle(QuoteExactSingleParams memory p) external returns (uint256 amountIn, uint256 gasEst);
    function quoteExactInputSingle(QuoteExactSingleParams memory p) external returns (uint256 amountOut, uint256 gasEst);
}

contract QuoterProbe is Test {
    address constant SPY  = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;

    function testQuoterExactOutput() public {
        if (SPY.code.length == 0) { vm.skip(true); return; }
        IV4Quoter q = IV4Quoter(QUOTER);
        PoolKey memory key = PoolKey(Currency.wrap(SPY), Currency.wrap(USDG), 3000, 60, address(0));
        // how much USDG (currency1) for exactly 1 SPY (currency0) out?  -> !zeroForOne
        (uint256 usdgIn,) = q.quoteExactOutputSingle(
            QuoteExactSingleParams({ poolKey: key, zeroForOne: false, exactAmount: uint128(1 ether), hookData: "" })
        );
        emit log_named_uint("USDG needed for 1 SPY (1e6)", usdgIn);
        assertGt(usdgIn, 100e6);   // SPY ~ $700+, so >100 USDG
        assertLt(usdgIn, 5000e6);
        // and exact-input the other way as a cross-check
        (uint256 spyOut,) = q.quoteExactInputSingle(
            QuoteExactSingleParams({ poolKey: key, zeroForOne: false, exactAmount: uint128(1000e6), hookData: "" })
        );
        emit log_named_uint("SPY out for 1000 USDG (1e18)", spyOut);
        assertGt(spyOut, 0);
    }
}
