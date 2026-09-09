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

contract TaxBreakdown is HookedBase {
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant PM  = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant SV  = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address taxWallet = address(0x7A11);
    Racks k; WRacks w; address wa; V4Swap sw; PoolKey key; bool wIsC0; TwapOracleV4 oracle;

    function setUp() public {
        if (SPY.code.length == 0) return;
        k = new Racks(1e27/1e6); w = new WRacks(address(k)); wa = address(w);
        k.setTaxExempt(wa, true); k.setExempt(taxWallet, true);
        k.mint(address(this), 10_000_000 ether); k.approve(wa, type(uint256).max); IW(wa).wrap(5_000_000 ether);
        deal(SPY, address(this), 20_000 ether);
        (address c0, address c1) = wa < SPY ? (wa, SPY) : (SPY, wa); wIsC0 = (wa == c0);
        TaxHook hook = _deployHook(PM, wa, address(k), taxWallet);
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, address(hook));
        V4Pool pool = new V4Pool(PM); pool.initialize(key, 79228162514264337593543950336);
        w.setCapExempt(PM, true); w.setCapExempt(address(pool), true);
        IERC20x(wa).approve(address(pool), type(uint256).max); IERC20x(SPY).approve(address(pool), type(uint256).max);
        pool.addLiquidity(key, -887220, 887220, int256(3_000 ether)); // ~3000 / 3000 reserve
        sw = new V4Swap(PM); w.setCapExempt(address(sw), true);
        IERC20x(wa).approve(address(sw), type(uint256).max); IERC20x(SPY).approve(address(sw), type(uint256).max);
        oracle = new TwapOracleV4(SV, keccak256(abi.encode(key)), wIsC0); hook.setOracle(address(oracle));
        for (uint i; i < 6; i++) { vm.warp(block.timestamp + 3 minutes); oracle.update(); } // settled TWAP
    }
    modifier onFork() { if (SPY.code.length == 0) { vm.skip(true); return; } _; }

    function _roundTrip(uint256 spyIn, string memory label) internal {
        uint256 snap = vm.snapshotState();
        uint256 twW0 = IERC20x(wa).balanceOf(taxWallet); uint256 twS0 = IERC20x(SPY).balanceOf(taxWallet);
        uint256 spy0 = IERC20x(SPY).balanceOf(address(this));
        uint256 wrOut = sw.swap(key, !wIsC0, spyIn, 0, address(this));            // BUY
        uint256 buyTax = IERC20x(wa).balanceOf(taxWallet) - twW0;
        uint256 buyBps = buyTax * 10000 / (wrOut + buyTax);
        uint256 spyBack = sw.swap(key, wIsC0, wrOut, 0, address(this));           // SELL
        uint256 sellTax = IERC20x(SPY).balanceOf(taxWallet) - twS0;
        uint256 sellBps = sellTax * 10000 / (spyBack + sellTax);
        uint256 lossBps = (spy0 - IERC20x(SPY).balanceOf(address(this))) * 10000 / spyIn;
        emit log(label);
        emit log_named_uint("  trade size as % of pool reserve (bps)", spyIn * 10000 / 3000 ether);
        emit log_named_uint("  BUY  tax bps (base 400 + impact)", buyBps);
        emit log_named_uint("  SELL tax bps (base 400 + impact)", sellBps);
        emit log_named_uint("  total round-trip loss bps (tax+fees+slippage)", lossBps);
        vm.revertToState(snap);
    }
    function testBreakdown() public onFork {
        _roundTrip(1 ether,   "=== SMALL trade: 1 SPY into a 3000-SPY pool ===");
        _roundTrip(30 ether,  "=== MEDIUM trade: 30 SPY (1% of pool) ===");
        _roundTrip(100 ether, "=== BIG trade: 100 SPY (3.3% of pool) (the stress-test case) ===");
    }
}
