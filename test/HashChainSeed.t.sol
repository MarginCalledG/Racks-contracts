// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {IRSAgent} from "../src/IRSAgent.sol";
import {HashChainSeed} from "../src/HashChainSeed.sol";
import {MockERC20} from "./MockERC20.sol";

/// The real randomness source, end to end with the real agent and vault.
contract HashChainSeedTest is Test {
    Racks k; CaymanIslands vault; IRSAgent agent; HashChainSeed src; MockERC20 usdg;
    address keeper = address(0xEE1); address alice = address(0xA11CE); address locker = address(0x10C);
    bytes32[] chain;   // chain[0] = secret root ... chain[N] = committed end
    uint256 constant N = 20;
    uint256 nextIdx;   // index of the next preimage to reveal (from the end backwards)

    function setUp() public {
        k = new Racks(1e27/1e6); usdg = new MockERC20();
        vault = new CaymanIslands(address(k), address(usdg), address(0x8E5E));
        // agent needs the seed source address; source needs the agent -> deploy agent with a placeholder
        // then create the source and swap it in via the (timelocked) admin path is overkill for a test:
        // deploy source first with agent = 0, then the agent, then setAgent on the source (one-shot).
        src = new HashChainSeed(address(k), address(vault), address(0), 10_000 ether);
        agent = new IRSAgent(address(usdg), address(vault), address(src), address(0x8E5E));
        src.setAgent(address(agent)); src.setKeeper(keeper);
        agent.setPaused(false);
        k.setVault(address(vault)); k.setExempt(address(vault), true); k.setTaxExempt(address(vault), true);
        k.setExempt(address(src), true);          // the bond must not melt
        vault.setAgent(address(agent)); k.setTaxExempt(address(agent), true);

        // keeper builds the chain off-chain and commits only the end
        chain.push(keccak256("root-secret"));
        for (uint256 i; i < N; i++) chain.push(keccak256(abi.encodePacked(chain[i])));
        vm.prank(keeper); src.commit(chain[N], N);
        nextIdx = N - 1;
        k.mint(keeper, 100_000 ether); vm.prank(keeper); k.approve(address(src), type(uint256).max);
        vm.prank(keeper); src.depositBond(50_000 ether);

        k.mint(locker, 10_000_000 ether); usdg.mint(locker, 1_000 ether); usdg.mint(alice, 1_000 ether);
        vm.startPrank(locker); k.approve(address(vault), type(uint256).max); usdg.approve(address(vault), type(uint256).max);
        vault.lock(0, 5_000_000 ether); vm.stopPrank();
        vm.prank(alice); usdg.approve(address(agent), type(uint256).max);
    }
    function _reveal(uint32 e) internal { vm.prank(keeper); src.reveal(e, chain[nextIdx]); nextIdx--; }
    function _nextEpoch() internal { vm.warp(block.timestamp + 8 hours); }

    function testRevealMustMatchChain() public {
        uint32 e = agent.currentEpoch(); _nextEpoch();
        vm.prank(keeper); vm.expectRevert(bytes("bad preimage")); src.reveal(e, keccak256("wrong"));
        _reveal(e);
        assertTrue(src.resolved(e)); assertTrue(src.seed(e) != bytes32(0));
        // the same value cannot be replayed for the next epoch
        uint32 e2 = agent.currentEpoch(); _nextEpoch();
        vm.prank(keeper); vm.expectRevert(bytes("bad preimage")); src.reveal(e2, chain[nextIdx + 1]);
    }

    function testCannotRevealOpenEpoch() public {
        uint32 e = agent.currentEpoch();
        vm.prank(keeper); vm.expectRevert(bytes("open")); src.reveal(e, chain[nextIdx]);
    }

    // full flow: mint -> reveal tier -> attack -> reveal -> settle -> claim
    function testFullFlowWithRealSource() public {
        vm.prank(alice); uint256 id = agent.mint();
        uint32 e0 = agent.currentEpoch(); _nextEpoch(); _reveal(e0);
        assertTrue(agent.revealed(id));
        uint8 t = agent.tier(id);
        // attack in the next epoch, keep going until a hit lands (tier-dependent odds)
        bool paid;
        for (uint256 i; i < 12 && !paid; i++) {
            vm.prank(alice); agent.feed(id);
            vm.prank(alice); agent.attack(id);
            uint32 e = agent.currentEpoch(); _nextEpoch(); _reveal(e);
            agent.settle(e);
            if (agent.pending(id, e) > 0) { vm.prank(alice); agent.claim(id, e); paid = true; }
        }
        emit log_named_uint("tier", t);
        assertTrue(paid, "a hit landed and was paid from the real seed");
        assertGt(k.balanceOf(alice), 0);
    }

    // keeper withholds: anyone slashes, epoch fails, bond flows into the pot, everyone misses
    function testWithholdingIsSlashedAndPaysNothing() public {
        vm.prank(alice); uint256 id = agent.mint();
        uint32 e0 = agent.currentEpoch(); _nextEpoch(); _reveal(e0);
        vm.prank(alice); agent.attack(id);
        uint32 e = agent.currentEpoch(); _nextEpoch();
        vm.expectRevert(bytes("window open")); src.slash(e);        // keeper still has time
        vm.warp(block.timestamp + 2 hours);
        uint256 pot0 = vault.potBalance(); uint256 bond0 = src.bond();
        vm.prank(address(0xA99)); src.slash(e);                       // permissionless
        assertTrue(src.failed(e));
        assertEq(src.bond(), bond0 - 10_000 ether, "bond slashed");
        assertEq(vault.potBalance(), pot0 + 10_000 ether, "slash went to the pot");
        agent.settle(e);
        assertEq(agent.pending(id, e), 0, "everyone misses in a failed epoch");
        // and the keeper cannot reveal it afterwards
        vm.prank(keeper); vm.expectRevert(bytes("done")); src.reveal(e, chain[nextIdx]);
    }

    // a mint during a failed epoch is revealed by the next good seed
    function testMintInFailedEpochRevealsLater() public {
        vm.prank(alice); uint256 id = agent.mint();
        uint32 e0 = agent.currentEpoch(); _nextEpoch(); vm.warp(block.timestamp + 2 hours);
        src.slash(e0);
        assertFalse(agent.revealed(id));
        uint32 e1 = agent.currentEpoch(); vm.warp(agent.epochEnd(e1)); _reveal(e1);   // inside e1's window
        assertTrue(agent.revealed(id), "revealed by the first later non-failed seed");
    }

    function testOnlyKeeperAndBondCover() public {
        vm.prank(alice); vm.expectRevert(bytes("!keeper")); src.reveal(0, chain[nextIdx]);
        vm.prank(keeper); vm.expectRevert(bytes("keep cover")); src.withdrawBond(50_000 ether);
        vm.prank(keeper); src.withdrawBond(30_000 ether);   // leaves 20k >= one slash
    }
}
