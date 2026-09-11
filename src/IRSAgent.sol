// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuard} from "./ReentrancyGuard.sol";

interface IERC20r { function transferFrom(address f, address t, uint256 a) external returns (bool); function decimals() external view returns (uint8); function allowance(address,address) external view returns (uint256); function balanceOf(address) external view returns (uint256); }
interface ICaymanPot {
    function potBalance() external view returns (uint256);
    function potLive() external view returns (uint256);
    function drawPot(address to, uint256 amount) external;
    function harvestBatch(uint256 from, uint256 count) external;
    function activeCount() external view returns (uint256);
}
/// one seed per epoch (HashChainSeed or any future source with the same shape)
interface ISeedSource {
    function seed(uint32 e) external view returns (bytes32);
    function failed(uint32 e) external view returns (bool);
    function resolved(uint32 e) external view returns (bool);
}

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
    ISeedSource public seedSource;
    address public reserve;
    address public admin;
    uint256 public immutable startTime;

    uint256 public livingCount;
    uint256 public nextId = 1;

    struct R { uint40 lastFed; uint32 lastAtkEpoch1; uint32 mintEpoch; bool dead; }
    mapping(uint256 => R) public agents;
    mapping(address => uint256) public ownedLiving;


    mapping(uint32 => uint256) public totalShares;
    mapping(uint32 => uint256) public rewardPerShareRay;
    mapping(uint32 => bool) internal _settledMap;
    uint32[] public activeEpochs;      // epochs that ever had an attack (ascending)
    uint256 public activeCursor;       // first not-yet-settled entry in activeEpochs
    /// N3: O(1) — everything below settledThrough counts as settled without touching storage per epoch
    function settled(uint32 e) public view returns (bool) { return e < settledThrough || _settledMap[e]; }
    mapping(uint256 => mapping(uint32 => uint256)) public shares;
    uint256 public allocatedPot;
    bool public paused = true;   // casino starts PAUSED until a real randomness source is wired
    uint256 public autoHarvest = 25; // positions harvested inside settle() (bounded gas); keepers page the rest
    uint256 public harvestCursor;     // E4 fix: rotating start index so spam can't starve real positions
    uint32 public settledThrough;     // F1: every epoch < settledThrough is settled
    // attacks are only REGISTERED during the epoch; outcomes are derived once the epoch's seed exists
    mapping(uint32 => uint256[]) internal _attackers;   // agent ids that attacked in epoch e
    mapping(uint32 => bytes32) public attackDigest;     // running hash of attackers, mixed into the seed
    mapping(uint32 => uint256) public tallyCursor;      // how many attackers of e have been scored
    mapping(uint32 => uint256) public epochUnclaimed;  // A5: prize still unclaimed per epoch
    uint256 public constant DUST = 1e9;   // 1e-9 RACKS: below any economically claimable prize
    uint32 public constant CLAIM_WINDOW = 90;          // epochs (~30 days) to claim before sweep

    event Minted(uint256 indexed id, address indexed owner);
    event Tallied(uint32 indexed epoch, uint256 upTo);
    event Attacked(uint256 indexed id, uint32 epoch);
    event Claimed(uint256 indexed id, uint32 epoch, uint256 amount);

    modifier onlyAdmin() { require(msg.sender == admin, "!admin"); _; }

    constructor(address _usdg, address _vault, address _seed, address _reserve)
        ERC721("IRS Agent", "IRS")
    {
        usdg = IERC20r(_usdg); vault = ICaymanPot(_vault); seedSource = ISeedSource(_seed);
        reserve = _reserve; admin = msg.sender; startTime = block.timestamp;
        uint256 u = 10 ** usdg.decimals();
        MINT_PRICE = 99 * u; FEED = [10 * u, 20 * u, 30 * u]; // decimal-aware
    }

    function currentEpoch() public view returns (uint32) {
        return uint32((block.timestamp - startTime) / EPOCH);
    }

    /// the seed that reveals an agent: its mint epoch's seed, or the first later non-failed one
    function _revealSeed(uint256 id) internal view returns (bytes32) {
        uint32 e = agents[id].mintEpoch; uint32 now_ = currentEpoch();
        while (e < now_) {
            if (seedSource.failed(e)) { e++; continue; }
            bytes32 sd = seedSource.seed(e);
            if (sd == bytes32(0)) return bytes32(0);
            return sd;
        }
        return bytes32(0);
    }
    function revealed(uint256 id) public view returns (bool) { return _revealSeed(id) != bytes32(0); }
    /// 0 common (75%) | 1 senior (20%) | 2 special (5%)
    function tier(uint256 id) public view returns (uint8) {
        bytes32 sd = _revealSeed(id);
        require(sd != bytes32(0), "unrevealed");
        uint256 w = uint256(keccak256(abi.encode(sd, id, "tier"))) % 100;
        return w < 75 ? 0 : (w < 95 ? 1 : 2);
    }

    function alive(uint256 id) public view returns (bool) {
        R storage r = agents[id];
        return revealed(id) && !r.dead && block.timestamp <= uint256(r.lastFed) + LIFE;
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
        require(!paused, "paused");
        require(ownedLiving[msg.sender] < MAX_PER_WALLET, "wallet cap");
        require(livingCount < CAP, "cap");
        require(usdg.transferFrom(msg.sender, reserve, MINT_PRICE), "pay");
        id = nextId++;
        agents[id] = R(uint40(block.timestamp), 0, currentEpoch(), false);
        livingCount++;
        _mint(msg.sender, id); // _update bumps ownedLiving
        emit Minted(id, msg.sender);   // tier is revealed by this epoch's seed once the epoch closes
    }

    function feed(uint256 id) external nonReentrant {
        require(ownerOf(id) == msg.sender, "!owner");
        require(alive(id), "dead");
        require(usdg.transferFrom(msg.sender, reserve, FEED[tier(id)]), "pay");
        agents[id].lastFed = uint40(block.timestamp);
    }

    function reap(uint256 id) external {
        R storage r = agents[id];
        require(!r.dead, "n/a");
        require(block.timestamp > uint256(r.lastFed) + LIFE, "alive");
        r.dead = true;
        livingCount--;
        ownedLiving[ownerOf(id)]--;
    }

    function attack(uint256 id) external nonReentrant {
        require(!paused, "paused");
        require(ownerOf(id) == msg.sender, "!owner");
        require(alive(id), "dead");
        R storage r = agents[id];
        uint32 e = currentEpoch();
        require(uint32(e + 1) > r.lastAtkEpoch1, "cooldown");
        r.lastAtkEpoch1 = e + 1;
        if (_attackers[e].length == 0 && (activeEpochs.length == 0 || activeEpochs[activeEpochs.length - 1] != e)) activeEpochs.push(e);
        _attackers[e].push(id);
        attackDigest[e] = keccak256(abi.encode(attackDigest[e], id));   // mixed into the epoch seed
        emit Attacked(id, e);
    }
    function attackersOf(uint32 e) external view returns (uint256 n) { return _attackers[e].length; }

    /// score the attackers of a closed epoch against its seed, in pages. Permissionless.
    /// A FAILED epoch (keeper withheld) scores everyone as a miss — the keeper's agents too.
    function tally(uint32 e, uint256 count) public {
        require(e < currentEpoch(), "open");
        require(seedSource.resolved(e), "no seed yet");
        uint256[] storage ids = _attackers[e];
        uint256 i = tallyCursor[e]; uint256 to = i + count; if (to > ids.length) to = ids.length;
        if (!seedSource.failed(e)) {
            bytes32 sd = seedSource.seed(e);
            for (; i < to; i++) {
                uint256 id = ids[i];
                bool hit = uint256(keccak256(abi.encode(sd, id, e))) % 100 < HITRATE[tier(id)];
                if (hit) { uint256 w = WEIGHT[tier(id)]; shares[id][e] = w; totalShares[e] += w; }
            }
        } else { i = to; }
        tallyCursor[e] = to;
        emit Tallied(e, to);
    }
    function tallied(uint32 e) public view returns (bool) { return tallyCursor[e] == _attackers[e].length; }

    function epochEnd(uint32 e) public view returns (uint256) { return startTime + (uint256(e) + 1) * EPOCH; }

    function settle(uint32 e) public {
        require(e < currentEpoch(), "open");
        // F1 + N3: strictly in order, in O(1). Empty epochs need no per-epoch write — advancing
        // settledThrough covers them. Only epochs that ever saw an attack are tracked, and the
        // earliest unsettled one of those must not lie before e.
        if (activeCursor < activeEpochs.length) require(activeEpochs[activeCursor] >= e, "prev");
        // outcomes exist only once the epoch's seed is in (or the epoch failed) and every attacker
        // has been scored — no result can ever arrive "late" any more
        require(seedSource.resolved(e), "no seed yet");
        if (!tallied(e)) tally(e, type(uint256).max);
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
        // Pari-mutuel rounding leaves a few wei per epoch. Without clearing it, allocatedPot never
        // returns to 0 and the vault's migration guard (which requires "owes nothing") would be
        // blocked forever by dust. The remainder simply stays in the pot, unallocated.
        if (epochUnclaimed[e] > 0 && epochUnclaimed[e] <= DUST) {
            allocatedPot -= epochUnclaimed[e];
            epochUnclaimed[e] = 0;
        }
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

    /// unpause only once a real VRF is wired; refuses a codeless placeholder outright
    // ---- randomness source ----
    // The vault's agent pointer is permanent, so the ONLY thing that ever needs replacing is the
    // randomness source (RH had none at launch). Timelocked so players see a change coming, and
    // renounceable so it can be closed for good once a real VRF is settled.
    uint256 public constant VRF_DELAY = 7 days;   // kept name: 'vrf' = the seed source
    address public pendingVrf;
    uint256 public pendingVrfAt;
    bool public vrfFinal;
    event VrfProposed(address vrf, uint256 executableAt);
    event VrfChanged(address indexed oldVrf, address indexed newVrf);
    event VrfFinalised();

    function proposeVrf(address v_) external onlyAdmin {
        require(!vrfFinal, "vrf final");
        require(v_.code.length > 0, "vrf has no code");
        pendingVrf = v_; pendingVrfAt = block.timestamp + VRF_DELAY;
        emit VrfProposed(v_, pendingVrfAt);
    }
    function executeVrf() external onlyAdmin {
        require(!vrfFinal, "vrf final");
        require(pendingVrf != address(0) && block.timestamp >= pendingVrfAt, "timelock");
        emit VrfChanged(address(seedSource), pendingVrf);
        seedSource = ISeedSource(pendingVrf); pendingVrf = address(0); pendingVrfAt = 0;
    }
    function cancelVrf() external onlyAdmin { pendingVrf = address(0); pendingVrfAt = 0; }
    /// one-way: give up the ability to ever change the randomness source again
    function renounceVrfControl() external onlyAdmin {
        require(address(seedSource).code.length > 0, "no real vrf yet");
        vrfFinal = true; pendingVrf = address(0); pendingVrfAt = 0;
        emit VrfFinalised();
    }

    function setPaused(bool p_) external onlyAdmin {
        if (!p_) require(address(seedSource).code.length > 0, "vrf has no code");
        paused = p_;
    }
    function setAutoHarvest(uint256 n) external onlyAdmin { autoHarvest = n; }
    /// what the next epoch will realistically pay from (for UIs)
    function potPreview() external view returns (uint256) { return vault.potLive(); }

    address public pendingAdmin;
    function transferOwnership(address n) external onlyAdmin { pendingAdmin = n; }
    function acceptOwnership() external { require(msg.sender == pendingAdmin, "!pending"); admin = pendingAdmin; pendingAdmin = address(0); }

    function setReserve(address r) external onlyAdmin { reserve = r; }
}
