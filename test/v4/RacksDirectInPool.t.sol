// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {V4Swap, PoolKey, Currency, IERC20x} from "../../src/v4/V4Swap.sol";
import {V4Pool} from "../../src/v4/V4Pool.sol";
import {Racks} from "../../src/Racks.sol";

/// What happens if melting RACKS sits DIRECTLY in a standard v4 pool (no wrapper)?
contract RacksDirectInPool is Test {
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant PM  = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    Racks k; V4Pool pool; V4Swap sw; PoolKey key; bool kIsC0;

    function setUp() public {
        if (SPY.code.length == 0) return;
        k = new Racks(1e27/1e6);                       // RACKS melts; PoolManager NOT exempt
        k.mint(address(this), 10_000_000 ether); deal(SPY, address(this), 20_000 ether);
        (address c0, address c1) = address(k) < SPY ? (address(k), SPY) : (SPY, address(k)); kIsC0 = (address(k) == c0);
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, address(0));
        pool = new V4Pool(PM); pool.initialize(key, 79228162514264337593543950336);
        k.approve(address(pool), type(uint256).max); IERC20x(SPY).approve(address(pool), type(uint256).max);
        pool.addLiquidity(key, -887220, 887220, int256(3_000 ether));   // ~3000 RACKS / 3000 SPY
        sw = new V4Swap(PM); k.approve(address(sw), type(uint256).max); IERC20x(SPY).approve(address(sw), type(uint256).max);
    }
    modifier onFork() { if (SPY.code.length == 0) { vm.skip(true); return; } _; }

    function testMeltingRacksBreaksTheV4Pool() public onFork {
        uint256 pmRacks0 = k.balanceOf(PM);
        emit log_named_uint("PoolManager RACKS at deposit", pmRacks0);
        vm.warp(block.timestamp + 7 days); k.poke();                     // a week of melt
        uint256 pmRacks1 = k.balanceOf(PM);
        emit log_named_uint("PoolManager RACKS after 7d melt", pmRacks1);
        emit log_named_uint("pool STILL thinks its RACKS reserve is (approx)", pmRacks0);
        // 1) the pool prices RACKS as if nothing melted: a buyer of RACKS gets the pre-melt amount
        uint256 got = sw.swap(key, !kIsC0, 1 ether, 0, address(this));
        emit log_named_uint("buyer gets RACKS for 1 SPY (pre-melt pricing)", got);
        // 2) the LP tries to withdraw everything: the pool owes MORE RACKS than the PoolManager holds
        vm.expectRevert();
        pool.removeLiquidity(key, -887220, 887220, int256(3_000 ether));
        emit log("removeLiquidity REVERTED: pool is insolvent in RACKS (owes pre-melt reserve)");
        assertLt(pmRacks1, pmRacks0 * 70 / 100, "melt happened underneath the pool");
    }
}
