# RACKS — Status & Entscheidungen (Stand: aktueller Zwischenstand)

## Was funktioniert
- Vollstaendiges Protokoll (v2-basiert), **72 Tests gruen** (Foundry, inkl. Invarianten-Fuzzing).
- **Erfolgreich auf Robinhood-Testnet deployt und live getestet**: Token/Melt, Cayman-Locks,
  IRS-Agents (Mint + VRF-Reveal), Launch-Tax (8%), Sell-Tax — alles on-chain bestaetigt.

## Gerade gefixt
- **USDG-Decimals-Bug**: USDG hat auf RH **6 Decimals**, nicht 18. Alle USDG-Gebuehren
  (Cayman-Locks $3/$5/$10, IRS-Mint $99, Feed $10/$20/$30) sind jetzt **decimal-bewusst**
  (im Konstruktor aus `usdg.decimals()` skaliert). Getestet fuer 6- und 18-Decimal.

## On-chain verifizierte Fakten (RH Chain)
- **USDG** (mainnet): 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 — **6 decimals**
- **WETH** (mainnet): 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73
- **SPY** (SPDR S&P 500, mainnet): 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C — **18 decimals**
  - ~12.929 SPY in v4-Pools (~57% der Supply) = tiefe, echte Liquiditaet (~$7-8M).
  - SPY ist von Pool-Contracts haltbar (v4-PoolManager haelt es) -> keine DeFi-Transfer-Sperre.
  - SPY nutzt uiMultiplier (ERC-8056) fuer Splits/Dividenden -> Orakel muss das einrechnen.
  - SPY ist eine restringierte Schuldverschreibung (RH Assets Jersey Ltd; nicht fuer US-Personen).
- **Uniswap v4** (mainnet UND testnet, gleiche Adressen):
  - PoolManager: 0x8366a39CC670B4001A1121B8F6A443A643e40951
  - Quoter:      0x8dc178efb8111bb0973dd9d722ebeff267c98f94
  - StateView:   0xf3334192d15450cdd385c8b70e03f9a6bd9e673b
  - RHs Modifikation sitzt NUR im Universal Router (extra `minHopPriceX36`-Feld);
    der PoolManager ist Standard-v4 -> gegen den bauen wir.
- **Uniswap v2** existiert nur als Dritt-Deployment auf MAINNET (Router 0x89e5DB8B...),
  NICHT auf dem Testnet. Vorsicht: Look-alike-Router kursieren.

## Architektur-Entscheidung: Wechsel auf v4 + wRACKS
Begruendung:
- Echte SPY-Liquiditaet liegt auf v4, nicht v2.
- RHs v4 ist auf dem Testnet -> echter Testnet-Test gegen echte Infrastruktur.
- **wRACKS-Wrapper** (non-rebasing) im Pool loest das Rebasing-Problem, ohne komplexen,
  un-auditierten Custom-Hook: der Pool sieht nie ein schmelzendes Token -> kein Pool-Melt,
  kein Sync-Call, kein Drift. Melt lebt in Wallet-balanceOf + Wrapper-Kurs (beide lazy).
- Pool = **wRACKS/SPY**; SPY-Pairing bleibt (Marketing-/Stock-Meta).
- Ein **Zap-Contract** buendelt wrap+swap in EINE Transaktion -> fuer den User unsichtbar.

## v4-Schicht: GEBAUT, fork-getestet und gestresst (src/v4/)
- LAUNCH-CAP (1% pro Wallet, NACH Tax): Zap kappt den Input via v4-Quoter (Rueckwaerts-Rechnung),
  Ueber-Cap-Kaeufe SCHEITERN NICHT -> Kaeufer bekommt exakt 1% + Rest-USDG zurueck.
  Test (LaunchCap.t.sol): 50k USDG -> 7.960 RACKS (Cap 8.000) + 42.601 USDG refund.
  Grenze gilt nur im Launch-Fenster; danach frei. Sniper, die den Zap UMGEHEN (direkt am Pool),
  koennen weiterhin ueber 1% -> war der Zap-only-Cap. JETZT GESCHLOSSEN:
- HARTER Cap in WRacks._update: jeder wRACKS-Transfer > 1% (in RACKS-Wert) revertet WAEHREND
  des Launch-Fensters -> blockt auch Direkt-zu-Pool-Sniper (LaunchRealistic.t.sol: $500-Direktkauf
  grabbte 9.06% der Supply UNGEKAPPT -> jetzt REVERT). Zap-Kaeufer bleiben unter dem Cap -> glatt.
  DEPLOY-PFLICHT: PoolManager, der wRACKS/SPY-Pool, der V4Swap und der Zap MUESSEN cap-exempt sein
  (setCapExempt), sonst revertet die Liquiditaetsbereitstellung / das Routing. Owner ist auto-exempt.
  Sybil (viele Wallets) bleibt eine bekannte Grenze; der Cap ist pro Wallet.
