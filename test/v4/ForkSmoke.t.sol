// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

interface IERC20meta { function decimals() external view returns (uint8); function symbol() external view returns (string memory); function balanceOf(address) external view returns (uint256); }

// Proves we can fork RH mainnet and read the REAL SPY token + v4 PoolManager
contract ForkSmoke is Test {
    address constant SPY  = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant POOLMANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    function testForkReadsRealSpyAndV4() public {
        if (SPY.code.length == 0) { vm.skip(true); return; } // needs --fork-url
        // read the real SPY on the fork
        assertEq(IERC20meta(SPY).decimals(), 18);
        assertEq(IERC20meta(USDG).decimals(), 6);
        // the v4 PoolManager holds real SPY (proves pools hold it)
        uint256 spyInV4 = IERC20meta(SPY).balanceOf(POOLMANAGER);
        emit log_named_uint("SPY in v4 PoolManager (raw 1e18)", spyInV4);
        assertGt(spyInV4, 1000 ether); // >1000 SPY = deep liquidity
    }
}
