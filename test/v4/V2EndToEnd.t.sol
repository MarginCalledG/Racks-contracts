// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {Racks} from "../../src/Racks.sol";
import {TwapOracle} from "../../src/TwapOracle.sol";

interface IERC20m { function balanceOf(address) external view returns (uint256); function approve(address,uint256) external returns (bool); function decimals() external view returns (uint8); }
interface IV2Factory { function createPair(address,address) external returns (address); }
interface IV2Router {
    function addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256) external returns (uint256,uint256,uint256);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256,uint256,address[] calldata,address,uint256) external;
    function getAmountsOut(uint256, address[] calldata) external view returns (uint256[] memory);
}
interface IV2Pair { function token0() external view returns (address); function sync() external; function getReserves() external view returns (uint112,uint112,uint32); }

/// Can the WHOLE protocol live on Robinhood's real Uniswap v2 — no wrapper, no hook?
contract V2EndToEnd is Test {
    address constant SPY     = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant USDG    = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;
    address constant ROUTER  = 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba;
    address taxWallet = address(0x7A11);
    Racks k; IV2Pair pair; TwapOracle oracle;
    address[] W;

    function setUp() public {
        if (SPY.code.length == 0) return;
        k = new Racks(1e27/1e6);
        k.mint(address(this), 69_420_000_000 ether);
        deal(SPY, address(this), 20_000 ether);
        pair = IV2Pair(IV2Factory(FACTORY).createPair(address(k), SPY));
        oracle = new TwapOracle(address(pair), address(k));
        k.setDex(address(pair), true); k.setTaxOracle(address(oracle));
        k.setTaxWallet(taxWallet); k.setExempt(taxWallet, true); k.setTaxExempt(address(this), true);
        k.setCapExempt(address(pair), true);          // pair is the distributor: its deliveries = acquisitions
        k.approve(ROUTER, type(uint256).max); IERC20m(SPY).approve(ROUTER, type(uint256).max);
        IV2Router(ROUTER).addLiquidity(address(k), SPY, 69_420_000_000 ether, 6 ether, 0, 0, address(this), block.timestamp);
        for (uint i; i < 6; i++) { address u = address(uint160(0x3000 + i)); W.push(u); deal(SPY, u, 50 ether);
            vm.prank(u); IERC20m(SPY).approve(ROUTER, type(uint256).max); vm.prank(u); k.approve(ROUTER, type(uint256).max); }
    }
    modifier onFork() { if (SPY.code.length == 0) { vm.skip(true); return; } _; }

    function _buy(address who, uint256 spyIn) internal returns (uint256 got) {
        pair.sync();                                   // reconcile melt BEFORE quoting/swapping
        address[] memory p = new address[](2); p[0] = SPY; p[1] = address(k);
        uint256 b = k.balanceOf(who);
        vm.prank(who); IV2Router(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(spyIn, 0, p, who, block.timestamp);
        got = k.balanceOf(who) - b;
    }
    function _sell(address who, uint256 racksIn) internal returns (uint256 got) {
        pair.sync();
        address[] memory p = new address[](2); p[0] = address(k); p[1] = SPY;
        uint256 b = IERC20m(SPY).balanceOf(who);
        vm.prank(who); IV2Router(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(racksIn, 0, p, who, block.timestamp);
        got = IERC20m(SPY).balanceOf(who) - b;
    }

    // 1) LAUNCH HOUR: 8% flat + the cumulative 1% cap must work WITHOUT any wrapper
    function testLaunchCapAndTaxWithoutWrapper() public onFork {
        k.enableTrading();
        uint256 cap = k.maxWallet();
        uint256 got = _buy(W[0], 0.02 ether);   // ~0.3% of supply, under the 1% cap
        emit log_named_uint("launch buy RACKS", got); emit log_named_uint("1% cap", cap);
        emit log_named_uint("tax wallet RACKS", k.balanceOf(taxWallet));
        assertLe(k.launchReceived(W[0]), cap, "cap respected");
        assertGt(k.balanceOf(taxWallet), 0, "8% launch tax collected at the token");
        // buy -> move away -> buy again must NOT reset the ledger
        vm.prank(W[0]); k.transfer(address(0xA17), k.balanceOf(W[0]) / 2);   // move tokens away
        vm.expectRevert(); _buy(W[0], 1 ether);   // a 1 SPY buy would blow far past the cap
        emit log("second over-cap buy REVERTED (cumulative ledger holds)");
    }

    // 2) AFTER LAUNCH: dynamic tax off real reserves — sell pressure raises sell tax, lowers buy tax
    function testDynamicTaxOnRealReserves() public onFork {
        k.enableTrading(); vm.warp(block.timestamp + 1 hours + 1); k.poke();
        for (uint i; i < 6; i++) { vm.warp(block.timestamp + 3 minutes); oracle.update(); }
        _buy(W[1], 2 ether);
        uint256 tw0 = k.balanceOf(taxWallet);
        uint256 sold = k.balanceOf(W[1]) / 2;
        _sell(W[1], sold);
        uint256 sellBps = (k.balanceOf(taxWallet) - tw0) * 10000 / sold;
        uint256 tw1 = k.balanceOf(taxWallet);
        uint256 gotB = _buy(W[2], 1 ether);
        uint256 buyBps = (k.balanceOf(taxWallet) - tw1) * 10000 / (gotB + k.balanceOf(taxWallet) - tw1);
        emit log_named_uint("sell tax bps after dump", sellBps);
        emit log_named_uint("buy  tax bps after dump", buyBps);
        assertGe(sellBps, 400); assertLe(sellBps, 800);
        assertLe(buyBps, sellBps, "buy cheaper than sell under sell pressure");
    }

    // 3) USDG -> RACKS in ONE tx via the v2 router (USDG->SPY->RACKS). Does a v2 path exist?
    function testUsdgPathExists() public onFork {
        address[] memory p = new address[](3); p[0] = USDG; p[1] = SPY; p[2] = address(k);
        try IV2Router(ROUTER).getAmountsOut(1000 * 10 ** IERC20m(USDG).decimals(), p) returns (uint256[] memory a) {
            emit log_named_uint("USDG->SPY->RACKS quote (RACKS)", a[2]);
            assertGt(a[2], 0, "v2 route exists");
        } catch {
            emit log("NO v2 USDG/SPY pair -> USDG leg must route via v4 (zap keeps one v4 hop)");
        }
    }

    // 4) melt + sync + trading over 7 days: pool solvent, price reflects melt, tax accrues
    function testWeekOfMeltAndTrading() public onFork {
        k.enableTrading(); vm.warp(block.timestamp + 1 hours + 1); k.poke();
        uint256 first = _buy(W[3], 1 ether);
        for (uint d; d < 7; d++) { vm.warp(block.timestamp + 1 days); k.poke(); pair.sync(); _buy(W[4], 0.2 ether); }
        uint256 last = _buy(W[5], 1 ether);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        emit log_named_uint("RACKS per SPY at start", first);
        emit log_named_uint("RACKS per SPY after 7d", last);
        emit log_named_uint("tax collected (RACKS)", k.balanceOf(taxWallet));
        emit log_named_uint("reserve0", r0); emit log_named_uint("reserve1", r1);
        assertLt(last, first, "melt made RACKS scarcer -> price up");
        assertGt(k.balanceOf(taxWallet), 0);
    }
}
