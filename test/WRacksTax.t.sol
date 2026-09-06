// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {WRacks} from "../src/WRacks.sol";

interface IW {
    function wrap(uint256) external returns (uint256);
    function unwrap(uint256) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function setTaxWallet(address) external;
}

contract WRacksTaxTest is Test {
    Racks k; WRacks w;
    address user = address(0xA11CE);
    address taxWallet = address(0x7A11);
    uint256 constant RAY = 1e27;

    function setUp() public {
        k = new Racks(RAY / 1e6);
        w = new WRacks(address(k));
                k.setTaxExempt(address(w), true);
        k.setExempt(taxWallet, true);
        w.setTaxWallet(taxWallet);
        k.mint(user, 100_000 ether);
        vm.prank(user);
        k.approve(address(w), type(uint256).max);
    }

    // wrap takes the 4% sell-side tax; tax lands in RACKS at the tax wallet
    function testWrapTaxed() public {
        vm.prank(user);
        w.wrap(10_000 ether);
        assertEq(k.balanceOf(taxWallet), 400 ether);       // 4% of 10,000
    }

    // unwrap takes the 4% buy-side tax on the way out
    function testUnwrapTaxed() public {
        vm.startPrank(user);
        uint256 sh = w.wrap(10_000 ether);                 // 400 tax -> 9,600 wrapped
        uint256 before = k.balanceOf(taxWallet);
        w.unwrap(sh);                                      // ~9,600 gross out, 4% tax
        vm.stopPrank();
        assertApproxEqAbs(k.balanceOf(taxWallet) - before, 384 ether, 1e15); // 4% of ~9,600
    }

    // during the RACKS launch window, wrap/unwrap tax jumps to 8%
    function testLaunchTax8() public {
        w.setCapExempt(user, true); // this test checks tax, not the wallet cap
        k.enableTrading();
        vm.prank(user);
        w.wrap(10_000 ether);
        assertEq(k.balanceOf(taxWallet), 800 ether);       // 8% launch tax
    }

    function testTaxCapAndOnlyOwner() public {
        vm.expectRevert(bytes("cap"));
        w.setTaxBps(801);
        vm.prank(address(0xBAD));
        vm.expectRevert(bytes("!owner"));
        w.setTaxWallet(address(0xBEEF));
    }
}
