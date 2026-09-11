# RACKS — Status

## MELT-FAKTOREN (ein Ratengesetz, fuenf Positionstypen)
Jede Position schmilzt mit `r_w * Faktor`. r_w ist die freefloat-gekoppelte, 24h-geglaettete Basisrate
(4,2 %/d bei FF=0 ... 6,9 %/d bei FF=1). Die Faktoren sind als exakte Per-Sekunden-Konstanten fuer
BEIDE Bandenden hinterlegt und mit demselben FF-Signal interpoliert — jeder Typ folgt r_w also
proportional, an jedem Punkt des Bandes.

| Position   | Faktor | bei 4,2 % | bei 6,9 % | Ziel des Melts        | Bindung          |
|------------|--------|-----------|-----------|-----------------------|------------------|
| Unlocked   | 1,0    | 4,20 %/d  | 6,90 %/d  | Burn (Supply sinkt)   | keine            |
| LP (Pair)  | 0,5    | 2,10 %/d  | 3,45 %/d  | Burn, via meltPool    | Tax rein/raus+IL |
| Lock 1d    | 0,3    | 1,26 %/d  | 2,07 %/d  | **Agent-Pot**         | 1 Tag, $3        |
| Lock 3d    | 0,2    | 0,84 %/d  | 1,38 %/d  | **Agent-Pot**         | 3 Tage, $5       |
| Lock 14d   | 0,1    | 0,42 %/d  | 0,69 %/d  | **Agent-Pot**         | 14 Tage, $10     |

API: `perSecFactorFor(pos)` und `ratePerDayBpsFor(pos)` mit
P_UNLOCKED=0, P_LP=1, P_LOCK_1D=2, P_LOCK_3D=3, P_LOCK_14D=4.
Aenderungen ggue. dem alten Modell:
- Die Lock-Bleeds sind nicht mehr fix (2,0 / 1,5 / 0 %/d), sondern an r_w gekoppelt.
- **Die 14d-Stufe ist nicht mehr melt-frei** (0,1x statt 0) — und speist damit erstmals auch den Pot.
  Damit haengt das Casino nicht mehr allein an Kurz-Lockern (loest die Pot-Starvation aus der 2-Wochen-Sim).
- **Das Pair schmilzt mit 0,5x** statt voll; `meltPool` rechnet zeitbasiert ab pairLastMelt.
  Der SELF-Call aus _preOp feuert nur beim Epochenwechsel (Gaskosten); extern ist meltPool
  permissionless und meltet ab der ersten Sekunde. Die Balance ist innerhalb einer Epoche also NICHT
  konstant — das ist unschaedlich, weil Melt und Sync atomar sind (kein K-Revert moeglich) und der
  Gesamtmelt unabhaengig von der Aufrufhaeufigkeit ist. Die Atomaritaet ist die tragende Eigenschaft,
  nicht die Epochen-Diskretisierung.
- Abgelaufene Locks schmelzen unveraendert mit Faktor 1,0 und werden GEBRANNT (nicht in den Pot).
Reihenfolge bleibt garantiert: 14d < 3d < 1d < LP < unlocked (Test testLockingBeatsHolding).

## AUTOMATISCHE TAX-UMWANDLUNG (RACKS -> SPY -> Reserve)
Die Tax faellt auf dem Token selbst an und wird ueber `swapTax()` in SPY getauscht und an `reserve`
geschickt. Permissionless mit Bounty; ein Cron als Fallback ist Teil des Runbooks.

