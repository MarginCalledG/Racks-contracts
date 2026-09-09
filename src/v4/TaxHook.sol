// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolKey, Currency} from "./V4Swap.sol";

struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }

interface IPoolManagerHook { function take(Currency currency, address to, uint256 amount) external; }
interface ITaxOracleH { function update() external; function taxBps(uint256 amount, bool isSell) external view returns (uint256); }
interface IRacksH { function inLaunchWindow() external view returns (bool); function isExempt(address) external view returns (bool); function capExempt(address) external view returns (bool); function isTaxExempt(address) external view returns (bool); }
interface IWRacksH { function capExempt(address) external view returns (bool); }

/// @title TaxHook — Uniswap v4 afterSwap hook that takes the RACKS trading tax on EVERY swap of the
///        wRACKS/SPY pool, directly from the swapper's output. Unavoidable for direct traders, bots and
///        routers alike. Sell tax is collected in SPY, buy tax in wRACKS. Samples the TWAP every swap.
/// @dev Address must be mined so its low 14 bits == AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA (0x44).
contract TaxHook {
    address public immutable pm;
    address public immutable wracks;
    IRacksH  public immutable racks;
    address  public owner;
    address  public taxWallet;
    ITaxOracleH public oracle;
    uint256 public constant LAUNCH_TAX_BPS = 800;
    uint256 public constant TAX_CAP = 800;
    uint256 public baseBps = 400;
    mapping(address => bool) public exemptSender; // e.g. the tax wallet converting its own tax

    event Taxed(address indexed sender, bool isSell, uint256 bps, uint256 amount, address currency);
    modifier onlyOwner() { require(msg.sender == owner, "!owner"); _; }

    constructor(address _pm, address _wracks, address _racks, address _taxWallet) {
        pm = _pm; wracks = _wracks; racks = IRacksH(_racks); taxWallet = _taxWallet; owner = msg.sender;
    }
    function setOracle(address o) external onlyOwner { require(o == address(0) || o.code.length > 0, "no code"); oracle = ITaxOracleH(o); }
    function setTaxWallet(address w) external onlyOwner { taxWallet = w; }
    function setBaseBps(uint256 b) external onlyOwner { require(b <= TAX_CAP, "cap"); baseBps = b; }
    function setExemptSender(address a, bool e) external onlyOwner { exemptSender[a] = e; }

    /// Deploy self-check: during the launch hour the hook delivers tax wRACKS to taxWallet, which runs
    /// through the cumulative launch ledger. If taxWallet is not exempt, swaps start reverting once it
    /// has received ~1% -> the pool would be dead for the rest of the launch hour. Require this is true.
    function wiringOk() external view returns (bool) {
        return taxWallet != address(0)
            && (racks.isExempt(taxWallet) || racks.capExempt(taxWallet) || racks.isTaxExempt(taxWallet))
            && IWRacksH(wracks).capExempt(taxWallet);
    }

    function _rate(uint256 wrAmount, bool isSell) internal returns (uint256) {
        if (racks.inLaunchWindow()) return LAUNCH_TAX_BPS;
        if (address(oracle) != address(0) && address(oracle).code.length > 0) {
            try oracle.update() {} catch {}
            try oracle.taxBps(wrAmount, isSell) returns (uint256 b) { return b > TAX_CAP ? TAX_CAP : b; } catch {}
        }
        return baseBps;
    }

    /// v4 calls this after every swap. We take `fee` of the UNSPECIFIED currency (the output for
    /// exact-input swaps) and return it as the hook delta so the swapper's output shrinks by exactly fee.
    function afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, int256 delta, bytes calldata)
        external returns (bytes4, int128)
    {
        require(msg.sender == pm, "!pm");
        if (exemptSender[sender] || taxWallet == address(0)) return (this.afterSwap.selector, 0);
        (uint256 fee, bool isSell, uint256 bps, Currency feeCur) = _compute(key, params, delta);
        if (fee == 0) return (this.afterSwap.selector, 0);
        IPoolManagerHook(pm).take(feeCur, taxWallet, fee);
        emit Taxed(sender, isSell, bps, fee, Currency.unwrap(feeCur));
        return (this.afterSwap.selector, int128(int256(fee)));
    }

    function _abs(int128 x) internal pure returns (uint256) { return x >= 0 ? uint256(int256(x)) : uint256(int256(-x)); }

    function _compute(PoolKey calldata key, SwapParams calldata params, int256 delta)
        internal returns (uint256 fee, bool isSell, uint256 bps, Currency feeCur)
    {
        bool unspecIs0 = (params.amountSpecified < 0) ? !params.zeroForOne : params.zeroForOne;
        int128 a0 = int128(delta >> 128); int128 a1 = int128(delta);
        bool wIs0 = Currency.unwrap(key.currency0) == wracks;
        int128 wDelta = wIs0 ? a0 : a1;
        isSell = wDelta < 0;                                   // swapper pays wRACKS in
        bps = _rate(_abs(wDelta), isSell);
        fee = _abs(unspecIs0 ? a0 : a1) * bps / 10000;
        feeCur = unspecIs0 ? key.currency0 : key.currency1;
    }
}
