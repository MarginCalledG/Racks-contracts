// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockPair {
    uint256 public racksReserve;
    uint256 public spyReserve;
    function set(uint256 k, uint256 s) external { racksReserve = k; spyReserve = s; }
}