EINZIGER PFAD: `swapTax()` ist permissionless und zahlt 0.25% Bounty — NUR bei Erfolg. Bots (oder
ein Cron als Fallback) wandeln damit in eigenen Transaktionen um; nichts landet je vor der Order
eines Verkaeufers. Es gibt keine In-Transfer-Konvertierung mehr (kostete ~140k Gas pro Sell und
stellte das Protokoll vor seine eigenen Verkaeufer).
Schutzmechanismen:
- `maxSwapBps` (0.1% der Pair-Reserve pro Umwandlung, Obergrenze 0.5%) deckelt den Preis-Impact.
- Die Tax-Rate wird VOR jeder Umwandlung bestimmt — kein Verkaeufer zahlt auf unsere eigene Dislokation.
- `minOut` = MAXIMUM aus Live-Quote und TWAP-Bewertung. Die schuetzende Seite ist die hoehere:
  ein gedrueckter Spot wird nicht bedient. Folge: bei einem echten scharfen Rutsch pausiert die
  Umwandlung, bis der TWAP nachzieht; Verkaeufe laufen unbeeintraechtigt weiter.
- `router`, `spy` und `reserve` sind nach der ersten Konfiguration unveraenderlich.
- `swapSlippageBps` (3%) gegen getAmountsOut; scheitert der Swap, faengt try/catch ihn ab —
  **ein Nutzer-Verkauf darf daran nie scheitern** (Fork-Test deckt das ab).
- Eigener Reentrancy-Guard: waehrend der Umwandlung darf ausschliesslich `swapRouter` zurueckrufen
  (`inSwap && msg.sender == swapRouter`), jeder andere Pfad bleibt blockiert.
- Die wartende Tax ist melt-exempt und tax-exempt (sie schrumpft nicht und besteuert sich nicht selbst).
Konfiguration: `enableAutoSwap(router, spy, reserve, threshold)`, `setSwapParams(threshold, maxBps, slipBps)`,
`setAutoSwap(bool)`. Der frühere TaxSwapper-Contract ist ersatzlos entfernt.

## ARCHITEKTUR-ENTSCHEIDUNG: Uniswap v2 (kein Wrapper, kein Hook)
Auf RH-Mainnet gegen die ECHTE Uniswap v2 verifiziert (Factory 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f,
Router02 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba).

Warum nicht v3/v4: beide leiten Reserven aus L und Preis ab und haben kein sync(). Fork-Beweis (in Runde 6 gefahren, Test seither
mit der v4-Schicht entfernt; Ergebnis in AUDIT.md dokumentiert): nach 7 Tagen Melt haelt der PoolManager 1.818 statt 3.000 RACKS,
der Pool rechnet weiter mit 3.000 -> Melt kommt NICHT im Preis an und removeLiquidity revertet
(insolvent). v3 zusaetzlich ohne Fee-on-Transfer-Router und ohne Hooks.

### Pool-Melt: atomar (src/Racks.sol)
Das Pair ist melt-EXEMPT (nominale Balance, kein lazy Melt). Sein Melt wird explizit angewendet und
im selben Call mit pair.sync() verheiratet -> Reserven und Balance laufen NIE auseinander, ein Swap
kann kein "UniswapV2: K" sehen.
- `setPair(p)` — verlangt, dass p bereits melt-exempt ist; setzt isDex + capExempt + pairIndex.
- `meltPool()` — permissionless, wendet Melt an und synct atomar. Bounty MELT_BOUNTY_BPS = 25 (0.25%
  des Pool-Melts) an externe Caller; MEV-Bots erledigen den Job damit von selbst.
- `_preOp()` ruft `try this.meltPool() catch {}` immer wenn der Pool nachhinkt (selbstheilend, nicht
  nur bei Epochenwechsel). BEWUSST kein nonReentrant auf meltPool: der externe Self-Call rollt bei
  gelocktem Pair (mitten im Swap) alles zurueck, statt Melt ohne Sync stehenzulassen.
- Reihenfolge ist kritisch: _preOp laeuft VOR jedem _credit in _move. Beim Sell schiebt der Router
  RACKS ins Pair und ruft dann swap; der Sync sieht die eingehenden Token also noch nicht —
  sonst rechnete der Router amountIn == 0.

