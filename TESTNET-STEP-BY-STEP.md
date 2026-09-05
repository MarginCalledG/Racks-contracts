# RACKS — Testnet Deploy & Test, Schritt für Schritt

Erster Bring-up auf Robinhood-Testnet mit **Mock-Infrastruktur** (Mock-USDG/SPY/VRF/Pool),
damit das ganze System live läuft, bevor echte Bausteine reinkommen.

Netzwerk:
- RPC:      https://rpc.testnet.chain.robinhood.com/rpc
- Chain ID: 46630
- Explorer: https://explorer.testnet.chain.robinhood.com
- Faucet:   https://faucet.testnet.chain.robinhood.com

---

## PHASE 0 — Lokales Setup

**1. Foundry installieren**
```
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

**2. Repo klonen**
```
git clone https://github.com/DEIN_USER/DEIN_REPO.git
cd DEIN_REPO
```

**3. Dependencies installieren**
```
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts --no-git
```

**4. Bauen + testen (muss 59 grün zeigen)**
```
forge build
forge test
```
Wenn hier alles grün ist, ist der Code gesund. Erst dann weiter.

---

## PHASE 1 — Wallet & Test-ETH

**5. Frische Testnet-Wallet erzeugen**
```
cast wallet new
```
Gibt dir eine Adresse und einen Private Key. **Nur fuer Testnet. Nirgends sonst verwenden.**
Adresse + Key notieren.

**6. Test-ETH holen**
Faucet oeffnen (https://faucet.testnet.chain.robinhood.com), deine neue Adresse einfuegen,
Anweisungen folgen. Danach pruefen, dass ETH da ist:
```
cast balance DEINE_ADRESSE --rpc-url https://rpc.testnet.chain.robinhood.com/rpc
```

---

## PHASE 2 — Konfigurieren

**7. `.env` anlegen** (im Repo-Root; wird durch .gitignore NICHT committet)
```
echo 'PRIVATE_KEY=0xDEIN_NEUER_TESTNET_KEY' > .env
```
Fuer den Testnet-Bring-up brauchst du NUR den PRIVATE_KEY — die Mocks deployt das Skript selbst.

---

## PHASE 3 — Deployen

**8. Das ganze System deployen (ein Befehl)**
```
forge script script/DeployTestnet.s.sol:DeployTestnet \
  --rpc-url https://rpc.testnet.chain.robinhood.com/rpc \
  --broadcast
```
Am Ende loggt es alle Adressen (USDG, RACKS, Cayman, IRSAgent, VRF, ...). **Alle notieren.**

Falls es an Gas/Transaktions-Format scheitert, haenge `--legacy` an.

**9. Auf dem Explorer pruefen**
RACKS-Adresse auf https://explorer.testnet.chain.robinhood.com eingeben — Contract sollte
sichtbar sein mit deinen Mint-Transaktionen.

---

## PHASE 4 — Interagieren & Testen

Setz dir Variablen (mit deinen echten Adressen aus Schritt 8):
```
export RPC=https://rpc.testnet.chain.robinhood.com/rpc
export PK=0xDEIN_KEY
export ME=DEINE_ADRESSE
export RACKS=0x...
export CAYMAN=0x...
export AGENTS=0x...
export USDG=0x...
export VRF=0x...
export MAX=$(cast max-uint)
```

**10. Zustand lesen**
```
cast call $RACKS "balanceOf(address)(uint256)" $ME --rpc-url $RPC
cast call $RACKS "ratePerDayBps()(uint256)" --rpc-url $RPC     # ~690 (=6.9%/Tag), sinkt mit Locks
cast call $RACKS "epochNow()(uint256)" --rpc-url $RPC          # aktuelle Epoche
```

**11. Offshore locken (Cayman, 1-Tage-Stufe)**
```
cast send $RACKS "approve(address,uint256)" $CAYMAN $MAX --rpc-url $RPC --private-key $PK
cast send $USDG  "approve(address,uint256)" $CAYMAN $MAX --rpc-url $RPC --private-key $PK
cast send $CAYMAN "lock(uint8,uint256)" 0 100000000000000000000000 --rpc-url $RPC --private-key $PK
cast call $CAYMAN "claimOf(address,uint8)(uint256)" $ME 0 --rpc-url $RPC   # ~100000e18 geschuetzt
```

**12. IRS-Agent minten + Rang aufdecken**
```
cast send $USDG "approve(address,uint256)" $AGENTS $MAX --rpc-url $RPC --private-key $PK
cast send $AGENTS "mint()" --rpc-url $RPC --private-key $PK
# VRF-Request-ID holen, dann aufdecken (Wort 97 -> Special-Rang):
cast call $VRF "lastId()(uint256)" --rpc-url $RPC
cast send $VRF "fulfill(uint256,uint256)" DIE_ID 97 --rpc-url $RPC --private-key $PK
# Agent ansehen (id 1): (tier,lastFed,lastAtkEpoch1,revealed,dead)
cast call $AGENTS "agents(uint256)(uint8,uint40,uint32,bool,bool)" 1 --rpc-url $RPC
```

**13. Den Melt beobachten** (zeitbasiert — echtes Warten noetig)
Standard-Epoche ist 30 Min. Fuer schnelleres Testen auf 15-Min-Boden stellen:
```
cast send $RACKS "setEpochLength(uint256)" 900 --rpc-url $RPC --private-key $PK
```
balanceOf jetzt lesen, 15+ Min warten, nochmal lesen -> kleiner. (Innerhalb einer Epoche
bleibt sie konstant — genau das macht den V2-Pool stabil.)

Audit -> Settle -> Claim braucht eine ganze 8h-Epoche Wartezeit, deshalb hier nur der
Mint/Reveal-Smoke-Test. Der volle Loop ist in den Foundry-Tests (Integration.t.sol) belegt.

---

## PHASE 5 — Echte Infrastruktur reintauschen (spaeter)

Wenn der Mock-Durchlauf sitzt, tauschst du Stueck fuer Stueck echt:
1. Echtes Testnet-USDG (Adresse vom Testnet-Explorer) statt Mock-USDG.
2. Echten S&P-500-Token statt Mock-SPY.
3. Echten Uniswap-V2-Pool (RACKS/SPY anlegen + Liquiditaet) statt MockPair -> in TwapOracle/setDex.
4. Echtes VRF (Chainlink/Randomizer) statt MockVRF.
Dafuer gibt es `Deploy.s.sol` (liest alle Adressen aus .env). Eine Komponente nach der anderen,
nach jedem Tausch neu smoke-testen.
