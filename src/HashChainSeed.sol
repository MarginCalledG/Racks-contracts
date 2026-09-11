// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "./ReentrancyGuard.sol";

interface IRacksS { function transfer(address, uint256) external returns (bool); function transferFrom(address, address, uint256) external returns (bool); function approve(address, uint256) external returns (bool); function balanceOf(address) external view returns (uint256); }
interface IVaultS { function fundPot(uint256 amount) external; }
interface IAgentS { function attackDigest(uint32 e) external view returns (bytes32); function epochEnd(uint32 e) external view returns (uint256); function currentEpoch() external view returns (uint32); }

/// @title HashChainSeed — one random seed per epoch from a pre-committed hash chain.
///
/// The keeper rolls N secret values in advance and commits only the END of the hash chain
/// (h_N = keccak(h_{N-1}) ... ). Each epoch it reveals the next preimage; the contract checks that
/// keccak(preimage) equals the current head. Values are therefore FIXED before any agent exists —
/// the keeper cannot choose them. The seed is mixed with the digest of the epoch's attackers, so
/// nobody (keeper included) knows an outcome until the epoch has closed.
///
/// The keeper's only remaining power is to withhold. Two rules make that worthless:
///   1. a missed reveal marks the epoch FAILED — every attack that epoch misses, the keeper's too;
///   2. every miss slashes the keeper's bond into the agent pot, and anyone may trigger it.
contract HashChainSeed is ReentrancyGuard {
    IRacksS public immutable racks;
    IVaultS public immutable vault;
    IAgentS public agent;
    address public owner;
    address public keeper;

    bytes32 public head;                 // current chain head; reveal must hash to it
    uint256 public remaining;            // values left in the committed chain
    uint256 public constant REVEAL_WINDOW = 2 hours;   // after epoch end
    uint256 public slashPerMiss;         // RACKS per missed epoch
    uint256 public bond;                 // keeper's posted RACKS

    mapping(uint32 => bytes32) public seed;
    mapping(uint32 => bool)    public failed;

    event Committed(bytes32 head, uint256 length);
    event Revealed(uint32 indexed epoch, bytes32 seed);
    event Failed(uint32 indexed epoch, uint256 slashed);
    event KeeperSet(address keeper);
    event Bonded(uint256 amount);

    modifier onlyOwner()  { require(msg.sender == owner,  "!owner");  _; }
    modifier onlyKeeper() { require(msg.sender == keeper, "!keeper"); _; }

    constructor(address _racks, address _vault, address _agent, uint256 _slashPerMiss) {
        racks = IRacksS(_racks); vault = IVaultS(_vault); agent = IAgentS(_agent);
        owner = msg.sender; slashPerMiss = _slashPerMiss;
    }

    // ---- owner: who is keeper ----
    function setKeeper(address k) external onlyOwner { keeper = k; emit KeeperSet(k); }
    function setAgent(address a) external onlyOwner { require(address(agent) == address(0), "agent is final"); agent = IAgentS(a); }
    function setSlash(uint256 s) external onlyOwner { slashPerMiss = s; }
    address public pendingOwner;
    function transferOwnership(address n) external onlyOwner { pendingOwner = n; }
    function acceptOwnership() external { require(msg.sender == pendingOwner, "!pending"); owner = pendingOwner; pendingOwner = address(0); }

    // ---- keeper: commit, bond, reveal ----
    /// commit a fresh chain. Only allowed when the previous one is exhausted (or none exists).
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
    /// keeper may withdraw only what is not needed to cover the epochs still unrevealed & open
    function withdrawBond(uint256 amount) external onlyKeeper nonReentrant {
        require(bond - amount >= slashPerMiss, "keep cover");
        bond -= amount; require(racks.transfer(msg.sender, amount), "send");
    }

    /// reveal the next chain value for epoch `e`. Allowed once the epoch has closed, inside the window.
    function reveal(uint32 e, bytes32 preimage) external onlyKeeper {
        require(seed[e] == bytes32(0) && !failed[e], "done");
        require(block.timestamp >= agent.epochEnd(e), "open");
        require(block.timestamp < agent.epochEnd(e) + REVEAL_WINDOW, "window closed");
        require(remaining > 0, "chain exhausted");
        require(keccak256(abi.encodePacked(preimage)) == head, "bad preimage");
        head = preimage; remaining--;
        // mix with what actually happened in the epoch: nobody knows the seed before attacks closed
        bytes32 s = keccak256(abi.encode(preimage, e, agent.attackDigest(e)));
        seed[e] = s;
        emit Revealed(e, s);
    }

    /// permissionless: a missed reveal fails the epoch (everyone misses) and slashes the bond into the pot
    function slash(uint32 e) external nonReentrant {
        require(seed[e] == bytes32(0) && !failed[e], "done");
        require(block.timestamp >= agent.epochEnd(e) + REVEAL_WINDOW, "window open");
        failed[e] = true;
        uint256 amt = slashPerMiss > bond ? bond : slashPerMiss;
        if (amt > 0) {
            bond -= amt;
            racks.approve(address(vault), amt);
            vault.fundPot(amt);
        }
        emit Failed(e, amt);
    }

    /// resolved = the agent can settle this epoch (seed known or epoch failed)
    function resolved(uint32 e) external view returns (bool) { return seed[e] != bytes32(0) || failed[e]; }
}
