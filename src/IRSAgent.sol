// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuard} from "./ReentrancyGuard.sol";

interface IERC20r { function transferFrom(address f, address t, uint256 a) external returns (bool); function decimals() external view returns (uint8); }
interface ICaymanPot {
    function potBalance() external view returns (uint256);
    function potLive() external view returns (uint256);
    function drawPot(address to, uint256 amount) external;
    function harvestBatch(uint256 from, uint256 count) external;
    function activeCount() external view returns (uint256);
}
interface IVRFCoordinatorR { function requestRandom(address cb) external returns (uint256); }

/// @title IRSAgent / "IRS Agent" (Stage 3, ERC721) — VRF ranks, epoch raids, pari-mutuel payout
contract IRSAgent is ERC721, ReentrancyGuard {
    uint256 internal constant RAY = 1e27;
    uint256 public constant EPOCH = 8 hours;
    uint256 public immutable MINT_PRICE; // 99 USDG, decimal-scaled in constructor
    uint256 public constant MAX_PER_WALLET = 10;
    uint256 public constant CAP = 10_000;
    uint256 public constant LIFE = 3 days;

    uint16[3] public HITRATE = [30, 50, 75];
    uint256[3] public WEIGHT = [4, 27, 144];
    uint256[3] public FEED; // $10/$20/$30 in USDG, decimal-scaled in constructor

    IERC20r public immutable usdg;
    ICaymanPot public immutable vault;
    IVRFCoordinatorR public immutable vrf;
    address public reserve;
    address public admin;
    uint256 public immutable startTime;

    uint256 public livingCount;
    uint256 public nextId = 1;

    struct R { uint8 tier; uint40 lastFed; uint32 lastAtkEpoch1; bool revealed; bool dead; }
    mapping(uint256 => R) public agents;
    mapping(address => uint256) public ownedLiving;

    struct Req { uint8 kind; uint256 agentId; uint32 epoch; }
    mapping(uint256 => Req) internal reqs;

    mapping(uint32 => uint256) public totalShares;
    mapping(uint32 => uint256) public rewardPerShareRay;
    mapping(uint32 => bool) internal _settledMap;
    uint32[] public activeEpochs;      // epochs that ever had an attack (ascending)
    uint256 public activeCursor;       // first not-yet-settled entry in activeEpochs
    /// N3: O(1) — everything below settledThrough counts as settled without touching storage per epoch
    function settled(uint32 e) public view returns (bool) { return e < settledThrough || _settledMap[e]; }
    mapping(uint256 => mapping(uint32 => uint256)) public shares;
    uint256 public allocatedPot;
    uint256 public autoHarvest = 25; // positions harvested inside settle() (bounded gas); keepers page the rest
    uint256 public harvestCursor;     // E4 fix: rotating start index so spam can't starve real positions
    uint32 public settledThrough;     // F1: every epoch < settledThrough is settled
    uint256 public constant SETTLE_GRACE = 10 minutes; // E1/E2 fix: let VRF results land before settling
    mapping(uint32 => uint256) public pendingAttacks;   // unfulfilled attack requests per epoch
    mapping(uint32 => uint256) public epochUnclaimed;  // A5: prize still unclaimed per epoch
    uint32 public constant CLAIM_WINDOW = 90;          // epochs (~30 days) to claim before sweep

    event Minted(uint256 indexed id, address indexed owner);
    event Revealed(uint256 indexed id, uint8 tier);
    event Attacked(uint256 indexed id, uint32 epoch, bool hit);
    event Claimed(uint256 indexed id, uint32 epoch, uint256 amount);

    modifier onlyAdmin() { require(msg.sender == admin, "!admin"); _; }

    constructor(address _usdg, address _vault, address _vrf, address _reserve)
        ERC721("IRS Agent", "IRS")
    {
        usdg = IERC20r(_usdg); vault = ICaymanPot(_vault); vrf = IVRFCoordinatorR(_vrf);
        reserve = _reserve; admin = msg.sender; startTime = block.timestamp;
        uint256 u = 10 ** usdg.decimals();
        MINT_PRICE = 99 * u; FEED = [10 * u, 20 * u, 30 * u]; // decimal-aware
    }

    function currentEpoch() public view returns (uint32) {
        return uint32((block.timestamp - startTime) / EPOCH);
    }

    function alive(uint256 id) public view returns (bool) {
        R storage r = agents[id];
        return r.revealed && !r.dead && block.timestamp <= uint256(r.lastFed) + LIFE;
    }

    /// keep the per-wallet living count correct across NFT transfers
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = super._update(to, tokenId, auth);
        if (!agents[tokenId].dead) {
            if (from != address(0)) ownedLiving[from]--;
            if (to != address(0)) { ownedLiving[to]++; require(ownedLiving[to] <= MAX_PER_WALLET, "max agents"); } // F8
        }
    }

    function mint() external nonReentrant returns (uint256 id) {
        require(ownedLiving[msg.sender] < MAX_PER_WALLET, "wallet cap");
        require(livingCount < CAP, "cap");
        require(usdg.transferFrom(msg.sender, reserve, MINT_PRICE), "pay");
        id = nextId++;
        agents[id] = R(0, uint40(block.timestamp), 0, false, false);
        livingCount++;
        _mint(msg.sender, id); // _update bumps ownedLiving
        uint256 rid = vrf.requestRandom(address(this));
        reqs[rid] = Req(1, id, 0);
        emit Minted(id, msg.sender);
    }

    function feed(uint256 id) external nonReentrant {
        require(ownerOf(id) == msg.sender, "!owner");
        require(alive(id), "dead");
        require(usdg.transferFrom(msg.sender, reserve, FEED[agents[id].tier]), "pay");
        agents[id].lastFed = uint40(block.timestamp);
    }

    function reap(uint256 id) external {
        R storage r = agents[id];
        require(!r.dead, "n/a");                                       // F9: unrevealed zombies reapable too
        require(block.timestamp > uint256(r.lastFed) + LIFE, "alive");
        r.dead = true;
        livingCount--;
        ownedLiving[ownerOf(id)]--;
    }

    function attack(uint256 id) external nonReentrant {
        require(ownerOf(id) == msg.sender, "!owner");
        require(alive(id), "dead");
        R storage r = agents[id];
        uint32 e = currentEpoch();
        require(uint32(e + 1) > r.lastAtkEpoch1, "cooldown");
        r.lastAtkEpoch1 = e + 1;
        if (pendingAttacks[e] == 0 && (activeEpochs.length == 0 || activeEpochs[activeEpochs.length - 1] != e)) activeEpochs.push(e);
        pendingAttacks[e]++;
        uint256 rid = vrf.requestRandom(address(this));
        reqs[rid] = Req(2, id, e);
    }

    function rawFulfill(uint256 reqId, uint256 word) external {
        require(msg.sender == address(vrf), "!vrf");
        Req memory q = reqs[reqId];
        require(q.kind != 0, "unknown req");   // A2 fix: replay/unknown id must not corrupt state
        delete reqs[reqId];
        if (q.kind == 1) {
            uint256 rr = word % 100;
            uint8 tier = rr < 75 ? 0 : (rr < 95 ? 1 : 2);
            agents[q.agentId].tier = tier;
            agents[q.agentId].revealed = true;
            emit Revealed(q.agentId, tier);
        } else {
            if (pendingAttacks[q.epoch] > 0) pendingAttacks[q.epoch]--;
            // E1 fix: a result landing AFTER the epoch was settled must not mint phantom shares
            if (settled(q.epoch)) { emit Attacked(q.agentId, q.epoch, false); return; }
            R storage rab = agents[q.agentId];
            bool hit = (word % 100) < HITRATE[rab.tier];
            if (hit) {
                uint256 w = WEIGHT[rab.tier];
                shares[q.agentId][q.epoch] += w;
                totalShares[q.epoch] += w;
            }
            emit Attacked(q.agentId, q.epoch, hit);
        }
    }

    function epochEnd(uint32 e) public view returns (uint256) { return startTime + (uint256(e) + 1) * EPOCH; }

    function settle(uint32 e) public {
        require(e < currentEpoch(), "open");
        // F1 + N3: strictly in order, in O(1). Empty epochs need no per-epoch write — advancing
        // settledThrough covers them. Only epochs that ever saw an attack are tracked, and the
        // earliest unsettled one of those must not lie before e.
        if (activeCursor < activeEpochs.length) require(activeEpochs[activeCursor] >= e, "prev");
        // E2 fix: cannot settle until every attack's VRF result is in, or the grace period passed
        require(pendingAttacks[e] == 0 || block.timestamp >= epochEnd(e) + SETTLE_GRACE, "results pending");
        if (settled(e)) return;
        _settledMap[e] = true;
        if (e + 1 > settledThrough) settledThrough = e + 1;
        while (activeCursor < activeEpochs.length && activeEpochs[activeCursor] <= e) activeCursor++;
        if (totalShares[e] > 0) {
            // E4 fix: rotate the harvest window so every active position gets booked over time
            uint256 n = vault.activeCount();
            if (n > 0) {
                uint256 start = harvestCursor % n;
                vault.harvestBatch(start, autoHarvest);
                if (start + autoHarvest < n) harvestCursor = start + autoHarvest;
                else { vault.harvestBatch(0, start + autoHarvest - n); harvestCursor = 0; } // wrap around
            }
            uint256 pot = vault.potBalance();
            uint256 prize = pot > allocatedPot ? pot - allocatedPot : 0;
            rewardPerShareRay[e] = prize * RAY / totalShares[e];
            allocatedPot += prize;
            epochUnclaimed[e] = prize;
        }
    }

    function claim(uint256 id, uint32 e) external nonReentrant {
        require(ownerOf(id) == msg.sender, "!owner");
        if (!settled(e)) settle(e);
        uint256 w = shares[id][e];
        require(w > 0, "nothing");
        shares[id][e] = 0;
        uint256 payout = w * rewardPerShareRay[e] / RAY;
        if (payout > epochUnclaimed[e]) payout = epochUnclaimed[e];   // F2: never pay from other epochs / swept epochs
        require(payout > 0, "empty");
        if (payout > allocatedPot) payout = allocatedPot;
        allocatedPot -= payout;
        epochUnclaimed[e] -= payout;
        vault.drawPot(msg.sender, payout);
        emit Claimed(id, e, payout);
    }

    /// full roster for a wallet (alive or dead-not-reaped). O(n) view — off-chain eth_call only.
    function agentsOf(address who) external view returns (uint256[] memory ids) {
        uint256 n = nextId - 1;
        uint256 c;
        for (uint256 i = 1; i <= n; i++) if (_ownerOf(i) == who) c++;
        ids = new uint256[](c);
        uint256 j;
        for (uint256 i = 1; i <= n; i++) if (_ownerOf(i) == who) ids[j++] = i;
    }

    function pending(uint256 id, uint32 e) external view returns (uint256) {
        if (!settled(e) || shares[id][e] == 0) return 0;
        return shares[id][e] * rewardPerShareRay[e] / RAY;
    }

    /// A5 fix: after CLAIM_WINDOW epochs, whatever a settled epoch never paid out returns to the pot
    /// (otherwise forgotten claims would lock pot forever). Permissionless.
    function sweepStale(uint32 e) external {
        require(settled(e) && currentEpoch() > e + CLAIM_WINDOW, "not stale");
        uint256 left = epochUnclaimed[e];
        if (left == 0) return;
        epochUnclaimed[e] = 0;
        allocatedPot = allocatedPot > left ? allocatedPot - left : 0; // released back into potBalance
    }

    function setAutoHarvest(uint256 n) external onlyAdmin { autoHarvest = n; }
    /// what the next epoch will realistically pay from (for UIs)
    function potPreview() external view returns (uint256) { return vault.potLive(); }

    function setReserve(address r) external onlyAdmin { reserve = r; }
}