Fork-Beweise (test/v4/V2AtomicMelt.t.sol, test/v4/V2MeltAdversarial.t.sol):
- 12 Epochenwechsel OHNE Keeper/Cron: jeder Buy und jeder Sell geht durch, kein einziger Revert.
- Sell als erste TX nach einem Epochenwechsel: funktioniert.
- Reserven == Pair-Balance nach jeder Epoche.
- Melt im Preis: 995.015 -> 603.222 RACKS pro SPY nach 7 Tagen.
- Bounty nicht farmbar (100 Wiederholungen zahlen 0), Pool-Melt folgt exakt dem Index,
  LP kommt immer raus, Round-Trip um den Melt herum verliert Geld, Pool-Melt verkleinert die Supply.

### Was dadurch entfaellt
WRacks (Wrapper), TaxHook (v4), Zap, V4Swap, V4Pool, TwapOracleV4, Hook-Mining, wiringOk —
und mit ihnen die Angriffsflaechen Share-Inflation, Wrapper-Cap-Meldung und Hook-Deploy-Falle.
Tax laeuft im Token (isDex): Kauf und Verkauf besteuert, Wallet-zu-Wallet frei, dynamisch
ueber TwapOracle (jetzt auf dem echten v2-Pair-Interface: getReserves/token0).
Ohne Orakel greift BASE_TAX_BPS = 400 statt 0 (eine fehlende Quelle darf die Tax nie abschalten).
USDG-Weg existiert auf v2: USDG->SPY->RACKS in einer TX ueber den Standard-Router, kein Zap noetig.

### Deploy (script/Deploy.s.sol — v2, gegen RH-Fork getestet)
Reihenfolge ist zwingend und wird per require geprueft. Jeder Schritt ist unter --broadcast eine
eigene TX in einem eigenen Block — deshalb muss JEDES Zwischenfenster gate-geschuetzt sein:
1. Token/Vault/Agents + Wiring, mint, renounceMint
2. Pair anlegen, `setExempt(pair)`, dann SOFORT `setPair(pair)` + TwapOracle — VOR jeder Liquiditaet
   (sonst existiert ein Block, in dem der Pool handelbar, aber ungegatet und steuerfrei ist)
3. Liquiditaet seeden (Gate zu; nur der tax-exempte Deployer kommt durch)
4. `enableTrading()` -> Launch-Stunde startet
5. LP an LP_DESTINATION (0x...dEaD = burn), `setTaxExempt(deployer,false)`, dann Ownership-Uebergabe
   ALLER VIER Contracts an die Multisig: racks, vault, agents, oracle (2-Step, per require geprueft).
   **Die Multisig muss auf allen vieren `acceptOwnership()` rufen** — bis dahin kontrolliert sie der
   Deployer. Der Vault haelt die Einlagen der Locker und den Pot; ihn beim Deployer zu lassen waere
   ein Single-Key-Risiko, unabhaengig davon wie gut der Token gehaertet ist.
   **Der Agent-Zeiger im Vault ist FINAL.** `setAgent` geht genau einmal (beim Deploy), danach nie
   wieder — es gibt keinen proposeAgent/executeAgent mehr. Damit existiert KEIN Schluessel, der den
   Pot umleiten koennte, und unbeanspruchte Gewinne koennen nicht durch eine Migration verfallen.
   Kein Upgrade-Pfad, bewusst.
   Austauschbar ist nur die ZUFALLSQUELLE, und zwar im Agenten selbst: `proposeVrf` -> 7 Tage ->
   `executeVrf`, danach `renounceVrfControl()` als Einbahnstrasse. Machtvergleich: ein Agententausch
   haette den Pot in einem Call bewegt; eine manipulierte Zufallsquelle kann nur beeinflussen, WER
   gewinnt — Epoche fuer Epoche, durch die pari-mutuel-Aufteilung gedeckelt und on-chain sichtbar.
