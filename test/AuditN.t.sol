// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {IRSAgent} from "../src/IRSAgent.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockVRF} from "./MockVRF.sol";

/// A custodial fee-router like the sniper bots use: takes tokens, keeps a cut, forwards the rest.
contract FeeRouter {
    Racks k;
    constructor(Racks _k) { k = _k; }
    function buyFor(address pool, address user, uint256 amt) external {
        // pool -> router (delivery), router -> user (forward)
        k.transferFrom(pool, address(this), amt);
        k.transfer(user, k.balanceOf(address(this)));
    }
}

contract AuditN is Test {
    Racks k; address pool = address(0xB0001); address alice = address(0xA11CE);
    function setUp() public { k = new Racks(1e27/1e6); k.mint(address(this), 100_000_000 ether); }

    // N1 BLOCKED: after renouncing, the owner can no longer exempt or de-exempt anything
    function testN1_RenounceActuallyBinds() public {
        k.setExempt(pool, true);
        k.renounceExemptControl();
        vm.expectRevert(bytes("renounced")); k.setExempt(pool, false);
        vm.expectRevert(bytes("renounced")); k.setExempt(address(0xBEEF), true);
        assertTrue(k.isExempt(pool), "pair stays exempt - rug vector closed");
    }

    // N2 BLOCKED: no pool trading before enableTrading, but LP seeding (tax-exempt) still works
    function testN2_TradingGate() public {
        k.setTaxExempt(address(this), true);
        k.setExempt(pool, true); k.setPair(pool);
        k.transfer(pool, 50_000_000 ether);                    // seeding LP: allowed
        assertEq(k.balanceOf(pool), 50_000_000 ether, "LP seeding works before launch");
        vm.prank(pool); vm.expectRevert(bytes("not started"));
        k.transfer(alice, 20_000_000 ether);                   // sniper: blocked
        k.enableTrading();
        vm.prank(pool); k.transfer(alice, 500_000 ether);      // after launch: works, and is capped
        assertGt(k.launchReceived(alice), 0, "now the ledger sees it");
    }

    // N11 BLOCKED: a shared custodial router no longer accumulates everyone's volume
    function testN11_SharedRouterWorks() public {
        k.setExempt(pool, true); k.setPair(pool);
        k.setTaxExempt(address(this), true);
        k.transfer(pool, 50_000_000 ether);
        k.enableTrading();                                // cap = 1% = 1,000,000
        FeeRouter r = new FeeRouter(k);
        vm.prank(pool); k.approve(address(r), type(uint256).max);
        uint256 chunk = 300_000 ether;                    // 0.3% each, well under the cap
        // each user drives their own tx (msg.sender AND tx.origin = that user)
        for (uint160 i = 1; i <= 5; i++) {
            address u = address(i);
            vm.prank(u, u);
            r.buyFor(pool, u, chunk);
        }
        emit log_named_uint("router ledger (must stay 0)", k.launchReceived(address(r)));
        assertEq(k.launchReceived(address(r)), 0, "router must not accumulate");
        assertGt(k.balanceOf(address(0x5)), 0, "5th user still gets through");
    }

    // N3 BLOCKED: settle is O(1) regardless of how many empty epochs came before
    function testN3_SettleIsConstantGas() public {
        MockERC20 usdg = new MockERC20(); MockVRF vrf = new MockVRF();
        CaymanIslands v = new CaymanIslands(address(k), address(usdg), address(this));
        IRSAgent ag = new IRSAgent(address(usdg), address(v), address(vrf), address(this));
        ag.setPaused(false);   // MockVRF has code; casino starts paused by default
        v.setAgent(address(ag));
        vm.warp(block.timestamp + 3000 * 8 hours);        // ~2.7 years of empty epochs
        uint32 e = ag.currentEpoch() - 1;
        uint256 g0 = gasleft();
        ag.settle(e);
        uint256 used = g0 - gasleft();
        emit log_named_uint("gas for settle after 3000 empty epochs", used);
        assertLt(used, 200_000, "settle must be O(1)");
        assertTrue(ag.settled(e));
        assertTrue(ag.settled(e - 2000), "older epochs count as settled without storage writes");
    }
}
