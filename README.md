# RACKS Protocol — Contracts (Testnet-Prototyp)

Getesteter Prototyp des gesamten Protokolls. **54 Tests grün**, inkl. Invarianten-Fuzzing.
Noch NICHT auditiert; VRF/SPY/V2 sind gemockt (siehe "Offen").

## Module (src/)
- **Racks**         — der Token: Demurrage, Free-Float-Rate (4,2–6,9 %/Tag, 24h-geglättet),
                      Boden gegen Brick, Fee-on-TRADE (nur Pool-Trades). ERC20 name/symbol = RACKS.
- **CaymanIslands** — die Vaults: 3-Stufen-Lock (1/3/14 Tage), 1:1-Schutz, Bleed->Pot,
                      Post-Expiry-Penalty, Reentrancy-Guard.
- **IRSAgent**      — die Spiel-NFTs (ERC721 "IRS Agent"): VRF-Rank (75/20/5),
                      Pari-mutuel (4/27/144), Feed/Verfall, 1 Audit/8h-Epoche.
- **DynamicTax**    — Tax-Rate: Spot-vs-TWAP + Impact, Caps 7/5, Floor 1.
- **TwapOracle**    — 15-Min-TWAP, manipulationsresistent.
- **TaxSwapper**    — Auto Tax-RACKS -> SPY -> Reserve, gebatcht, Slippage-Floor.
- **WRacks**        — non-rebasing Wrapper (WAMPL) für V2, falls Rebasing im Pool bricht.
- **RayMath / ReentrancyGuard** — Hilfsmodule.

## Tests (test/)  — `forge test`  (54 Tests, 12 Suiten)
Token-Decay/Free-Float/Glättung + Invarianten; Lock/Bleed/Pot/Post-Expiry + Invarianten;
IRSAgent-Pari-mutuel/VRF/Feed/ERC721-Transfer + Invarianten; Tax-Fuzz; Fee-on-Trade;
Auto-Swap; TWAP; wRACKS; Integration (voller End-to-End-Flow).

## Deploy (dein Key bleibt lokal)
```
cp .env.example .env      # ausfuellen, NIE committen
forge script script/Deploy.s.sol --rpc-url <rh-testnet> --broadcast
```
Deployt alle Contracts, verdrahtet sie vollstaendig, liest den Key aus PRIVATE_KEY der .env.

## Bauen
```
curl -L https://foundry.paradigm.xyz | bash && foundryup
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts --no-git
forge test -vv
```

## OFFEN (bewusst, vor Mainnet zwingend)
1. Echte Uniswap-V2-Anbindung testen -> RACKS direkt ODER WRacks-Wrapper (liegt bereit).
2. Echtes VRF (Randomizer/Chainlink) statt Mock.
3. Tokenisiertes SPY auf RH Chain: haltbar durch Multisig? Transfer-Restriktionen?
4. tokenURI/Metadata + Bilder fuer die IRS-Agent-NFTs.
5. Parameter-Kalibrierung am echten Testchain-Verhalten.
6. EXTERNES AUDIT (Gluecksspiel- + Wertpapier-Bezug + echtes Geld).
7. Rechtliche Einordnung (Anwalt).
