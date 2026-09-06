// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "./ReentrancyGuard.sol";

interface IRacks {
    function transfer(address to, uint256 a) external returns (bool);
    function transferFrom(address f, address t, uint256 a) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
    function inLaunchWindow() external view returns (bool);
    function maxWallet() external view returns (uint256);
}
interface ITaxOracle {
    function update() external;
    function taxBps(uint256 amount, bool isSell) external view returns (uint256);
}

/// @title WRacks — non-rebasing wrapper for RACKS (WAMPL pattern), for use in V2 pools
/// @dev wRACKS balances are FIXED (share-based). The demurrage melt is reflected in the
///      floating redemption rate: each wRACKS redeems for fewer RACKS over time.
///      The wrapper is NOT melt-exempt: its RACKS holdings melt, shared pro-rata across holders.
contract WRacks is ERC20, ReentrancyGuard {
    IRacks public immutable racks;

    // --- tax on wrap (sell-side) / unwrap (buy-side); collected in RACKS ---
    address public owner;
    address public taxWallet;                       // 0 = no tax (keeps wrapper neutral until set)
    uint256 public taxBps = 400;                    // 4% base; dynamic oracle wired in a later step
    uint256 public constant LAUNCH_TAX_BPS = 800;   // 8% during RACKS launch window
    uint256 public constant TAX_CAP = 800;          // 8% hard cap
    uint256 public constant MINIMUM_LIQUIDITY = 1000; // dead shares (first-depositor protection)
    address public constant DEAD_SHARES = 0x000000000000000000000000000000000000dEaD;
    address public taxOracle;                       // 0 = flat taxBps; else dynamic (spot vs TWAP)

    modifier onlyOwner() { require(msg.sender == owner, "!owner"); _; }

    mapping(address => bool) public capExempt;   // pool/PoolManager/zap/LP-adder must be exempt
    function setCapExempt(address a, bool e) external onlyOwner { capExempt[a] = e; }

    constructor(address _racks) ERC20("Wrapped RACKS", "wRACKS") {
        racks = IRacks(_racks); owner = msg.sender; capExempt[msg.sender] = true;
        capExempt[DEAD_SHARES] = true;     // dead-share sink can never 'buy'; must not trip the cap
    }

    /// Hard launch-hour wallet cap (1%), enforced on EVERY wRACKS transfer -> also blocks
    /// direct-to-pool snipers, not just the zap. Value compared in RACKS terms (exact).
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (to != address(0) && !capExempt[to] && racks.inLaunchWindow()) {
            uint256 held = racks.balanceOf(address(this));
            uint256 racksValue = totalSupply() == 0 ? 0 : balanceOf(to) * held / totalSupply();
            require(racksValue <= racks.maxWallet(), "launch cap");
        }
    }

    address public pendingOwner;
    function transferOwnership(address n) external onlyOwner { pendingOwner = n; }
    function acceptOwnership() external { require(msg.sender == pendingOwner, "!pending"); owner = pendingOwner; pendingOwner = address(0); }

    function setTaxWallet(address w) external onlyOwner { taxWallet = w; }
    function setTaxBps(uint256 b) external onlyOwner { require(b <= TAX_CAP, "cap"); taxBps = b; }
    function setTaxOracle(address o) external onlyOwner { taxOracle = o; }

    function _rateBps(uint256 amount, bool isSell) internal returns (uint256) {
        if (racks.inLaunchWindow()) return LAUNCH_TAX_BPS;
        if (taxOracle != address(0)) {
            // W5 fix: oracle failure falls back to the flat rate instead of bricking the wrapper
            try ITaxOracle(taxOracle).update() {} catch {}
            try ITaxOracle(taxOracle).taxBps(amount, isSell) returns (uint256 b) {
                return b > TAX_CAP ? TAX_CAP : b;
            } catch { return taxBps; }
        }
        return taxBps;
    }
    function _tax(uint256 amount, bool isSell) internal returns (uint256) {
        if (taxWallet == address(0)) return 0;      // no tax until a wallet is configured
        return amount * _rateBps(amount, isSell) / 10000;
    }

    /// deposit RACKS, receive fixed-supply wRACKS shares priced against the current pool value
    function wrap(uint256 amount) external nonReentrant returns (uint256 shares) {
        uint256 heldBefore = racks.balanceOf(address(this));
        uint256 supply = totalSupply();
        require(racks.transferFrom(msg.sender, address(this), amount), "pull");
        uint256 tax = _tax(amount, true);                       // sell-side tax
        if (tax > 0) require(racks.transfer(taxWallet, tax), "tax");
        uint256 net = racks.balanceOf(address(this)) - heldBefore; // ACTUAL net that stays (rounding-safe)
        require(net > 0, "zero");
        if (supply == 0) {
            // W1 fix: lock MINIMUM_LIQUIDITY dead shares so the share ratio can never be
            // inflated by a 1-wei first deposit + donation (first-depositor attack).
            require(net > MINIMUM_LIQUIDITY, "too small");
            _mint(DEAD_SHARES, MINIMUM_LIQUIDITY);
            shares = net - MINIMUM_LIQUIDITY;
        } else {
            shares = net * supply / heldBefore;
        }
        require(shares > 0, "zero shares");
        _mint(msg.sender, shares);
    }

    /// burn wRACKS, receive the current (melted) RACKS value of those shares
    function unwrap(uint256 shares) external nonReentrant returns (uint256 out) {
        uint256 held = racks.balanceOf(address(this));
        uint256 gross = shares * held / totalSupply();
        _burn(msg.sender, shares);
        uint256 tax = _tax(gross, false);                       // buy-side tax
        if (tax > 0) require(racks.transfer(taxWallet, tax), "tax");
        out = gross - tax;
        require(racks.transfer(msg.sender, out), "send");
    }

    /// current RACKS value of one wRACKS (1e18-scaled)
    function racksPerShare() external view returns (uint256) {
        uint256 s = totalSupply();
        return s == 0 ? 1e18 : racks.balanceOf(address(this)) * 1e18 / s;
    }
}