- V4Swap (unlock->swap->settle->take, exakt-settle + Refund bei Teil-Fill)
- V4Pool (initialize + addLiquidity), Zap (1-Klick USDG<->RACKS), TwapOracleV4 (Spot/TWAP + Impact)
- WRacks: Tax auf Wrap (Sell) / Unwrap (Buy), dynamisch ueber TwapOracleV4, 8%-Cap
- 16 Fork-Tests gegen RH-Mainnet gruen (`forge test --match-path "test/v4/*.t.sol" --fork-url <mainnet-rpc>`)

### Stresstest-Ergebnisse (Fork, echter SPY-Markt)
- Round-Trip Swap: -0.58% (nur Fees+Slippage) -> kein Gratisgeld
- 100 Zufalls-Swaps: SPY und wRACKS exakt erhalten (Fees bleiben im Pool)
- 50%- und 5x-Reserve-Dumps: fuellen sauber, kein Token bleibt im Swapper haengen
- Slippage-Revert laesst Guthaben unangetastet; Dust (1 wei) revertet sauber
- Zap Round-Trip: 5000 USDG -> 6.15 RACKS -> 4534 USDG (Tax beide Beine, Zap haelt nichts)
- Orakel: Spot -75% in einem Block, TWAP 0 bps -> manipulationsfest; folgt anhaltenden Moves
- Melt 7 Tage: racksPerShare 1.00 -> 0.606, wRACKS-Menge im Pool konstant (Wrapper-Design bewiesen)
- Erster Dumper zahlt Impact (10% der Reserve -> 8%-Cap)

### 2-Wochen-Simulation (Fork, test/v4/Simulation2W.t.sol) — bestanden
- 10 Wallets, 100 Agenten, 42 Epochen (14 Tage), ~$1.09M Volumen via Zap durch beide echten Pools
- Raritaet n=100: 76 / 20 / 4 (Soll 75 / 20 / 5). Formel exakt per Grenzwert-Test bewiesen
  (Woerter 74/75/94/95 -> Tier 0/1/1/2; Treffer bei rate-1, Fehlschlag bei rate).
- Trefferquoten (4.168 Angriffe): T0 30.34% / T1 49.28% / T2 75.59% (Soll 30/50/75)
- Pot-Oekonomie reconciled: ~215k RACKS Bleed (1d/3d-Locks) -> 212.985 an Gewinner ausgezahlt
  -> Pot leer -> exakt 40.000 aus 4%-Verspaetungsstrafe (Wallet 8, 2 Tage spaet) wieder drin.
- 14d-Lock ohne Bleed: 1M -> 999.999,99 (1 wei Rundung); unbefuetterter Agent stirbt nach 3d,
  Angriff revertet "dead"; Vault bleibt solvent; Melt reduziert Supply.
- Tax: 3.75M RACKS auf $1.09M Volumen.
- Hinweis: der Pot lebt von KONTINUIERLICHEM Kurz-Lock-Bleed. In der Sim liefen alle Locks an Tag 0
  aus -> Pot ab Tag ~10 leer. Ohne stetige 1d/3d-Locker haben Agenten nichts zu raiden (Design-Abhaengigkeit).
- foundry.toml: gas_limit auf u64-max gesetzt (Sim braucht ~1.2B Gas; Foundry-Default 2^30 reichte nicht).

### Hardening-Fixes aus Review + Stresstest
1. V4Swap settlete blind `amountIn` -> jetzt exakt das geschuldete Delta, Rest wird refunded.
2. WRacks.wrap rechnete `amount - tax` statt Ist-Delta -> jetzt rounding-sicher (Rebasing!).
3. TwapOracleV4 hatte den Impact-Term verloren (erster Dumper zahlte Basis) -> wieder drin
   (virtuelle Reserve aus aktiver Liquiditaet).
4. **REGEL: der wRACKS-Wrapper darf NIE melt-exempt sein** (waere eine Demurrage-Fluchttuer).
   Nur tax-exempt. Guard in beiden Deploy-Skripten: `require(!racks.isExempt(wracks))`.

## Naechste Phase (Integration + Launch-Vorbereitung)
1. Testnet-SPY-Adresse klaeren (oder Mock-SPY fuer Tests).
2. wRACKS/SPY-Pool auf RHs v4 (PoolManager direkt, wie rhcswap zeigt).
3. Tax von Fee-on-Trade (v2/isDex) auf die **Wrap/Unwrap-Ebene** umziehen.
4. TWAP/Orakel auf den v4-Pool umstellen, **inkl. uiMultiplier**.
5. **Zap-Contract** (USDG/ETH -> ... -> RACKS in einem Klick).
6. Pruefen, ob diskrete Epochen / sync / wKARROT-Backup mit wRACKS noch noetig sind
   (wahrscheinlich vereinfachbar, da kein Pool-Melt mehr).

## Vor Mainnet (unabhaengig)
- Externes Audit (Gambling-Layer + wertpapiernaher SPY-Bezug + echtes Geld).
- Rechtliche Pruefung (SPY = restringiertes Wertpapier; Gambling-Klassifizierung der Agents).
- Reihenfolge am Launch-Tag: deploy -> Liquiditaet -> enableTrading() -> renounceMint() (zuletzt).
