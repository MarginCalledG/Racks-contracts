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
Tax laeuft wieder im Token (isDex): Kauf und Verkauf besteuert, Wallet-zu-Wallet frei, dynamisch
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
5. LP an LP_DESTINATION (0x...dEaD = burn), `setTaxExempt(deployer,false)`, `transferOwnership(multisig)`
Env: PRIVATE_KEY, VRF_COORDINATOR, RESERVE, TAX_WALLET, MULTISIG, LP_DESTINATION
Selbstchecks am Ende: Pair melt-exempt, setPair gesetzt, isDex, capExempt, Tax-Wallet melt-exempt,
Orakel verdrahtet, Mint renounced, Trading an, maxWallet > 0.
Fork-Test test/v4/DeployScript.t.sol fuehrt das echte Skript aus und handelt danach: Kauf in der
Launch-Stunde OK, zweiter Kauf ueber dem Cap revertet, Kauf+Verkauf ueber einen Melt-Epochenwechsel
ohne Keeper OK.
NACH dem Launch: `transferOwnership(multisig)` + `acceptOwnership()`, dann `renounceExemptControl()`.

## OFFEN
1. Repo: v4-Schicht ist ENTFERNT (Clean-Clone-Build gruen). Auf GitHub per git rm nachziehen —
   'Add files via upload' loescht nichts.
3. VRF: Chainlink VRF laeuft NICHT auf RH (nur Data Feeds/Streams/CCIP). IRSAgent startet deshalb
   `paused = true`; `setPaused(false)` verlangt einen VRF mit Code. Empfehlung: EIN Zufalls-Seed pro
   Epoche via CCIP-Relay von Arbitrum One; Treffer = hash(seed, agentId). Beseitigt zugleich die
   ganze Klasse der VRF-Timing-Exploits. Entscheidung offen — bis dahin bleibt das Casino aus.
6. Pot-Seed ist NOETIG, nicht optional, wenn am ersten Tag geraidet werden soll. Der Pot speist sich
   ausschliesslich aus den drei Lock-Bleeds: Pot_in = 0,3*r_w*V1d + 0,2*r_w*V3d + 0,1*r_w*V14d.
   Unlocked-Melt und Pool-Melt werden GEBRANNT und tragen nichts bei (kein W-Term). Ohne Locker ist
   der Pot null. Optionen: (a) Supply-Reserve zurueckhalten und `fundPot` am Launch, (b) den W-Term
   nachruesten (ein Teil des Unlocked-Melts in den Pot statt in den Burn) — Owner-Entscheidung.
7. renounceExemptControl ist IRREVERSIBEL — danach sind auch noetige Exemptions (neue Vault-Version,
   neue Tax-Wallet) unmoeglich. Bewusst erst nach dem Launch und nach Abwaegung aufrufen.
4. Externes Audit vor Mainnet.
5. Frontend-Konstanten an die Contracts angleichen (siehe AUDIT.md).
