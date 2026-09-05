// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {WRacks} from "../src/WRacks.sol";

contract WRacksTest is Test {
    Racks k;
    WRacks w;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    uint256 constant RAY = 1e27;

    function setUp() public {
        k = new Racks(RAY / 1e6);
        w = new WRacks(address(k));
        k.mint(alice, 1_000_000 ether);
        k.mint(bob, 1_000_000 ether);
        vm.prank(alice); k.approve(address(w), type(uint256).max);
        vm.prank(bob); k.approve(address(w), type(uint256).max);
    }

    // wRACKS balance is FIXED (non-rebasing) while underlying melts
    function testWrappedBalanceStableWhileUnderlyingMelts() public {
        vm.prank(alice);
        uint256 shares = w.wrap(100_000 ether);
        assertEq(w.balanceOf(alice), shares);
        uint256 rps0 = w.racksPerShare();
        vm.warp(block.timestamp + 10 days);
        assertEq(w.balanceOf(alice), shares);       // fixed supply, no rebase
        assertLt(w.racksPerShare(), rps0);          // but redemption value fell (melt reflected in price)
    }

    // unwrap returns the melted value
    function testUnwrapReturnsMeltedValue() public {
        vm.prank(alice);
        uint256 shares = w.wrap(100_000 ether);
        vm.warp(block.timestamp + 10 days);
        uint256 balBefore = k.balanceOf(alice);
        vm.prank(alice);
        uint256 out = w.unwrap(shares);
        assertLt(out, 100_000 ether);               // less than deposited (it melted inside)
        assertApproxEqAbs(k.balanceOf(alice) - balBefore, out, 1e12);
    }

    // two wrappers share the melt pro-rata
    function testProRataAcrossHolders() public {
        vm.prank(alice); uint256 sa = w.wrap(100_000 ether);
        vm.prank(bob);   uint256 sb = w.wrap(100_000 ether);
        assertApproxEqAbs(sa, sb, 1e12);            // equal deposits -> equal shares
        vm.warp(block.timestamp + 30 days);
        vm.prank(alice); uint256 oa = w.unwrap(sa);
        vm.prank(bob);   uint256 ob = w.unwrap(sb);
        assertApproxEqRel(oa, ob, 0.001e18);        // both took the same melt hit
    }
}
