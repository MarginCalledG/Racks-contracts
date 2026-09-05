// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {MockERC20} from "./MockERC20.sol";

contract CaymanTest is Test {
    Racks k;
    CaymanIslands vault;
    MockERC20 usdg;
    address alice = address(0xA11CE);
    address reserve = address(0x5E5E5E);
    address winner = address(0x111);
    uint256 constant RAY = 1e27;

    function setUp() public {
        k = new Racks(RAY / 1e6);
        usdg = new MockERC20();
        vault = new CaymanIslands(address(k), address(usdg), reserve);
        k.setExempt(address(vault), true);
        k.setVault(address(vault));

        k.mint(alice, 1_000_000 ether);
        usdg.mint(alice, 1_000 ether);
        vm.startPrank(alice);
        k.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    // 14-day lock: 0 bleed, protected from global melt
    function testFullProtection() public {
        vm.prank(alice);
        vault.lock(2, 100_000 ether); // tier 2 = 14-day
        vm.warp(block.timestamp + 14 days);
        assertApproxEqRel(vault.claimOf(alice, 2), 100_000 ether, 0.0001e18); // intact
        assertLt(k.balanceOf(alice), 900_000 ether);                          // unlocked melted

        uint256 balBefore = k.balanceOf(alice);
        vm.prank(alice);
        vault.unlock(2);
        assertApproxEqRel(k.balanceOf(alice) - balBefore, 100_000 ether, 0.0001e18); // got ~100k back
    }

    function testCannotUnlockEarly() public {
        vm.prank(alice);
        vault.lock(0, 100_000 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("locked"));
        vault.unlock(0);
    }

    // 1-day bucket bleeds 2%/day into the pot
    function testOneDayBleedToPot() public {
        vm.prank(alice);
        vault.lock(0, 100_000 ether);
        assertEq(vault.potBalance(), 0);
        vm.warp(block.timestamp + 1 days);
        assertApproxEqRel(vault.claimOf(alice, 0), 98_000 ether, 0.002e18);
        assertApproxEqRel(vault.potBalance(), 2_000 ether, 0.02e18);
    }

    // 3-day bucket bleeds 1.5%/day
    function testThreeDayBleed() public {
        vm.prank(alice);
        vault.lock(1, 100_000 ether);
        vm.warp(block.timestamp + 1 days);
        assertApproxEqRel(vault.potBalance(), 1_500 ether, 0.02e18);
    }

    function testFeeCollected() public {
        vm.prank(alice);
        vault.lock(2, 100_000 ether); // 14-day fee = $10
        assertEq(usdg.balanceOf(reserve), 10 ether);
    }

    // locking reduces free float -> after smoothing, Racks rate drops
    function testLockedSupplyFeedsRate() public {
        uint256 rBefore = k.ratePerDayBps();
        vm.prank(alice);
        vault.lock(2, 900_000 ether);
        vm.warp(block.timestamp + 1 days);
        k.poke();
        assertLt(k.ratePerDayBps(), rBefore - 100);
    }

    // Stage 3 hook: agent draws loot from the pot
    function testDrawPot() public {
        vault.setAgent(address(this));
        vm.prank(alice);
        vault.lock(0, 100_000 ether);
        vm.warp(block.timestamp + 1 days);
        uint256 pot = vault.potBalance();
        assertGt(pot, 0);
        vault.drawPot(winner, pot / 2);
        assertApproxEqAbs(k.balanceOf(winner), pot / 2, 1e6);
        assertApproxEqRel(vault.potBalance(), pot / 2, 0.01e18);
    }

    function testUnlockReturnsBledClaim() public {
        vm.prank(alice);
        vault.lock(0, 100_000 ether);
        vm.warp(block.timestamp + 1 days);
        uint256 claim = vault.claimOf(alice, 0);
        uint256 balBefore = k.balanceOf(alice); // her (melted) unlocked balance
        vm.prank(alice);
        vault.unlock(0);
        // she receives exactly the bled claim on top of her current balance
        assertApproxEqAbs(k.balanceOf(alice) - balBefore, claim, 1e12);
    }

    // an expired 14-day position bleeds to the pot at 2%/day until withdrawn/relocked
    function testPostExpiryPenalty() public {
        vm.prank(alice);
        vault.lock(2, 100_000 ether);         // 14-day, 0 bleed while locked
        vm.warp(block.timestamp + 14 days + 3 days); // 3 days past expiry
        vm.prank(alice);
        vault.unlock(2);
        // ~6% penalty (3d * 2%/day) stayed in the vault as pot
        assertApproxEqRel(vault.potBalance(), 6_000 ether, 0.02e18);
    }
}
