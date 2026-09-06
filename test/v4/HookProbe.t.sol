// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {V4Pool} from "../../src/v4/V4Pool.sol";
import {V4Swap} from "../../src/v4/V4Swap.sol";
import {PoolKey, Currency, IERC20x} from "../../src/v4/V4Swap.sol";
import {ProbeHook} from "../../src/v4/CapHook.sol";
import {Racks} from "../../src/Racks.sol";
import {WRacks} from "../../src/WRacks.sol";

interface IW { function wrap(uint256) external returns (uint256); function approve(address,uint256) external returns (bool); }

// Can RH's MODIFIED v4 run a custom hook at all? Deploy a pool WITH a hook and see if it fires.
contract HookProbe is Test {
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant PM  = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    uint160 constant SQRT_1TO1 = 79228162514264337593543950336;

    // beforeSwap|afterSwap|beforeInitialize permission bits (standard v4)
    uint160 constant FLAGS = uint160(
        (1 << 7)  |  // BEFORE_SWAP
        (1 << 6)  |  // AFTER_SWAP
        (1 << 13)    // BEFORE_INITIALIZE
    );

    function _mineHook() internal returns (ProbeHook hook) {
        // find a salt so CREATE2(hookInit) lands on an address with the right low bits
        bytes memory initCode = type(ProbeHook).creationCode;
        bytes32 initHash = keccak256(initCode);
        for (uint256 salt = 0; salt < 200000; salt++) {
            address predicted = address(uint160(uint256(keccak256(abi.encodePacked(
                bytes1(0xff), address(this), bytes32(salt), initHash)))));
            if (uint160(predicted) & uint160((1<<14)-1) == FLAGS) {
                hook = new ProbeHook{salt: bytes32(salt)}();
                require(address(hook) == predicted, "mismatch");
                return hook;
            }
        }
        revert("no salt in range");
    }

    function testCustomHookFiresOnRHv4() public {
        if (SPY.code.length == 0) { vm.skip(true); return; }

        ProbeHook hook = _mineHook();
        emit log_named_address("mined hook addr", address(hook));

        Racks k = new Racks(1e27 / 1e6);
        WRacks w = new WRacks(address(k)); address wa = address(w);
        k.setTaxExempt(wa, true);
        k.mint(address(this), 2_000_000 ether);
        k.approve(wa, type(uint256).max);
        IW(wa).wrap(1_000_000 ether);
        deal(SPY, address(this), 5_000 ether);

        (address c0, address c1) = wa < SPY ? (wa, SPY) : (SPY, wa);
        bool wIsC0 = (wa == c0);
        // pool WITH the hook
        PoolKey memory key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, address(hook));

        V4Pool pool = new V4Pool(PM);
        pool.initialize(key, SQRT_1TO1);
        IERC20x(wa).approve(address(pool), type(uint256).max);
        IERC20x(SPY).approve(address(pool), type(uint256).max);
        pool.addLiquidity(key, -887220, 887220, int256(2_000 ether));

        V4Swap sw = new V4Swap(PM);
        IERC20x(SPY).approve(address(sw), type(uint256).max);
        sw.swap(key, !wIsC0, 10 ether, 0, address(this));   // SPY -> wRACKS through the HOOKED pool

        assertTrue(hook.beforeSwapCalled(), "beforeSwap did not fire");
        assertTrue(hook.afterSwapCalled(),  "afterSwap did not fire");
        emit log("RH v4 fired the custom hook on both beforeSwap and afterSwap");
    }
}
