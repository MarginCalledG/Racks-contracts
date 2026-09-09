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

interface IW { function wrap(uint256) external returns (uint256); function unwrap(uint256) external returns (uint256); function approve(address,uint256) external returns (bool); function balanceOf(address) external view returns (uint256); function racksPerShare() external view returns (uint256); }

contract StressTest is HookedBase {
    address constant SPY  = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant PM   = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant SV   = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    uint160 constant SQRT_1TO1 = 79228162514264337593543950336;
    address taxWallet = address(0x7A11);

    Racks k; WRacks w; V4Swap sw; V4Pool pool; Zap zap; TwapOracleV4 oracle;
    PoolKey wrSpy; PoolKey spyUsdg; address wa; bool wIsC0; bool forked;

    function setUp() public {
        if (SPY.code.length == 0) return; // not forked -> tests skip
        forked = true;
        k = new Racks(1e27 / 1e6);
        w = new WRacks(address(k)); wa = address(w);
        k.setTaxExempt(wa, true); /* wrapper MUST melt: never setExempt */ k.setExempt(taxWallet, true);
        k.mint(address(this), 10_000_000 ether);
        k.approve(wa, type(uint256).max);
        IW(wa).wrap(6_000_000 ether);                // seed wrap (untaxed)
        deal(SPY, address(this), 50_000 ether);

        (address c0, address c1) = wa < SPY ? (wa, SPY) : (SPY, wa);
        wIsC0 = (wa == c0);
        TaxHook hook = _deployHook(PM, wa, address(k), taxWallet);
        wrSpy = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, address(hook));
        spyUsdg = PoolKey(Currency.wrap(SPY), Currency.wrap(USDG), 3000, 60, address(0));

        pool = new V4Pool(PM);
        pool.initialize(wrSpy, SQRT_1TO1);
        IERC20x(wa).approve(address(pool), type(uint256).max);
        IERC20x(SPY).approve(address(pool), type(uint256).max);
        pool.addLiquidity(wrSpy, -887220, 887220, int256(3_000 ether)); // ~3000/3000 virtual

        sw = new V4Swap(PM);
        IERC20x(wa).approve(address(sw), type(uint256).max);
        IERC20x(SPY).approve(address(sw), type(uint256).max);
        oracle = new TwapOracleV4(SV, keccak256(abi.encode(wrSpy)), wIsC0);
        hook.setOracle(address(oracle));
        zap = new Zap(address(sw), wa, address(k), USDG, SPY, 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94, spyUsdg, wrSpy);
    }
    modifier onFork() { if (!forked) { vm.skip(true); return; } _; }

    function _totalSpy() internal view returns (uint256) { return IERC20x(SPY).balanceOf(address(this)) + IERC20x(SPY).balanceOf(PM) + IERC20x(SPY).balanceOf(taxWallet); }
    function _totalWr()  internal view returns (uint256) { return IERC20x(wa).balanceOf(address(this)) + IERC20x(wa).balanceOf(PM) + IERC20x(wa).balanceOf(taxWallet); }

    // 1) buy then sell back: must NEVER end with more than started (no free money)
    function testSwapRoundTripNoFreeMoney() public onFork {
        uint256 spy0 = IERC20x(SPY).balanceOf(address(this));
        uint256 wrOut = sw.swap(wrSpy, !wIsC0, 100 ether, 0, address(this));   // SPY -> wRACKS
        uint256 spyBack = sw.swap(wrSpy, wIsC0, wrOut, 0, address(this));      // wRACKS -> SPY
        uint256 spy1 = IERC20x(SPY).balanceOf(address(this));
        assertLt(spy1, spy0, "round trip must cost something");
        assertEq(spy1, spy0 - 100 ether + spyBack);
        uint256 lossBps = (spy0 - spy1) * 10000 / 100 ether;
        emit log_named_uint("round-trip loss bps (fees+slippage)", lossBps);
        assertLt(lossBps, 1500, "loss unreasonably high"); // pool tax both ways (~4%+impact each) + 2x0.3% fee + slippage
    }

    // 2) 100 alternating swaps: no revert, tokens conserved across user+pool (fees stay in pool)
    function testManySequentialSwapsConserve() public onFork {
        uint256 spyT = _totalSpy(); uint256 wrT = _totalWr();
        uint256 seed = 12345;
        for (uint i = 0; i < 100; i++) {
            seed = uint256(keccak256(abi.encode(seed)));
            uint256 amt = 1 ether + (seed % 60 ether);       // 1..61 tokens
            bool dir = (seed >> 128) & 1 == 1;                 // random direction
            sw.swap(wrSpy, dir, amt, 0, address(this));
        }
        assertEq(_totalSpy(), spyT, "SPY leaked/created");
        assertEq(_totalWr(),  wrT,  "wRACKS leaked/created");
        assertGt(oracle.spot(), 0);
    }

    // 3) huge swaps: 50% of reserve, then 5x reserve — must not break or strand funds
    function testHugeSwapsDoNotBreak() public onFork {
        uint256 r = oracle.wracksReserve();
        emit log_named_uint("virtual wRACKS reserve", r);
        uint256 wr0 = IERC20x(wa).balanceOf(address(this));
        uint256 out1 = sw.swap(wrSpy, wIsC0, r / 2, 0, address(this));         // dump 50%
        assertGt(out1, 0);
        uint256 spot1 = oracle.spot();
        uint256 out2 = sw.swap(wrSpy, wIsC0, r * 5, 0, address(this));         // dump 5x reserve
        assertGt(out2, 0, "5x swap should still fill on full-range");
        assertLt(oracle.spot(), spot1, "price must keep falling");
        // input fully consumed or refunded -> our balance dropped by at most what we sent
        assertGe(IERC20x(wa).balanceOf(address(this)), wr0 - r / 2 - r * 5);
        assertEq(IERC20x(wa).balanceOf(address(sw)), 0, "swapper must not strand tokens");
        assertEq(IERC20x(SPY).balanceOf(address(sw)), 0, "swapper must not strand tokens");
    }

    // 4) slippage guard reverts AND leaves balances untouched
    function testSlippageRevertKeepsFunds() public onFork {
        uint256 spy0 = IERC20x(SPY).balanceOf(address(this));
        uint256 wr0  = IERC20x(wa).balanceOf(address(this));
        vm.expectRevert(bytes("slippage"));
        sw.swap(wrSpy, !wIsC0, 100 ether, type(uint256).max, address(this));
        assertEq(IERC20x(SPY).balanceOf(address(this)), spy0);
        assertEq(IERC20x(wa).balanceOf(address(this)), wr0);
    }

    // 5) dust: 1 wei in -> clean revert (0 out fails bad-delta) or tiny out; never corrupts state
    function testDustSwap() public onFork {
        uint256 spyT = _totalSpy();
        try sw.swap(wrSpy, !wIsC0, 1, 0, address(this)) returns (uint256 o) {
            emit log_named_uint("dust out", o);
        } catch { emit log("dust swap reverted cleanly"); }
        assertEq(_totalSpy(), spyT);
    }

    // 6) Zap round trip: buy with USDG, sell everything back -> less USDG, RACKS zero, tax both legs
    function testZapRoundTripNoFreeMoney() public onFork {
        address user = address(0xB0B);
        deal(USDG, user, 5_000e6);
        vm.startPrank(user);
        IERC20x(USDG).approve(address(zap), type(uint256).max);
        uint256 racksOut = zap.buyRacks(5_000e6, 0, user);
        uint256 taxAfterBuy = IERC20x(wa).balanceOf(taxWallet);          // buy tax lands in wRACKS
        k.approve(address(zap), type(uint256).max);
        uint256 usdgBack = zap.sellRacks(k.balanceOf(user), 0, user);
        vm.stopPrank();
        emit log_named_uint("RACKS bought", racksOut);
        emit log_named_uint("USDG back (1e6)", usdgBack);
        assertLt(usdgBack, 5_000e6, "must not profit from a round trip");
        assertLe(k.balanceOf(user), 1, "RACKS should be fully sold (dust ok)");
        assertGt(taxAfterBuy, 0, "buy-side tax (wRACKS)");
        assertGt(IERC20x(SPY).balanceOf(taxWallet), 0, "sell-side tax (SPY)");
        assertEq(k.balanceOf(address(zap)), 0, "zap must not hold RACKS");
        assertEq(IERC20x(USDG).balanceOf(address(zap)), 0, "zap must not hold USDG");
    }

    // 7) oracle manipulation: one giant single-block swap moves SPOT a lot but TWAP barely
    function testOracleManipulationResistance() public onFork {
        for (uint i = 0; i < 6; i++) { vm.warp(block.timestamp + 3 minutes); oracle.update(); }
        uint256 twap0 = oracle.twap(); uint256 spot0 = oracle.spot();
        sw.swap(wrSpy, wIsC0, oracle.wracksReserve(), 0, address(this));   // dump 100% of reserve
        oracle.update();
        uint256 spot1 = oracle.spot(); uint256 twap1 = oracle.twap();
        uint256 spotMove = (spot0 - spot1) * 10000 / spot0;
        uint256 twapMove = twap0 > twap1 ? (twap0 - twap1) * 10000 / twap0 : 0;
        emit log_named_uint("spot move bps", spotMove);
        emit log_named_uint("twap move bps (same block)", twapMove);
        assertGt(spotMove, 3000, "spot should crash >30%");
        assertLt(twapMove, 200,  "TWAP must not follow a same-block spike");
        // sustained move IS tracked over time
        vm.warp(block.timestamp + 15 minutes); oracle.update();
        assertLt(oracle.twap(), twap0 * 9 / 10, "TWAP should follow a sustained move");
    }

    // 8) the whole point of wRACKS: melt never touches the pool's wRACKS quantity
    function testMeltInPoolWrappedQuantityFixed() public onFork {
        uint256 pmWr0 = IERC20x(wa).balanceOf(PM);
        uint256 rps0 = IW(wa).racksPerShare();
        vm.warp(block.timestamp + 7 days);
        k.poke();
        assertEq(IERC20x(wa).balanceOf(PM), pmWr0, "pool wRACKS must be constant");
        uint256 rps1 = IW(wa).racksPerShare();
        emit log_named_uint("racksPerShare before", rps0);
        emit log_named_uint("racksPerShare after 7d", rps1);
        assertLt(rps1, rps0 * 80 / 100, "melt should show in redemption rate (>20% in 7d)");
    }

    // 9) wrap/unwrap conservation: X in -> X minus exactly two taxes, RACKS total conserved
    function testWrapUnwrapConservation() public onFork {
        address u = address(0xCA7);
        k.transfer(u, 100_000 ether);
        uint256 tax0 = k.balanceOf(taxWallet);
        uint256 total0 = k.balanceOf(u) + k.balanceOf(wa) + tax0;
        vm.startPrank(u);
        k.approve(wa, type(uint256).max);
        uint256 sh = IW(wa).wrap(100_000 ether);
        uint256 out = IW(wa).unwrap(sh);
        vm.stopPrank();
        emit log_named_uint("got back", out);
        // wrap/unwrap is a pure form change now (tax lives in the pool hook): value conserved, no fee
        assertApproxEqAbs(out, 100_000 ether, 1e6, "wrap/unwrap must not lose value");
        assertEq(k.balanceOf(taxWallet), tax0, "no tax on wrap/unwrap");
        assertApproxEqAbs(k.balanceOf(u) + k.balanceOf(wa) + k.balanceOf(taxWallet), total0, 1e6);
    }

    // 10) first dumper now pays impact even at a neutral price
    function testFirstDumperPaysImpact() public onFork {
        for (uint i = 0; i < 6; i++) { vm.warp(block.timestamp + 3 minutes); oracle.update(); }
        uint256 small = oracle.taxBps(1 ether, true);
        uint256 big   = oracle.taxBps(oracle.wracksReserve() / 10, true); // 10% of reserve
        emit log_named_uint("small sell tax bps", small);
        emit log_named_uint("big-dump sell tax bps", big);
        assertApproxEqAbs(small, 400, 5, "neutral small trade ~ base (+tiny impact)");
        assertGt(big, small, "a big dump must pay impact");
        assertLe(big, 800);
    }
}
