// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {TaxSwapper} from "../src/TaxSwapper.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockRouter, MockPrice} from "./MockSwap.sol";

contract MockTaxOracle2 {
    function taxBps(uint256, bool) external pure returns (uint256) { return 400; } // 4%
    function update() external {}
}

contract TaxSwapperTest is Test {
    Racks k;
    MockERC20 spy;
    MockRouter router;
    MockPrice price;
    TaxSwapper swapper;
    MockTaxOracle2 oracle;

    address alice = address(0xA11CE);
    address pool = address(0x9001);
    address reserve = address(0x5E5E5E);
    uint256 constant RAY = 1e27;

    function setUp() public {
        k = new Racks(RAY / 1e6);
        spy = new MockERC20();
        oracle = new MockTaxOracle2();
        // rate: 1 RACKS -> 0.5 SPY
        router = new MockRouter(address(spy), 1, 2);
        price = new MockPrice(1, 2);
        // threshold 3000 RACKS, 3% max slippage
        swapper = new TaxSwapper(address(k), address(spy), address(router), address(price), reserve, 3000 ether, 300);

        k.setTaxWallet(address(swapper));
        k.setExempt(address(swapper), true);    // accrued tax RACKS must not melt
        k.setTaxExempt(address(swapper), true);
        k.setTaxOracle(address(oracle));
        k.setDex(pool, true);

        k.mint(alice, 1_000_000 ether);
        k.enableTrading(); vm.warp(block.timestamp + 1 hours + 1);   // launch armed, window over
        k.setExempt(alice, true); k.setExempt(pool, true);           // exact tax assertions, no melt drift
    }

    function _sell(uint256 amt) internal { vm.prank(alice); k.transfer(pool, amt); }

    function testTaxAccruesInSwapper() public {
        _sell(100_000 ether);                      // 4% = 4000 RACKS tax
        assertEq(swapper.pending(), 4_000 ether);
    }

    function testSwapBelowThresholdReverts() public {
        _sell(50_000 ether);                       // 2000 RACKS < 3000 threshold
        vm.expectRevert(bytes("below threshold"));
        swapper.swap();
    }

    function testAutoSwapToReserve() public {
        _sell(100_000 ether);                      // 4000 RACKS accrued
        uint256 amt = swapper.pending();
        swapper.swap();                            // permissionless
        assertEq(swapper.pending(), 0);            // drained
        // 4000 RACKS * 0.5 = 2000 SPY to reserve
        assertEq(spy.balanceOf(reserve), (amt * 1) / 2);
    }

    // batching: several trades accumulate, one swap clears them
    function testBatching() public {
        _sell(40_000 ether); // 1600
        _sell(40_000 ether); // 1600
        _sell(40_000 ether); // 1600 -> 4800 total, over threshold
        assertEq(swapper.pending(), 4_800 ether);
        swapper.swap();
        assertEq(spy.balanceOf(reserve), 2_400 ether); // 4800 * 0.5
    }

    // slippage floor protects the swap
    function testSlippageProtection() public {
        _sell(100_000 ether);
        router.setRate(1, 4); // router now pays only 0.25 SPY/RACKS -> below the 3% floor
        vm.expectRevert(bytes("slippage"));
        swapper.swap();
    }

    function testMaxSlippageCapped() public {
        vm.expectRevert(bytes("slip cap"));
        swapper.setMaxSlippage(1001); // >10% rejected
    }
}
