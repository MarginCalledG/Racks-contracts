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
    /// close epoch e: step 1 fixes a future block, step 2 (next block) freezes its hash
    function _close(uint32 e) internal {
        vm.warp(agent.epochEnd(e)); vm.roll(block.number + 1);
        src.captureClose(e);                          // step 1: closeBlock = next block
        vm.roll(block.number + 2);
        src.captureClose(e);                          // step 2: hash now exists, freeze it
    }
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
        vm.warp(agent.epochEnd(e));
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
        vm.warp(agent.epochEnd(e));
        vm.prank(keeper); vm.expectRevert(bytes("epoch over")); src.reveal(e, chain[nextIdx]);   // C6
    }

    // C1: the first toucher fixes a FUTURE block, whose hash nobody knows; the freezer cannot choose it.
    // A grinder who touches at a moment of his choosing gets nothing: the hash is decided later.
    function testC1_FirstToucherCannotPickTheHash() public {
        uint32 e = agent.currentEpoch(); _revealNow(e);
        vm.warp(agent.epochEnd(e)); vm.roll(block.number + 1);
        // grinder "waits" for a block it likes, then touches — all it can fix is a number in the future
        vm.roll(block.number + 185);
        vm.prank(address(0x6B1E)); src.captureClose(e);
        uint256 cb = src.closeBlock(e);
        assertEq(cb, block.number + 1, "step 1 fixes the NEXT block, not a known one");
        assertEq(src.closeHash(e), bytes32(0), "nothing frozen yet: the hash does not exist");
        // touching again in the same block changes nothing
        vm.prank(address(0x6B1E)); src.captureClose(e);
        assertEq(src.closeBlock(e), cb);
        // step 2 in a later block freezes exactly blockhash(cb) — whoever calls it
        vm.roll(cb + 1);
        vm.prank(address(0xA99)); src.captureClose(e);
        assertEq(src.closeHash(e), blockhash(cb), "frozen hash is the predetermined block's");
        // and it is final
        vm.roll(block.number + 5); src.captureClose(e);
        assertEq(src.closeHash(e), blockhash(cb));
    }

    // C1: if the 256-block window lapses, a NEW future block is fixed — still unknowable, no re-roll of a known value
    function testC1_ExpiredWindowRefixesFutureBlock() public {
        uint32 e = agent.currentEpoch(); _revealNow(e);
        vm.warp(agent.epochEnd(e)); vm.roll(block.number + 1);
        src.captureClose(e); uint256 cb1 = src.closeBlock(e);
        vm.roll(cb1 + 300);                                    // nobody froze it in time
        src.captureClose(e);
        assertEq(src.closeBlock(e), block.number + 1, "re-fixed to a future block");
        assertEq(src.closeHash(e), bytes32(0));
        vm.roll(block.number + 2); src.captureClose(e);
        assertTrue(src.closeHash(e) != bytes32(0)); cb1;
    }

    // C5: reap must not block the mint refund
    function testC5_ReapDoesNotBlockRefund() public {
        vm.prank(alice); uint256 id = agent.mint();
        usdg.mint(address(0x8E5E), 1_000 ether); vm.prank(address(0x8E5E)); usdg.approve(address(agent), type(uint256).max);
        vm.warp(block.timestamp + 3 days + 1); agent.reap(id);          // griefer reaps at day 3
        vm.warp(block.timestamp + 4 days);
        uint256 before = usdg.balanceOf(alice);
        agent.reclaimUnrevealed(id);                                   // refund at day 7+ still works
        assertEq(usdg.balanceOf(alice) - before, 99 ether);
        vm.expectRevert(bytes("n/a")); agent.reclaimUnrevealed(id);    // one-shot
    }
}
