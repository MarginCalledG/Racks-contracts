// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {Racks} from "../../src/Racks.sol";
import {TwapOracle} from "../../src/TwapOracle.sol";

interface IERC20m { function balanceOf(address) external view returns (uint256); function approve(address,uint256) external returns (bool); function transfer(address,uint256) external returns (bool); }
interface IV2Factory { function createPair(address,address) external returns (address); function getPair(address,address) external view returns (address); }
interface IV2Router {
    function addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256) external returns (uint256,uint256,uint256);
    function removeLiquidity(address,address,uint256,uint256,uint256,address,uint256) external returns (uint256,uint256);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256,uint256,address[] calldata,address,uint256) external;
}
interface IV2Pair { function getReserves() external view returns (uint112,uint112,uint32); function sync() external; function token0() external view returns (address); function balanceOf(address) external view returns (uint256); function approve(address,uint256) external returns (bool); }

/// The SAME experiment as RacksDirectInPool, on Robinhood Chain's REAL Uniswap v2: melting RACKS directly in the pair.
contract RacksOnRealV2 is Test {
    address constant SPY     = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;
    address constant ROUTER  = 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba;
    address taxWallet = address(0x7A11); address buyer = address(0xB0B);
    Racks k; IV2Pair pair; bool kIs0;

    function setUp() public {
        if (SPY.code.length == 0) return;
        k = new Racks(1e27/1e6);
        k.mint(address(this), 10_000_000 ether); deal(SPY, address(this), 20_000 ether); deal(SPY, buyer, 1_000 ether);
        pair = IV2Pair(IV2Factory(FACTORY).createPair(address(k), SPY)); kIs0 = (pair.token0() == address(k));
        k.setDex(address(pair), true);                 // trades with the pair are taxed (buy/sell)
        k.setTaxOracle(address(new TwapOracle(address(pair), address(k))));   // dynamic tax straight off the pair's reserves
        k.setTaxWallet(taxWallet); k.setExempt(taxWallet, true);
        k.setTaxExempt(address(this), true);           // LP seeding is not a trade
        k.approve(ROUTER, type(uint256).max); IERC20m(SPY).approve(ROUTER, type(uint256).max);
        IV2Router(ROUTER).addLiquidity(address(k), SPY, 3_000 ether, 3_000 ether, 0, 0, address(this), block.timestamp);
        vm.prank(buyer); IERC20m(SPY).approve(ROUTER, type(uint256).max);
    }
    modifier onFork() { if (SPY.code.length == 0) { vm.skip(true); return; } _; }
    function _racksReserve() internal view returns (uint256) { (uint112 r0, uint112 r1,) = pair.getReserves(); return kIs0 ? r0 : r1; }
    function _buy(uint256 spyIn) internal returns (uint256 got) {
        address[] memory path = new address[](2); path[0] = SPY; path[1] = address(k);
        uint256 b = k.balanceOf(buyer);
        vm.prank(buyer); IV2Router(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(spyIn, 0, path, buyer, block.timestamp);
        got = k.balanceOf(buyer) - b;
    }

    function testMeltingRacksWorksOnV2() public onFork {
        uint256 got0 = _buy(1 ether);
        emit log_named_uint("RACKS reserve at start", _racksReserve());
        emit log_named_uint("buyer gets RACKS for 1 SPY at start", got0);

        vm.warp(block.timestamp + 7 days); k.poke();                     // a week of melt
        pair.sync();                                                     // v2's reconciliation (permissionless)
        uint256 reserveAfter = _racksReserve();
        uint256 got1 = _buy(1 ether);
        emit log_named_uint("RACKS reserve after 7d melt + sync", reserveAfter);
        emit log_named_uint("buyer gets RACKS for 1 SPY after melt", got1);
        emit log_named_uint("tax collected in RACKS", k.balanceOf(taxWallet));

        // the LP withdraws EVERYTHING: no insolvency, gets the melted (real) amount back
        uint256 lp = pair.balanceOf(address(this)); pair.approve(ROUTER, lp);
        (uint256 rOut, uint256 sOut) = IV2Router(ROUTER).removeLiquidity(address(k), SPY, lp, 0, 0, address(this), block.timestamp);
        emit log_named_uint("LP withdrew RACKS", rOut); emit log_named_uint("LP withdrew SPY", sOut);

        assertLt(reserveAfter, 3_000 ether * 70 / 100, "reserve reflects the melt");
        assertLt(got1, got0 * 70 / 100, "MELT SHOWS UP IN THE PRICE: fewer RACKS per SPY");
        assertGt(k.balanceOf(taxWallet), 0, "trades taxed at the token level, no hook");
        assertGt(rOut, 0, "LP can exit - pool stays solvent");
    }
}
