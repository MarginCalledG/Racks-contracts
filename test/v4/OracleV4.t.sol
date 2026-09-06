// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {V4Swap, PoolKey, Currency, IERC20x} from "../../src/v4/V4Swap.sol";
import {V4Pool} from "../../src/v4/V4Pool.sol";
import {TwapOracleV4} from "../../src/v4/TwapOracleV4.sol";
import {Racks} from "../../src/Racks.sol";
import {WRacks} from "../../src/WRacks.sol";

interface IW { function wrap(uint256) external returns (uint256); function approve(address,uint256) external returns (bool); }

contract OracleV4Test is Test {
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant PM  = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant SV  = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    uint160 constant SQRT_1TO1 = 79228162514264337593543950336;

    function testV4OracleReadsAndDynamicTaxResponds() public {
        if (SPY.code.length == 0) { vm.skip(true); return; }

        Racks k = new Racks(1e27 / 1e6);
        WRacks w = new WRacks(address(k));
        k.setTaxExempt(address(w), true); /* wrapper MUST melt: never setExempt */
        k.mint(address(this), 5_000_000 ether);
        k.approve(address(w), type(uint256).max);
        IW(address(w)).wrap(3_000_000 ether);
        deal(SPY, address(this), 10_000 ether);

        address wa = address(w);
        (address c0, address c1) = wa < SPY ? (wa, SPY) : (SPY, wa);
        bool wracksIsC0 = (wa == c0);
        PoolKey memory key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, address(0));

        V4Pool pool = new V4Pool(PM);
        pool.initialize(key, SQRT_1TO1);
        IERC20x(wa).approve(address(pool), type(uint256).max);
        IERC20x(SPY).approve(address(pool), type(uint256).max);
        pool.addLiquidity(key, -887220, 887220, int256(3_000 ether));

        bytes32 poolId = keccak256(abi.encode(key));
        TwapOracleV4 oracle = new TwapOracleV4(SV, poolId, wracksIsC0);

        // 1) reads a sane spot (~1e18 SPY-per-wRACKS at 1:1)
        uint256 sp0 = oracle.spot();
        emit log_named_uint("spot (1e18)", sp0);
        assertApproxEqRel(sp0, 1e18, 0.02e18);

        // 2) build a TWAP baseline over several periods at stable price
        for (uint i = 0; i < 6; i++) { vm.warp(block.timestamp + 3 minutes); oracle.update(); }
        uint256 baseSell = oracle.taxBps(0, true);
        emit log_named_uint("baseline sell tax bps", baseSell);

        // 3) move price DOWN for wRACKS: dump wRACKS -> SPY
        V4Swap sw = new V4Swap(PM);
        IERC20x(wa).approve(address(sw), type(uint256).max);
        bool wracksIn = (wa == c0); // wRACKS -> SPY
        sw.swap(key, wracksIn, 800 ether, 0, address(this));

        uint256 spAfter = oracle.spot();
        uint256 sellAfter = oracle.taxBps(0, true);
        emit log_named_uint("spot after dump (1e18)", spAfter);
        emit log_named_uint("sell tax after dump bps", sellAfter);

        assertLt(spAfter, sp0, "spot should drop after dumping wRACKS");
        assertGt(sellAfter, baseSell, "sell tax should rise under sell pressure");
        assertLe(sellAfter, 800, "never above 8% cap");
    }
}
