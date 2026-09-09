// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {HookedBase} from "./HookedBase.sol";
import {TaxHook} from "../../src/v4/TaxHook.sol";
import {V4Swap, PoolKey, Currency, IERC20x} from "../../src/v4/V4Swap.sol";
import {V4Pool} from "../../src/v4/V4Pool.sol";
import {Zap} from "../../src/v4/Zap.sol";
import {TwapOracleV4} from "../../src/v4/TwapOracleV4.sol";
import {Racks} from "../../src/Racks.sol";
import {WRacks} from "../../src/WRacks.sol";

interface IW { function wrap(uint256) external returns (uint256); function approve(address,uint256) external returns (bool); }

contract LaunchCapTest is HookedBase {
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant PM  = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant SV  = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address constant QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address taxWallet = address(0x7A11);

    Racks k; WRacks w; V4Swap sw; Zap zap; address wa; uint256 maxW;

    function _isqrt(uint256 x) internal pure returns (uint256 y){ if(x==0) return 0; uint256 z=(x+1)/2; y=x; while(z<y){y=z; z=(x/z+z)/2;} }

    function setUp() public {
        if (SPY.code.length == 0) return;
        k = new Racks(1e27 / 1e6);
        w = new WRacks(address(k)); wa = address(w);
        k.setTaxExempt(wa, true); k.setExempt(taxWallet, true);
        k.mint(address(this), 1_000_000 ether);          // small supply -> maxWallet = 8,000
        k.approve(wa, type(uint256).max);
        IW(wa).wrap(500_000 ether);
        deal(SPY, address(this), 20_000 ether);

        (address c0, address c1) = wa < SPY ? (wa, SPY) : (SPY, wa);
        bool wIsC0 = (wa == c0);
        // price 1 SPY = 1,000,000 wRACKS  (wRACKS very cheap -> tiny SPY depth sells the whole cap)
        uint256 pC1overC0 = wIsC0 ? 1e15 : 1e21;          // 1 SPY = 1000 wRACKS
        uint160 sqrtP = uint160(_isqrt(pC1overC0) * (uint256(1) << 96) / 1e9);
        TaxHook hook = _deployHook(PM, wa, address(k), taxWallet);
        PoolKey memory wrSpy = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, address(hook));
        PoolKey memory spyUsdg = PoolKey(Currency.wrap(SPY), Currency.wrap(USDG), 3000, 60, address(0));
        V4Pool pool = new V4Pool(PM); pool.initialize(wrSpy, sqrtP);
        IERC20x(wa).approve(address(pool), type(uint256).max);
        IERC20x(SPY).approve(address(pool), type(uint256).max);
        pool.addLiquidity(wrSpy, -887220, 887220, int256(3_000 ether));

        w.setCapExempt(PM, true); w.setCapExempt(address(pool), true);
        sw = new V4Swap(PM); w.setCapExempt(address(sw), true);
        TwapOracleV4 oracle = new TwapOracleV4(SV, keccak256(abi.encode(wrSpy)), wIsC0);
        hook.setOracle(address(oracle));
        zap = new Zap(address(sw), wa, address(k), USDG, SPY, QUOTER, spyUsdg, wrSpy);
        k.setWrapper(wa); k.setCapExempt(address(zap), true); // F3 ledger wiring (REQUIRED)
        w.setCapExempt(address(zap), true);
        k.enableTrading();                 // launch window ON
        maxW = k.maxWallet();
        emit log_named_uint("maxWallet (0.8% RACKS)", maxW);
    }
    modifier onFork() { if (SPY.code.length == 0) { vm.skip(true); return; } _; }

    // over-cap buy: succeeds, delivers ~0.8% (AFTER tax), refunds the rest in USDG
    function testOverCapBuyRefunds() public onFork {
        address user = address(0xB0B);
        deal(USDG, user, 50_000e6);                    // far more than the ~$6.2k cap costs
        uint256 usdgBefore = 50_000e6;
        vm.startPrank(user);
        IERC20x(USDG).approve(address(zap), type(uint256).max);
        uint256 racksOut = zap.buyRacks(usdgBefore, 0, user);
        vm.stopPrank();

        uint256 usdgLeft = IERC20x(USDG).balanceOf(user);
        emit log_named_uint("RACKS delivered", racksOut);
        emit log_named_uint("maxWallet cap", maxW);
        emit log_named_uint("USDG refunded", usdgLeft);

        assertGt(racksOut, 0, "tx must succeed with RACKS");
        assertLe(k.balanceOf(user), maxW, "must NOT exceed 0.8% after tax");
        assertGe(racksOut, maxW * 90 / 100, "should get close to the full 0.8%");
        assertGt(usdgLeft, 40_000e6, "big refund since cap is cheap");
        assertEq(IERC20x(USDG).balanceOf(address(zap)), 0, "zap holds no USDG");
    }

    // F3 end-to-end: the SAME wallet cannot buy 1% twice through the zap (cumulative ledger)
    function testSecondBuySameWalletRefusedByLedger() public onFork {
        address user = address(0x5EC);
        deal(USDG, user, 100_000e6);
        vm.startPrank(user);
        IERC20x(USDG).approve(address(zap), type(uint256).max);
        uint256 first = zap.buyRacks(50_000e6, 0, user);          // capped to ~1%
        k.transfer(address(0xA17), k.balanceOf(user));            // move it all away (would reset a snapshot)
        uint256 second = zap.buyRacks(50_000e6, 0, user);         // ledger says: already at cap
        vm.stopPrank();
        emit log_named_uint("first buy RACKS", first); emit log_named_uint("second buy RACKS", second);
        assertGt(first, 0);
        assertLt(second, first / 20, "second buy only fills the remaining sliver, never another 1%");
        assertLe(k.launchReceived(user), k.maxWallet());
    }

    // a normal small buy under the cap is unaffected (little/no refund)
    function testUnderCapBuyNormal() public onFork {
        address user = address(0xCA7);
        deal(USDG, user, 3_000e6);
        vm.startPrank(user);
        IERC20x(USDG).approve(address(zap), type(uint256).max);
        uint256 racksOut = zap.buyRacks(3_000e6, 0, user);
        vm.stopPrank();
        assertGt(racksOut, 0);
        assertLe(k.balanceOf(user), maxW);
        assertEq(IERC20x(USDG).balanceOf(user), 0, "small buy fully spent, no refund");
    }

    // after the launch window closes, no cap: a big buy goes fully through
    function testNoCapAfterWindow() public onFork {
        vm.warp(block.timestamp + 1 hours + 1);
        address user = address(0xDEE);
        deal(USDG, user, 50_000e6);
        vm.startPrank(user);
        IERC20x(USDG).approve(address(zap), type(uint256).max);
        uint256 racksOut = zap.buyRacks(50_000e6, 0, user);
        vm.stopPrank();
        assertGt(k.balanceOf(user), maxW, "post-launch a whale can exceed 0.8%");
        assertEq(IERC20x(USDG).balanceOf(user), 0, "no refund post-launch");
        assertGt(racksOut, 0);
    }
}
