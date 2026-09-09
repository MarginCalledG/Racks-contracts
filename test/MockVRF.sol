// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVRFCallback2 { function rawFulfill(uint256 id, uint256 word) external; }

/// Deterministic VRF stand-in: requests get sequential ids; tests fulfill them by hand.
contract MockVRF {
    uint256 public lastId;
    mapping(uint256 => address) public cb;

    function requestRandom(address callback) external returns (uint256 id) {
        id = ++lastId;
        cb[id] = callback;
    }

    function fulfill(uint256 id, uint256 word) external {
        IVRFCallback2(cb[id]).rawFulfill(id, word);
    }
}
