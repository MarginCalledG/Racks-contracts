// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {IRSAgent} from "../src/IRSAgent.sol";
import {TwapOracle} from "../src/TwapOracle.sol";

interface IV2Factory { function createPair(address,address) external returns (address); function getPair(address,address) external view returns (address); }
interface IV2Router { function addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256) external returns (uint256,uint256,uint256); }
interface IERC20d { function approve(address,uint256) external returns (bool); function balanceOf(address) external view returns (uint256); }

/// RACKS mainnet deploy — Uniswap v2 on Robinhood Chain. No wrapper, no hook.
/// Ordering matters and is enforced by the checks below:
///   1. deploy token + vault + agents, wire them
///   2. create the pair, make it MELT-EXEMPT, seed liquidity  (trading gate still closed)
///   3. setPair (registers isDex + capExempt + pairIndex) and the tax oracle
///   4. enableTrading LAST -> launch hour (8% flat, 1% cumulative cap) starts here
contract DeployScript is Script {
    address public deployedRacks;   // for fork tests / verification tooling
    address constant FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;
    address constant ROUTER  = 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba;
    address constant SPY     = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant USDG    = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    uint256 constant SUPPLY   = 69_420_000_000 ether;
    uint256 constant SPY_SEED = 6.45 ether;          // ~$5k seed
    uint256 constant RAY      = 1e27;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        address vrf      = vm.envAddress("VRF_COORDINATOR");   // see STATUS.md — VRF is still open on RH
        address reserve  = vm.envAddress("RESERVE");           // multisig
        address taxWallet= vm.envAddress("TAX_WALLET");

        vm.startBroadcast(pk);

        // ---- 1. core ----
        Racks racks = new Racks(RAY / 1e6);
        CaymanIslands vault = new CaymanIslands(address(racks), USDG, reserve);
        IRSAgent agents = new IRSAgent(USDG, address(vault), vrf, reserve);
        vault.setAgent(address(agents));
        racks.setVault(address(vault));
        racks.setExempt(address(vault), true);      // locked RACKS must not lazy-melt
        racks.setTaxExempt(address(vault), true);
        racks.setTaxExempt(address(agents), true);
        racks.setTaxWallet(taxWallet);
        racks.setExempt(taxWallet, true);           // accrued tax must not melt away
        racks.setTaxExempt(taxWallet, true);
        racks.setTaxExempt(me, true);               // deployer seeds LP untaxed (and passes the gate)

        racks.mint(me, SUPPLY);
        racks.renounceMint();                       // supply is final

        // ---- 2. pair + liquidity (trading gate still closed: only tax-exempt may move pool tokens) ----
        address pair = IV2Factory(FACTORY).getPair(address(racks), SPY);
        if (pair == address(0)) pair = IV2Factory(FACTORY).createPair(address(racks), SPY);
        racks.setExempt(pair, true);                // REQUIRED before setPair: pair holds a NOMINAL balance
        IERC20d(address(racks)).approve(ROUTER, type(uint256).max);
        IERC20d(SPY).approve(ROUTER, type(uint256).max);
        require(IERC20d(SPY).balanceOf(me) >= SPY_SEED, "fund the deployer with SPY first");
        IV2Router(ROUTER).addLiquidity(address(racks), SPY, SUPPLY, SPY_SEED, 0, 0, me, block.timestamp + 600);

        // ---- 3. register the pair + dynamic tax oracle ----
        racks.setPair(pair);                        // isDex + capExempt + pairIndex, enables atomic meltPool
        TwapOracle oracle = new TwapOracle(pair, address(racks));
        racks.setTaxOracle(address(oracle));

        // ---- 4. arm the launch LAST ----
        racks.enableTrading();

        vm.stopBroadcast();

        // ---- deploy self-checks: fail loudly rather than launch broken ----
        require(racks.isExempt(pair), "pair must be melt-exempt");
        require(racks.pair() == pair && racks.pairIndex() != 0, "setPair missing");
        require(racks.isDex(pair), "pair not marked as dex");
        require(racks.capExempt(pair), "pair must be cap-exempt (it is the distributor)");
        require(racks.isExempt(taxWallet), "tax wallet must be melt-exempt");
        require(racks.taxOracle() == address(oracle), "oracle not wired");
        require(racks.mintRenounced(), "mint not renounced");
        require(racks.tradingStart() != 0, "trading not enabled");
        require(racks.maxWallet() > 0, "launch cap not set");

        deployedRacks = address(racks);
        console.log("RACKS   ", address(racks));
        console.log("Vault   ", address(vault));
        console.log("Agents  ", address(agents));
        console.log("Pair    ", pair);
        console.log("Oracle  ", address(oracle));
        console.log("maxWallet (1%)", racks.maxWallet());
        console.log("HAND OVER: racks.transferOwnership(multisig) then acceptOwnership()");
        console.log("AFTER LAUNCH: racks.renounceExemptControl() to close the exempt rug vector");
    }
}
