// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {IRSAgent} from "../src/IRSAgent.sol";
import {WRacks} from "../src/WRacks.sol";
import {TaxHook} from "../src/v4/TaxHook.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockVRF} from "./MockVRF.sol";

interface IW { function wrap(uint256) external returns (uint256); function unwrap(uint256) external returns (uint256); function balanceOf(address) external view returns (uint256); function transfer(address,uint256) external returns (bool); }

/// External audit findings — every exploit must now be BLOCKED.
contract ExternalAuditFixes is Test {
    Racks k; CaymanIslands v; IRSAgent ag; MockERC20 usdg; MockVRF vrf;
    address locker = address(0x10C); address alice = address(0xA11CE); address bob = address(0xB0B);

    function setUp() public {
        k = new Racks(1e27/1e6); usdg = new MockERC20(); vrf = new MockVRF();
        v = new CaymanIslands(address(k), address(usdg), address(this));
        ag = new IRSAgent(address(usdg), address(v), address(vrf), address(this));
        k.setVault(address(v)); k.setExempt(address(v), true); k.setTaxExempt(address(v), true);
        v.setAgent(address(ag)); k.setTaxExempt(address(ag), true);
        k.mint(locker, 10_000_000 ether); usdg.mint(locker, 1_000 ether);
        usdg.mint(alice, 1_000 ether); usdg.mint(bob, 1_000 ether);
        vm.startPrank(locker); k.approve(address(v), type(uint256).max); usdg.approve(address(v), type(uint256).max); vm.stopPrank();
        vm.prank(alice); usdg.approve(address(ag), type(uint256).max);
        vm.prank(bob); usdg.approve(address(ag), type(uint256).max);
    }
    function _agent(address who, uint256 word) internal returns (uint256 id) { vm.prank(who); id = ag.mint(); vrf.fulfill(vrf.lastId(), word); }

    // F1 BLOCKED: settle must be sequential
    function testF1_SettleMustBeSequential() public {
        vm.prank(locker); v.lock(0, 5_000_000 ether);
        uint256 aId = _agent(alice, 10); uint256 bId = _agent(bob, 10);
        uint32 e0 = ag.currentEpoch();
        vm.prank(alice); ag.attack(aId); vrf.fulfill(vrf.lastId(), 1);
        vm.warp(block.timestamp + 8 hours);
        uint32 e1 = ag.currentEpoch();
        vm.prank(bob); ag.attack(bId); vrf.fulfill(vrf.lastId(), 1);
        vm.warp(block.timestamp + 8 hours);
        vm.expectRevert(bytes("prev")); ag.settle(e1);                        // out of order refused
        ag.settle(e0); vm.warp(block.timestamp + 1 hours); ag.settle(e1);      // e1 gets its own hour of bleed
        uint256 ab = k.balanceOf(alice); vm.prank(alice); ag.claim(aId, e0);
        uint256 bb = k.balanceOf(bob);   vm.prank(bob);   ag.claim(bId, e1);
        assertGt(k.balanceOf(alice) - ab, 0, "alice paid");
        assertGt(k.balanceOf(bob) - bb, 0, "bob paid");
    }

    // F2 BLOCKED: a swept epoch cannot be claimed; bob keeps his full prize
    function testF2_SweptEpochNotClaimable() public {
        vm.prank(locker); v.lock(0, 5_000_000 ether);
        uint256 aId = _agent(alice, 10);
        uint32 e0 = ag.currentEpoch();
        vm.prank(alice); ag.attack(aId); vrf.fulfill(vrf.lastId(), 1);
        vm.warp(block.timestamp + 8 hours); ag.settle(e0);
        vm.warp(block.timestamp + 91 * 8 hours);
        for (uint32 x = e0 + 1; x < ag.currentEpoch(); x++) ag.settle(x);    // sequential empties
        ag.sweepStale(e0);
        uint256 bId = _agent(bob, 10);
        uint32 e2 = ag.currentEpoch();
        vm.prank(bob); ag.attack(bId); vrf.fulfill(vrf.lastId(), 1);
        vm.warp(block.timestamp + 8 hours); ag.settle(e2);
        uint256 bobPrize = ag.pending(bId, e2);
        vm.prank(alice); vm.expectRevert(bytes("empty")); ag.claim(aId, e0);
        uint256 bb = k.balanceOf(bob); vm.prank(bob); ag.claim(bId, e2);
        assertApproxEqAbs(k.balanceOf(bob) - bb, bobPrize, 1e6, "bob paid in full");
    }

    // F3 BLOCKED: cumulative ledger — the unwrap loop cannot exceed the cap in one wallet
    function testF3_CumulativeLaunchCap() public {
        WRacks w = new WRacks(address(k)); k.setTaxExempt(address(w), true); k.setWrapper(address(w));
        address pool = address(0x9001); w.setCapExempt(pool, true);
        k.mint(address(this), 1_000_000 ether); k.approve(address(w), type(uint256).max);
        IW(address(w)).wrap(900_000 ether); IW(address(w)).transfer(pool, 800_000 ether);
        k.enableTrading();                                                    // cap = 110,000
        address sniper = address(0x5A1);
        vm.prank(pool); IW(address(w)).transfer(sniper, 100_000 ether);      // 1st buy ok
        uint256 bal = IW(address(w)).balanceOf(sniper); vm.prank(sniper); IW(address(w)).unwrap(bal);
        vm.prank(pool); vm.expectRevert(bytes("max wallet")); IW(address(w)).transfer(sniper, 100_000 ether); // 2nd blocked
        // transfer-away does not reset it either
        vm.prank(sniper); k.transfer(address(0xA17), k.balanceOf(sniper));
        vm.prank(pool); vm.expectRevert(bytes("max wallet")); IW(address(w)).transfer(sniper, 100_000 ether);
        assertLe(k.launchReceived(sniper), k.maxWallet());
    }

    // F6 BLOCKED: codeless oracle rejected by the tax hook's setter
    function testF6_CodelessOracleRejected() public {
        TaxHook hook = new TaxHook(address(0x1), address(0x2), address(k), address(0x3));
        vm.expectRevert(bytes("no code")); hook.setOracle(address(0xBEEF));
    }

    // F7: expired dust is pruned from the active list; potLive can be paged
    function testF7_ExpiredDustPruned() public {
        for (uint i; i < 5; i++) {
            address d = address(uint160(0x7000 + i)); k.mint(d, 1_000 ether); usdg.mint(d, 10 ether);
            vm.startPrank(d); k.approve(address(v), type(uint256).max); usdg.approve(address(v), type(uint256).max);
            v.lock(0, 1_000 ether); vm.stopPrank();                         // exactly MIN_LOCK
        }
        assertEq(v.activeCount(), 5);
        vm.warp(block.timestamp + 1 days + 5 days); k.poke();               // expired + melted below floor
        v.harvestAll();
        assertEq(v.activeCount(), 0, "expired dust pruned");
        (uint256 live, uint256 next) = v.potLiveRange(0, 100);
        assertEq(next, 0);
    }

    // F8 BLOCKED: cannot exceed MAX_PER_WALLET via transfers
    function testF8_TransferCapEnforced() public {
        for (uint i; i < 10; i++) _agent(alice, 10);
        uint256 bId = _agent(bob, 10);
        vm.prank(bob); vm.expectRevert(bytes("max agents")); ag.transferFrom(bob, alice, bId);
    }

    // F9: an unrevealed zombie can be reaped after LIFE
    function testF9_UnrevealedZombieReapable() public {
        vm.prank(alice); uint256 id = ag.mint();                              // VRF never answers
        assertEq(ag.livingCount(), 1);
        vm.warp(block.timestamp + 3 days + 1);
        ag.reap(id);
        assertEq(ag.livingCount(), 0, "zombie reaped");
    }
}
