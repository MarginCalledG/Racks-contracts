// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {HookedBase} from "./HookedBase.sol";
import {TaxHook} from "../../src/v4/TaxHook.sol";
import {V4Swap, PoolKey, Currency, IERC20x} from "../../src/v4/V4Swap.sol";
import {V4Pool} from "../../src/v4/V4Pool.sol";
import {Zap} from "../../src/v4/Zap.sol";
import {Racks} from "../../src/Racks.sol";
import {WRacks} from "../../src/WRacks.sol";

interface IW { function wrap(uint256) external returns (uint256); function approve(address,uint256) external returns (bool); function balanceOf(address) external view returns (uint256); function setTaxWallet(address) external; }

contract ZapTest is HookedBase {
    address constant SPY  = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant PM   = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    uint160 constant SQRT_1TO1 = 79228162514264337593543950336;
    address taxWallet = address(0x7A11);

    function testOneClickBuyRacks() public {
        if (SPY.code.length == 0) { vm.skip(true); return; }

        // our tokens + taxed wrapper
        Racks k = new Racks(1e27 / 1e6);
        WRacks w = new WRacks(address(k));
        k.setTaxExempt(address(w), true); /* wrapper MUST melt: never setExempt */
        k.setExempt(taxWallet, true);
        k.mint(address(this), 2_000_000 ether);
        k.approve(address(w), type(uint256).max);
        IW(address(w)).wrap(1_000_000 ether);   // seed wrap (untaxed)

        // seed our wRACKS/SPY pool
        deal(SPY, address(this), 5_000 ether);
        address wa = address(w);
        (address c0, address c1) = wa < SPY ? (wa, SPY) : (SPY, wa);
        TaxHook hook = _deployHook(PM, wa, address(k), taxWallet);
        PoolKey memory wrSpy = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, address(hook));
        V4Pool pool = new V4Pool(PM);
        pool.initialize(wrSpy, SQRT_1TO1);
        IERC20x(wa).approve(address(pool), type(uint256).max);
        IERC20x(SPY).approve(address(pool), type(uint256).max);
        pool.addLiquidity(wrSpy, -887220, 887220, int256(2_000 ether));

        // real SPY/USDG pool key (SPY=c0, USDG=c1)
        PoolKey memory spyUsdg = PoolKey(Currency.wrap(SPY), Currency.wrap(USDG), 3000, 60, address(0));

        // deploy zap
        V4Swap sw = new V4Swap(PM);
        Zap zap = new Zap(address(sw), address(w), address(k), USDG, SPY, 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94, spyUsdg, wrSpy);

        // one-click BUY: user has USDG, wants RACKS
        address user = address(0xB0B);
        deal(USDG, user, 1_000e6);   // 1000 USDG
        vm.startPrank(user);
        IERC20x(USDG).approve(address(zap), type(uint256).max);
        uint256 racksOut = zap.buyRacks(1_000e6, 0, user);
        vm.stopPrank();

        emit log_named_uint("USDG in (1e6)", 1_000e6);
        emit log_named_uint("RACKS out to user", racksOut);
        emit log_named_uint("tax collected (wRACKS, at the pool)", IERC20x(wa).balanceOf(taxWallet));
        assertGt(racksOut, 0, "no RACKS delivered");
        assertEq(k.balanceOf(user), racksOut, "RACKS not in user wallet");
        assertGt(IERC20x(wa).balanceOf(taxWallet), 0, "no tax collected");
    }
}
