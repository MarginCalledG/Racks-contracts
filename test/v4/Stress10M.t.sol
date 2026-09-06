// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {V4Swap, PoolKey, Currency, IERC20x} from "../../src/v4/V4Swap.sol";
import {V4Pool} from "../../src/v4/V4Pool.sol";
import {Zap} from "../../src/v4/Zap.sol";
import {TwapOracleV4} from "../../src/v4/TwapOracleV4.sol";
import {Racks} from "../../src/Racks.sol";
import {WRacks} from "../../src/WRacks.sol";

interface IW { function wrap(uint256) external returns (uint256); function approve(address,uint256) external returns (bool); }

/// $10M volume stress on the wRACKS/SPY pool (fork): launch-window load, giant trades,
/// sustained one-way pressure, conservation, tax band, pool stays functional.
contract Stress10M is Test {
    address constant SPY  = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant PM   = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant SV   = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address constant QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address taxWallet = address(0x7A11);

    Racks k; WRacks w; V4Swap sw; V4Pool pool; Zap zap; TwapOracleV4 oracle;
    PoolKey wrSpy; PoolKey spyUsdg; address wa; bool wIsC0;
    address[20] W; uint256 seed = 0xBEEF;
    function _rand() internal returns (uint256) { seed = uint256(keccak256(abi.encode(seed))); return seed; }
    function _isqrt(uint256 x) internal pure returns (uint256 y){ if(x==0) return 0; uint256 z=(x+1)/2; y=x; while(z<y){y=z; z=(x/z+z)/2;} }

    function setUp() public {
        if (SPY.code.length == 0) return;
        k = new Racks(1e27/1e6); w = new WRacks(address(k)); wa = address(w);
        k.setTaxExempt(wa, true); k.setExempt(taxWallet, true);
        k.mint(address(this), 69_420_000_000 ether);
        k.approve(wa, type(uint256).max); IW(wa).wrap(20_000_000_000 ether);
        deal(SPY, address(this), 50_000 ether);
        (address c0, address c1) = wa < SPY ? (wa, SPY) : (SPY, wa); wIsC0 = (wa == c0);
        // 1 SPY = 1000 wRACKS; ~2000 SPY (~$1.5M) deep
        uint256 pC1overC0 = wIsC0 ? 1e15 : 1e21;
        uint160 sqrtP = uint160(_isqrt(pC1overC0) * (uint256(1) << 96) / 1e9);
        wrSpy = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, address(0));
        spyUsdg = PoolKey(Currency.wrap(SPY), Currency.wrap(USDG), 3000, 60, address(0));
        pool = new V4Pool(PM); pool.initialize(wrSpy, sqrtP);
        w.setCapExempt(PM, true); w.setCapExempt(address(pool), true);
        IERC20x(wa).approve(address(pool), type(uint256).max); IERC20x(SPY).approve(address(pool), type(uint256).max);
        pool.addLiquidity(wrSpy, -887220, 887220, int256(63_000 ether)); // ~2000 SPY / ~2M wRACKS
        sw = new V4Swap(PM); w.setCapExempt(address(sw), true);
        oracle = new TwapOracleV4(SV, keccak256(abi.encode(wrSpy)), wIsC0);
        w.setTaxOracle(address(oracle)); w.setTaxWallet(taxWallet);
        zap = new Zap(address(sw), wa, address(k), USDG, SPY, QUOTER, spyUsdg, wrSpy);
        w.setCapExempt(address(zap), true);
        for (uint i; i < 20; i++) {
            W[i] = address(uint160(0x2000 + i)); deal(USDG, W[i], 5_000_000e6);
            vm.startPrank(W[i]); IERC20x(USDG).approve(address(zap), type(uint256).max); k.approve(address(zap), type(uint256).max); vm.stopPrank();
        }
        k.enableTrading();
    }
    modifier onFork() { if (SPY.code.length == 0) { vm.skip(true); return; } _; }

    function _sysSpy() internal view returns (uint256 t) { t = IERC20x(SPY).balanceOf(PM) + IERC20x(SPY).balanceOf(address(this)) + IERC20x(SPY).balanceOf(address(zap)) + IERC20x(SPY).balanceOf(address(sw)); for (uint i; i<20; i++) t += IERC20x(SPY).balanceOf(W[i]); }
    function _sysWr()  internal view returns (uint256 t) { t = IERC20x(wa).balanceOf(PM) + IERC20x(wa).balanceOf(address(this)) + IERC20x(wa).balanceOf(address(zap)) + IERC20x(wa).balanceOf(address(sw)) + IERC20x(wa).balanceOf(w.DEAD_SHARES()); for (uint i; i<20; i++) t += IERC20x(wa).balanceOf(W[i]); }

    function testTenMillionVolume() public onFork {
        uint256 spyT0 = _sysSpy();
        uint256 vol; uint256 maxTax; uint256 minTax = type(uint256).max; uint256 reverts;

        // PHASE 1: launch hour — 40 buyers hammer the cap/refund logic (8% tax, 1% cap)
        for (uint i; i < 40; i++) {
            address who = W[i % 20];
            vm.prank(who);
            try zap.buyRacks(50_000e6, 0, who) returns (uint256) { vol += 50_000e6; } catch { reverts++; }
            assertLe(k.balanceOf(who), k.maxWallet(), "launch cap breached");
        }
        emit log_named_uint("phase1 launch-hour buys (reverts)", reverts);
        vm.warp(block.timestamp + 1 hours + 1); k.poke();

        // PHASE 2: $8M balanced churn over ~10 days, tax band monitored every trade
        uint256 t0 = block.timestamp;
        for (uint i; i < 400; i++) {
            address who = W[_rand() % 20];
            if (i % 2 == 0) { vm.prank(who); zap.buyRacks(20_000e6, 0, who); vol += 20_000e6; }
            else { uint256 b = k.balanceOf(who); if (b > 1 ether) { vm.prank(who); vol += zap.sellRacks(b / 3, 0, who); } }
            if (i % 8 == 0) { vm.warp(block.timestamp + 36 minutes); oracle.update(); k.poke(); }
            uint256 tb = oracle.taxBps(1 ether, true); if (tb > maxTax) maxTax = tb; if (tb < minTax) minTax = tb;
        }
        emit log_named_uint("phase2 days elapsed", (block.timestamp - t0) / 1 days);

        // PHASE 3: one giant $2M buy, then sustained one-way pressure: $1.5M buys then $1.5M sells
        vm.prank(W[0]); zap.buyRacks(2_000_000e6, 0, W[0]); vol += 2_000_000e6;
        for (uint i; i < 30; i++) { vm.prank(W[i%20]); zap.buyRacks(50_000e6, 0, W[i%20]); vol += 50_000e6; oracle.update(); }
        uint256 spotAfterBuys = oracle.spot();
        for (uint i; i < 30; i++) { address who = W[i%20]; uint256 b = k.balanceOf(who); if (b > 1 ether) { vm.prank(who); vol += zap.sellRacks(b / 2, 0, who); } oracle.update(); }
        uint256 spotAfterSells = oracle.spot();

        // PHASE 4: pool still works after all that
        vm.prank(W[5]); uint256 got = zap.buyRacks(1_000e6, 0, W[5]); vol += 1_000e6;
        assertGt(got, 0, "pool dead after stress");

        // ---- REPORT ----
        emit log_named_uint("TOTAL VOLUME (USDG, 1e6)", vol);
        emit log_named_uint("tax collected (RACKS)", k.balanceOf(taxWallet));
        emit log_named_uint("tax band seen: min bps", minTax); emit log_named_uint("tax band seen: max bps", maxTax);
        emit log_named_uint("spot after one-way buys", spotAfterBuys); emit log_named_uint("spot after one-way sells", spotAfterSells);
        emit log_named_uint("pool wRACKS", IERC20x(wa).balanceOf(PM));

        // ---- ASSERTIONS ----
        assertGe(vol, 10_000_000e6, ">= $10M");
        assertGe(minTax, 100, "tax below 1% floor"); assertLe(maxTax, 800, "tax above 8% cap");
        assertGt(spotAfterBuys, spotAfterSells, "buys must raise, sells must lower the price");
        assertEq(IERC20x(SPY).balanceOf(address(zap)) + IERC20x(SPY).balanceOf(address(sw)), 0, "SPY stranded in routers");
        assertEq(IERC20x(wa).balanceOf(address(zap)) + IERC20x(wa).balanceOf(address(sw)), 0, "wRACKS stranded in routers");
        assertEq(k.balanceOf(address(zap)), 0, "RACKS stranded in zap");
        assertEq(IERC20x(USDG).balanceOf(address(zap)) + IERC20x(USDG).balanceOf(address(sw)), 0, "USDG stranded");
        // SPY conservation across the whole system (only the real SPY/USDG pool trades SPY in/out, which we track via PM)
        assertGt(_sysSpy(), spyT0 * 90 / 100, "SPY vanished from the system");
    }
}
