// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {IRSAgent} from "../src/IRSAgent.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockVRF} from "./MockVRF.sol";


/// Audit regression suite: every exploit found must now be BLOCKED.
contract AuditFixes is Test {
    Racks k;
    address attacker = address(0xBAD);
    address victim   = address(0xB1C);
    uint256 constant RAY = 1e27;

    function setUp() public {
        k = new Racks(RAY / 1e6);
        k.mint(attacker, 2_000_000 ether);
        k.mint(victim,   1_000_000 ether);
    }



    // R2: transferring more than balance now REVERTS (ERC20 semantics), no silent clamp
    function testFixed_OverBalanceTransferReverts() public {
        vm.prank(victim);
        vm.expectRevert(bytes("balance"));
        k.transfer(attacker, 1_000_001 ether);
        // exact full balance still works (rounding-safe)
        uint256 b = k.balanceOf(victim);
        vm.prank(victim); k.transfer(attacker, b);
        assertEq(k.balanceOf(victim), 0);
    }

    // R5: enableTrading with zero supply is rejected (would set maxWallet=0 and block all buys)
    function testFixed_EnableTradingNeedsSupply() public {
        Racks k2 = new Racks(RAY / 1e6);
        vm.expectRevert(bytes("no supply"));
        k2.enableTrading();
    }

    // A2: an unknown / replayed VRF request id is rejected instead of corrupting epoch-0 shares
    function testFixed_UnknownVrfRequestRejected() public {
        MockERC20 usdg = new MockERC20(); MockVRF vrf = new MockVRF();
        CaymanIslands vault = new CaymanIslands(address(k), address(usdg), address(this));
        IRSAgent ag = new IRSAgent(address(usdg), address(vault), address(vrf), address(this));
        ag.setPaused(false);   // MockVRF has code; casino starts paused by default
        vm.prank(address(vrf));
        vm.expectRevert(bytes("unknown req"));
        ag.rawFulfill(999, 42);
    }

    // A5: an epoch's unclaimed prize is swept back into the pot after the claim window
    function testFixed_StaleUnclaimedPrizeSwept() public {
        MockERC20 usdg = new MockERC20(); MockVRF vrf = new MockVRF();
        CaymanIslands vault = new CaymanIslands(address(k), address(usdg), address(this));
        IRSAgent ag = new IRSAgent(address(usdg), address(vault), address(vrf), address(this));
        ag.setPaused(false);   // MockVRF has code; casino starts paused by default
        k.setVault(address(vault)); k.setExempt(address(vault), true); k.setTaxExempt(address(vault), true);
        vault.setAgent(address(ag)); k.setTaxExempt(address(ag), true);
        // fund a pot by donating RACKS to the vault (simulates bleed), win an epoch, never claim
        k.mint(address(this), 1_000 ether); k.approve(address(vault), type(uint256).max); vault.fundPot(1_000 ether);
        usdg.mint(attacker, 1_000 ether);
        vm.startPrank(attacker); usdg.approve(address(ag), type(uint256).max);
        uint256 id = ag.mint(); vm.stopPrank();
        vrf.fulfill(vrf.lastId(), 97);
        vm.prank(attacker); ag.attack(id); vrf.fulfill(vrf.lastId(), 1);   // hit
        uint32 e = ag.currentEpoch();
        vm.warp(block.timestamp + 8 hours); ag.settle(e);
        assertGt(ag.allocatedPot(), 0, "prize allocated");
        // 90 epochs later nobody claimed -> sweep releases it back to the pot
        vm.warp(block.timestamp + 91 * 8 hours);
        ag.sweepStale(e);
        assertEq(ag.allocatedPot(), 0, "unclaimed prize returned to pot");
    }
}