Env: PRIVATE_KEY, VRF_COORDINATOR, RESERVE, TAX_WALLET, MULTISIG, LP_DESTINATION
Selbstchecks am Ende: Pair melt-exempt, setPair gesetzt, isDex, capExempt, Tax-Wallet melt-exempt,
Orakel verdrahtet, Mint renounced, Trading an, maxWallet > 0.
Fork-Test test/v4/DeployScript.t.sol fuehrt das echte Skript aus und handelt danach: Kauf in der
Launch-Stunde OK, zweiter Kauf ueber dem Cap revertet, Kauf+Verkauf ueber einen Melt-Epochenwechsel
ohne Keeper OK.
NACH dem Launch: `transferOwnership(multisig)` + `acceptOwnership()`, dann `renounceExemptControl()`.

## ZUFALLSQUELLE (src/HashChainSeed.sol + keeper/) — reveal-then-play
Ein Seed pro Epoche aus ZWEI Komponenten, zwei Parteien, keine steuert allein:
- Der vorab committete Kettenwert des Keepers, enthuellt am EPOCHENANFANG. Ab dann oeffentlich —
  fuer niemanden ein Vorteil, denn er entscheidet allein nichts.
- Ein Blockhash NACH Epochenschluss, in ZWEI Schritten erfasst (C1): die erste Transaktion nach dem
  Ende fixiert eine ZUKUENFTIGE Blocknummer (Hash existiert noch nicht — wer wann anfasst, gewinnt
  nichts); eine spaetere Transaktion innerhalb von 256 Bloecken friert diesen Hash ein (kann ihn nur
  festhalten, nicht waehlen). Verfaellt das Fenster, wird erneut eine Zukunftsnummer gesetzt.
  Der Keeper-Bot tickt alle 15 s, damit das Einfrieren sicher innerhalb der ~64 s passiert.
seed(e) = keccak(preimage_e, closeHash_e). Der Keeper kennt ein Ergebnis NIE vor Epochenschluss.
Es gibt keinen Angreifer-Input im Seed mehr (der fruehere attackDigest war ein Grinding-Eingang fuer
den Keeper — K1, kritisch, behoben).
Enthuellen ist NUR bis zum Epochenende erlaubt (C6) — der Keeper sieht den Post-Close-Hash nie zuerst.
Verbleibende Keeper-Macht: innerhalb der Epoche spaet enthuellen oder gar nicht. Preis:
1. Keine Enthuellung bis Epochenende = Epoche FAILED, jeder verliert, auch der Keeper.
2. Slash = max(slashPerMiss, aktueller Pot) aus der Kaution in den Pot — Zurueckhalten kostet
   mindestens das, was auf dem Spiel stand. `attack()` verweigert, solange die Kaution den Pot
   nicht deckt (bondOk).
3. Mints, deren Epoche nie einen Seed bekommt (Keeper weg): `reclaimUnrevealed` nach 7 Tagen
   erstattet die 99 USDG aus der Reserve (Allowance noetig, `refundsReady()`).
Restvertrauen, dokumentiert: der Post-Close-Blockhash stammt vom RH-Sequencer, der nichts zu
gewinnen hat. Wer auch das nicht will: CCIP-Relay ueber proposeVrf. chain.json ist ein pot-wertiges
Geheimnis und wird wie der Keeper-Key behandelt.
Griefing, dokumentiert (C7): jeder kann per `fundPot` den Pot ueber die Kaution heben und damit
Angriffe sperren, bis der Keeper nachschiesst — auf eigene Kosten, das Geld bleibt im Pot.
Rollen: Multisig setzt/ersetzt den Keeper; Keeper committed, hinterlegt Kaution, enthuellt am Start;
jeder darf captureClose, tally, settle, slash.

