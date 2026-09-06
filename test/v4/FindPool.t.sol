// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

interface IStateView {
    function getSlot0(bytes32 poolId) external view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
    function getLiquidity(bytes32 poolId) external view returns (uint128 liquidity);
}

// PoolKey exactly as v4 defines it (order matters for the id hash)
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

contract FindPool is Test {
    address constant SPY  = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    IStateView constant SV = IStateView(0xF3334192D15450CdD385c8B70e03f9A6bD9E673b);

    function _id(PoolKey memory k) internal pure returns (bytes32) {
        return keccak256(abi.encode(k));
    }

    function testFindSpyUsdgPool() public {
        if (SPY.code.length == 0) { vm.skip(true); return; } // needs --fork-url
        // SPY (0x117c) < USDG (0x5fc5) -> SPY is currency0
        require(SPY < USDG, "order");
        uint24[4] memory fees      = [uint24(100), 500, 3000, 10000];
        int24[4]  memory spacings  = [int24(1),   10,  60,   200];

        for (uint i = 0; i < 4; i++) {
            PoolKey memory k = PoolKey({
                currency0: SPY, currency1: USDG,
                fee: fees[i], tickSpacing: spacings[i], hooks: address(0)
            });
            bytes32 id = _id(k);
            uint128 liq = SV.getLiquidity(id);
            (uint160 sp, int24 tick,,) = SV.getSlot0(id);
            if (liq > 0 || sp > 0) {
                emit log_named_uint("FOUND fee", fees[i]);
                emit log_named_uint("  liquidity", liq);
                emit log_named_uint("  sqrtPriceX96", sp);
                emit log_named_int ("  tick", tick);
            }
        }
    }
}
