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

// REAL launch conditions: ~$5,000 of SPY seeding the LP, ~all supply wrapped in.
contract LaunchRealistic is Test {
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant PM  = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant SV  = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address constant QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address taxWallet = address(0x7A11);

    Racks k; WRacks w; V4Swap sw; Zap zap; address wa; uint256 maxW; uint256 SUPPLY = 69_420_000_000 ether;

    function _isqrt(uint256 x) internal pure returns (uint256 y){ if(x==0) return 0; uint256 z=(x+1)/2; y=x; while(z<y){y=z; z=(x/z+z)/2;} }

    function setUp() public {
        if (SPY.code.length == 0) return;
        k = new Racks(1e27 / 1e6);
        w = new WRacks(address(k)); wa = address(w);
        k.setTaxExempt(wa, true); k.setExempt(taxWallet, true);
        k.mint(address(this), SUPPLY);
        k.approve(wa, type(uint256).max);
        IW(wa).wrap(SUPPLY * 999 / 1000);                 // ~all supply wrapped into tradeable form

        // seed LP with ~$5,000 of SPY. SPY ~ $775 -> ~6.45 SPY. Pair against ~all wRACKS.
        uint256 spySeed = 645 ether / 100;                // 6.45 SPY ~ $5,000
        deal(SPY, address(this), spySeed);
        uint256 wrSeed = IERC20x(wa).balanceOf(address(this)); // ~69.35B wRACKS

        (address c0, address c1) = wa < SPY ? (wa, SPY) : (SPY, wa);
        bool wIsC0 = (wa == c0);
        // price = wrSeed/spySeed wRACKS per SPY -> c1/c0 raw
        uint256 wrPerSpy = wrSeed * 1e18 / spySeed;       // ~1.07e10 wRACKS per SPY, 1e18-scaled ratio
        uint256 pC1overC0 = wIsC0 ? (1e36 / wrPerSpy) : wrPerSpy;
        uint160 sqrtP = uint160(_isqrt(pC1overC0) * (uint256(1) << 96) / 1e9);

        PoolKey memory wrSpy = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, address(0));
        PoolKey memory spyUsdg = PoolKey(Currency.wrap(SPY), Currency.wrap(USDG), 3000, 60, address(0));
        V4Pool pool = new V4Pool(PM); pool.initialize(wrSpy, sqrtP);
        IERC20x(wa).approve(address(pool), type(uint256).max);
        IERC20x(SPY).approve(address(pool), type(uint256).max);
        // liquidity L ~ sqrt(reserve0*reserve1)
        uint256 L = _isqrt(wrSeed) * _isqrt(spySeed);
        pool.addLiquidity(wrSpy, -887220, 887220, int256(L));

        // exemptions so the pool infra can hold/move wRACKS during the launch window
        w.setCapExempt(PM, true);
        w.setCapExempt(address(pool), true);
        sw = new V4Swap(PM);
        w.setCapExempt(address(sw), true);
        TwapOracleV4 oracle = new TwapOracleV4(SV, keccak256(abi.encode(wrSpy)), wIsC0);
        w.setTaxOracle(address(oracle)); w.setTaxWallet(taxWallet);
        zap = new Zap(address(sw), wa, address(k), USDG, SPY, QUOTER, spyUsdg, wrSpy);
        w.setCapExempt(address(zap), true);
        k.enableTrading();
        maxW = k.maxWallet();
    }
    modifier onFork() { if (SPY.code.length == 0) { vm.skip(true); return; } _; }

    // what would a $500 buy grab WITHOUT the cap? (measure the raw danger)
    function testUncappedDanger() public onFork {
        // simulate by buying directly through the pools (bypassing the zap cap) with $500
        address whale = address(0xBADB0B);
        deal(USDG, whale, 500e6);
        PoolKey memory spyUsdg = PoolKey(Currency.wrap(SPY), Currency.wrap(USDG), 3000, 60, address(0));
        vm.startPrank(whale);
        IERC20x(USDG).approve(address(sw), type(uint256).max);
        uint256 spyOut = sw.swap(spyUsdg, false, 500e6, 0, whale);  // USDG->SPY ok (SPY not capped)
        IERC20x(SPY).approve(address(sw), type(uint256).max);
        PoolKey memory wrSpy = zapWrSpy();
        bool spyIsC0 = SPY == Currency.unwrap(wrSpy.currency0);
        // the over-cap wRACKS delivery must revert -> sniper cannot grab 9%
        vm.expectRevert();
        sw.swap(wrSpy, spyIsC0, spyOut, 0, whale);
        vm.stopPrank();
        emit log("direct-to-pool over-cap buy REVERTED (sniper blocked)");
        assertLt(IERC20x(wa).balanceOf(whale), maxW, "sniper got nothing over cap");
        emit log("direct-to-pool over-cap buy REVERTED (sniper blocked)");
        assertLt(IERC20x(wa).balanceOf(whale), maxW, "sniper got nothing over cap");
    }
    function zapWrSpy() internal view returns (PoolKey memory) { (Currency c0,Currency c1,uint24 f,int24 ts,address h)=zap.wrSpy(); return PoolKey(c0,c1,f,ts,h); }

    // the same $500 buy THROUGH THE ZAP must be capped to 0.8% + refund
    function testCappedBuyThroughZap() public onFork {
        address whale = address(0xB0B);
        deal(USDG, whale, 500e6);
        vm.startPrank(whale);
        IERC20x(USDG).approve(address(zap), type(uint256).max);
        uint256 got = zap.buyRacks(500e6, 0, whale);
        vm.stopPrank();
        emit log_named_uint("$500 via zap -> RACKS", got);
        emit log_named_uint("cap (0.8%)", maxW);
        emit log_named_uint("USDG refunded", IERC20x(USDG).balanceOf(whale));
        assertLe(k.balanceOf(whale), maxW, "capped to 0.8%");
    }
}
