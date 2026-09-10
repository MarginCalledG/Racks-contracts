// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {IRSAgent} from "../src/IRSAgent.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockVRF} from "./MockVRF.sol";

contract AuditM is Test {
    Racks k; CaymanIslands v; IRSAgent oldAg; MockERC20 usdg; MockVRF vrf;
    address locker = address(0x10C); address alice = address(0xA11CE); address bob = address(0xB0B);

    function setUp() public {
        k = new Racks(1e27/1e6); usdg = new MockERC20(); vrf = new MockVRF();
        v = new CaymanIslands(address(k), address(usdg), address(0x8E5E));
        oldAg = new IRSAgent(address(usdg), address(v), address(vrf), address(0x8E5E));
        oldAg.setPaused(false);
        k.setVault(address(v)); k.setExempt(address(v), true); k.setTaxExempt(address(v), true);
        v.setAgent(address(oldAg)); k.setTaxExempt(address(oldAg), true);
        k.mint(locker, 10_000_000 ether); usdg.mint(locker, 1_000 ether);
        usdg.mint(alice, 1_000 ether); usdg.mint(bob, 1_000 ether);
        vm.startPrank(locker); k.approve(address(v), type(uint256).max); usdg.approve(address(v), type(uint256).max);
        v.lock(0, 5_000_000 ether); vm.stopPrank();
        vm.prank(alice); usdg.approve(address(oldAg), type(uint256).max);
    }
    function _win(IRSAgent a, address who) internal returns (uint256 id, uint32 e) {
        vm.prank(who); id = a.mint(); vrf.fulfill(vrf.lastId(), 97);
        e = a.currentEpoch();
        vm.prank(who); a.attack(id); vrf.fulfill(vrf.lastId(), 1);
        vm.warp(block.timestamp + 8 hours); a.settle(e);
    }

    // The agent pointer is FINAL: there is no migration path at all, so unclaimed prizes can
    // never be stranded and the pot can never be redirected by an owner key.
    function testAgentPointerIsFinal() public {
        (uint256 aliceId, uint32 e0) = _win(oldAg, alice);
        uint256 alicePrize = oldAg.pending(aliceId, e0);
        assertGt(alicePrize, 0);
        IRSAgent newAg = new IRSAgent(address(usdg), address(v), address(vrf), address(0x8E5E));
        vm.expectRevert(bytes("agent is final"));
        v.setAgent(address(newAg));
        // alice can still collect, on the only agent there will ever be
        uint256 before = k.balanceOf(alice);
        vm.prank(alice); oldAg.claim(aliceId, e0);
        assertApproxEqAbs(k.balanceOf(alice) - before, alicePrize, 1e12, "prize still payable");
    }

    // What CAN be replaced is the randomness source - inside the agent, timelocked.
    function testVrfIsTimelockedAndRenounceable() public {
        MockVRF newVrf = new MockVRF();
        vm.expectRevert(bytes("vrf has no code")); oldAg.proposeVrf(address(0xBEEF));
        oldAg.proposeVrf(address(newVrf));
        vm.expectRevert(bytes("timelock")); oldAg.executeVrf();
        vm.warp(block.timestamp + 7 days + 1);
        oldAg.executeVrf();
        assertEq(address(oldAg.vrf()), address(newVrf), "randomness source replaced");

        // and it can be closed for good
        oldAg.renounceVrfControl();
        assertTrue(oldAg.vrfFinal());
        MockVRF another = new MockVRF();   // construct BEFORE expectRevert, or it eats the expectation
        vm.expectRevert(bytes("vrf final")); oldAg.proposeVrf(address(another));
    }

    // a non-owner can touch neither
    function testOnlyOwnerControls() public {
        vm.startPrank(address(0xBAD));
        vm.expectRevert(bytes("!admin")); oldAg.proposeVrf(address(vrf));
        vm.expectRevert(bytes("!owner")); v.setAgent(address(0x1));
        vm.stopPrank();
    }

    // X6: a mint stranded by a VRF change (or outage) can be reclaimed with the fee refunded
    function testX6_StuckMintReclaimable() public {
        vm.prank(alice); uint256 id = oldAg.mint();     // VRF never answers
        uint256 reqId = vrf.lastId();
        assertEq(oldAg.livingCount(), 1);
        uint256 paid = 99 * 10 ** usdg.decimals();
        // the reserve must have approved the agent to pay refunds out
        vm.prank(address(0x8E5E)); usdg.approve(address(oldAg), type(uint256).max);
        usdg.mint(address(0x8E5E), paid);

        vm.expectRevert(bytes("too early")); oldAg.reclaimStuckMint(reqId);
        vm.warp(block.timestamp + 3 days + 1);
        uint256 before = usdg.balanceOf(alice);
        oldAg.reclaimStuckMint(reqId);
        assertEq(usdg.balanceOf(alice) - before, paid, "mint fee refunded");
        assertEq(oldAg.livingCount(), 0, "zombie retired");
        vm.expectRevert(bytes("not a mint req")); oldAg.reclaimStuckMint(reqId);
    }
}
