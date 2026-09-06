// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {IRSAgent} from "../src/IRSAgent.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockVRF} from "./MockVRF.sol";

contract PotLiveTest is Test {
    Racks k; CaymanIslands v; IRSAgent ag; MockERC20 usdg; MockVRF vrf;
    address locker = address(0x10C); address player = address(0xB1A);
    function setUp() public {
        k = new Racks(1e27/1e6); usdg = new MockERC20(); vrf = new MockVRF();
        v = new CaymanIslands(address(k), address(usdg), address(this));
        ag = new IRSAgent(address(usdg), address(v), address(vrf), address(this));
        k.setVault(address(v)); k.setExempt(address(v), true); k.setTaxExempt(address(v), true);
        v.setAgent(address(ag)); k.setTaxExempt(address(ag), true);
        k.mint(locker, 1_000_000 ether); usdg.mint(locker, 100 ether); usdg.mint(player, 1_000 ether);
        vm.startPrank(locker); k.approve(address(v), type(uint256).max); usdg.approve(address(v), type(uint256).max); vm.stopPrank();
        vm.prank(player); usdg.approve(address(ag), type(uint256).max);
    }

    // The user's exact scenario: locker locks, then NEVER transacts again.
    function testPotVisibleAndPaidWithoutAnyLockerTx() public {
        vm.prank(locker); v.lock(0, 1_000_000 ether);          // 1-day lock, 2%/day bleed
        vm.warp(block.timestamp + 12 hours); k.poke();          // half a day, nobody touched anything

        // OLD problem: settled pot is 0 ...
        assertEq(v.potBalance(), 0, "settled pot is 0 (nobody harvested)");
        // ... but the LIVE pot shows the real accrued bleed -> agents see ~1% of 1M = ~10k
        uint256 live = v.potLive();
        emit log_named_uint("potBalance (settled)", v.potBalance());
        emit log_named_uint("potLive   (what holders see)", live);
        assertApproxEqRel(live, 10_000 ether, 0.01e18, "live pot must show accrued bleed");
        assertEq(ag.potPreview(), live, "agent UI preview == live pot");

        // a player mints an agent and attacks; epoch settles with NO locker/keeper tx
        vm.prank(player); uint256 id = ag.mint(); vrf.fulfill(vrf.lastId(), 97);
        vm.prank(player); ag.attack(id); vrf.fulfill(vrf.lastId(), 1);   // hit
        uint32 e = ag.currentEpoch();
        vm.warp(block.timestamp + 8 hours);
        uint256 before = k.balanceOf(player);
        vm.prank(player); ag.claim(id, e);                      // settle auto-harvests inside
        uint256 won = k.balanceOf(player) - before;
        emit log_named_uint("winner paid (RACKS)", won);
        assertGt(won, 0, "winner must NOT get 0 just because no locker transacted");
        assertApproxEqRel(won, live + (live * 2 / 3), 0.35e18, "paid roughly the accrued bleed (20h total)");
    }

    // harvestBatch pages through many positions; potLive == potBalance after a full harvest
    function testBatchHarvestPaging() public {
        for (uint i = 1; i <= 60; i++) {
            address u = address(uint160(0x5000 + i));
            k.mint(u, 10_000 ether); usdg.mint(u, 10 ether);
            vm.startPrank(u); k.approve(address(v), type(uint256).max); usdg.approve(address(v), type(uint256).max);
            v.lock(0, 10_000 ether); vm.stopPrank();
        }
        assertEq(v.activeCount(), 60);
        vm.warp(block.timestamp + 6 hours);
        uint256 live = v.potLive();
        v.harvestBatch(0, 25); v.harvestBatch(25, 25); v.harvestBatch(50, 25); // 3 pages
        assertApproxEqRel(v.potBalance(), live, 0.001e18, "after full harvest settled == live");
        // unlocking removes from the active set
        vm.warp(block.timestamp + 1 days);
        vm.prank(address(0x5001)); v.unlock(0);
        assertEq(v.activeCount(), 59);
    }
}
