// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {WRacks} from "../src/WRacks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {IRSAgent} from "../src/IRSAgent.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockVRF} from "./MockVRF.sol";

interface IW { function wrap(uint256) external returns (uint256); function unwrap(uint256) external returns (uint256); function balanceOf(address) external view returns (uint256); function setTaxOracle(address) external; function setTaxWallet(address) external; }
contract RevertingOracle { function update() external pure { revert("boom"); } function taxBps(uint256, bool) external pure returns (uint256) { revert("boom"); } }

/// Audit regression suite: every exploit found must now be BLOCKED.
contract AuditFixes is Test {
    Racks k; WRacks w; address wa;
    address attacker = address(0xBAD);
    address victim   = address(0xB1C);
    uint256 constant RAY = 1e27;

    function setUp() public {
        k = new Racks(RAY / 1e6);
        w = new WRacks(address(k)); wa = address(w);
        k.setTaxExempt(wa, true);
        k.mint(attacker, 2_000_000 ether);
        k.mint(victim,   1_000_000 ether);
        vm.prank(attacker); k.approve(wa, type(uint256).max);
        vm.prank(victim);   k.approve(wa, type(uint256).max);
    }

    // W1: share-inflation attack is now unprofitable; victim gets fair shares
    function testFixed_ShareInflationBlocked() public {
        vm.startPrank(attacker);
        IW(wa).wrap(2000);                                // first wrap: 1000 dead + 1000 to attacker
        k.transfer(wa, 1_000_000 ether);                  // donate to inflate
        vm.stopPrank();
        vm.prank(victim);
        uint256 vs = IW(wa).wrap(500_000 ether);
        assertGt(vs, 0, "victim must get shares");
        uint256 atkShares = IW(wa).balanceOf(attacker);
        vm.prank(attacker);
        IW(wa).unwrap(atkShares);
        // attacker gave 1e24 + 2000 and cannot get more than a fair pro-rata slice back
        assertLt(k.balanceOf(attacker), 2_000_000 ether, "attacker must LOSE money on the attack");
        // victim can redeem ~what they put in
        uint256 vShares = IW(wa).balanceOf(victim);
        vm.prank(victim);
        uint256 back = IW(wa).unwrap(vShares);
        assertGt(back, 500_000 ether * 99 / 100, "victim keeps ~all their deposit");
    }

    // W1: tiny first deposit (<= dead shares) is rejected
    function testFixed_TinyFirstWrapRejected() public {
        vm.prank(attacker);
        vm.expectRevert(bytes("too small"));
        IW(wa).wrap(1);
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

    // W5: a reverting oracle no longer bricks wrap/unwrap (falls back to flat rate)
    function testFixed_RevertingOracleDoesNotBrick() public {
        w.setTaxWallet(address(0x7A11)); k.setExempt(address(0x7A11), true);
        w.setTaxOracle(address(new RevertingOracle()));
        vm.prank(attacker); uint256 sh = IW(wa).wrap(10_000 ether);   // must not revert
        assertGt(sh, 0);
        assertEq(k.balanceOf(address(0x7A11)), 400 ether);            // fell back to 4% flat
        vm.prank(attacker); IW(wa).unwrap(sh);                         // must not revert
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
        vm.prank(address(vrf));
        vm.expectRevert(bytes("unknown req"));
        ag.rawFulfill(999, 42);
    }

    // A5: an epoch's unclaimed prize is swept back into the pot after the claim window
    function testFixed_StaleUnclaimedPrizeSwept() public {
        MockERC20 usdg = new MockERC20(); MockVRF vrf = new MockVRF();
        CaymanIslands vault = new CaymanIslands(address(k), address(usdg), address(this));
        IRSAgent ag = new IRSAgent(address(usdg), address(vault), address(vrf), address(this));
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
