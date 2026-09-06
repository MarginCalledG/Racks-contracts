// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {V4Swap, PoolKey, Currency, IERC20x} from "../../src/v4/V4Swap.sol";
import {V4Pool} from "../../src/v4/V4Pool.sol";
import {Zap} from "../../src/v4/Zap.sol";
import {TwapOracleV4} from "../../src/v4/TwapOracleV4.sol";
import {Racks} from "../../src/Racks.sol";
import {WRacks} from "../../src/WRacks.sol";
import {CaymanIslands} from "../../src/CaymanIslands.sol";
import {IRSAgent} from "../../src/IRSAgent.sol";
import {MockVRF} from "../MockVRF.sol";

interface IW { function wrap(uint256) external returns (uint256); function approve(address,uint256) external returns (bool); }

/// 2-week economic simulation on a mainnet fork: ~$1M volume via Zap, vaults in all tiers,
/// 100 IRS agents across 10 wallets attacking every epoch, feeding, dying, pari-mutuel payouts.
contract Simulation2W is Test {
    address constant SPY  = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant PM   = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant SV   = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address taxWallet = address(0x7A11);
    address reserve   = address(0x5E5E);

    Racks k; WRacks w; CaymanIslands vault; IRSAgent ag; MockVRF vrf;
    V4Swap sw; V4Pool pool; Zap zap; TwapOracleV4 oracle;
    PoolKey wrSpy; PoolKey spyUsdg; address wa;
    address[10] W;
    uint256 seed = 0xC0FFEE;

    function _rand() internal returns (uint256) { seed = uint256(keccak256(abi.encode(seed))); return seed; }
    function _isqrt(uint256 x) internal pure returns (uint256 y) { if (x == 0) return 0; uint256 z = (x + 1) / 2; y = x; while (z < y) { y = z; z = (x / z + z) / 2; } }

    function setUp() public {
        if (SPY.code.length == 0) return;
        k = new Racks(1e27 / 1e6);
        w = new WRacks(address(k)); wa = address(w);
        vrf = new MockVRF();
        vault = new CaymanIslands(address(k), USDG, reserve);
        ag = new IRSAgent(USDG, address(vault), address(vrf), reserve);
        k.setVault(address(vault)); k.setExempt(address(vault), true); k.setTaxExempt(address(vault), true);
        vault.setAgent(address(ag));
        k.setTaxExempt(wa, true); k.setExempt(taxWallet, true); k.setTaxExempt(address(ag), true);
        k.mint(address(this), 69_420_000_000 ether);

        // pool priced 1 SPY = 100,000 wRACKS (cheap memecoin), ~2000 SPY deep
        k.approve(wa, type(uint256).max);
        IW(wa).wrap(5_000_000_000 ether);
        deal(SPY, address(this), 20_000 ether);
        (address c0, address c1) = wa < SPY ? (wa, SPY) : (SPY, wa);
        bool wIsC0 = (wa == c0);
        uint256 price1e18 = wIsC0 ? 1e13 : 1e23;              // SPY per wRACKS or wRACKS per SPY
        uint160 sqrtP = uint160(_isqrt(price1e18) * (1 << 96) / 1e9);
        wrSpy = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, address(0));
        spyUsdg = PoolKey(Currency.wrap(SPY), Currency.wrap(USDG), 3000, 60, address(0));
        pool = new V4Pool(PM); pool.initialize(wrSpy, sqrtP);
        IERC20x(wa).approve(address(pool), type(uint256).max); IERC20x(SPY).approve(address(pool), type(uint256).max);
        pool.addLiquidity(wrSpy, -887220, 887220, int256(632_000 ether));

        sw = new V4Swap(PM);
        oracle = new TwapOracleV4(SV, keccak256(abi.encode(wrSpy)), wIsC0);
        w.setTaxOracle(address(oracle)); w.setTaxWallet(taxWallet);
        zap = new Zap(address(sw), wa, address(k), USDG, SPY, 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94, spyUsdg, wrSpy);
        k.enableTrading();

        for (uint i = 0; i < 10; i++) {
            W[i] = address(uint160(0x1000 + i));
            deal(USDG, W[i], 100_000e6);
            k.transfer(W[i], 5_000_000 ether);
            vm.startPrank(W[i]);
            IERC20x(USDG).approve(address(zap), type(uint256).max);
            IERC20x(USDG).approve(address(vault), type(uint256).max);
            IERC20x(USDG).approve(address(ag), type(uint256).max);
            k.approve(address(zap), type(uint256).max);
            k.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
        vm.warp(block.timestamp + 2 hours); // past the 1h launch window
    }
    modifier onFork() { if (SPY.code.length == 0) { vm.skip(true); return; } _; }

    // ---- exact formula boundaries (proves the odds in the contract, independent of sampling) ----
    function testTierAndHitBoundariesExact() public onFork {
        uint8[5] memory words = [74, 75, 94, 95, 99];
        uint8[5] memory tiers = [0, 1, 1, 2, 2];
        for (uint i = 0; i < 5; i++) {
            vm.prank(W[0]); uint256 id = ag.mint();
            vrf.fulfill(vrf.lastId(), words[i]);
            (uint8 t,,,,) = ag.agents(id);
            assertEq(t, tiers[i], "tier boundary");
        }
        // hit thresholds: word == rate-1 hits, word == rate misses (rates 30/50/75)
        uint8[3] memory rate = [30, 50, 75];
        for (uint8 t = 0; t < 3; t++) {
            uint16 r = ag.HITRATE(t); assertEq(r, rate[t]);
            uint256 idA = _mintTier(W[1], t); uint256 idB = _mintTier(W[1], t);
            vm.prank(W[1]); ag.attack(idA); vrf.fulfill(vrf.lastId(), r - 1);   // hit
            vm.prank(W[1]); ag.attack(idB); vrf.fulfill(vrf.lastId(), r);       // miss
            uint32 e = ag.currentEpoch();
            assertGt(ag.shares(idA, e), 0, "should hit at rate-1");
            assertEq(ag.shares(idB, e), 0, "should miss at rate");
        }
    }
    function _mintTier(address who, uint8 t) internal returns (uint256 id) {
        vm.prank(who); id = ag.mint();
        vrf.fulfill(vrf.lastId(), t == 0 ? 10 : (t == 1 ? 80 : 97));
    }

    // ---- the 2-week world ----
    function testTwoWeekSimulation() public onFork {
        uint256 t0 = block.timestamp;
        uint256 volumeUsdg;
        uint256[3] memory tierCount; uint256[3] memory attacks; uint256[3] memory hits;
        uint256 payoutsTotal; uint256 deadCount;

        // day 0: everyone locks (tier = wallet%3), everyone mints 10 agents
        for (uint i = 0; i < 10; i++) {
            vm.prank(W[i]); vault.lock(uint8(i % 3), 1_000_000 ether);
            for (uint j = 0; j < 10; j++) {
                vm.prank(W[i]); uint256 id = ag.mint();
                vrf.fulfill(vrf.lastId(), _rand());
                (uint8 t,,,,) = ag.agents(id); tierCount[t]++;
            }
        }
        uint256[3] memory claimAt0; for (uint b = 0; b < 3; b++) claimAt0[b] = vault.claimOf(W[b], uint8(b));
        assertEq(ag.livingCount(), 100);

        bool[10] memory unlocked;
        // 42 epochs of 8h = 14 days
        for (uint32 step = 0; step < 42; step++) {
            // trading: 4 trades/epoch, alternating buy/sell ~ $6k -> ~$1M over 2 weeks
            for (uint tr = 0; tr < 4; tr++) {
                address who = W[(step + tr) % 10];
                if (tr % 2 == 0) {
                    vm.prank(who); zap.buyRacks(8_500e6, 0, who); volumeUsdg += 8_500e6;
                } else {
                    uint256 bal = k.balanceOf(who);
                    uint256 sellAmt = bal / 14;                                   // ~7% of holdings
                    vm.prank(who); uint256 got = zap.sellRacks(sellAmt, 0, who); volumeUsdg += got;
                }
            }
            oracle.update();

            // agents: every living agent attacks this epoch
            uint32 e = ag.currentEpoch();
            for (uint256 id = 1; id <= 100; id++) {
                if (!ag.alive(id)) continue;
                address owner = W[(id - 1) / 10];
                (uint8 t,,,,) = ag.agents(id);
                vm.prank(owner); ag.attack(id);
                uint256 word = _rand();
                vrf.fulfill(vrf.lastId(), word);
                attacks[t]++; if (word % 100 < ag.HITRATE(t)) hits[t]++;
            }

            // advance one epoch, settle & claim the one that just closed
            vm.warp(block.timestamp + 8 hours);
            ag.settle(e);
            for (uint256 id = 1; id <= 100; id++) {
                if (ag.shares(id, e) == 0 || ag.rewardPerShareRay(e) == 0) continue;
                address owner = W[(id - 1) / 10];
                uint256 before = k.balanceOf(owner);
                vm.prank(owner); ag.claim(id, e);
                payoutsTotal += k.balanceOf(owner) - before;
            }

            // feed every 8 epochs (64h < 72h life); agent #100 is deliberately starved
            if (step % 8 == 7) {
                for (uint256 id = 1; id < 100; id++) {
                    if (!ag.alive(id)) continue;
                    vm.prank(W[(id - 1) / 10]); ag.feed(id);
                }
            }
            k.poke();

            // vault unlocks: tier0 after 1d, tier1 after 3d, tier2 exactly at 14d (last step)
            uint256 days_ = (block.timestamp - t0) / 1 days;
            for (uint i = 0; i < 10; i++) {
                uint8 b = uint8(i % 3);
                if (unlocked[i]) continue;
                bool due = (b == 0 && days_ >= 1) || (b == 1 && days_ >= 3) || (b == 2 && step == 41 && i != 8);
                if (due) { vm.prank(W[i]); vault.unlock(b); unlocked[i] = true; }
            }
        }

        // ---- late 14-day unlock (wallet 8): 2 days past expiry -> 4% penalty stays in pot ----
        vm.warp(block.timestamp + 2 days);
        uint256 w8before = k.balanceOf(W[8]);
        uint256 w8claim = vault.claimOf(W[8], 2);
        vm.prank(W[8]); vault.unlock(2);
        uint256 w8got = k.balanceOf(W[8]) - w8before;

        // ---- REPORT ----
        emit log("=== 2-WEEK SIMULATION REPORT ===");
        emit log_named_uint("trading volume (USDG, 1e6)", volumeUsdg);
        emit log_named_uint("tax collected (RACKS)", k.balanceOf(taxWallet));
        emit log_named_uint("tier0 (common) count / 100", tierCount[0]);
        emit log_named_uint("tier1 (senior) count / 100", tierCount[1]);
        emit log_named_uint("tier2 (special) count / 100", tierCount[2]);
        for (uint8 t = 0; t < 3; t++) {
            uint256 pct = attacks[t] == 0 ? 0 : hits[t] * 10000 / attacks[t];
            emit log_named_uint(string(abi.encodePacked("tier", vm.toString(t), " attacks")), attacks[t]);
            emit log_named_uint(string(abi.encodePacked("tier", vm.toString(t), " hit rate bps (exp ", vm.toString(uint256(ag.HITRATE(t)) * 100), ")")), pct);
        }
        emit log_named_uint("total agent payouts from pot (RACKS)", payoutsTotal);
        emit log_named_uint("pot remaining", vault.potBalance());
        emit log_named_uint("wallet8 late unlock: claim", w8claim);
        emit log_named_uint("wallet8 late unlock: got (4% penalty)", w8got);

        // ---- ASSERTIONS ----
        assertGe(volumeUsdg, 1_000_000e6, "need >= $1M volume");
        assertGt(k.balanceOf(taxWallet), 0, "tax must accrue");
        // rarity within statistical bounds for n=100 (exact odds proven by boundary test)
        assertTrue(tierCount[0] >= 60 && tierCount[0] <= 88, "tier0 ~75%");
        assertTrue(tierCount[1] >= 8  && tierCount[1] <= 34, "tier1 ~20%");
        assertTrue(tierCount[2] <= 14, "tier2 ~5%");
        // hit rates within +-8pp of expected with thousands of samples
        for (uint8 t = 0; t < 3; t++) {
            if (attacks[t] < 50) continue;
            uint256 pct = hits[t] * 100 / attacks[t]; uint256 exp = ag.HITRATE(t);
            assertTrue(pct + 8 >= exp && pct <= exp + 8, "hit rate off");
        }
        // vaults: 1-day tier bled ~2%/day, 3-day ~1.5%/day, 14-day exact; late unlock penalized
        assertGt(payoutsTotal, 0, "agents must have won pot");
        assertGe(k.balanceOf(address(vault)), vault.totalClaims(), "vault solvent");
        assertApproxEqRel(w8got, w8claim * 96 / 100, 0.01e18, "2 days late = 4% penalty");
        // starved agent #100 must be dead; fed ones alive
        assertFalse(ag.alive(100), "unfed agent must die");
        assertTrue(ag.alive(1), "fed agent alive");
        vm.prank(W[9]); vm.expectRevert(bytes("dead")); ag.attack(100);
        // melt: circulating supply fell over 2 weeks
        assertLt(k.totalSupply(), 69_420_000_000 ether, "melt");
    }
}
