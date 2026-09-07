// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RayMath} from "./RayMath.sol";
import {ReentrancyGuard} from "./ReentrancyGuard.sol";

interface IRacks {
    function transfer(address to, uint256 a) external returns (bool);
    function transferFrom(address f, address t, uint256 a) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
    function setLockedSupply(uint256 L) external;
    function burn(uint256 amount) external;
    function perSecFactor() external view returns (uint256);
}
interface IERC20 { function transferFrom(address f, address t, uint256 a) external returns (bool); function decimals() external view returns (uint8); }

/// @title CaymanIslands — 3-tier lock. WHILE locked: melt-protected, short tiers bleed into the
///        agent pot. AFTER expiry (not relocked): the position becomes a normal token again and
///        undergoes the normal RACKS melt (burned, supply-reducing) — nothing more goes to the pot.
contract CaymanIslands is ReentrancyGuard {
    uint256 internal constant RAY = 1e27;
    uint256 internal constant B1 = 999999766172396388505092096; // 2%/day
    uint256 internal constant B3 = 999999825073651690567106560; // 1.5%/day

    IRacks public immutable racks;
    IERC20  public immutable usdg;
    address public reserve;
    address public owner;
    address public agent;

    uint256[3] public DURATION = [uint256(1 days), 3 days, 14 days];
    uint256[3] public FEE;
    uint256[3] public BLEED = [B1, B3, RAY];
    uint256 public constant MIN_LOCK = 1 ether; // E4: no 1-wei dust positions

    struct Pos { uint256 principal; uint64 lockedAt; uint64 unlockAt; } // lockedAt doubles as "last settled"
    mapping(address => Pos[3]) internal _pos;
    uint256 public pot; // settled bleed, raidable by agents

    // enumerable set of active positions (packed user|tier) so the LIVE pot can be computed and
    // positions can be batch-harvested. swap-and-pop removal.
    bytes32[] internal _active;
    mapping(bytes32 => uint256) internal _activeIdx; // 1-based; 0 = not present
    function _key(address u, uint8 b) internal pure returns (bytes32) { return bytes32(uint256(uint160(u)) << 8 | b); }
    function _add(address u, uint8 b) internal { bytes32 k = _key(u, b); if (_activeIdx[k] == 0) { _active.push(k); _activeIdx[k] = _active.length; } }
    function _remove(address u, uint8 b) internal {
        bytes32 k = _key(u, b); uint256 i = _activeIdx[k]; if (i == 0) return;
        bytes32 last = _active[_active.length - 1]; _active[i - 1] = last; _activeIdx[last] = i;
        _active.pop(); delete _activeIdx[k];
    }
    function activeCount() external view returns (uint256) { return _active.length; }
    function activeAt(uint256 i) external view returns (address u, uint8 b) { bytes32 k = _active[i]; return (address(uint160(uint256(k) >> 8)), uint8(uint256(k) & 0xff)); }

    /// LIVE pot = settled pot + bleed that has accrued but not been settled yet, across ALL active
    /// positions. This is what agent holders should see before attacking (never a misleading 0).
    function potLive() external view returns (uint256 live) {
        live = pot;
        for (uint256 i; i < _active.length; i++) {
            bytes32 k = _active[i]; address u = address(uint160(uint256(k) >> 8)); uint8 b = uint8(uint256(k) & 0xff);
            (, uint256 bleedAmt,) = _split(_pos[u][b], b);
            live += bleedAmt;
        }
    }

    /// settle a page of active positions into the pot. Permissionless; used by keepers and by the
    /// agent contract right before an epoch settles.
    function harvestBatch(uint256 from, uint256 count) public nonReentrant {
        uint256 n = _active.length; if (from >= n) return;
        uint256 to = from + count; if (to > n) to = n;
        for (uint256 i = from; i < to; i++) {
            bytes32 k = _active[i]; _settle(address(uint160(uint256(k) >> 8)), uint8(uint256(k) & 0xff));
        }
        _syncLocked();
    }
    function harvestAll() external { harvestBatch(0, _active.length); }

    event Locked(address indexed u, uint8 tier, uint256 amount, uint256 unlockAt);
    event Unlocked(address indexed u, uint8 tier, uint256 amount);
    event Settled(address indexed u, uint8 tier, uint256 bleedToPot, uint256 meltBurned);

    modifier onlyOwner() { require(msg.sender == owner, "!owner"); _; }

    constructor(address _k, address _usdg, address _reserve) {
        racks = IRacks(_k); usdg = IERC20(_usdg); reserve = _reserve; owner = msg.sender;
        uint256 u = 10 ** usdg.decimals();
        FEE = [3 * u, 5 * u, 10 * u];
    }

    function setAgent(address r) external onlyOwner { agent = r; }
    function setReserve(address r) external onlyOwner { reserve = r; }
    function position(address u, uint8 b) external view returns (uint256 principal, uint64 lockedAt, uint64 unlockAt) {
        Pos storage p = _pos[u][b]; return (p.principal, p.lockedAt, p.unlockAt);
    }
    function unlockAt(address u, uint8 b) external view returns (uint256) { return _pos[u][b].unlockAt; }

    /// split a position's value: bleed accrues only until expiry (-> pot); melt accrues only after (-> burn)
    function _split(Pos memory p, uint8 b) internal view returns (uint256 payout, uint256 bleedAmt, uint256 meltAmt) {
        if (p.principal == 0) return (0, 0, 0);
        uint256 nowT = block.timestamp;
        uint256 bleedEnd = nowT < p.unlockAt ? nowT : p.unlockAt;
        uint256 tBleed = bleedEnd > p.lockedAt ? bleedEnd - p.lockedAt : 0;
        uint256 afterBleed = tBleed == 0 ? p.principal : RayMath.rmul(p.principal, RayMath.rpow(BLEED[b], tBleed));
        bleedAmt = p.principal - afterBleed;
        uint256 meltStart = p.lockedAt > p.unlockAt ? p.lockedAt : p.unlockAt;
        uint256 tMelt = nowT > meltStart ? nowT - meltStart : 0;
        if (tMelt == 0) { payout = afterBleed; }
        else {
            payout = RayMath.rmul(afterBleed, RayMath.rpow(racks.perSecFactor(), tMelt)); // normal RACKS melt
            meltAmt = afterBleed - payout;
        }
    }

    /// current redeemable value of a position
    function claimOf(address u, uint8 b) public view returns (uint256) {
        (uint256 v,,) = _split(_pos[u][b], b); return v;
    }
    function potBalance() public view returns (uint256) { return pot; }

    /// settle accrued bleed (-> pot) and post-expiry melt (-> burn); position continues with the remainder
    function _settle(address u, uint8 b) internal returns (uint256 remaining) {
        Pos storage p = _pos[u][b];
        (uint256 payout, uint256 bleedAmt, uint256 meltAmt) = _split(p, b);
        if (bleedAmt > 0) pot += bleedAmt;
        if (meltAmt > 0) racks.burn(meltAmt);                 // real melt: supply shrinks, not pot
        p.principal = payout; p.lockedAt = uint64(block.timestamp);
        if (bleedAmt > 0 || meltAmt > 0) emit Settled(u, b, bleedAmt, meltAmt);
        remaining = payout;
    }

    /// anyone can seed the agent pot directly (e.g. protocol seeding the casino at launch)
    function fundPot(uint256 amount) external nonReentrant {
        uint256 before = racks.balanceOf(address(this));
        require(racks.transferFrom(msg.sender, address(this), amount), "pull");
        pot += racks.balanceOf(address(this)) - before;
        _syncLocked();
    }

    /// permissionless: harvest a position's accrued bleed into the pot (keeps the pot flowing)
    function harvest(address u, uint8 b) external nonReentrant { require(b < 3, "bad"); _settle(u, b); _syncLocked(); }

    function _syncLocked() internal {
        uint256 bal = racks.balanceOf(address(this));
        racks.setLockedSupply(bal > pot ? bal - pot : 0);     // only user-locked value counts as locked
    }

    function lock(uint8 b, uint256 amount) external nonReentrant {
        require(b < 3 && amount >= MIN_LOCK, "bad");
        require(usdg.transferFrom(msg.sender, reserve, FEE[b]), "fee");
        _settle(msg.sender, b);                                // settle any existing position first
        uint256 beforeBal = racks.balanceOf(address(this));
        require(racks.transferFrom(msg.sender, address(this), amount), "pull");
        uint256 received = racks.balanceOf(address(this)) - beforeBal;
        Pos storage p = _pos[msg.sender][b];
        p.principal += received;
        p.lockedAt = uint64(block.timestamp);
        p.unlockAt = uint64(block.timestamp + DURATION[b]);
        _add(msg.sender, b);
        _syncLocked();
        emit Locked(msg.sender, b, received, p.unlockAt);
    }

    function relock(uint8 b) external nonReentrant {
        require(b < 3 && _pos[msg.sender][b].principal > 0, "none");
        require(usdg.transferFrom(msg.sender, reserve, FEE[b]), "fee");
        _settle(msg.sender, b);                                // applies any post-expiry melt first
        _pos[msg.sender][b].unlockAt = uint64(block.timestamp + DURATION[b]);
        _syncLocked();
    }

    function unlock(uint8 b) external nonReentrant {
        require(b < 3, "bad");
        Pos storage p = _pos[msg.sender][b];
        require(p.principal > 0, "none");
        require(block.timestamp >= p.unlockAt, "locked");
        uint256 payout = _settle(msg.sender, b);
        delete _pos[msg.sender][b];
        _remove(msg.sender, b);
        require(racks.transfer(msg.sender, payout), "send");
        _syncLocked();
        emit Unlocked(msg.sender, b, payout);
    }

    /// agent draws won loot from the settled pot
    function drawPot(address to, uint256 amount) external nonReentrant {
        require(msg.sender == agent, "!agent");
        require(amount <= pot, "pot");
        pot -= amount;
        require(racks.transfer(to, amount), "send");
        _syncLocked();
    }
}
