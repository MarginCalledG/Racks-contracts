// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {V4Swap, PoolKey, Currency, IERC20x} from "./V4Swap.sol";

interface IWR {
    function wrap(uint256) external returns (uint256);
    function unwrap(uint256) external returns (uint256);
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function LAUNCH_TAX_BPS() external view returns (uint256);
}
interface IRacksLaunch {
    function inLaunchWindow() external view returns (bool);
    function maxWallet() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}
struct QuoteExactSingleParams { PoolKey poolKey; bool zeroForOne; uint128 exactAmount; bytes hookData; }
interface IV4Quoter {
    function quoteExactOutputSingle(QuoteExactSingleParams memory p) external returns (uint256 amountIn, uint256 gasEst);
    function quoteExactInputSingle(QuoteExactSingleParams memory p) external returns (uint256 amountOut, uint256 gasEst);
}

/// One-click RACKS in/out, with a launch-hour buy cap of 1% AFTER tax.
/// Over-cap buys succeed: the zap buys only up to the cap and REFUNDS the unused USDG,
/// so the buyer pays only for the 1% they receive.
contract Zap {
    V4Swap    public immutable swapper;
    IWR       public immutable w;
    IERC20x   public immutable racks;
    IRacksLaunch public immutable racksL;
    IV4Quoter public immutable quoter;
    address   public immutable usdg;
    address   public immutable spy;
    PoolKey   public spyUsdg;
    PoolKey   public wrSpy;

    constructor(
        address _swapper, address _w, address _racks, address _usdg, address _spy,
        address _quoter, PoolKey memory _spyUsdg, PoolKey memory _wrSpy
    ) {
        swapper = V4Swap(_swapper); w = IWR(_w); racks = IERC20x(_racks); racksL = IRacksLaunch(_racks);
        quoter = IV4Quoter(_quoter); usdg = _usdg; spy = _spy; spyUsdg = _spyUsdg; wrSpy = _wrSpy;
    }

    function _dir(PoolKey memory k, address tokenIn) internal pure returns (bool) {
        return tokenIn == Currency.unwrap(k.currency0);
    }

    /// how much USDG to actually spend so the buyer's post-tax RACKS stays <= 1% cap
    function _launchCapUsdg(uint256 usdgIn, address to) internal returns (uint256) {
        if (!racksL.inLaunchWindow()) return usdgIn;
        uint256 maxW = racksL.maxWallet();
        uint256 cur  = racksL.balanceOf(to);
        if (cur >= maxW) return 0;
        uint256 capRacks = maxW - cur;
        if (!_wouldExceed(usdgIn, capRacks)) return usdgIn;   // cheap forward check
        uint256 need = _usdgForCap(capRacks);                 // backward solve, only when needed
        return usdgIn < need ? usdgIn : need;
    }

    function _grossFromWr(uint256 wr) internal view returns (uint256) {
        uint256 held = racks.balanceOf(address(w));
        return held == 0 ? wr : wr * held / w.totalSupply();
    }
    function _wrFromGross(uint256 gross) internal view returns (uint256) {
        uint256 held = racks.balanceOf(address(w));
        return held == 0 ? gross : gross * w.totalSupply() / held;
    }

    function _wouldExceed(uint256 usdgIn, uint256 capRacks) internal returns (bool) {
        (uint256 spyOut,) = quoter.quoteExactInputSingle(QuoteExactSingleParams(spyUsdg, _dir(spyUsdg, usdg), uint128(usdgIn), ""));
        (uint256 wrOut,)  = quoter.quoteExactInputSingle(QuoteExactSingleParams(wrSpy,   _dir(wrSpy, spy),    uint128(spyOut), ""));
        uint256 gross = _grossFromWr(wrOut);
        return gross - gross * w.LAUNCH_TAX_BPS() / 10000 > capRacks;
    }

    function _usdgForCap(uint256 capRacks) internal returns (uint256 usdgNeeded) {
        uint256 grossNeeded = (capRacks * 995 / 1000) * 10000 / (10000 - w.LAUNCH_TAX_BPS());
        uint256 wrNeeded = _wrFromGross(grossNeeded);
        (uint256 spyNeeded,) = quoter.quoteExactOutputSingle(QuoteExactSingleParams(wrSpy, _dir(wrSpy, spy), uint128(wrNeeded), ""));
        (usdgNeeded,)        = quoter.quoteExactOutputSingle(QuoteExactSingleParams(spyUsdg, _dir(spyUsdg, usdg), uint128(spyNeeded), ""));
    }

    /// USDG in -> RACKS out (post buy-side tax). Excess over the launch cap is refunded in USDG.
    function buyRacks(uint256 usdgIn, uint256 minRacksOut, address to) external returns (uint256 racksOut) {
        require(IERC20x(usdg).transferFrom(msg.sender, address(this), usdgIn), "pull");
        uint256 use = _launchCapUsdg(usdgIn, to);
        if (use == 0) { require(IERC20x(usdg).transfer(to, usdgIn), "refund"); return 0; }

        IERC20x(usdg).approve(address(swapper), use);
        uint256 spyAmt = swapper.swap(spyUsdg, _dir(spyUsdg, usdg), use, 0, address(this));
        IERC20x(spy).approve(address(swapper), spyAmt);
        uint256 wrAmt  = swapper.swap(wrSpy, _dir(wrSpy, spy), spyAmt, 0, address(this));
        racksOut = w.unwrap(wrAmt);
        require(racksOut >= minRacksOut, "slippage");
        require(racks.transfer(to, racksOut), "send");
        if (use < usdgIn) require(IERC20x(usdg).transfer(to, usdgIn - use), "refund");
    }

    /// RACKS in -> USDG out (post sell-side tax).
    function sellRacks(uint256 racksIn, uint256 minUsdgOut, address to) external returns (uint256 usdgOut) {
        require(racks.transferFrom(msg.sender, address(this), racksIn), "pull");
        racks.approve(address(w), racksIn);
        uint256 wrAmt  = w.wrap(racksIn);
        w.approve(address(swapper), wrAmt);
        uint256 spyAmt = swapper.swap(wrSpy, _dir(wrSpy, address(w)), wrAmt, 0, address(this));
        IERC20x(spy).approve(address(swapper), spyAmt);
        usdgOut = swapper.swap(spyUsdg, _dir(spyUsdg, spy), spyAmt, 0, address(this));
        require(usdgOut >= minUsdgOut, "slippage");
        require(IERC20x(usdg).transfer(to, usdgOut), "send");
    }
}
