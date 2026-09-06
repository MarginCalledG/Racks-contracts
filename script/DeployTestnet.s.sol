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
import {MockERC20} from "../test/MockERC20.sol";
import {MockVRF} from "../test/MockVRF.sol";
import {MockPair} from "../test/MockPair.sol";
import {MockRouter, MockPrice} from "../test/MockSwap.sol";

/// TESTNET BRING-UP: deploys MOCK external infra (USDG, SPY, VRF, pool, router) + the full
/// protocol, wires everything, and seeds the deployer with test funds. Lets you exercise the
/// whole system live on the testnet before swapping in real USDG/SPY/Uniswap/VRF one by one.
/// Reads PRIVATE_KEY from your local .env — nothing else needed.
contract DeployTestnet is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);

        vm.startBroadcast(pk);

        // ---- mock external infra ----
        MockERC20 usdg = new MockERC20();
        MockERC20 spy  = new MockERC20();
        MockVRF vrf    = new MockVRF();
        MockPair pair  = new MockPair();
        pair.set(1_000_000 ether, 500_000 ether); // seed a price so the TWAP has data
        MockRouter router = new MockRouter(address(spy), 1, 2);
        MockPrice price   = new MockPrice(1, 2);

        // ---- protocol ----
        Racks racks          = new Racks(1e27 / 1e6);
        CaymanIslands vault  = new CaymanIslands(address(racks), address(usdg), me);
        IRSAgent agents      = new IRSAgent(address(usdg), address(vault), address(vrf), me);
        TwapOracle twap      = new TwapOracle(address(pair));
        TaxSwapper swapper   = new TaxSwapper(address(racks), address(spy), address(router), address(price), me, 1000 ether, 300);
        WRacks wracks        = new WRacks(address(racks));

        // ---- wiring (same as Deploy.s.sol) ----
        racks.setVault(address(vault));
        racks.setExempt(address(vault), true);
        vault.setAgent(address(agents));
        racks.setTaxWallet(address(swapper));
        racks.setExempt(address(swapper), true);
        racks.setTaxExempt(address(swapper), true);
        racks.setTaxOracle(address(twap));
        racks.setDex(address(pair), true);
        racks.setTaxExempt(address(vault), true);
        racks.setTaxExempt(address(agents), true);

        // ---- seed the deployer for testing ----
        racks.mint(me, 69_420_000_000 ether); // start supply: 69,420,000,000 RACKS (melts from here)
        usdg.mint(me, 100_000 ether);

        // SAFETY: the wRACKS wrapper must NEVER be melt-exempt (it would be a demurrage escape hatch).
        // It may only be tax-exempt. Guarded here so a future edit can't silently break the economics.
        require(!racks.isExempt(address(wracks)), "wrapper must melt");
        racks.setTaxExempt(address(wracks), true);

        vm.stopBroadcast();

        console2.log("== external mocks ==");
        console2.log("USDG    ", address(usdg));
        console2.log("SPY     ", address(spy));
        console2.log("VRF     ", address(vrf));
        console2.log("PAIR    ", address(pair));
        console2.log("== protocol ==");
        console2.log("RACKS   ", address(racks));
        console2.log("Cayman  ", address(vault));
        console2.log("IRSAgent", address(agents));
        console2.log("Twap    ", address(twap));
        console2.log("Swapper ", address(swapper));
        console2.log("wRACKS  ", address(wracks));
        console2.log("deployer", me);
    }
}
