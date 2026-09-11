// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "./ReentrancyGuard.sol";

interface IRacksS { function transfer(address, uint256) external returns (bool); function transferFrom(address, address, uint256) external returns (bool); function approve(address, uint256) external returns (bool); }
interface IVaultS { function fundPot(uint256 amount) external; function potBalance() external view returns (uint256); }
interface IAgentS { function epochStart(uint32 e) external view returns (uint256); function epochEnd(uint32 e) external view returns (uint256); function currentEpoch() external view returns (uint32); }

/// @title HashChainSeed — reveal-then-play randomness.
///
/// Two components, two parties, neither can steer the outcome alone:
///   * the keeper's PRE-COMMITTED chain value, revealed at the START of the epoch (public from then
///     on, so it is an advantage to nobody — attacks are placed knowing it, and it decides nothing yet);
///   * a block hash from AFTER the epoch closed, captured by the first transaction that touches the
///     epoch after its end. No player controls it. The sequencer could, but it has no stake.
/// seed(e) = keccak(preimage_e, closeHash_e). The keeper never knows a result before attacks close.
///
/// The keeper's remaining powers are (a) to delay an epoch by revealing late and (b) to not reveal at
/// all. Both are priced: a missed reveal fails the epoch (everyone misses, keeper included) and
/// slashes max(slashPerMiss, current pot) from the bond into the pot. The bond must cover that, or
/// attacks are refused (agent checks bondOk()).
contract HashChainSeed is ReentrancyGuard {
    IRacksS public immutable racks;
    IVaultS public immutable vault;
    IAgentS public agent;
    address public owner;
    address public keeper;

    bytes32 public head;
    uint256 public remaining;
    uint256 public constant REVEAL_WINDOW = 2 hours;    // reveal must land before epochEnd + window
    uint256 public slashPerMiss;                        // floor; the actual slash is max(this, pot)
    uint256 public bond;

    mapping(uint32 => bytes32) public preimage;         // public from epoch start
    mapping(uint32 => bytes32) public closeHash;        // captured after epoch end
    mapping(uint32 => bool)    public failed;

    event Committed(bytes32 head, uint256 length);
    event Revealed(uint32 indexed epoch, bytes32 preimage);
    event Closed(uint32 indexed epoch, bytes32 closeHash, uint256 blockNumber);
    event Failed(uint32 indexed epoch, uint256 slashed);
    event KeeperSet(address keeper);
    event Bonded(uint256 amount);

    modifier onlyOwner()  { require(msg.sender == owner,  "!owner");  _; }
    modifier onlyKeeper() { require(msg.sender == keeper, "!keeper"); _; }

    constructor(address _racks, address _vault, address _agent, uint256 _slashPerMiss) {
        racks = IRacksS(_racks); vault = IVaultS(_vault); agent = IAgentS(_agent);
        owner = msg.sender; slashPerMiss = _slashPerMiss;
    }

    // ---- owner ----
    function setKeeper(address k) external onlyOwner { keeper = k; emit KeeperSet(k); }
    function setAgent(address a) external onlyOwner { require(address(agent) == address(0), "agent is final"); agent = IAgentS(a); }
    function setSlash(uint256 s) external onlyOwner { slashPerMiss = s; }
    address public pendingOwner;
    function transferOwnership(address n) external onlyOwner { pendingOwner = n; }
    function acceptOwnership() external { require(msg.sender == pendingOwner, "!pending"); owner = pendingOwner; pendingOwner = address(0); }

    // ---- keeper ----
    function commit(bytes32 chainEnd, uint256 length) external onlyKeeper {
        require(remaining == 0, "chain not exhausted");
        require(chainEnd != bytes32(0) && length > 0, "bad chain");
        head = chainEnd; remaining = length;
        emit Committed(chainEnd, length);
    }
    function depositBond(uint256 amount) external onlyKeeper nonReentrant {
        require(racks.transferFrom(msg.sender, address(this), amount), "pull");
        bond += amount; emit Bonded(bond);
    }
    function withdrawBond(uint256 amount) external onlyKeeper nonReentrant {
        require(bond - amount >= slashAmount(), "keep cover");
        bond -= amount; require(racks.transfer(msg.sender, amount), "send");
    }

    /// reveal the chain value for epoch e. Allowed from the epoch's START (reveal-then-play): the
    /// value is public while attacks are placed, and decides nothing on its own.
    function reveal(uint32 e, bytes32 pre) external onlyKeeper {
        require(preimage[e] == bytes32(0) && !failed[e], "done");
        require(block.timestamp >= agent.epochStart(e), "not started");
        require(block.timestamp < agent.epochEnd(e) + REVEAL_WINDOW, "window closed");
        require(remaining > 0, "chain exhausted");
        require(keccak256(abi.encodePacked(pre)) == head, "bad preimage");
        head = pre; remaining--;
        preimage[e] = pre;
        emit Revealed(e, pre);
    }

    /// permissionless: capture the post-close entropy. The FIRST transaction after the epoch's end
    /// fixes it (any agent interaction calls this too), so no single party picks the block.
    function captureClose(uint32 e) public {
        if (closeHash[e] != bytes32(0) || failed[e]) return;
        if (block.timestamp < agent.epochEnd(e)) return;
        bytes32 h = blockhash(block.number - 1);
        if (h == bytes32(0)) return;                     // genesis edge case
        closeHash[e] = h;
        emit Closed(e, h, block.number - 1);
    }

    /// permissionless: a missed reveal fails the epoch and slashes the keeper into the pot
    function slash(uint32 e) external nonReentrant {
        require(preimage[e] == bytes32(0) && !failed[e], "done");
        require(block.timestamp >= agent.epochEnd(e) + REVEAL_WINDOW, "window open");
        failed[e] = true;
        uint256 amt = slashAmount(); if (amt > bond) amt = bond;
        if (amt > 0) { bond -= amt; racks.approve(address(vault), amt); vault.fundPot(amt); }
        emit Failed(e, amt);
    }

    // ---- views ----
    /// a withheld epoch must cost at least what was at stake
    function slashAmount() public view returns (uint256) { uint256 p = vault.potBalance(); return p > slashPerMiss ? p : slashPerMiss; }
    /// attacks are only accepted while the keeper's bond covers the pot
    function bondOk() external view returns (bool) { return bond >= slashAmount(); }
    function seed(uint32 e) public view returns (bytes32) {
        if (preimage[e] == bytes32(0) || closeHash[e] == bytes32(0)) return bytes32(0);
        return keccak256(abi.encode(preimage[e], closeHash[e]));
    }
    function resolved(uint32 e) external view returns (bool) { return failed[e] || seed(e) != bytes32(0); }
}
