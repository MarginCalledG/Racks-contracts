// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DynamicTax} from "../src/DynamicTax.sol";

contract TaxHarness {
    function t(bool s, uint256 sp, uint256 tw, uint256 im) external pure returns (uint256) {
        return DynamicTax.taxBps(s, sp, tw, im);
    }
}

contract DynamicTaxTest is Test {
    TaxHarness h;
    function setUp() public { h = new TaxHarness(); }

    // neutral market, no impact: base 4/4
    function testNeutral() public view {
        assertEq(h.t(true, 100, 100, 0), 400);
        assertEq(h.t(false, 100, 100, 0), 400);
    }

    // strong sell pressure: sell -> 7%, buy -> 1%
    function testSellPressure() public view {
        assertEq(h.t(true, 90, 100, 0), 700);  // 10% below twap = full ramp
        assertEq(h.t(false, 90, 100, 0), 100); // buy incentivised to floor
    }

    // strong buy pressure: buy -> 5%, sell HOLDS at 4%
    function testBuyPressure() public view {
        assertEq(h.t(false, 110, 100, 0), 500);
        assertEq(h.t(true, 110, 100, 0), 400); // sell does not get cheaper at the top
    }

    // the first dumper: neutral state but a big sell still pays up via impact
    function testImpactCatchesFirstDumper() public view {
        assertEq(h.t(true, 100, 100, 500), 700); // 5% impact ramps sell to cap even at neutral
        assertEq(h.t(true, 100, 100, 250), 550); // half impact -> halfway
    }

    // partial dislocation scales linearly
    function testPartialDislocation() public view {
        assertEq(h.t(true, 95, 100, 0), 550); // 5% below -> halfway 400..700
    }

    // caps and floor are never breached, for any inputs
    function testFuzzBounds(bool isSell, uint256 spot, uint256 twap, uint256 impact) public view {
        twap = bound(twap, 1, 1e30);
        spot = bound(spot, 0, 1e30);
        impact = bound(impact, 0, 5000);
        uint256 tax = h.t(isSell, spot, twap, impact);
        assertGe(tax, 100);          // never below floor
        assertLe(tax, 700);          // never above the hard sell cap
        if (!isSell) assertLe(tax, 500); // buy never above its own cap
    }
}
