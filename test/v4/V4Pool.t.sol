// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {V4Swap, PoolKey, Currency, IERC20x} from "../../src/v4/V4Swap.sol";
import {V4Pool} from "../../src/v4/V4Pool.sol";
import {Racks} from "../../src/Racks.sol";
import {WRacks} from "../../src/WRacks.sol";

interface IWrap { function wrap(uint256) external returns (uint256); function approve(address,uint256) external returns (bool); function balanceOf(address) external view returns (uint256); function transfer(address,uint256) external returns (bool); }

contract V4PoolTest is Test {
    address constant SPY  = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant POOLMANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    uint160 constant SQRT_1TO1 = 79228162514264337593543950336; // 2^96 = price 1:1

    function testCreateAndSwapOwnPool() public {
        if (SPY.code.length == 0) { vm.skip(true); return; }

        // 1) our tokens: deploy RACKS, mint, wrap -> wRACKS
        Racks k = new Racks(1e27 / 1e6);
        WRacks w = new WRacks(address(k));
                k.setTaxExempt(address(w), true);
        k.mint(address(this), 1_000_000 ether);
        k.approve(address(w), type(uint256).max);
        uint256 wr = IWrap(address(w)).wrap(500_000 ether);
        emit log_named_uint("wRACKS minted", wr);

        // 2) get SPY to seed the pool
        deal(SPY, address(this), 3_000 ether); // 1000 fuer LP + Rest fuer Swaps

        // 3) sort into currency0/currency1 (v4 requires currency0 < currency1)
        address wa = address(w);
        (address c0, address c1) = wa < SPY ? (wa, SPY) : (SPY, wa);
        PoolKey memory key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, address(0));

        // 4) create + seed the pool
        V4Pool pool = new V4Pool(POOLMANAGER);
        pool.initialize(key, SQRT_1TO1);
        IERC20x(wa).approve(address(pool), type(uint256).max);
        IERC20x(SPY).approve(address(pool), type(uint256).max);
        int24 lo = -887220; int24 hi = 887220; // full range (tickSpacing 60)
        pool.addLiquidity(key, lo, hi, int256(1_000 ether));
        emit log("pool created + liquidity added");

        // 5) swap SPY -> wRACKS through OUR pool
        V4Swap v4 = new V4Swap(POOLMANAGER);
        IERC20x(SPY).approve(address(v4), type(uint256).max);
        // SPY -> wRACKS: is SPY currency0 or 1?
        bool zeroForOne = (SPY == c0); // swapping SPY(in) for wRACKS(out)
        uint256 out = v4.swap(key, zeroForOne, 10 ether, 0, address(this));
        emit log_named_uint("wRACKS out of our pool", out);
        assertGt(out, 0, "swap through own pool failed");
    }
}
