// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IRacks {
    function transfer(address to, uint256 a) external returns (bool);
    function transferFrom(address f, address t, uint256 a) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

/// @title WRacks — non-rebasing wrapper for RACKS (WAMPL pattern), for use in V2 pools
/// @dev wRACKS balances are FIXED (share-based). The demurrage melt is reflected in the
///      floating redemption rate: each wRACKS redeems for fewer RACKS over time.
///      The wrapper is NOT melt-exempt: its RACKS holdings melt, shared pro-rata across holders.
contract WRacks is ERC20 {
    IRacks public immutable racks;

    constructor(address _racks) ERC20("Wrapped RACKS", "wRACKS") { racks = IRacks(_racks); }

    /// deposit RACKS, receive fixed-supply wRACKS shares priced against the current pool value
    function wrap(uint256 amount) external returns (uint256 shares) {
        uint256 heldBefore = racks.balanceOf(address(this));
        uint256 supply = totalSupply();
        require(racks.transferFrom(msg.sender, address(this), amount), "pull");
        shares = (supply == 0 || heldBefore == 0) ? amount : amount * supply / heldBefore;
        _mint(msg.sender, shares);
    }

    /// burn wRACKS, receive the current (melted) RACKS value of those shares
    function unwrap(uint256 shares) external returns (uint256 out) {
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
