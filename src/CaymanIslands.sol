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
    function perSecFactorFor(uint8 pos) external view returns (uint256);
}
interface IERC20 { function transferFrom(address f, address t, uint256 a) external returns (bool); function decimals() external view returns (uint8); }

/// @title CaymanIslands — 3-tier lock. WHILE locked: melt-protected, short tiers bleed into the
///        agent pot. AFTER expiry (not relocked): the position becomes a normal token again and
///        undergoes the normal RACKS melt (burned, supply-reducing) — nothing more goes to the pot.
contract CaymanIslands is ReentrancyGuard {
    uint256 internal constant RAY = 1e27;


    IRacks public immutable racks;
    IERC20  public immutable usdg;
    address public reserve;
    address public owner;
    address public agent;

    uint256[3] public DURATION = [uint256(1 days), 3 days, 14 days];
    uint256[3] public FEE;
    // melt factor per tier, resolved in RACKS: 1d = 0.3, 3d = 0.2, 14d = 0.1 of r_w
    uint8[3] public POS = [uint8(2), 3, 4];
    uint256 public constant MIN_LOCK = 1_000 ether; // dust floor; expired dust is auto-pruned (F7)

    struct Pos { uint256 principal; uint64 lockedAt; uint64 unlockAt; bool expiredCounted; } // lockedAt doubles as "last settled"
    mapping(address => Pos[3]) internal _pos;
    uint256 public pot; // settled bleed, raidable by agents
    /// principal of positions past their unlock time. These melt at the UNLOCKED rate and are free to
    /// leave, so they must not count as locked supply — otherwise a large forgotten position depresses
    /// the free float (and the rate) for everyone until it is pruned.
    uint256 public expiredPrincipal;

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

    /// paged live pot for frontends when the active list is large
    function potLiveRange(uint256 from, uint256 count) external view returns (uint256 live, uint256 next) {
        uint256 n = _active.length; if (from >= n) return (0, n);
        uint256 to = from + count; if (to > n) to = n;
        for (uint256 i = from; i < to; i++) {
            bytes32 k = _active[i]; (, uint256 bleedAmt,) = _split(_pos[address(uint160(uint256(k) >> 8))][uint8(uint256(k) & 0xff)], uint8(uint256(k) & 0xff));
            live += bleedAmt;
        }
        next = to;
    }

    /// settle a page of active positions into the pot. Permissionless; used by keepers and by the
    /// agent contract right before an epoch settles.
    function harvestBatch(uint256 from, uint256 count) public nonReentrant {
        uint256 i = from; uint256 done;
        // removal-safe: a pruned entry is swapped out for the last one, so re-check index i
        while (done < count && i < _active.length) {
            bytes32 k = _active[i];
            _settle(address(uint160(uint256(k) >> 8)), uint8(uint256(k) & 0xff));
            if (i < _active.length && _active[i] == k) i++;   // not pruned -> advance
            done++;
        }
        _syncLocked();
    }
    function harvestAll() external { harvestBatch(0, _active.length); }

    event Locked(address indexed u, uint8 tier, uint256 amount, uint256 unlockAt);
    event Unlocked(address indexed u, uint8 tier, uint256 amount);
    event Settled(address indexed u, uint8 tier, uint256 bleedToPot, uint256 meltBurned);
    event AgentSet(address indexed agent);

    modifier onlyOwner() { require(msg.sender == owner, "!owner"); _; }

    constructor(address _k, address _usdg, address _reserve) {
        racks = IRacks(_k); usdg = IERC20(_usdg); reserve = _reserve; owner = msg.sender;
        uint256 u = 10 ** usdg.decimals();
        FEE = [3 * u, 5 * u, 10 * u];
    }

    /// The agent is set ONCE, at deploy, and can never be changed again. It is the only address
    /// allowed to draw from the pot, so a swappable pointer would be a permanent "one call drains
    /// everything" power over the lockers' bleed. There is no upgrade path and none is wanted:
    /// randomness is changed inside the agent (see IRSAgent.proposeVrf), which can only influence
    /// who wins, never move the pot wholesale.
    function setAgent(address r) external onlyOwner {
        require(agent == address(0), "agent is final");
        require(r != address(0), "zero");
        agent = r;
        emit AgentSet(r);
    }

    address public pendingOwner;
    function transferOwnership(address n) external onlyOwner { pendingOwner = n; }
    function acceptOwnership() external { require(msg.sender == pendingOwner, "!pending"); owner = pendingOwner; pendingOwner = address(0); }
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
        uint256 afterBleed = tBleed == 0 ? p.principal : RayMath.rmul(p.principal, RayMath.rpow(racks.perSecFactorFor(POS[b]), tBleed));
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
        // keep the expired-principal tally in step before overwriting the position
        if (p.expiredCounted) expiredPrincipal -= p.principal;
        bool nowExpired = block.timestamp >= p.unlockAt;
        if (nowExpired) expiredPrincipal += payout;
        p.expiredCounted = nowExpired;
        p.principal = payout; p.lockedAt = uint64(block.timestamp);
        if (bleedAmt > 0 || meltAmt > 0) emit Settled(u, b, bleedAmt, meltAmt);
        // F7: expired positions that melted below the dust floor leave the active set (list poisoning)
        if (payout > 0 && payout < MIN_LOCK && block.timestamp >= p.unlockAt) {
            if (p.expiredCounted) expiredPrincipal -= payout;
            delete _pos[u][b]; _remove(u, b);
            require(racks.transfer(u, payout), "dust");
            return 0;
        }
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
        uint256 notLocked = pot + expiredPrincipal;          // pot is protocol-owned, expired is free to leave
        racks.setLockedSupply(bal > notLocked ? bal - notLocked : 0);
    }

    function lock(uint8 b, uint256 amount) external nonReentrant {
        require(b < 3 && amount >= MIN_LOCK, "bad");
        require(usdg.transferFrom(msg.sender, reserve, FEE[b]), "fee");
        _settle(msg.sender, b);                                // settle any existing position first
        uint256 beforeBal = racks.balanceOf(address(this));
        require(racks.transferFrom(msg.sender, address(this), amount), "pull");
        uint256 received = racks.balanceOf(address(this)) - beforeBal;
        Pos storage p = _pos[msg.sender][b];
        if (p.expiredCounted) { expiredPrincipal -= p.principal; p.expiredCounted = false; }
        p.principal += received;
        p.lockedAt = uint64(block.timestamp);
        p.unlockAt = uint64(block.timestamp + DURATION[b]);
        _add(msg.sender, b);
        _syncLocked();
        emit Locked(msg.sender, b, received, p.unlockAt);
    }

    function relock(uint8 b) external nonReentrant {
        require(b < 3 && _pos[msg.sender][b].principal > 0, "none");
        _settle(msg.sender, b);
        { Pos storage rp = _pos[msg.sender][b];
          if (rp.expiredCounted) { expiredPrincipal -= rp.principal; rp.expiredCounted = false; } }
        // the settle above may have pruned a dust position and paid it out — do not charge a fee
        // for relocking something that no longer exists
        require(_pos[msg.sender][b].principal > 0, "pruned");
        require(usdg.transferFrom(msg.sender, reserve, FEE[b]), "fee");                                // applies any post-expiry melt first
        _pos[msg.sender][b].unlockAt = uint64(block.timestamp + DURATION[b]);
        _syncLocked();
    }

    function unlock(uint8 b) external nonReentrant {
        require(b < 3, "bad");
        Pos storage p = _pos[msg.sender][b];
        require(p.principal > 0, "none");
        require(block.timestamp >= p.unlockAt, "locked");
        uint256 payout = _settle(msg.sender, b);
        if (_pos[msg.sender][b].expiredCounted) expiredPrincipal -= payout;
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
