// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DynamicTax} from "../DynamicTax.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IStateView {
    function getSlot0(bytes32 poolId)
        external view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
    function getLiquidity(bytes32 poolId) external view returns (uint128 liquidity);
}

/// @title TwapOracleV4 — 15-min TWAP over a Uniswap v4 pool's price (via StateView),
///        feeding the DynamicTax rate. Sampled on each wrap/unwrap (or by a keeper).
/// @dev Reads "SPY per wRACKS" from the pool's sqrtPriceX96 (both tokens 18 decimals).
contract TwapOracleV4 {
    uint256 public constant WINDOW = 15 minutes;
    uint256 public constant PERIOD = 3 minutes;
    uint256 internal constant N = 8;
    uint256 internal constant Q96 = 1 << 96;

    IStateView public immutable sv;
    bytes32   public immutable poolId;
    bool      public immutable wracksIsCurrency0;
    address   public owner;

    uint256[N] internal cumHist;
    uint256[N] internal tsHist;
    uint8 internal head;
    uint8 internal count;
    uint256 public accCumulative;
    uint256 public lastTs;
    uint256 public lastSpot;

    constructor(address _sv, bytes32 _poolId, bool _wracksIsCurrency0) {
        sv = IStateView(_sv); poolId = _poolId; wracksIsCurrency0 = _wracksIsCurrency0;
        owner = msg.sender; lastTs = block.timestamp; lastSpot = _spot();
    }

    function _spot() internal view returns (uint256) {
        (uint160 sqrtP,,,) = sv.getSlot0(poolId);
        if (sqrtP == 0) return lastSpot;
        uint256 priceX96  = Math.mulDiv(uint256(sqrtP), uint256(sqrtP), Q96); // price(c1/c0)*2^96
        uint256 price1e18 = Math.mulDiv(priceX96, 1e18, Q96);                 // price(c1/c0), 1e18
        // want SPY-per-wRACKS: if wRACKS=c0 then price(c1/c0)=SPY/wRACKS already; else invert
        if (wracksIsCurrency0) return price1e18;
        return price1e18 == 0 ? lastSpot : 1e36 / price1e18;
    }
    function spot() external view returns (uint256) { return _spot(); }

    function update() external {
        uint256 nowTs = block.timestamp;
        accCumulative += lastSpot * (nowTs - lastTs);
        lastTs = nowTs;
        lastSpot = _spot();
        if (count == 0 || nowTs - tsHist[(head + N - 1) % N] >= PERIOD) {
            cumHist[head] = accCumulative; tsHist[head] = nowTs;
            head = uint8((head + 1) % N);
            if (count < N) count++;
        }
    }

    function twap() public view returns (uint256) {
        if (count == 0) return _spot();
        uint256 nowTs = block.timestamp;
        uint256 nowCum = accCumulative + lastSpot * (nowTs - lastTs);
        uint256 minTs = type(uint256).max; uint256 minCum;
        for (uint8 i; i < count; i++) {
            uint8 idx = uint8((head + N - count + i) % N);
            if (tsHist[idx] < minTs) { minTs = tsHist[idx]; minCum = cumHist[idx]; }
        }
        if (nowTs <= minTs) return _spot();
        return (nowCum - minCum) / (nowTs - minTs);
    }

    /// virtual wRACKS reserve at the current price from active liquidity L:
    /// token0 reserve = L * 2^96 / sqrtP, token1 reserve = L * sqrtP / 2^96
    function wracksReserve() public view returns (uint256) {
        (uint160 sqrtP,,,) = sv.getSlot0(poolId);
        uint256 L = sv.getLiquidity(poolId);
        if (sqrtP == 0 || L == 0) return 0;
        return wracksIsCurrency0
            ? Math.mulDiv(L, Q96, sqrtP)
            : Math.mulDiv(L, sqrtP, Q96);
    }

    /// dislocation (spot vs TWAP) + single-trade impact vs virtual reserve (catches the first dumper)
    function taxBps(uint256 amount, bool isSell) external view returns (uint256) {
        uint256 sp = _spot();
        uint256 tw = twap();
        if (tw == 0) tw = sp;
        uint256 r = wracksReserve();
        uint256 impactBps = r == 0 ? 0 : amount * 10000 / r;
        return DynamicTax.taxBps(isSell, sp, tw, impactBps);
    }
}
