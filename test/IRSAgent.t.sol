// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {IRSAgent} from "../src/IRSAgent.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockVRF} from "./MockVRF.sol";

contract AgentTest is Test {
    Racks k;
    CaymanIslands vault;
    IRSAgent agent;
    MockERC20 usdg;
    MockVRF vrf;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA401); // pot funder (short-vault)
    address reserve = address(0x5E5E5E);
    uint256 constant RAY = 1e27;

    function setUp() public {
        k = new Racks(RAY / 1e6);
        usdg = new MockERC20();
        vrf = new MockVRF();
        vault = new CaymanIslands(address(k), address(usdg), reserve);
        agent = new IRSAgent(address(usdg), address(vault), address(vrf), reserve);

        k.setExempt(address(vault), true);
        k.setVault(address(vault));
        vault.setAgent(address(agent));

        // players get USDG to mint/feed
        usdg.mint(alice, 100_000 ether);
        usdg.mint(bob, 100_000 ether);
        vm.prank(alice); usdg.approve(address(agent), type(uint256).max);
        vm.prank(bob); usdg.approve(address(agent), type(uint256).max);

        // carol funds the pot: lock 1M in the 1-day bucket, let it bleed
        k.mint(carol, 1_000_000 ether);
        usdg.mint(carol, 100 ether);
        vm.startPrank(carol);
        k.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        vault.lock(0, 1_000_000 ether); // 1-day tier
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days); // ~2% bleeds into the pot
    }

    function _mintTier(address who, uint8 tier) internal returns (uint256 id) {
        vm.prank(who);
        id = agent.mint();
        uint256 word = tier == 0 ? 10 : (tier == 1 ? 80 : 97); // <75 T1, <95 T2, else T3
        vrf.fulfill(vrf.lastId(), word);
    }

    function _attack(address who, uint256 id, bool hit) internal {
        vm.prank(who);
        agent.attack(id);
        vrf.fulfill(vrf.lastId(), hit ? 0 : 99); // 0 always hits, 99 always misses
    }

    function testMintCapAndPayment() public {
        uint256 before = usdg.balanceOf(reserve); // carol's lock fee already sits here
        for (uint256 i; i < 10; i++) { vm.prank(alice); agent.mint(); }
        assertEq(usdg.balanceOf(reserve) - before, 990 ether); // 99 * 10
        vm.prank(alice);
        vm.expectRevert(bytes("wallet cap"));
        agent.mint();
    }

    function testTierReveal() public {
        uint256 t1 = _mintTier(alice, 0);
        uint256 t2 = _mintTier(alice, 1);
        uint256 t3 = _mintTier(alice, 2);
        (uint8 tierA,,,,) = agent.agents(t1);
        (uint8 tierB,,,,) = agent.agents(t2);
        (uint8 tierC,,,,) = agent.agents(t3);
        assertEq(tierA, 0);
        assertEq(tierB, 1);
        assertEq(tierC, 2);
    }

    function testAttackOncePerEpoch() public {
        uint256 id = _mintTier(alice, 0);
        _attack(alice, id, true);
        vm.prank(alice);
        vm.expectRevert(bytes("cooldown"));
        agent.attack(id);
    }

    // core economics: T1 (w=4) and T3 (w=144) both hit the same epoch -> loot splits 4:144
    function testPariMutuelSplit() public {
        uint32 e = agent.currentEpoch();
        uint256 aId = _mintTier(alice, 0); // T1
        uint256 bId = _mintTier(bob, 2);   // T3
        _attack(alice, aId, true);
        _attack(bob, bId, true);

        vm.warp(block.timestamp + 8 hours); // close the epoch
        uint256 potAtSettle = vault.potLive();   // settle auto-harvests, so it distributes the LIVE pot
        agent.settle(e);

        uint256 pa = agent.pending(aId, e);
        uint256 pb = agent.pending(bId, e);
        assertApproxEqRel(pb, (pa * 144) / 4, 0.001e18);   // weight ratio
        assertApproxEqRel(pa + pb, potAtSettle, 0.001e18); // whole prize distributed

        vm.prank(alice); agent.claim(aId, e);
        vm.prank(bob); agent.claim(bId, e);
        assertApproxEqAbs(k.balanceOf(alice), pa, 1e12); // winners receive RACKS from the pot
        assertApproxEqAbs(k.balanceOf(bob), pb, 1e12);
    }

    // a miss earns no shares
    function testMissEarnsNothing() public {
        uint32 e = agent.currentEpoch();
        uint256 id = _mintTier(alice, 0);
        _attack(alice, id, false); // miss
        vm.warp(block.timestamp + 8 hours);
        agent.settle(e);
        assertEq(agent.pending(id, e), 0);
    }

    function testFeedAndDeath() public {
        uint256 id = _mintTier(alice, 0);
        assertTrue(agent.alive(id));
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice); agent.feed(id);          // pays FEED[0] = $10
        vm.warp(block.timestamp + 2 days);
        assertTrue(agent.alive(id));               // still alive (fed 2 days ago)
        vm.warp(block.timestamp + 2 days);          // now 4 days since last feed
        assertFalse(agent.alive(id));
        vm.prank(alice);
        vm.expectRevert(bytes("dead"));
        agent.attack(id);
    }

    function testReapFreesCap() public {
        uint256 id = _mintTier(alice, 0);
        uint256 lc = agent.livingCount();
        uint256 owned = agent.ownedLiving(alice);
        vm.warp(block.timestamp + 3 days + 1);
        agent.reap(id);
        assertEq(agent.livingCount(), lc - 1);
        assertEq(agent.ownedLiving(alice), owned - 1);
    }

    // transferring an IRS Agent NFT moves the wallet-cap slot and control
    function testAgentTransfer() public {
        uint256 id = _mintTier(alice, 0);
        assertEq(agent.ownerOf(id), alice);
        assertEq(agent.ownedLiving(alice), 1);
        vm.prank(alice);
        agent.transferFrom(alice, bob, id);
        assertEq(agent.ownerOf(id), bob);
        assertEq(agent.ownedLiving(alice), 0);
        assertEq(agent.ownedLiving(bob), 1);
        // bob now controls it; alice cannot
        vm.prank(alice);
        vm.expectRevert(bytes("!owner"));
        agent.attack(id);
        vm.prank(bob);
        agent.attack(id); // works
    }
}
