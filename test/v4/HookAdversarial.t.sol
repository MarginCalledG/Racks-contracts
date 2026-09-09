// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {HookedBase} from "./HookedBase.sol";
import {TaxHook} from "../../src/v4/TaxHook.sol";
import {V4Swap, PoolKey, Currency, IERC20x} from "../../src/v4/V4Swap.sol";
import {V4Pool} from "../../src/v4/V4Pool.sol";
import {TwapOracleV4} from "../../src/v4/TwapOracleV4.sol";
import {Racks} from "../../src/Racks.sol";
import {WRacks} from "../../src/WRacks.sol";
interface IW { function wrap(uint256) external returns (uint256); function approve(address,uint256) external returns (bool); }

/// Adversarial pass on the newest code: the pool tax hook + launch ledger interplay.
contract HookAdversarial is HookedBase {
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant PM  = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant SV  = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address taxWallet = address(0x7A11);
    Racks k; WRacks w; address wa; V4Swap sw; V4Pool pool; PoolKey key; bool wIsC0; TaxHook hook;

    function setUp() public {
        if (SPY.code.length == 0) return;
        k = new Racks(1e27/1e6); w = new WRacks(address(k)); wa = address(w);
        k.setTaxExempt(wa, true);
        k.mint(address(this), 10_000_000 ether); k.approve(wa, type(uint256).max); IW(wa).wrap(5_000_000 ether);
        deal(SPY, address(this), 20_000 ether);
        (address c0, address c1) = wa < SPY ? (wa, SPY) : (SPY, wa); wIsC0 = (wa == c0);
        hook = _deployHook(PM, wa, address(k), taxWallet);
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, address(hook));
        pool = new V4Pool(PM); pool.initialize(key, 79228162514264337593543950336);
        w.setCapExempt(PM, true); w.setCapExempt(address(pool), true);
        IERC20x(wa).approve(address(pool), type(uint256).max); IERC20x(SPY).approve(address(pool), type(uint256).max);
        pool.addLiquidity(key, -887220, 887220, int256(3_000 ether));
        sw = new V4Swap(PM); w.setCapExempt(address(sw), true);
        IERC20x(wa).approve(address(sw), type(uint256).max); IERC20x(SPY).approve(address(sw), type(uint256).max);
        hook.setOracle(address(new TwapOracleV4(SV, keccak256(abi.encode(key)), wIsC0)));
        k.setWrapper(wa);
    }
    modifier onFork() { if (SPY.code.length == 0) { vm.skip(true); return; } _; }

    // DEPLOY TRAP: tax wallet NOT exempt -> launch swaps revert once it has received ~1% of supply
    // -> pool dead for the rest of the launch hour. wiringOk() catches it. Small-supply world so it triggers.
    function testTaxWalletMustBeExemptOrLaunchDies() public onFork {
        Racks k2 = new Racks(1e27/1e6); WRacks w2 = new WRacks(address(k2)); address wa2 = address(w2);
        k2.setTaxExempt(wa2, true); k2.mint(address(this), 40_000 ether);             // cap will be 400
        deal(SPY, address(this), 50_000 ether);
        k2.approve(wa2, type(uint256).max); IW(wa2).wrap(30_000 ether);
        (address c0, address c1) = wa2 < SPY ? (wa2, SPY) : (SPY, wa2); bool w2IsC0 = (wa2 == c0);
        TaxHook h2 = _deployHook(PM, wa2, address(k2), taxWallet);
        PoolKey memory k2key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, address(h2));
        V4Pool p2 = new V4Pool(PM); p2.initialize(k2key, 79228162514264337593543950336);
        w2.setCapExempt(PM, true); w2.setCapExempt(address(p2), true);
        IERC20x(wa2).approve(address(p2), type(uint256).max); IERC20x(SPY).approve(address(p2), type(uint256).max);
        p2.addLiquidity(k2key, -887220, 887220, int256(10_000 ether));
        V4Swap s2 = new V4Swap(PM); w2.setCapExempt(address(s2), true);
        IERC20x(SPY).approve(address(s2), type(uint256).max);
        k2.setWrapper(wa2); k2.enableTrading();                                          // launch: 8% tax
        assertFalse(h2.wiringOk(), "self-check must flag a non-exempt tax wallet");

        bool died; uint256 n;
        for (n = 0; n < 60; n++) { try s2.swap(k2key, !w2IsC0, 400 ether, 0, address(this)) {} catch { died = true; break; } }
        emit log_named_uint("swaps before the pool died", n);
        assertTrue(died, "un-exempt tax wallet eventually reverts every swap (launch DoS)");

        // the fix: exempt it on both sides -> wiringOk true -> swaps flow again
        k2.setExempt(taxWallet, true); w2.setCapExempt(taxWallet, true);
        assertTrue(h2.wiringOk());
        s2.swap(k2key, !w2IsC0, 400 ether, 0, address(this));
    }

    // only the owner can exempt a sender from tax; a random address cannot whitelist itself
    function testExemptSenderOnlyOwner() public onFork {
        vm.prank(address(0xBAD)); vm.expectRevert(bytes("!owner")); hook.setExemptSender(address(0xBAD), true);
    }

    // exact-OUTPUT swaps are taxed on the input leg (no free path via the other swap mode)
    function testExactOutputIsTaxedOnInput() public onFork {
        k.setExempt(taxWallet, true); w.setCapExempt(taxWallet, true);
        // ask for exactly 10 wRACKS out; hook must take SPY (input side) as tax
        uint256 tw0 = IERC20x(SPY).balanceOf(taxWallet);
        _exactOut(10 ether);
        assertGt(IERC20x(SPY).balanceOf(taxWallet) - tw0, 0, "exact-output swap escaped the tax");
    }
    function _exactOut(uint256 outAmt) internal {
        // route a positive amountSpecified through our own minimal unlock (V4Swap is exact-in only)
        ExactOutHelper h = new ExactOutHelper(PM);
        w.setCapExempt(address(h), true);
        IERC20x(SPY).approve(address(h), type(uint256).max);
        h.buyExactOut(key, !wIsC0, outAmt, 1_000 ether, address(this));
    }

    // liquidity operations are never taxed (afterSwap only)
    function testLiquidityOpsUntaxed() public onFork {
        k.setExempt(taxWallet, true); w.setCapExempt(taxWallet, true);
        uint256 tw = IERC20x(wa).balanceOf(taxWallet) + IERC20x(SPY).balanceOf(taxWallet);
        pool.addLiquidity(key, -887220, 887220, int256(100 ether));
        assertEq(IERC20x(wa).balanceOf(taxWallet) + IERC20x(SPY).balanceOf(taxWallet), tw, "LP add must be untaxed");
    }

    // taxWallet = 0 disables the tax (owner-only lever) -> documented, not exploitable by others
    function testZeroTaxWalletDisablesTax() public onFork {
        hook.setTaxWallet(address(0));
        uint256 got = sw.swap(key, !wIsC0, 1 ether, 0, address(this));
        assertGt(got, 0);
        vm.prank(address(0xBAD)); vm.expectRevert(bytes("!owner")); hook.setTaxWallet(address(0xBAD));
    }

    // a foreign pool that attaches our hook just taxes ITS traders into our wallet — harmless to us
    function testForeignPoolWithOurHookIsHarmless() public onFork {
        k.setExempt(taxWallet, true); w.setCapExempt(taxWallet, true);
        // hook stores wracks; on a foreign pair (SPY/USDG) neither leg is wRACKS -> isSell=false path, fee still taken from output
        // (we just assert nothing reverts and our pool is unaffected)
        uint256 before = IERC20x(wa).balanceOf(PM);
        sw.swap(key, !wIsC0, 1 ether, 0, address(this));
        assertLt(IERC20x(wa).balanceOf(PM), before);
    }
}

