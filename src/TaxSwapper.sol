// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20x {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}
interface ISwapRouter {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        external returns (uint256 out);
}
/// price reference for slippage floor (in production: pool/TWAP; here: injectable)
interface IPriceSource { function expectedOut(uint256 racksIn) external view returns (uint256); }

/// @title TaxSwapper — auto-converts accumulated tax RACKS -> SPY -> reserve, batched at a threshold
/// @dev Is set as Racks.taxWallet (melt- & tax-exempt) so tax RACKS accrues here without decay.
contract TaxSwapper {
    IERC20x public immutable racks;
    IERC20x public immutable spy;
    ISwapRouter public router;
    IPriceSource public price;
    address public reserve;
    address public owner;

    uint256 public threshold;       // min accrued RACKS before a swap fires
    uint256 public maxSlippageBps;  // hard-capped at 1000 (10%)
    bool internal locked;

    event Swapped(uint256 racksIn, uint256 spyOut);

    modifier onlyOwner() { require(msg.sender == owner, "!owner"); _; }
    modifier nonReentrant() { require(!locked, "reentrant"); locked = true; _; locked = false; }

    constructor(
        address _racks, address _spy, address _router, address _price,
        address _reserve, uint256 _threshold, uint256 _maxSlippageBps
    ) {
        require(_maxSlippageBps <= 1000, "slip cap");
        racks = IERC20x(_racks); spy = IERC20x(_spy);
        router = ISwapRouter(_router); price = IPriceSource(_price);
        reserve = _reserve; owner = msg.sender;
        threshold = _threshold; maxSlippageBps = _maxSlippageBps;
    }

    function pending() public view returns (uint256) { return racks.balanceOf(address(this)); }

    /// permissionless: anyone (or a keeper) can fire once enough tax has accrued
    function swap() external nonReentrant returns (uint256 out) {
        uint256 amt = racks.balanceOf(address(this));
        require(amt >= threshold && threshold > 0, "below threshold");
        uint256 expected = price.expectedOut(amt);
        uint256 minOut = expected * (10000 - maxSlippageBps) / 10000;
        racks.approve(address(router), amt);
        out = router.swap(address(racks), address(spy), amt, minOut, reserve);
        emit Swapped(amt, out);
    }

    function setThreshold(uint256 t) external onlyOwner { threshold = t; }
    function setMaxSlippage(uint256 b) external onlyOwner { require(b <= 1000, "slip cap"); maxSlippageBps = b; }
    function setReserve(address r) external onlyOwner { reserve = r; }
    function setRouter(address r) external onlyOwner { router = ISwapRouter(r); }
    function setPrice(address p) external onlyOwner { price = IPriceSource(p); }
}
