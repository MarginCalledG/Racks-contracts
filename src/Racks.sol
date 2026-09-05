// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RayMath} from "./RayMath.sol";

interface ITaxOracle {
    function update() external;
    function taxBps(uint256 amount, bool isSell) external view returns (uint256);
}

/// @title Racks (Stage 1, hardened) — demurrage token, free-float-coupled rate, 24h-smoothed
contract Racks {
    uint256 internal constant RAY = 1e27;
    uint256 public constant TAU = 86400; // 24h smoothing window

    uint256 public constant F_FF0 = 999999503385528269210124288; // per-sec retention @ 4.2%/day (FF=0)
    uint256 public constant F_FF1 = 999999172500322683774304256; // per-sec retention @ 6.9%/day (FF=1)

    string public name = "RACKS";
    string public symbol = "RACKS";
    uint8 public constant decimals = 18;

    mapping(address => uint256) internal _scaled;
    mapping(address => uint256) internal _nominal;
    mapping(address => bool) public isExempt;
    mapping(address => bool) public isFloatExcluded;
    mapping(address => mapping(address => uint256)) public allowance;

    // fee-on-TRADE (not on transfer): tax only when a DEX pool is involved
    mapping(address => bool) public isDex;
    mapping(address => bool) public isTaxExempt;
    address public taxWallet;
    address public taxOracle;

    uint256 internal _totalScaled;
    uint256 internal _totalScaledFloatExcl;
    uint256 internal _totalNominalExempt;
    uint256 public lockedSupply;

    uint256 public indexCheckpoint;
    uint256 public lastUpdate;
    uint256 public perSecFactor;
    uint256 public smoothedFFRay;     // 24h-smoothed free float
    uint256 public immutable minIndex;

    uint256 public immutable startTime;
    uint256 public epochLength;               // discrete decay step (seconds)
    uint256 public constant MIN_EPOCH = 900;  // 15-min floor
    uint256 public checkpointEpoch;

    // launch guardrails (all keyed off enableTrading())
    uint256 public constant LAUNCH_WINDOW  = 1 hours;
    uint256 public constant MAX_WALLET_BPS = 80;   // 0.8% of launch supply
    uint256 public constant LAUNCH_TAX_BPS = 800;  // 8% flat during the launch hour
    uint256 public tradingStart;                    // 0 until enableTrading()
    uint256 public launchSupply;
    uint256 public maxWallet;
    bool public mintRenounced;

    address public owner;
    address public vault;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }

    constructor(uint256 _minIndex) {
        owner = msg.sender;
        minIndex = _minIndex;
        indexCheckpoint = RAY;
        lastUpdate = block.timestamp;
        smoothedFFRay = RAY;      // starts at max float
        perSecFactor = F_FF1;
        startTime = block.timestamp;
        epochLength = 1800;       // 30-min epochs by default
    }

    function epochNow() public view returns (uint256) {
        return (block.timestamp - startTime) / epochLength;
    }

    // ---- index (DISCRETE epochs: balances only step at boundaries -> V2-safe between steps) ----
    function index() public view returns (uint256) {
        uint256 steps = epochNow() - checkpointEpoch;
        uint256 i = steps == 0
            ? indexCheckpoint
            : RayMath.rmul(indexCheckpoint, RayMath.rpow(perSecFactor, steps * epochLength));
        return i < minIndex ? minIndex : i;
    }

    // ---- free float ----
    function instantFreeFloatRay() public view returns (uint256) {
        uint256 scaledFloat = _totalScaled - _totalScaledFloatExcl;
        uint256 U = scaledFloat * index() / RAY;
        uint256 L = lockedSupply;
        if (U + L == 0) return RAY;
        return U * RAY / (U + L);
    }

    function _perSecFromFF(uint256 ff) internal pure returns (uint256) {
        return F_FF0 - ((F_FF0 - F_FF1) * ff / RAY);
    }

    /// smoothed daily debase in bps (420..690)
    function ratePerDayBps() external view returns (uint256) {
        return 420 + (270 * smoothedFFRay / RAY);
    }

    // ---- op lifecycle: accrue index (old rate) -> mutate -> blend FF -> new rate ----
    function _preOp() internal returns (uint256 dt) {
        uint256 e = epochNow();
        if (e > checkpointEpoch) { indexCheckpoint = index(); checkpointEpoch = e; }
        dt = block.timestamp - lastUpdate;
        lastUpdate = block.timestamp;
    }

    function _postOp(uint256 dt) internal {
        uint256 instFF = instantFreeFloatRay();
        uint256 cap = dt > TAU ? TAU : dt;
        // time-weighted blend: a single-block change (small dt) barely moves the rate
        smoothedFFRay = (smoothedFFRay * (TAU - cap) + instFF * cap) / TAU;
        perSecFactor = _perSecFromFF(smoothedFFRay);
    }

    /// keeper/test hook: advance index + smoothing without moving balances
    function poke() external { uint256 dt = _preOp(); _postOp(dt); }

    // ---- balances ----
    function balanceOf(address a) public view returns (uint256) {
        if (isExempt[a]) return _nominal[a];
        return _scaled[a] * index() / RAY;
    }

    function totalSupply() external view returns (uint256) {
        return _totalNominalExempt + (_totalScaled * index() / RAY);
    }

    function _debit(address from, uint256 amount) internal returns (uint256 removed) {
        if (isExempt[from]) { _nominal[from] -= amount; _totalNominalExempt -= amount; return amount; }
        uint256 s = amount * RAY / indexCheckpoint;
        uint256 have = _scaled[from];
        if (s > have) s = have;                 // full-balance rounding: move all, never underflow
        _scaled[from] -= s; _totalScaled -= s;
        if (isFloatExcluded[from]) _totalScaledFloatExcl -= s;
        removed = s * indexCheckpoint / RAY;     // exact value removed (conservation)
    }

    function _credit(address to, uint256 amount) internal {
        if (isExempt[to]) { _nominal[to] += amount; _totalNominalExempt += amount; }
        else {
            uint256 s = amount * RAY / indexCheckpoint;
            _scaled[to] += s; _totalScaled += s;
            if (isFloatExcluded[to]) _totalScaledFloatExcl += s;
        }
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount); return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount); return true;
    }

    /// tax applies ONLY to pool trades (buy = pool->user, sell = user->pool); never plain transfers
    function _taxBps(address from, address to, uint256 amount) internal returns (uint256) {
        if (taxWallet == address(0)) return 0;
        bool sell = isDex[to];
        bool buy  = isDex[from];
        if (!sell && !buy) return 0;                        // wallet<->wallet: no tax
        if (isTaxExempt[from] || isTaxExempt[to]) return 0; // system contracts exempt
        if (inLaunchWindow()) return LAUNCH_TAX_BPS;        // flat 8% during launch hour
        if (taxOracle == address(0)) return 0;
        ITaxOracle(taxOracle).update();                     // advance TWAP accumulator on the trade
        return ITaxOracle(taxOracle).taxBps(amount, sell);
    }

    function _move(address from, address to, uint256 amount) internal {
        uint256 dt = _preOp();
        uint256 bal = balanceOf(from);
        if (amount > bal) amount = bal;                     // clamp to real balance (max-transfer safe)
        uint256 bps = _taxBps(from, to, amount);
        uint256 removed = _debit(from, amount);
        uint256 tax = removed * bps / 10000;
        if (tax > 0) { _credit(taxWallet, tax); emit Transfer(from, taxWallet, tax); }
        _credit(to, removed - tax);
        // launch anti-snipe: cap BUYS (pool -> wallet) per wallet during the first hour
        if (inLaunchWindow() && isDex[from] && !isDex[to] && !isExempt[to] && !isTaxExempt[to]) {
            require(balanceOf(to) <= maxWallet, "max wallet");
        }
        _postOp(dt);
        emit Transfer(from, to, removed - tax);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount; emit Approval(msg.sender, spender, amount); return true;
    }

    function renounceMint() external onlyOwner { mintRenounced = true; }

    function mint(address to, uint256 amount) external onlyOwner {
        require(!mintRenounced, "mint renounced");
        uint256 dt = _preOp(); _credit(to, amount); _postOp(dt);
        emit Transfer(address(0), to, amount);
    }

    function setExempt(address a, bool e) external onlyOwner {
        uint256 dt = _preOp();
        if (isExempt[a] != e) {
            uint256 bal = balanceOf(a);
            if (isExempt[a]) { _nominal[a] = 0; _totalNominalExempt -= bal; }
            else {
                uint256 s = _scaled[a]; _scaled[a] = 0; _totalScaled -= s;
                if (isFloatExcluded[a]) _totalScaledFloatExcl -= s;
            }
            isExempt[a] = e;
            if (e) { _nominal[a] = bal; _totalNominalExempt += bal; }
            else {
                uint256 s2 = bal * RAY / indexCheckpoint; _scaled[a] = s2; _totalScaled += s2;
                if (isFloatExcluded[a]) _totalScaledFloatExcl += s2;
            }
        }
        _postOp(dt);
    }

    function setFloatExcluded(address a, bool ex) external onlyOwner {
        uint256 dt = _preOp();
        if (isFloatExcluded[a] != ex && !isExempt[a]) {
            uint256 s = _scaled[a];
            if (ex) _totalScaledFloatExcl += s; else _totalScaledFloatExcl -= s;
        }
        isFloatExcluded[a] = ex; _postOp(dt);
    }

    function setVault(address l) external onlyOwner { vault = l; }
    function enableTrading() external onlyOwner {
        require(tradingStart == 0, "started");
        tradingStart = block.timestamp;
        launchSupply = _totalNominalExempt + (_totalScaled * index() / RAY);
        maxWallet = launchSupply * MAX_WALLET_BPS / 10000;
    }
    function inLaunchWindow() public view returns (bool) {
        return tradingStart != 0 && block.timestamp < tradingStart + LAUNCH_WINDOW;
    }
    function setEpochLength(uint256 s) external onlyOwner {
        require(s >= MIN_EPOCH, "epoch too short");
        if (epochNow() > checkpointEpoch) { indexCheckpoint = index(); } // settle under old length
        epochLength = s;
        checkpointEpoch = (block.timestamp - startTime) / s;
    }
    function setDex(address a, bool v) external onlyOwner { isDex[a] = v; }
    function setTaxExempt(address a, bool v) external onlyOwner { isTaxExempt[a] = v; }
    function setTaxWallet(address w) external onlyOwner { taxWallet = w; }
    function setTaxOracle(address o) external onlyOwner { taxOracle = o; }

    function setLockedSupply(uint256 L) external {
        require(msg.sender == vault || msg.sender == owner, "not vault");
        uint256 dt = _preOp(); lockedSupply = L; _postOp(dt);
    }
}
