// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Racks} from "../src/Racks.sol";
import {CaymanIslands} from "../src/CaymanIslands.sol";
import {IRSAgent} from "../src/IRSAgent.sol";
import {TwapOracle} from "../src/TwapOracle.sol";
import {TaxSwapper} from "../src/TaxSwapper.sol";
import {WRacks} from "../src/WRacks.sol";

/// Deploy + wire the full protocol. Reads the deployer key + external addresses from env.
/// Run:  forge script script/Deploy.s.sol --rpc-url <rh-testnet> --broadcast
/// The PRIVATE_KEY stays in YOUR local .env — never in this file or the repo.
contract Deploy is Script {
    function run() external {
        uint256 pk        = vm.envUint("PRIVATE_KEY");
        address usdg      = vm.envAddress("USDG");
        address spy       = vm.envAddress("SPY");
        address pair      = vm.envAddress("PAIR");       // (w)RACKS/SPY pool
        address vrfCoord  = vm.envAddress("VRF");
        address router    = vm.envAddress("ROUTER");
        address priceSrc  = vm.envAddress("PRICE_SRC");
        address reserve   = vm.envAddress("RESERVE");    // treasury multisig
        uint256 minIndex  = vm.envOr("MIN_INDEX", uint256(1e27 / 1e6));
        uint256 swapThr   = vm.envOr("SWAP_THRESHOLD", uint256(1000 ether));
        uint256 maxSlip   = vm.envOr("MAX_SLIPPAGE_BPS", uint256(300));

        vm.startBroadcast(pk);

        Racks racks  = new Racks(minIndex);
        CaymanIslands vault     = new CaymanIslands(address(racks), usdg, reserve);
        IRSAgent agents     = new IRSAgent(usdg, address(vault), vrfCoord, reserve);
        TwapOracle twap   = new TwapOracle(pair, address(racks));
        TaxSwapper swapper= new TaxSwapper(address(racks), spy, router, priceSrc, reserve, swapThr, maxSlip);
        WRacks wracks     = new WRacks(address(racks));

        // wiring
        racks.setVault(address(vault));
        racks.setExempt(address(vault), true);
        vault.setAgent(address(agents));
        racks.setTaxWallet(address(swapper));
        racks.setExempt(address(swapper), true);
        racks.setTaxExempt(address(swapper), true);
        racks.setTaxOracle(address(twap));
        racks.setDex(pair, true);
        racks.setTaxExempt(address(vault), true);
        racks.setTaxExempt(address(agents), true);

        // start supply: 69,420,000,000 RACKS (melts from here). Sent to the treasury/reserve
        // for distribution (LP, airdrop, presale). Adjust recipient/splits before mainnet.
        racks.mint(reserve, 69_420_000_000 ether);

        // SAFETY: the wRACKS wrapper must NEVER be melt-exempt (it would be a demurrage escape hatch).
        // It may only be tax-exempt. Guarded here so a future edit can't silently break the economics.
        require(!racks.isExempt(address(wracks)), "wrapper must melt");
        racks.setTaxExempt(address(wracks), true);

        vm.stopBroadcast();

        console2.log("RACKS   ", address(racks));
        console2.log("CaymanIslands  ", address(vault));
        console2.log("Agents  ", address(agents));
        console2.log("Twap    ", address(twap));
        console2.log("Swapper ", address(swapper));
        console2.log("wRACKS  ", address(wracks));
    }
}
