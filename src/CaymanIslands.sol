// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RayMath} from "./RayMath.sol";
import {ReentrancyGuard} from "./ReentrancyGuard.sol";

interface IRacks {
    function transfer(address to, uint256 a) external returns (bool);
    function transferFrom(address f, address t, uint256 a) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
    function setLockedSupply(uint256 L) external;
}
interface IERC20 { function transferFrom(address f, address t, uint256 a) external returns (bool); function decimals() external view returns (uint8); }

/// @title CaymanIslands (Stage 2) — 3-tier lock, 1:1 protection, short-lock bleed -> agent pot
contract CaymanIslands is ReentrancyGuard {
    uint256 internal constant RAY = 1e27;

    // per-second retention of each bucket (bleed to pot): 1d=2%/d, 3d=1.5%/d, 14d=0%
    uint256 internal constant B1 = 999999766172396388505092096;
    uint256 internal constant B3 = 999999825073651690567106560;

    IRacks public immutable racks;
    IERC20  public immutable usdg;
    address public reserve;
    address public owner;
    address public agent;

    uint256[3] public DURATION = [uint256(1 days), 3 days, 14 days];
    uint256[3] public FEE; // $3/$5/$10 in USDG, scaled to the token's decimals in the constructor
    uint256[3] public BLEED    = [B1, B3, RAY];

    uint256[3] public bIndex;
    uint256[3] public bLast;
    uint256[3] public totalScaled;

    mapping(address => uint256[3]) public scaled;
    mapping(address => uint256[3]) public unlockAt;

    event Locked(address indexed u, uint8 tier, uint256 amount, uint256 unlockAt);
    event Unlocked(address indexed u, uint8 tier, uint256 amount);

    modifier onlyOwner() { require(msg.sender == owner, "!owner"); _; }

    constructor(address _k, address _usdg, address _reserve) {
        racks = IRacks(_k); usdg = IERC20(_usdg); reserve = _reserve; owner = msg.sender;
        uint256 u = 10 ** usdg.decimals();
        FEE = [3 * u, 5 * u, 10 * u]; // decimal-aware: 6-dec USDG -> 3e6, 18-dec -> 3e18
        for (uint256 i; i < 3; i++) { bIndex[i] = RAY; bLast[i] = block.timestamp; }
    }

    function setAgent(address r) external onlyOwner { agent = r; }
    function setReserve(address r) external onlyOwner { reserve = r; }

    function _idx(uint8 b) internal view returns (uint256) {
        uint256 dt = block.timestamp - bLast[b];
        return dt == 0 ? bIndex[b] : RayMath.rmul(bIndex[b], RayMath.rpow(BLEED[b], dt));
    }

    function _accrue(uint8 b) internal { bIndex[b] = _idx(b); bLast[b] = block.timestamp; }

    function claimOf(address u, uint8 b) public view returns (uint256) {
        return scaled[u][b] * _idx(b) / RAY;
    }

    function totalClaims() public view returns (uint256 t) {
        for (uint8 b; b < 3; b++) t += totalScaled[b] * _idx(b) / RAY;
    }

    /// RACKS bled from short locks, waiting for agents to raid
    function potBalance() public view returns (uint256) {
        uint256 bal = racks.balanceOf(address(this));
        uint256 c = totalClaims();
        return bal > c ? bal - c : 0;
    }

    function _syncLocked() internal { racks.setLockedSupply(racks.balanceOf(address(this))); }

    function lock(uint8 b, uint256 amount) external nonReentrant {
        require(b < 3 && amount > 0, "bad");
        _accrue(b);
        require(usdg.transferFrom(msg.sender, reserve, FEE[b]), "fee");
        uint256 beforeBal = racks.balanceOf(address(this));
        require(racks.transferFrom(msg.sender, address(this), amount), "pull");
        uint256 received = racks.balanceOf(address(this)) - beforeBal; // actual (fee/rounding safe)
        uint256 s = received * RAY / bIndex[b];
        scaled[msg.sender][b] += s;
        totalScaled[b] += s;
        unlockAt[msg.sender][b] = block.timestamp + DURATION[b];
        _syncLocked();
        emit Locked(msg.sender, b, amount, unlockAt[msg.sender][b]);
    }

    function relock(uint8 b) external nonReentrant {
        require(scaled[msg.sender][b] > 0, "none");
        require(usdg.transferFrom(msg.sender, reserve, FEE[b]), "fee");
        unlockAt[msg.sender][b] = block.timestamp + DURATION[b];
    }

    function unlock(uint8 b) external nonReentrant {
        require(block.timestamp >= unlockAt[msg.sender][b], "locked");
        _accrue(b);
        uint256 s = scaled[msg.sender][b];
        require(s > 0, "none");
        uint256 amt = s * bIndex[b] / RAY;
        scaled[msg.sender][b] = 0;
        totalScaled[b] -= s;
        uint256 payout = amt;
        // post-expiry penalty for the 0-bleed 14-day tier: unprotected past expiry -> feeds the pot
        if (b == 2) {
            uint256 past = block.timestamp - unlockAt[msg.sender][b];
            if (past > 0) {
                uint256 bps = past * 200 / 1 days; // 2%/day past expiry
                if (bps > 5000) bps = 5000;        // capped at 50%
                payout = amt - (amt * bps / 10000); // penalty stays in vault -> pot
            }
        }
        require(racks.transfer(msg.sender, payout), "send");
        _syncLocked();
        emit Unlocked(msg.sender, b, payout);
    }

    /// Stage 3: agent draws won loot from the pot
    function drawPot(address to, uint256 amount) external nonReentrant {
        require(msg.sender == agent, "!agent");
        require(amount <= potBalance(), "pot");
        require(racks.transfer(to, amount), "send");
        _syncLocked();
    }
}
