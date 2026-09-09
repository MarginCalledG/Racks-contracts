// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {MockERC20} from "./MockERC20.sol";

/// The melt-factor table: every position type melts at r_w * factor.
contract MeltFactors is Test {
    Racks k; CaymanIslands v; MockERC20 usdg;
    uint256 constant RAY = 1e27;

    function setUp() public {
        k = new Racks(RAY / 1e6); usdg = new MockERC20();
        v = new CaymanIslands(address(k), address(usdg), address(this));
        k.setVault(address(v)); k.setExempt(address(v), true); k.setTaxExempt(address(v), true);
        k.mint(address(this), 100_000_000 ether);
    }

    // the whole table at both ends of the band
    function testFactorTableMatchesSpec() public {
        // FF = 1 (max free float, the default) -> the 6.9% column
        uint256[5] memory expect69 = [uint256(690), 345, 207, 138, 69];  // bps/day
        string[5] memory name = ["unlocked", "LP", "lock 1d", "lock 3d", "lock 14d"];
        for (uint8 i; i < 5; i++) {
            uint256 got = k.ratePerDayBpsFor(i);
            emit log_named_uint(string.concat(name[i], " bps/day @ r_w=6.9%"), got);
            assertApproxEqAbs(got, expect69[i], 1, "factor rate off");
        }
        // the base rate function and factor 0 must agree
        assertEq(k.ratePerDayBpsFor(0), k.ratePerDayBps(), "unlocked == base rate");
    }

    // rates scale with r_w: when free float drops, every factor drops proportionally
    function testFactorsTrackTheRate() public {
        uint256 unlockedHi = k.ratePerDayBpsFor(0);
        uint256 lpHi = k.ratePerDayBpsFor(1);
        k.setLockedSupply(k.totalSupply());              // free float -> 0
        vm.warp(block.timestamp + 2 days); k.poke();     // let the 24h smoothing follow
        uint256 unlockedLo = k.ratePerDayBpsFor(0);
        uint256 lpLo = k.ratePerDayBpsFor(1);
        emit log_named_uint("unlocked hi/lo", unlockedHi); emit log_named_uint("  ", unlockedLo);
        emit log_named_uint("LP hi/lo", lpHi); emit log_named_uint("  ", lpLo);
        assertLt(unlockedLo, unlockedHi, "rate falls with free float");
        // LP stays at half of unlocked at BOTH ends
        assertApproxEqAbs(lpHi * 2, unlockedHi, 2, "LP = 0.5x at high rate");
        assertApproxEqAbs(lpLo * 2, unlockedLo, 2, "LP = 0.5x at low rate");
    }

    // a locked position now melts at its factor, and that melt feeds the agent pot
    function testLockTiersMeltAtFactorIntoPot() public {
        usdg.mint(address(this), 1000 ether); usdg.approve(address(v), type(uint256).max);
        k.approve(address(v), type(uint256).max);
        v.lock(0, 1_000_000 ether);      // 1d tier, factor 0.3 -> 2.07%/day at FF=1
        vm.warp(block.timestamp + 1 days);
        uint256 claim = v.claimOf(address(this), 0);
        uint256 bled = 1_000_000 ether - claim;
        emit log_named_uint("1d lock: bled in 24h (bps of principal)", bled * 10000 / 1_000_000 ether);
        assertApproxEqAbs(bled * 10000 / 1_000_000 ether, 207, 2, "1d tier melts 2.07%/day");
        v.harvest(address(this), 0);
        assertApproxEqAbs(v.potBalance(), bled, 1e15, "the melt went to the pot");
    }

    // the 14d tier is no longer fully protected: it melts at 0.1x and also feeds the pot
    function test14dTierMeltsAtTenPercent() public {
        usdg.mint(address(this), 1000 ether); usdg.approve(address(v), type(uint256).max);
        k.approve(address(v), type(uint256).max);
        v.lock(2, 1_000_000 ether);
        vm.warp(block.timestamp + 1 days);
        uint256 bled = 1_000_000 ether - v.claimOf(address(this), 2);
        emit log_named_uint("14d lock: bled in 24h (bps)", bled * 10000 / 1_000_000 ether);
        assertApproxEqAbs(bled * 10000 / 1_000_000 ether, 69, 2, "14d tier melts 0.69%/day");
        v.harvest(address(this), 2);
        assertGt(v.potBalance(), 0, "even the 14d tier now feeds the casino");
    }

    // locking is still strictly better than holding: 14d < 3d < 1d < unlocked
    function testLockingBeatsHolding() public {
        assertLt(k.ratePerDayBpsFor(4), k.ratePerDayBpsFor(3));
        assertLt(k.ratePerDayBpsFor(3), k.ratePerDayBpsFor(2));
        assertLt(k.ratePerDayBpsFor(2), k.ratePerDayBpsFor(1));
        assertLt(k.ratePerDayBpsFor(1), k.ratePerDayBpsFor(0));
    }
}
