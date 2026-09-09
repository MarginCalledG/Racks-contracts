// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {V4Swap, PoolKey, Currency, IERC20x} from "../../src/v4/V4Swap.sol";
import {V4Pool} from "../../src/v4/V4Pool.sol";
import {TaxHook} from "../../src/v4/TaxHook.sol";
import {TwapOracleV4} from "../../src/v4/TwapOracleV4.sol";
import {Racks} from "../../src/Racks.sol";
import {WRacks} from "../../src/WRacks.sol";

interface IW { function wrap(uint256) external returns (uint256); function approve(address,uint256) external returns (bool); }
contract RevertingOracle { function update() external pure { revert("boom"); } function taxBps(uint256, bool) external pure returns (uint256) { revert("boom"); } }

/// Tax enforced AT THE POOL by a v4 afterSwap hook — unavoidable for direct traders.
contract TaxHookTest is Test {
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant PM  = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant SV  = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    uint160 constant SQRT_1TO1 = 79228162514264337593543950336;
    uint160 constant FLAGS = uint160((1 << 6) | (1 << 2)); // AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA
    address taxWallet = address(0x7A11);

    Racks k; WRacks w; address wa; TaxHook hook; V4Swap sw; PoolKey key; bool wIsC0; TwapOracleV4 oracle;

    function _mine(bytes memory initCode) internal view returns (bytes32 salt, address predicted) {
        bytes32 h = keccak256(initCode);
        for (uint256 s; s < 500000; s++) {
            address a = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(s), h)))));
            if (uint160(a) & uint160((1 << 14) - 1) == FLAGS) return (bytes32(s), a);
        }
        revert("no salt");
    }

    function setUp() public {
        if (SPY.code.length == 0) return;
        k = new Racks(1e27/1e6); w = new WRacks(address(k)); wa = address(w);
        k.setTaxExempt(wa, true); k.setExempt(taxWallet, true);
        k.mint(address(this), 10_000_000 ether); k.approve(wa, type(uint256).max); IW(wa).wrap(5_000_000 ether);
        deal(SPY, address(this), 20_000 ether);

        // mine + deploy the hook at an address whose low bits declare afterSwap + returns-delta
        bytes memory init = abi.encodePacked(type(TaxHook).creationCode, abi.encode(PM, wa, address(k), taxWallet));
        (bytes32 salt, address predicted) = _mine(init);
        hook = new TaxHook{salt: salt}(PM, wa, address(k), taxWallet);
        require(address(hook) == predicted, "mine mismatch");

        (address c0, address c1) = wa < SPY ? (wa, SPY) : (SPY, wa); wIsC0 = (wa == c0);
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, address(hook));   // HOOKED pool
        V4Pool pool = new V4Pool(PM); pool.initialize(key, SQRT_1TO1);
        w.setCapExempt(PM, true); w.setCapExempt(address(pool), true);
        IERC20x(wa).approve(address(pool), type(uint256).max); IERC20x(SPY).approve(address(pool), type(uint256).max);
        pool.addLiquidity(key, -887220, 887220, int256(3_000 ether));
        sw = new V4Swap(PM); w.setCapExempt(address(sw), true);
        IERC20x(wa).approve(address(sw), type(uint256).max); IERC20x(SPY).approve(address(sw), type(uint256).max);
        oracle = new TwapOracleV4(SV, keccak256(abi.encode(key)), wIsC0);
        hook.setOracle(address(oracle));
        k.setWrapper(wa);                                                       // F3 ledger wiring
    }
    modifier onFork() { if (SPY.code.length == 0) { vm.skip(true); return; } _; }

    // DIRECT pool buy (no zap, no wrapper): 4% of the wRACKS output lands at the tax wallet
    function testDirectBuyIsTaxed() public onFork {
        uint256 tw0 = IERC20x(wa).balanceOf(taxWallet);
        uint256 got = sw.swap(key, !wIsC0, 10 ether, 0, address(this));      // SPY -> wRACKS
        uint256 tax = IERC20x(wa).balanceOf(taxWallet) - tw0;
        emit log_named_uint("buyer got wRACKS", got); emit log_named_uint("tax wallet got wRACKS", tax);
        assertGt(tax, 0, "direct buy must be taxed");
        uint256 bps = tax * 10000 / (got + tax);
        assertTrue(bps >= 400 && bps <= 500, "base 4% + small impact");
    }

    // DIRECT pool sell: 4% of the SPY output lands at the tax wallet — in SPY (reserve-ready)
    function testDirectSellIsTaxedInSpy() public onFork {
        uint256 tw0 = IERC20x(SPY).balanceOf(taxWallet);
        uint256 got = sw.swap(key, wIsC0, 10 ether, 0, address(this));       // wRACKS -> SPY
        uint256 tax = IERC20x(SPY).balanceOf(taxWallet) - tw0;
        emit log_named_uint("seller got SPY", got); emit log_named_uint("tax wallet got SPY", tax);
        uint256 bps = tax * 10000 / (got + tax);
        assertTrue(bps >= 400 && bps <= 500, "base 4% + small impact, paid in SPY");
    }

    // launch window: flat 8% at the pool
    function testLaunchWindowEightPercent() public onFork {
        k.enableTrading();
        uint256 tw0 = IERC20x(wa).balanceOf(taxWallet);
        uint256 got = sw.swap(key, !wIsC0, 1 ether, 0, address(this));
        uint256 tax = IERC20x(wa).balanceOf(taxWallet) - tw0;
        assertApproxEqRel(tax, (got + tax) * 800 / 10000, 0.01e18, "8% during launch");
    }

    // dynamic: after a dump, the next seller pays up to the 8% cap; a buyer pays the 1% floor
    function testDynamicRateAfterDump() public onFork {
        for (uint i; i < 6; i++) { vm.warp(block.timestamp + 3 minutes); oracle.update(); }
        sw.swap(key, wIsC0, 800 ether, 0, address(this));                     // big dump
        uint256 tw0 = IERC20x(SPY).balanceOf(taxWallet);
        uint256 got = sw.swap(key, wIsC0, 1 ether, 0, address(this));         // next seller
        uint256 sellTax = IERC20x(SPY).balanceOf(taxWallet) - tw0;
        uint256 sellBps = sellTax * 10000 / (got + sellTax);
        uint256 tw1 = IERC20x(wa).balanceOf(taxWallet);
        uint256 gotB = sw.swap(key, !wIsC0, 1 ether, 0, address(this));       // a buyer under sell pressure
        uint256 buyBps = (IERC20x(wa).balanceOf(taxWallet) - tw1) * 10000 / (gotB + IERC20x(wa).balanceOf(taxWallet) - tw1);
        emit log_named_uint("sell tax bps after dump", sellBps); emit log_named_uint("buy tax bps after dump", buyBps);
        assertGt(sellBps, 600, "sell tax must rise toward the cap");
        assertLt(buyBps, 300, "buy tax must fall toward the floor");
    }

    // a reverting oracle must never brick the pool: the hook falls back to the base rate
    function testRevertingOracleFallsBack() public onFork {
        hook.setOracle(address(new RevertingOracle()));
        uint256 tw0 = IERC20x(wa).balanceOf(taxWallet);
        uint256 got = sw.swap(key, !wIsC0, 1 ether, 0, address(this));          // must not revert
        uint256 bps = (IERC20x(wa).balanceOf(taxWallet) - tw0) * 10000 / (got + IERC20x(wa).balanceOf(taxWallet) - tw0);
        assertApproxEqAbs(bps, 400, 2, "fell back to the 4% base rate");
    }

    // chunking no longer helps: 10 small sells pay >= one big sell (each chunk moves the price)
    function testChunkingDoesNotReduceTax() public onFork {
        for (uint i; i < 6; i++) { vm.warp(block.timestamp + 3 minutes); oracle.update(); }
        uint256 snap = vm.snapshotState();
        uint256 tw0 = IERC20x(SPY).balanceOf(taxWallet);
        sw.swap(key, wIsC0, 500 ether, 0, address(this));                     // one big sell
        uint256 taxBig = IERC20x(SPY).balanceOf(taxWallet) - tw0;
        vm.revertToState(snap);
        tw0 = IERC20x(SPY).balanceOf(taxWallet);
        for (uint i; i < 10; i++) sw.swap(key, wIsC0, 50 ether, 0, address(this)); // ten chunks, same block
        uint256 taxChunks = IERC20x(SPY).balanceOf(taxWallet) - tw0;
        emit log_named_uint("tax one big sell (SPY)", taxBig); emit log_named_uint("tax 10 chunks (SPY)", taxChunks);
        assertGe(taxChunks * 100, taxBig * 95, "chunking must not materially reduce tax");
    }
}
