// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {IRSAgent} from "../src/IRSAgent.sol";
import {TwapOracle} from "../src/TwapOracle.sol";
import {TaxSwapper} from "../src/TaxSwapper.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockVRF} from "./MockVRF.sol";
import {MockPair} from "./MockPair.sol";
import {MockRouter, MockPrice} from "./MockSwap.sol";

/// End-to-end journey against the fully-wired stack (mirrors Deploy.s.sol wiring).
contract IntegrationTest is Test {
    Racks racks; CaymanIslands vault; IRSAgent agents; TwapOracle twap; TaxSwapper swapper;
    MockERC20 usdg; MockERC20 spy; MockVRF vrf; MockPair pair; MockRouter router; MockPrice price;
    address alice = address(0xA11CE);
    address carol = address(0xCA401);
    address reserve = address(0x5E5E5E);
    uint256 constant RAY = 1e27;

    function setUp() public {
        usdg = new MockERC20(); spy = new MockERC20(); vrf = new MockVRF();
        pair = new MockPair(); pair.set(1_000_000 ether, 500_000 ether);
        router = new MockRouter(address(spy), 1, 2); price = new MockPrice(1, 2);

        racks = new Racks(RAY / 1e6);
        vault = new CaymanIslands(address(racks), address(usdg), reserve);
        agents = new IRSAgent(address(usdg), address(vault), address(vrf), reserve);
        twap = new TwapOracle(address(pair));
        swapper = new TaxSwapper(address(racks), address(spy), address(router), address(price), reserve, 1000 ether, 300);

        racks.setVault(address(vault));
        racks.setExempt(address(vault), true);
        vault.setAgent(address(agents));
        racks.setTaxWallet(address(swapper));
        racks.setExempt(address(swapper), true);
        racks.setTaxExempt(address(swapper), true);
        racks.setTaxOracle(address(twap));
        racks.setDex(address(pair), true);
        racks.setTaxExempt(address(vault), true);
        racks.setTaxExempt(address(agents), true);
    }

    function testFullUserJourney() public {
        racks.mint(alice, 1_000_000 ether);
        racks.mint(carol, 1_000_000 ether);
        usdg.mint(alice, 10_000 ether);
        usdg.mint(carol, 10_000 ether);

        // carol goes offshore (1-day) -> seeds the audit pool via bleed
        vm.startPrank(carol);
        racks.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        vault.lock(0, 500_000 ether);
        vm.stopPrank();

        // alice sells into the pool -> tax accrues in the swapper
        vm.prank(alice);
        racks.transfer(address(pair), 100_000 ether);
        assertGt(racks.balanceOf(address(swapper)), 0);

        // swapper auto-converts tax -> SPY -> reserve
        swapper.swap();
        assertGt(spy.balanceOf(reserve), 0);

        // pool bleeds into the pot
        vm.warp(block.timestamp + 1 days);
        vault.harvest(carol, 0);                     // carol is the short-locker; settle her bleed
        assertGt(vault.potBalance(), 0);

        // alice deploys an IRS Agent, audits, claims
        uint32 e = agents.currentEpoch();
        vm.startPrank(alice);
        usdg.approve(address(agents), type(uint256).max);
        uint256 id = agents.mint();
        vm.stopPrank();
        vrf.fulfill(vrf.lastId(), 97);       // special tier
        vm.prank(alice); agents.attack(id);
        vrf.fulfill(vrf.lastId(), 0);        // audit hits
        vm.warp(block.timestamp + 8 hours);
        agents.settle(e);
        assertGt(agents.pending(id, e), 0);
        vm.prank(alice); agents.claim(id, e);
        assertGt(racks.balanceOf(alice), 0); // won RACKS from the pot
    }
}