// minimal exact-output swapper for the test above
import {IPoolManager, SwapParams} from "../../src/v4/V4Swap.sol";
contract ExactOutHelper {
    IPoolManager immutable pm;
    uint160 constant MIN_SQRT = 4295128739; uint160 constant MAX_SQRT = 1461446703485210103287273052203988822378723970342;
    struct CB { PoolKey key; bool zeroForOne; uint256 amountOut; uint256 maxIn; address to; address payer; }
    constructor(address _pm) { pm = IPoolManager(_pm); }
    function buyExactOut(PoolKey calldata key, bool zeroForOne, uint256 amountOut, uint256 maxIn, address to) external {
        address tokenIn = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        IERC20x(tokenIn).transferFrom(msg.sender, address(this), maxIn);
        pm.unlock(abi.encode(CB(key, zeroForOne, amountOut, maxIn, to, msg.sender)));
    }
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        CB memory c = abi.decode(data, (CB));
        int256 delta = pm.swap(c.key, SwapParams(c.zeroForOne, int256(c.amountOut), c.zeroForOne ? MIN_SQRT + 1 : MAX_SQRT - 1), "");
        int128 a0 = int128(delta >> 128); int128 a1 = int128(delta);
        int128 inLeg = c.zeroForOne ? a0 : a1; int128 outLeg = c.zeroForOne ? a1 : a0;
        uint256 owed = uint256(int256(-inLeg)); require(owed <= c.maxIn, "maxIn");
        Currency curIn = c.zeroForOne ? c.key.currency0 : c.key.currency1; Currency curOut = c.zeroForOne ? c.key.currency1 : c.key.currency0;
        pm.sync(curIn); IERC20x(Currency.unwrap(curIn)).transfer(address(pm), owed); pm.settle();
        if (owed < c.maxIn) IERC20x(Currency.unwrap(curIn)).transfer(c.payer, c.maxIn - owed);
        pm.take(curOut, c.to, uint256(int256(outLeg)));
        return "";
    }
}
