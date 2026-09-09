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
    function recordLaunchReceipt(address to, uint256 v) external;
}

/// @title WRacks — non-rebasing wrapper for RACKS (WAMPL pattern). Trading tax lives in the v4 TaxHook,
///        NOT here: wrapping/unwrapping is a pure form change (no fee).
/// @dev wRACKS balances are FIXED (share-based). The demurrage melt is reflected in the
///      floating redemption rate: each wRACKS redeems for fewer RACKS over time.
///      The wrapper is NOT melt-exempt: its RACKS holdings melt, shared pro-rata across holders.
contract WRacks is ERC20, ReentrancyGuard {
    IRacks public immutable racks;

    address public owner;
    uint256 public constant MINIMUM_LIQUIDITY = 1e6; // dead shares (first-depositor protection; 1e6 makes donation griefing 1000x weaker)
    address public constant DEAD_SHARES = 0x000000000000000000000000000000000000dEaD;
    modifier onlyOwner() { require(msg.sender == owner, "!owner"); _; }

    address public pendingOwner;
    function transferOwnership(address n) external onlyOwner { pendingOwner = n; }
    function acceptOwnership() external { require(msg.sender == pendingOwner, "!pending"); owner = pendingOwner; pendingOwner = address(0); }

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
        // F3: report pool/peer deliveries (not mints from wrap, not burns) to the cumulative launch ledger
        if (from != address(0) && to != address(0) && !capExempt[to] && racks.inLaunchWindow()) {
            uint256 supply = totalSupply();
            uint256 racksValue = supply == 0 ? 0 : value * racks.balanceOf(address(this)) / supply;
            racks.recordLaunchReceipt(to, racksValue);
        }
    }


    /// deposit RACKS, receive fixed-supply wRACKS shares priced against the current pool value
    function wrap(uint256 amount) external nonReentrant returns (uint256 shares) {
        uint256 heldBefore = racks.balanceOf(address(this));
        uint256 supply = totalSupply();
        require(racks.transferFrom(msg.sender, address(this), amount), "pull");
        uint256 net = racks.balanceOf(address(this)) - heldBefore; // ACTUAL amount received (rounding-safe)
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
        out = shares * held / totalSupply();
        _burn(msg.sender, shares);
        require(racks.transfer(msg.sender, out), "send");
    }

    /// current RACKS value of one wRACKS (1e18-scaled)
    function racksPerShare() external view returns (uint256) {
        uint256 s = totalSupply();
        return s == 0 ? 1e18 : racks.balanceOf(address(this)) * 1e18 / s;
    }
}