## VERTRAUENSANNAHMEN GEGENUEBER DER MULTISIG (gehoert woertlich in den Launch-Text)
Auch nach renounceExemptControl und Ownership-Uebergabe verbleiben beim Owner:
- `setTaxExempt` — steuerfreies Trading fuer Einzeladressen
- `setDex(pair, false)` — Tax global aus
- `setLockedSupply` — Rate innerhalb des Bands verschieben (Vault ueberschreibt bei naechster Operation)
- `setSwapParams` — Konvertierungs-Deckel (max. 0.5% der Reserve) und Slippage
- `setPaused(false)` auf IRSAgent — mit jeder Adresse, die Code hat (ein permissionless Mock waere
  katastrophal; Multisig-Disziplin)
- `proposeVrf` (7 Tage) bis `renounceVrfControl`
- `enableAutoSwap` bis zum Renounce (Ziele danach fix)
- Tax-Wallet ist melt-exempt und Owner-kontrolliert

## PRE-LAUNCH-CHECKLISTE
- [x] Alle Code-Findings der 17 Audit-Runden gefixt und verifiziert (Abschlussbericht 10.09.2026)
- [ ] Push auf GitHub mit `git rm` fuer geloeschte Dateien; Clean-Clone-Build als Pflicht vor jedem Push
- [ ] W-Term und Pot-Seed schriftlich entscheiden; Seed-Betrag ins Deploy-Skript
- [ ] Multisig-Runbook: `acceptOwnership()` x5 innerhalb von Minuten nach dem Skript;
      `renounceExemptControl()` erst nach Abwaegung (irreversibel)
- [ ] Cron fuer `meltPool()` (alle 30 min) und `swapTax()` als Fallback — Self-Heal und Bounty tragen,
      aber nachts handelt niemand
- [ ] Keeper: Kette generieren, committen, Kaution hinterlegen; HashChainSeed separat auditieren;
      erst dann IRSAgent.setPaused(false)
- [ ] Bot-Kompatibilitaet live auf Testnet gegen GoPlus / honeypot.is: Sell-Simulation muss zu jeder
      Sekunde gruen sein
- [ ] Externes Audit mit AUDIT.md als Startpunkt; Scope src/ + script/

## OFFEN
1. Repo: v4-Schicht ist ENTFERNT (Clean-Clone-Build gruen). Auf GitHub per git rm nachziehen —
   'Add files via upload' loescht nichts.
3. ZUFALL: GELOEST durch src/HashChainSeed.sol (ein Seed pro Epoche aus einer vorab festgelegten
   Hash-Kette) — siehe Abschnitt ZUFALLSQUELLE. Das Casino bleibt pausiert, bis der Keeper eine Kette
   committed und die Kaution hinterlegt hat und die Quelle separat auditiert ist.
6. Pot-Seed ist NOETIG, nicht optional, wenn am ersten Tag geraidet werden soll. Der Pot speist sich
   ausschliesslich aus den drei Lock-Bleeds: Pot_in = 0,3*r_w*V1d + 0,2*r_w*V3d + 0,1*r_w*V14d.
   Unlocked-Melt und Pool-Melt werden GEBRANNT und tragen nichts bei (kein W-Term). Ohne Locker ist
   der Pot null. Optionen: (a) Supply-Reserve zurueckhalten und `fundPot` am Launch, (b) den W-Term
   nachruesten (ein Teil des Unlocked-Melts in den Pot statt in den Burn) — Owner-Entscheidung.
7. USDG (Paxos) hat eine Freeze-Liste: `reserve` darf keine einfrierbare Adresse sein, sonst reverten
   lock, mint und feed. `setReserve` ist der Ausweg — Adresse bewusst waehlen.
8. renounceExemptControl ist IRREVERSIBEL — danach sind auch noetige Exemptions (neue Vault-Version,
   neue Tax-Wallet) unmoeglich. Bewusst erst nach dem Launch und nach Abwaegung aufrufen.
4. Externes Audit vor Mainnet.
5. Frontend-Konstanten an die Contracts angleichen (siehe AUDIT.md).
