// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {IRSAgent} from "../src/IRSAgent.sol";
import {HashChainSeed} from "../src/HashChainSeed.sol";
import {MockERC20} from "./MockERC20.sol";

/// The reveal-then-play source, end to end, including the K1 grinding attempt.
contract HashChainSeedTest is Test {
    Racks k; CaymanIslands vault; IRSAgent agent; HashChainSeed src; MockERC20 usdg;
    address keeper = address(0xEE1); address alice = address(0xA11CE); address locker = address(0x10C);
    bytes32[] chain; uint256 constant N = 30; uint256 nextIdx;

    function setUp() public {
        k = new Racks(1e27/1e6); usdg = new MockERC20();
        vault = new CaymanIslands(address(k), address(usdg), address(0x8E5E));
        src = new HashChainSeed(address(k), address(vault), address(0), 10_000 ether);
        agent = new IRSAgent(address(usdg), address(vault), address(src), address(0x8E5E));
        src.setAgent(address(agent)); src.setKeeper(keeper); agent.setPaused(false);
        k.setVault(address(vault)); k.setExempt(address(vault), true); k.setTaxExempt(address(vault), true);
        k.setExempt(address(src), true); vault.setAgent(address(agent)); k.setTaxExempt(address(agent), true);
        chain.push(keccak256("root-secret"));
        for (uint256 i; i < N; i++) chain.push(keccak256(abi.encodePacked(chain[i])));
        vm.prank(keeper); src.commit(chain[N], N); nextIdx = N - 1;
        k.mint(keeper, 10_000_000 ether); vm.prank(keeper); k.approve(address(src), type(uint256).max);
        vm.prank(keeper); src.depositBond(5_000_000 ether);        // covers a big pot
        k.mint(locker, 10_000_000 ether); usdg.mint(locker, 1_000 ether); usdg.mint(alice, 1_000 ether); usdg.mint(keeper, 5_000 ether);
        vm.startPrank(locker); k.approve(address(vault), type(uint256).max); usdg.approve(address(vault), type(uint256).max);
        vault.lock(0, 5_000_000 ether); vm.stopPrank();   // 1d tier bleeds fast
        vm.prank(alice); usdg.approve(address(agent), type(uint256).max);
        vm.prank(keeper); usdg.approve(address(agent), type(uint256).max);
        vm.roll(1000);
    }
    function _revealNow(uint32 e) internal { vm.prank(keeper); src.reveal(e, chain[nextIdx]); nextIdx--; }
    /// close epoch e: move past its end, capture entropy in the "first touch" block
    function _close(uint32 e) internal { vm.warp(agent.epochEnd(e)); vm.roll(block.number + 1); src.captureClose(e); }
    function _next() internal { vm.warp(block.timestamp + 8 hours); vm.roll(block.number + 10); }

    // reveal at epoch START is allowed; the value alone decides nothing until the close hash exists
    function testRevealThenPlay() public {
        uint32 e = agent.currentEpoch();
        _revealNow(e);                                               // public from now on
        assertEq(src.seed(e), bytes32(0), "no seed before the epoch closes");
        _close(e);
        assertTrue(src.seed(e) != bytes32(0), "seed = preimage + post-close entropy");
    }

    // K1: the keeper cannot steer the seed by adding its own attacks (there is no attacker input)
    function testK1_KeeperCannotGrindTheSeed() public {
        uint32 e0 = agent.currentEpoch(); _revealNow(e0);
        vm.prank(keeper); uint256 kid = agent.mint(); vm.prank(alice); uint256 aid = agent.mint();
        _close(e0); _next();
        uint32 e = agent.currentEpoch(); _revealNow(e);
        vm.prank(alice); agent.attack(aid);
        bytes32 before = keccak256(abi.encode(src.preimage(e)));    // everything the keeper can know now
        vm.prank(keeper); agent.attack(kid);                        // keeper "grinds" with its own attack
        // the seed depends only on the preimage and the post-close block: attacking changed nothing
        _close(e);
        assertEq(src.seed(e), keccak256(abi.encode(src.preimage(e), src.closeHash(e))));
        assertTrue(src.closeHash(e) != bytes32(0)); before;
    }

    // full flow with the real source
    function testFullFlow() public {
        uint32 e0 = agent.currentEpoch(); _revealNow(e0);
        vm.prank(alice); uint256 id = agent.mint();
        _close(e0); _next();
        assertTrue(agent.revealed(id));
        bool paid;
        for (uint256 i; i < 15 && !paid; i++) {
            uint32 e = agent.currentEpoch(); _revealNow(e);
            vm.prank(alice); agent.feed(id); vm.prank(alice); agent.attack(id);
            _close(e); _next();
            agent.settle(e);
            if (agent.pending(id, e) > 0) { vm.prank(alice); agent.claim(id, e); paid = true; }
        }
        assertTrue(paid);
    }

    // K2: withholding costs at least the pot; underbonded keeper -> attacks refused
    function testK2_SlashIsPotRelativeAndGatesPlay() public {
        uint32 e0 = agent.currentEpoch(); _revealNow(e0);
        vm.prank(alice); uint256 id = agent.mint(); _close(e0); _next();
        vault.harvestAll();
        uint256 pot = vault.potBalance(); assertGt(pot, 10_000 ether, "pot above the floor");
        assertEq(src.slashAmount(), pot, "slash tracks the pot");
        // keeper withholds this epoch
        uint32 e = agent.currentEpoch(); vm.prank(alice); agent.attack(id);
        vm.warp(agent.epochEnd(e) + 2 hours);
        uint256 bond0 = src.bond();
        src.slash(e);
        assertEq(bond0 - src.bond(), pot, "slashed exactly the pot");
        // drain the bond below cover -> nobody can attack until it is topped up
        uint256 b = src.bond(); uint256 cover = src.slashAmount();
        vm.prank(keeper); vm.expectRevert(bytes("keep cover")); src.withdrawBond(b);
        vm.prank(keeper); src.withdrawBond(b - cover);
        // simulate pot growth beyond cover
        address funder = address(0xF0D); k.mint(funder, 10_000_000 ether);
        vm.startPrank(funder); k.approve(address(vault), type(uint256).max); vault.fundPot(k.balanceOf(funder)); vm.stopPrank();
        assertFalse(src.bondOk());
        _next(); vm.prank(alice); agent.feed(id);
        vm.prank(alice); vm.expectRevert(bytes("keeper underbonded")); agent.attack(id);
    }

    // K3: a mint the source never reveals can be reclaimed with the fee refunded
    function testK3_UnrevealedMintRefund() public {
        vm.prank(alice); uint256 id = agent.mint();                 // nobody ever reveals
        usdg.mint(address(0x8E5E), 1_000 ether); vm.prank(address(0x8E5E)); usdg.approve(address(agent), type(uint256).max);
        vm.warp(block.timestamp + 7 days + 1);
        uint256 before = usdg.balanceOf(alice);
        agent.reclaimUnrevealed(id);
        assertEq(usdg.balanceOf(alice) - before, 99 ether, "fee refunded");
        assertEq(agent.livingCount(), 0);
    }

    function testRevealNotBeforeStartNotAfterWindow() public {
        uint32 e = agent.currentEpoch();
        vm.prank(keeper); vm.expectRevert(bytes("not started")); src.reveal(e + 1, chain[nextIdx]);
        vm.warp(agent.epochEnd(e) + 2 hours);
        vm.prank(keeper); vm.expectRevert(bytes("window closed")); src.reveal(e, chain[nextIdx]);
    }
}
