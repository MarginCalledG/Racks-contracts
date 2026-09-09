// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TaxHook} from "../../src/v4/TaxHook.sol";

/// Deploys the TaxHook at a CREATE2 address whose low 14 bits declare AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA.
abstract contract HookedBase is Test {
    uint160 constant HOOK_FLAGS = uint160((1 << 6) | (1 << 2));

    function _deployHook(address pm, address wracks, address racks, address taxWallet) internal returns (TaxHook hook) {
        bytes memory init = abi.encodePacked(type(TaxHook).creationCode, abi.encode(pm, wracks, racks, taxWallet));
        bytes32 h = keccak256(init);
        for (uint256 s; s < 500000; s++) {
            address a = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(s), h)))));
            if (uint160(a) & uint160((1 << 14) - 1) == HOOK_FLAGS) {
                hook = new TaxHook{salt: bytes32(s)}(pm, wracks, racks, taxWallet);
                require(address(hook) == a, "mine mismatch");
                return hook;
            }
        }
        revert("no salt");
    }
}
