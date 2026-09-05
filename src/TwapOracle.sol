// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DynamicTax} from "./DynamicTax.sol";

interface IPair {
    function racksReserve() external view returns (uint256);
    function spyReserve() external view returns (uint256);
}

/// @title TwapOracle — 15-min time-weighted price + impact, feeding the DynamicTax rate
/// @dev Maintains its own cumulative accumulator sampled from the RACKS/SPY pair reserves.
///      A single-block spot spike contributes spot*dt with tiny dt -> negligible TWAP move.
contract TwapOracle {
    uint256 public constant WINDOW = 15 minutes;
    uint256 public constant PERIOD = 3 minutes;
    uint256 internal constant N = 8;

    IPair public pair;
    address public owner;

    uint256[N] internal cumHist;
    uint256[N] internal tsHist;
    uint8 internal head;
    uint8 internal count;
    uint256 public accCumulative;
    uint256 public lastTs;
    uint256 public lastSpot;

    constructor(address _pair) {
        pair = IPair(_pair);
        owner = msg.sender;
        lastTs = block.timestamp;
        lastSpot = _spot();
    }

    function setPair(address p) external { require(msg.sender == owner, "!owner"); pair = IPair(p); }

    function _spot() internal view returns (uint256) {
        uint256 kr = pair.racksReserve();
        if (kr == 0) return lastSpot;
        return pair.spyReserve() * 1e18 / kr; // SPY per RACKS, 1e18-scaled
    }

    function spot() external view returns (uint256) { return _spot(); }

    function update() external {
        uint256 nowTs = block.timestamp;
        accCumulative += lastSpot * (nowTs - lastTs);
        lastTs = nowTs;
        lastSpot = _spot();
        if (count == 0 || nowTs - tsHist[(head + N - 1) % N] >= PERIOD) {
            cumHist[head] = accCumulative;
            tsHist[head] = nowTs;
            head = uint8((head + 1) % N);
            if (count < N) count++;
        }
    }

    function twap() public view returns (uint256) {
        if (count == 0) return _spot();
        uint256 nowTs = block.timestamp;
        uint256 nowCum = accCumulative + lastSpot * (nowTs - lastTs);
        uint256 minTs = type(uint256).max;
        uint256 minCum;
        for (uint8 i; i < count; i++) {
            uint8 idx = uint8((head + N - count + i) % N);
            if (tsHist[idx] < minTs) { minTs = tsHist[idx]; minCum = cumHist[idx]; }
        }
        if (nowTs <= minTs) return _spot();
        return (nowCum - minCum) / (nowTs - minTs);
    }

    function taxBps(uint256 amount, bool isSell) external view returns (uint256) {
        uint256 sp = _spot();
        uint256 tw = twap();
        if (tw == 0) tw = sp;
        uint256 kr = pair.racksReserve();
        uint256 impactBps = kr == 0 ? 0 : amount * 10000 / kr;
        return DynamicTax.taxBps(isSell, sp, tw, impactBps);
    }
}
