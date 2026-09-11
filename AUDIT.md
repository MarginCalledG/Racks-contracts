# RACKS — Interner Security-Audit (Adversarial Review)

Vorgehen: alle Contracts vollstaendig gelesen; jede Angriffsklasse durchgegangen (Reentrancy, Access
Control, Arithmetik/Rundung, Oracle-Manipulation, First-Depositor, Flash-Loan, Griefing/DoS, oekonomische
Exploits); fuer echte Funde ein Proof-of-Concept-Test (test/Audit.t.sol) — erst Exploit bewiesen, dann
gefixt, dann Regressionstest der beweist dass er blockiert ist.

## KRITISCH (gefixt)
**W1 — First-Depositor / Share-Inflation im wRACKS-Wrapper.**
PoC: Angreifer wrappt 1 wei (1 Share), spendet 1M RACKS direkt an den Wrapper, Opfer wrappt 500k RACKS
und erhaelt 0 Shares; Angreifer wickelt seinen 1 Share aus und geht mit 2.5M statt 2.0M RACKS —
die kompletten 500k des Opfers gestohlen. Relevanz: jeder, der VOR dem Seed-Wrap 1 wei wrappt.
Fix: Uniswap-V2-Muster — beim ersten Wrap werden 1000 tote Shares an DEAD_SHARES geprägt
(MINIMUM_LIQUIDITY), `require(shares > 0)`. Regressionstest: Angriff verliert jetzt Geld, Opfer
behaelt ~100% seiner Einlage.

## MITTEL (gefixt)
- **R2 — Racks._move klemmte Transfers ueber dem Guthaben still auf das Guthaben** statt zu reverten.
  Verletzt ERC20-Semantik; jeder Integrator (Lending, DEX), der `transferFrom(X)` aufruft und X oder
  Revert erwartet, wird ueberrascht. Fix: `require(amount <= bal)`; die Klemme deckt nur noch die
  Exakt-Guthaben-Rundung. Nebeneffekt: hat einen echten Rundungs-Footgun in unserem eigenen Zap
  aufgedeckt (uebertrug nominal statt Ist-Bestand) -> Zap bewegt jetzt Ist-Bestaende.
- **W5 — Ein revertierendes/boesartiges Tax-Orakel bricked wrap/unwrap dauerhaft** (Owner-Rug-Vektor:
  Orakel auf revert setzen -> Funds im Wrapper gefangen). Fix: try/catch, Fallback auf flache Rate.
- **A5 — Nicht abgeholte Preise sperren den Pot fuer immer** (allocatedPot wird nie freigegeben).
  Fix: per-Epoche-Tracking + permissionless `sweepStale(e)` nach CLAIM_WINDOW (90 Epochen ~30d).
- **Zap/V4Swap — Rueckerstattung ging an `to` statt an den Zahler.** Wer fuer eine andere Adresse
  kauft, verlor die Rueckerstattung an sie. Fix: Refund an msg.sender / payer.

## NIEDRIG (gefixt)
- **R5** — `enableTrading()` bei Supply 0 setzte maxWallet=0 -> 1h lang jeder Kauf blockiert. Fix: require.
- **A2** — Unbekannte/wiederholte VRF-Request-ID lief in den Attack-Zweig fuer Agent 0 und korrumpierte
  Epoche-0-Shares (Pot dauerhaft an unclaimbaren Agent 0 alloziert). Fix: `require(q.kind != 0)`.
- **R7/W8** — Kein Reentrancy-Guard auf Racks.transfer/transferFrom (externer Orakel-Call in `_move`)
  und WRacks.wrap/unwrap. Fix: nonReentrant.
- **W10** — Kein Ownership-Transfer -> Admin-Rechte konnten nie an ein Multisig uebergeben werden.
  Fix: 2-step transferOwnership/acceptOwnership in Racks und WRacks.
- **Dead-Share-Senke** — `address(0xdead)` kollidierte mit Adressen aus Tests (0xDEAD == 0xdead).
  Jetzt dedizierte Konstante DEAD_SHARES. (Der Cap-Exempt der Senke ist harmlos: Burn-Adresse.)

## DESIGN-BEOBACHTUNGEN (bewusst NICHT gefixt — Entscheidung des Owners)
- **C1 — (ERLEDIGT durch Vault-Umbau)** Strafe entfaellt; abgelaufene Positionen melten normal.
- **C10 — (ERLEDIGT)** lockedSupply = Vault-Balance minus Pot; nur Nutzer-Locks zaehlen.
- **Pot-Abhaengigkeit** — der Pot lebt nur von kontinuierlichem 1d/3d-Bleed. Ohne stetige Kurz-Locker
  ist das Casino leer (2-Wochen-Sim: Pot ab Tag ~10 trocken).
- **A9 — MAX_PER_WALLET ist per Wallet-Wechsel umgehbar** (Sybil); nur CAP=10.000 bindet hart.
- **Launch-Cap-Sybil** — 1%/Wallet, 50 Wallets = 50%. Kein Wallet-Cap loest das.
- **Lock erneuert unlockAt fuer die GANZE Position** — wer zu einer Position dazulockt, verlaengert alles.
- **Owner-Macht (Vertrauensannahme)**: setExempt (koennte Pool melt-exempt machen), setLockedSupply
  (Melt-Rate in der 4.2–6.9%-Band verschieben), setCapExempt (Sniper waehrend Launch freischalten),
  setTaxOracle (Rate bis 8%-Cap). Tax-Hoehe selbst ist immutable gedeckelt. -> Admin an Multisig.
- **Infrastruktur-Abhaengigkeiten**: VRF-Ausfall verliert Angriffs-Cooldowns (attack setzt Cooldown
  vor Fulfill); VRF-Subscription muss finanziert sein.
- **TaxSwapper ist v2-only** (Uniswap-V2-Router). Im v4-Modell sammelt sich die Tax als RACKS in der
  Tax-Wallet und wird NICHT automatisch in SPY gewandelt -> v4-Swapper fehlt noch (funktionale Luecke).

## Runde 2 — nach dem Vault-Umbau (test/AuditVault.t.sol, test/v4/Stress10M.t.sol)
Gezielt angegriffen: permissionless `harvest` (Griefing/Doppel-Melt), `_settle`-Solvenz ueber 200
zufaellige Ops (lock/unlock/relock/harvest/drawPot/poke), Burn-Buchhaltung, Relock nach Ablauf,
Hinzufuegen zu Position. Ergebnis: keine Exploits.
- **Harvest-Spam** (72 Harvests/3 Tage) aendert das Ergebnis des Owners um ~0.12% — KEIN Diebstahl,
  sondern legitimer Feedback: Pot zaehlt nicht als lockedSupply -> Free Float minimal hoeher -> globale
  Melt-Rate rueckt Richtung 6.9%. Gedeckelt durch Band + 24h-Glaettung. Beobachtung, kein Bug.
- Abgelaufene Positionen fuettern den Pot nie (30 Tage getestet); Melt wird exakt gebrannt
  (Supply-Delta == Melt); Relock nach Ablauf wendet Melt zuerst an (kein Dodge).
- Solvenz-Identitaet `vault == sum(claims) + pot` haelt ueber 200 Zufalls-Ops.
- **$18.16M Volumen-Stress** (Fork): 40 Launch-Stunden-Kaeufe gegen den Cap ohne Revert, 400er
  Churn, $2M-Einzeltrade, $1.5M Einweg-Druck je Richtung: Tax stets in [400, 800] bps, Pool danach
  funktional, nichts in Zap/Swapper gestrandet, SPY im System erhalten.
- Bekannte OPERATIVE Abhaengigkeit (kein Bug): der Pot waechst nur bei Abrechnung. Vor `settle(e)`
  der Agenten sollte ein Keeper aktive Kurz-Positionen harvesten, sonst ist der Epochen-Preis 0.

## Runde 3 — Exploit-Muster aus der Praxis (test/ExploitsFromTheWild.t.sol)
Recherchierte Angriffsklassen (Balancer Nov-2025 Rundungs-Exploit im exact-out-Pfad; Lotterie-
Settlement-Timing und Rollback-/Prediction-Angriffe aus den arXiv-Taxonomien; ERC4626-Rest-
Inflation) gegen unsere Contracts angewandt. ZWEI ECHTE LUECKEN gefunden, per PoC bewiesen, gefixt:

**E1 — KRITISCH: Phantom-Share-Diebstahl ueber verspaetete VRF-Antwort.** Angreifer greift in der
letzten Sekunde der Epoche an, settlet sofort nach Epochenende (vor seiner VRF-Antwort); die
verspaetete Antwort schrieb 144 Shares in die bereits abgeschlossene Epoche -> Angreifer kassierte
den GESAMTEN allozierten Pot beider Epochen (66.892 RACKS), ehrlicher Gewinner bekam 0.
Fix: (a) `pendingAttacks[e]` — settle ist erst moeglich, wenn alle VRF-Ergebnisse der Epoche da sind
ODER `SETTLE_GRACE` (10 min) verstrichen ist (haengende VRF kann settle nicht ewig blockieren);
(b) ein Ergebnis, das NACH dem Settle landet, praegt keine Shares mehr.
**E2 — Sofort-Settle-Griefing:** jeder konnte eine Epoche im Moment ihres Endes settlen -> Preis 0.
Fix: derselbe Pending-/Grace-Gate.
**E4 — Harvest-Aushungerung:** 30 Dust-Locks (1 wei, je $3) belegten die 25 Auto-Harvest-Plaetze
-> echter Bleed nie gebucht -> Epochen-Preis 0. Fix: rotierender `harvestCursor` (jede Position
wird ueber aufeinanderfolgende Settles gebucht) + `MIN_LOCK` = 1 RACKS.
**E3 — Balancer-Klasse (Rundungs-Extraktion):** 300 krumm dosierte Wrap/Unwrap-Round-Trips im
duennen Wrapper -> Angreifer endet nie reicher. Nicht verwundbar (Ist-Delta-Messung + floor).
**E6 — ERC4626-Rest-Inflation nach toten Shares:** MINIMUM_LIQUIDITY von 1e3 auf 1e6 erhoeht ->
eine 1M-RACKS-Spende blockiert nur noch Wraps < 1 RACKS (vorher < 1000), Opfer verlieren nie
(Revert statt 0 Shares), Angreifer verbrennt ~seine ganze Spende. Unwirtschaftlich.
Rollback-/Prediction-Angriffe auf den Zufall: strukturell ausgeschlossen (Ergebnis kommt in einer
separaten VRF-Fulfill-TX, im Angriff-TX ist es unbekannt -> nichts zum Zurueckrollen).

## Runde 4 — Antwort auf das EXTERNE Audit (test/ExternalAudit.t.sol)
Jeder Diebstahl-Fund per PoC VERIFIZIERT (nicht geglaubt), dann gefixt, dann Regressionstest.

**F1 (kritisch) — Settle in falscher Reihenfolge stahl den Pot der Vorepoche.** PoC: Alice (einzige
Gewinnerin e0) bekam 0, Bob (e1) nahm 66.890 RACKS. BESTAETIGT. Fix: strikt sequenzielles Settle;
leere Vorgaenger-Epochen (keine Shares, nichts pendend) settlen automatisch mit, Epochen mit
Gewinnern muessen zuerst explizit gesettlet werden (`settledThrough`).
**F2 (kritisch) — Claim nach sweepStale war ein Double-Spend** (mein eigener A5-Fix hatte die Luecke
geoeffnet). PoC: Alice claimte 33.558 aus einer geswepten Epoche, Bob bekam 66.442 statt 100.000.
BESTAETIGT. Fix: Auszahlung wird auf `epochUnclaimed[e]` gedeckelt (nach Sweep 0) + require > 0.
**F3 (hoch) — Launch-Cap war ein Balance-Snapshot.** PoC: kaufen -> unwrappen -> kaufen: 500.000 RACKS
in EINEM Wallet bei 110.000 Cap (4.5x). BESTAETIGT. Fix: kumulatives `launchReceived`-Ledger in RACKS
(steigt nie), gespeist von Router->Wallet-Lieferungen (Zap) UND Pool->Wallet-Lieferungen (der Wrapper
meldet sie per `recordLaunchReceipt`). Peer-Transfers bleiben bewusst uncapped (Owner-Entscheidung);
Token wegzuschieben senkt den Erwerbs-Zaehler nie -> Schleife geschlossen. Fork-Test: zweiter Kauf
desselben Wallets liefert nur noch den 0.5%-Haircut-Rest.
  DEPLOY-PFLICHT: `racks.setWrapper(wRACKS)` und `racks.setCapExempt(zap)` — ohne setWrapper
  reverten Launch-Transfers an Nutzer mit "!wrapper" (fail-closed), ohne capExempt(zap) zaehlt
  der Zap-Kauf nicht und der Cap ist wirkungslos. Beides steht in STATUS.md.
**F6** — Orakel ohne Code brickte wrap/unwrap (try/catch faengt den extcodesize-Check nicht).
Fix: `require(o.code.length > 0)` im Setter + Codesize-Guard bei Nutzung.
**F7** — `_active`-Liste vergiftbar. Fix: abgelaufene Positionen unter MIN_LOCK werden beim Settle
automatisch entfernt (Dust an den Owner zurueck), MIN_LOCK 1.000 RACKS, `potLiveRange(from,count)`
zum Pagen; `harvestBatch` ist removal-sicher (swap-and-pop waehrend Iteration).
**F8** — MAX_PER_WALLET galt nur beim Mint. Fix: Cap in `_update` auf den Empfaenger.
**F9** — Unrevealter Agent war ein Zombie (nicht fuetter-/reapbar, zaehlte aber). Fix: reap nach
LIFE auch fuer unrevealte.
**Zap/V4Swap** — gestrandete Teil-Fill-Refunds. Fix: nach jedem Aufruf werden Restbestaende von
USDG/SPY/wRACKS an msg.sender gesweept; Return-Werte der Refund-Transfers werden geprueft.
**Owner-Macht** — `renounceExemptControl()` in RACKS: setExempt (der Rug-Vektor) laesst sich nach
dem Launch permanent abschalten.

**F4/F5 — GELOEST: Tax lebt jetzt AM POOL (src/v4/TaxHook.sol).** Owner-Entscheidung: "wir brauchen
unbedingt tax". v4-afterSwap-Hook nach dem Standard-"Taking-Fee"-Muster: nimmt bei JEDEM Swap die Tax
direkt aus dem Output des Swappers (hookDelta) und schickt sie per `take` an die Tax-Wallet.
Unumgehbar fuer Direkt-Trader, Bots, Router. Kauf-Tax faellt in wRACKS an, Verkaufs-Tax in SPY
(landet ohne Swapper reserve-fertig). Der Hook ruft bei jedem Swap `oracle.update()` -> das TWAP ist
nicht mehr stale (loest die Orakel-Beobachtung). Fork-Tests (test/v4/TaxHook.t.sol): Direktkauf/-
verkauf besteuert (Basis 4% + Impact), Launch 8%, nach Dump 799 bps Sell / 102 bps Buy,
**Stueckelung spart nur noch 2.3%** (vorher ~50%), revertierendes Orakel -> Fallback statt Brick.
Die Wrapper-Tax wurde ENTFERNT (ein einziges Tax-Modell; Zap-Nutzer zahlen nicht doppelt): wrap/
unwrap ist eine reine Formaenderung. Hook-Adresse muss per CREATE2 gemint werden (low 14 bits ==
AFTER_SWAP|AFTER_SWAP_RETURNS_DELTA = 0x44); der wRACKS/SPY-Pool MUSS mit dem Hook im PoolKey
erstellt werden (ein hookloser Pool haette keine Tax). Direkt-Round-Trip kostet nun ~13%.
Offen: Umwandlung der wRACKS-Tax in SPY (Tax-Wallet swappt mit `exemptSender`, damit sie sich nicht
selbst besteuert) — einfacher Keeper-Schritt, kein Contract noetig.
**OFFEN — Infrastruktur:** Deploy.s.sol ist v2-Stand (deployt weder Zap noch V4Swap noch
TwapOracleV4, kein setCapExempt/setWrapper/setTaxOracle); VRF-Interface ist fiktiv (Chainlink-v2.5-
Adapter noetig, Verfuegbarkeit auf RH ungeklaert); TwapOracleV4 sampelt nur bei wrap/unwrap.
**Frontend-Drift (nicht dieses Repo):** EXPIRED_BLEED 2%/d -> real: normaler Melt, gebrannt;
Special-Hitrate 80 -> 75; Tax-Caps 7/5 -> 8/8; useTradeTax muss wRACKS-Mengen quoten.

## Runde 5 — Komplett-Check nach dem Hook-Umbau (test/v4/HookAdversarial.t.sol + alles)
(A) Gezielte Angriffe auf den neuesten Code: exact-OUTPUT-Swaps werden auf der Input-Seite besteuert
(kein Umweg ueber den anderen Swap-Modus); Liquiditaets-Ops unbesteuert; nur der Owner kann Sender
exempten / die Tax-Wallet setzen; fremder Pool mit unserem Hook ist harmlos.
**DEPLOY-FALLE gefunden und abgesichert:** Der Hook liefert Tax-wRACKS an die Tax-Wallet; waehrend
der Launch-Stunde laeuft das durch das kumulative Cap-Ledger. Ist die Tax-Wallet NICHT exempt, hat
sie nach ~1% Tax den Cap erreicht und **jeder weitere Swap revertet — der Pool ist fuer den Rest
der Launch-Stunde tot** (Fork-Test: nach 25 Swaps). Fix/Guard: `TaxHook.wiringOk()` prueft, dass die
Tax-Wallet in RACKS exempt UND in wRACKS capExempt ist; das Deploy-Skript muss `require(wiringOk())`.
(B) Invarianten-Fuzz 1.000 Laeufe x 60 Tiefe = 60.000 Calls je Suite: keine Inflation, Index
gebunden, Rate im Band, Vault solvent, Allokation <= Pot — alles haelt.
(C) 99 normale + 40 Fork-Tests gruen.
(D) 2-Wochen-Sim und $17.9M-Stress unter dem Hook-Modell: Raritaet/Trefferquoten/Pot-Oekonomie
unveraendert; Tax faellt am Pool an (wRACKS bei Kaeufen, SPY bei Verkaeufen -> reserve-fertig);
Tax-Band stets in [400, 800]; Launch-Stunde ohne Revert.
Tax-Groessenordnung (gemessen): kleiner Trade 4.03%/4.01% -> ~8.4% Round-Trip; 1% des Pools
5.6%/4.7%; 3.3% des Pools 8.0%/6.4% -> ~14%. Der Impact-Term greift bei Whales, nicht bei
Kleinanlegern. Bei einem $5k-Launch-Pool ist JEDER mittlere Trade ein grosser Pool-Anteil -> nahe 8%.

## Runde 6 — Architekturwechsel auf v2 (atomarer Pool-Melt)
Angegriffen: Bounty-Farming (100 Wiederholungscalls zahlen 0), Doppelzaehlung des Pool-Melts
(folgt exakt dem Index-Verhaeltnis), LP-Ausstieg nach 5 Tagen Melt (funktioniert, keine Insolvenz),
Sandwich um den Melt herum (Round-Trip verliert Geld), setPair ohne Exempt (revertet),
Supply-Wirkung (Pool-Melt verkleinert die Supply wirklich). Keine Exploits.
Korrektur (Runde 9): meltPool ist fuer externe Caller NICHT epochen-gegatet — es meltet zeitbasiert
ab der ersten Sekunde. Unschaedlich (Melt+Sync atomar, Gesamtmelt aufrufunabhaengig), aber die frueher
behauptete Eigenschaft "Balance innerhalb einer Epoche konstant" gilt nur fuer den Self-Call.
Bewusste Abwaegung: meltPool traegt KEIN nonReentrant, weil der externe Self-Call aus _preOp genau
dann komplett zurueckrollen soll, wenn das Pair gelockt ist. Sicher, weil meltPool nur Pair-State
anfasst und sync() nicht in Racks zurueckruft.
Restrisiko (bekannt, klein): zwischen Epochenwechsel und erstem meltPool ist der Pool-Preis 0,09-0,15%
zu niedrig — dieselbe Arb-Klasse wie AMPL-Syncs; die Bounty haelt das Fenster praktisch geschlossen.

## Runde 7 — Antwort auf das externe Audit (N-Serie) — test/AuditN.t.sol
Alle vier per PoC BESTAETIGT, gefixt, Regressionstest.
**N1 (kritisch) — `renounceExemptControl()` war ein Flag, das niemand liest.** setExempt prueft es
nicht; nach dem Renounce konnte der Owner das Pair de-exempten — genau der Rug-Vektor, den AUDIT.md
als "permanent abgeschaltet" beschrieb. Mein Fix aus Runde 4 hatte die Datei nie erreicht und ich
hatte ihn nie getestet. Fix: `require(!exemptControlRenounced)` in setExempt + Test.
**N2 (hoch) — kein Trading-Gate.** PoC: zwischen addLiquidity und enableTrading nahm ein Sniper 20%
der Supply, launchReceived blieb 0. Fix: solange `tradingStart == 0` reverten alle Pool<->Wallet-
Transfers ("not started"); tax-exempte Adressen (Deployer) duerfen weiter seeden.
**N11 (hoch) — kumulativer Cap brickte custodial Bot-Router.** PoC: drei Nutzer a 0.3% durch
denselben Fee-Router, der vierte revertet, obwohl jedes Nutzer-Ledger 0 ist. Fix: bei
`to.code.length > 0` bucht das Ledger auf `tx.origin` statt auf den Router.
**N3 (mittel) — sequenzielles Settle unbegrenzt.** Gemessen: 81 Mio. Gas nach 3.000 leeren Epochen
(schlimmer als gemeldet). Fix: O(1) — `settled(e)` ist eine View (`e < settledThrough || _map[e]`),
und nur Epochen mit Angriffen landen in `activeEpochs` mit Cursor. Jetzt 79.556 Gas, unabhaengig vom Alter.
Niedrig: relock nach Auto-Prune kassierte die USDG-Fee fuer eine geloeschte Position (Fix: erst
settlen, dann pruefen, dann Fee); externes meltPool schreibt jetzt die Glaettung fort wie poke.
Repo: Deploy.s.sol komplett neu auf v2 (siehe unten); V2EndToEnd.t.sol und RacksOnRealV2.t.sol
entfernt (testeten das alte Modell; V2AtomicMelt deckt das echte ab) — der vom Auditor gefundene
Prank-Bug darin ist damit gegenstandslos. Der gemeldete Compile-Fehler (WRacksTax.t.sol) kam aus
einem aelteren Zip; die Datei war hier bereits geloescht.

**OFFEN — Entscheidungen des Owners (N4/N5):**
- N4: LP-Operationen werden wie Trades besteuert (Pair->LP = Buy, LP->Pair = Sell). Dritte werden
  so keine Liquiditaet stellen. Gleichzeitig ist genau das die Bremse gegen den LP-Melt-Dodge
  (Liquiditaet im Fenster rausnehmen, un-gemeltet, danach zurueck). Entweder nur eigene LP fahren,
  oder LP-Exemption plus Bedingung `pairIndex == index()` fuer Pair->Wallet-Transfers.
- N5: Bounty 0.25% des Epochen-Melts ist bei kleinem Pool nur Cent-Betraege. Wenn Bots den Job
  wirklich uebernehmen sollen, braucht es einen absoluten Mindestbetrag (bewusst als LP-Kosten).
  Aktuell traegt die Self-Heal-Logik in _preOp den Loewenanteil.

## Runde 8 — Deploy-Audit (P-Serie) — test/v4/DeployWindow.t.sol
**P1 (hoch, BESTAETIGT) — offenes Fenster zwischen addLiquidity und setPair.** Mit --broadcast ist
jeder Call eine eigene TX in einem eigenen Block. Mit vm.roll nachgestellt: in dem Fenster ist das
Pair nicht isDex -> Gate blind, Tax 0, Cap-Ledger aus. PoC: Sniper nahm **13.38% der Supply, null
Tax, launchReceived 0**. Mein alter Fork-Test konnte das nicht sehen, weil er das Skript in EINER
Test-TX ausfuehrte. Fix: `setPair` (und Orakel) VOR `addLiquidity`; der Deployer ist tax-exempt und
passiert das Gate, pairIndex wird auf leerem Pool gesetzt (erster Melt rechnet korrekt). Beide
Ordnungen sind als Tests hinterlegt (P1 = alte Reihenfolge bricht, P1b = neue haelt).
**VRF-Platzhalter (BESTAETIGT als reales Risiko).** IRSAgent startet jetzt `paused = true`;
`setPaused(false)` verlangt `vrf.code.length > 0`, ein codeloser Platzhalter laesst sich also gar
nicht scharfschalten. Ein permissionless Mock bliebe gefaehrlich — deshalb Deploy-Selbstcheck
`require(agents.paused())`.
**LP-Handling (BESTAETIGT).** LP lag beim dauerhaft tax-exempten Deployer: Scanner melden "creator
can pull liquidity", und der Melt-Dodge waere fuer ihn gratis. Skript sendet die LP jetzt an
`LP_DESTINATION` (0x...dEaD = burn), setzt `setTaxExempt(deployer, false)` und startet die
Ownership-Uebergabe an die Multisig. Selbstchecks: Deployer haelt keine LP, ist nicht mehr
tax-exempt, pendingOwner == Multisig.
**Repo-Drift (BEHOBEN).** Tote v4-Schicht entfernt: src/v4/*, src/WRacks.sol und alle zugehoerigen
Tests (inkl. der vom Auditor genannten WRacksTax/V2EndToEnd/RacksOnRealV2/RacksDirectInPool),
DeployTestnet.s.sol. Wrapper-spezifische Regressionen (W1, E3, E6, F3-Wrapper, F6-Hook) sind mit dem
Wrapper gegenstandslos und entfernt; die Token-Ebene-Regressionen bleiben. Clean-Clone-Build
verifiziert: 94 Tests gruen, 14 Fork-Tests gruen, keine Altlasten.
Niedrig, dokumentiert statt gefixt: tx.origin-Ledger teilt sich bei AA-Bundlern ein Cap (auf RH
heute nicht relevant); `renounceExemptControl` ist irreversibel und blockiert auch kuenftig noetige
Exemptions; `activeEpochs` waechst ~1.100 Eintraege/Jahr (Cursor-basiert, unkritisch).
**OFFEN (Owner):** Pot-Seed. Das Skript schickt 100% der Supply in den Pool -> Casino startet mit
Pot 0. Wenn am Launch geraidet werden soll, braucht es Supply-Reserve fuer `fundPot` oder frueh
Kurz-Locker. Widerspricht der bisherigen Doku und ist bewusst zu entscheiden.

## Runde 9 — Praezision und Doku
- **Zwei Quellen fuer dieselbe Rate** (F_FF0/F_FF1 vs. _factorEnds(0)) wichen um ~4e10 Wei auf 1e27 ab;
  ratePerDayBps() und ratePerDayBpsFor(0) konnten im letzten Bps-Digit auseinanderlaufen. Vereinheitlicht:
  die Faktortabelle ist jetzt die einzige Quelle, F_FF0/F_FF1 entfernt. Test: testSingleRateSource.
- **Abgelaufene Locks drueckten den Free Float** fuer alle, bis sie unter MIN_LOCK geprunt wurden (bei
  einer grossen vergessenen Position ueber Monate). `expiredPrincipal` wird jetzt mitgefuehrt und aus
  lockedSupply herausgerechnet. Gemessen: Rate springt nach Ablauf von 623 auf 690 bps/d zurueck.
- Doppelte Bedingung in _preOp entfernt; README auf die aktuelle Architektur umgeschrieben (beschrieb
  noch WRacks als Fallback); STATUS-Verweis auf den geloeschten RacksDirectInPool-Test korrigiert.
- Pot-Formel klargestellt: Pot_in = 0,3*r_w*V1d + 0,2*r_w*V3d + 0,1*r_w*V14d, kein W-Term.

## Runde 10 — Owner-Modell der Nachbar-Contracts (S-Serie)
**S1 — BESTAETIGT (hoch) und gefixt.** Auf dem veroeffentlichten Stand war `setAgent` owner-only
ohne jede Einschraenkung, und Vault, Agent und Orakel hatten keine Ownership-Uebergabe — das
Deploy-Skript uebertrug nur Racks. Der Deployer-Key konnte den gesamten Pot mit einem Call
umleiten, unabhaengig davon, wie gut der Token gehaertet war. Gefixt in derselben Runde: einmaliges
`setAgent`, 2-Step-Ownership in allen drei Contracts, Deploy-Skript uebergibt alle vier und prueft
alle vier im Self-Check. (Eine fruehere Fassung dieses Eintrags behauptete, der Befund beziehe
sich auf einen aelteren Stand — das war falsch und ist hier korrigiert.)
**S2 — bestaetigt und gefixt.** PoC: nach `setEpochLength(30min -> 2h)` war epochNow()=8 gegen
pairEpoch=24, der Self-Heal-Melt haette nie wieder gefeuert. `setEpochLength` re-ankert pairEpoch
jetzt auf die neue Zaehlung; Regressionstest prueft, dass der Pool danach wieder meltet.
**S3 — bestaetigt und entfernt.** `wrapper`, `setWrapper` und `recordLaunchReceipt` waren toter Code
aus der Wrapper-Aera, mit dem ein gesetzter `wrapper` fremden Wallets das Launch-Cap-Ledger haette
vollschreiben koennen. Ersatzlos geloescht.
Operativ uebernommen: USDG (Paxos) hat eine Freeze-Liste — `reserve` darf keine einfrierbare Adresse
sein, sonst reverten lock/mint/feed; `setReserve` ist der Ausweg. Steht in STATUS.md.

## Runde 11 — Migrationspfad (M1)
**M1 bestaetigt und gefixt.** PoC: Alice gewinnt 34.740 RACKS und claimt nicht; der Owner migriert
ueber den 48h-Timelock; danach revertet ihr Claim (der alte Agent darf kein drawPot mehr), und der
neue Agent startet mit allocatedPot == 0 und verteilt DASSELBE Geld erneut.
Fix: `executeAgent` verlangt, dass der alte Agent nichts mehr schuldet (`allocatedPot() == 0`), also
alle Gewinne abgeholt oder via sweepStale freigegeben sind — das passt zum Timelock-Gedanken.
Fail-closed: ein Agent, dessen Buecher nicht lesbar sind, gilt als schuldend. Der Code-Check muss
EXPLIZIT sein, weil ein `try` auf eine codelose Adresse schon an Soliditys extcodesize-Pruefung
revertet, bevor der catch greift (derselbe Fallstrick wie bei W5).
Dabei ein Folgeproblem gefunden, das der strikte Check erst sichtbar machte: pari-mutuel-Rundung
liess **1 Wei** pro Epoche in allocatedPot stehen — die Migration waere dauerhaft an Staub blockiert
gewesen. `claim` schliesst einen Epochen-Topf jetzt sauber, sobald der Rest unter DUST (1e9 wei)
faellt; der Rest bleibt unalloziert im Pot.
Ergaenzt: `forceExecuteAgent` als Notausgang nach FORCE_DELAY (30 Tage ab Vorschlag), damit ein
gebrickter Agent das Protokoll nicht fuer immer festhaelt — offene Preise gehen auf diesem Pfad
verloren, deshalb der lange Vorlauf und ein Event. `AgentChanged(old,new,forced)` und
`AgentCancelled` werden jetzt emittiert.
Kommentar korrigiert: der Timelock gibt NICHT Lockern Zeit zum Aussteigen (drawPot bewegt nur `pot`,
nie Principal) — er schuetzt Praemienberechtigte, deren Anspruch in den Buechern des alten Agenten steht.

## Runde 12 — Agent-Zeiger eingefroren (Owner-Entscheidung)
Statt M1 nur abzusichern, wurde die Faehigkeit ganz entfernt: `setAgent` ist einmalig, es gibt kein
proposeAgent/executeAgent/forceExecuteAgent mehr. Damit ist M1 gegenstandslos (keine Migration =
keine gestrandeten Preise), und der Vault hat keinen Schluessel mehr, der den Pot umleiten kann —
die staerkste Form von S1.
Voraussetzung dafuer: `vrf` in IRSAgent war `immutable`, der Agententausch war also der einzige Weg,
je eine echte Zufallsquelle anzuschliessen. Das wandert jetzt in den Agenten: `proposeVrf` mit 7-Tage-
Timelock, `executeVrf`, `renounceVrfControl` als Einbahnstrasse. Verbleibende Owner-Macht ist damit
strikt kleiner: eine manipulierte Zufallsquelle beeinflusst nur, wer gewinnt (epochenweise, gedeckelt,
sichtbar), waehrend ein Agententausch den ganzen Pot in einem Call bewegt haette.
Der M1-Dust-Fix (Epochen-Toepfe schliessen unter DUST) bleibt drin: er verhinderte, dass 1 Wei
Rundung Buchhaltung dauerhaft offen haelt.

## Runde 13 — Automatische Tax-Umwandlung, TaxSwapper entfernt
Die Tax wird jetzt IM TOKEN bei jedem Verkauf automatisch in SPY getauscht (an `reserve`).
Ein Kauf kann das nicht: `pair.swap()` haelt den Reentrancy-Lock, ein Rueck-Swap darin revertet
zwingend — Kauf-Tax wandert beim naechsten Verkauf mit. Fork-getestet gegen den echten RH-Router.
Sicherheitsrelevante Punkte dieser Aenderung (Audit-Schwerpunkt):
- Eigener Reentrancy-Guard: der Router MUSS waehrend der Umwandlung transferFrom auf uns aufrufen,
  deshalb ist genau dieser Pfad ueber `inSwap` erlaubt, jeder andere bleibt blockiert.
- `try/catch` um den Swap: eine fehlschlagende Umwandlung darf einen Nutzer-Verkauf nie kippen
  (Test erzwingt den Fall mit 0 bps Slippage-Toleranz).
- `maxSwapBps` = 0.5% der Pair-Reserve pro Umwandlung deckelt den Preis-Impact; der Rueckstand ist
  dadurch begrenzt, nicht unbegrenzt.
- Die wartende Tax ist melt- und tax-exempt (schrumpft nicht, besteuert sich nicht selbst).
`TaxSwapper.sol` und sein Test sind ersatzlos entfernt (Contract, Tests, Deploy-Wiring, Doku).
Clean-Clone-Build gruen: 100 normale + 18 Fork-Tests.

## Runde 14 — Auto-Swap-Nebenwirkungen (X-Serie)
Alle sechs Befunde uebernommen, in der vorgeschlagenen Reihenfolge.
**X2 (die schwerwiegendste) — der Verkaeufer wurde auf die Dislokation besteuert, die das Protokoll
gerade selbst erzeugt hatte.** `_swapTax` stand vor `_taxBps`, das Orakel sampelte den Post-Dump-Spot.
Fix: `bps` wird jetzt VOR jeder protokollseitigen Umwandlung berechnet.
**X1 — das Protokoll verkaufte vor seinen eigenen Verkaeufern.** Zwei Massnahmen: `maxSwapBps` von
50 auf 10 (0.1% der Reserve, unter jedem Bot-Default), und ein permissionless `swapTax()` mit
0.25%-Bounty analog `meltPool` — die Umwandlung passiert damit in EIGENEN Transaktionen, der
In-Transfer-Pfad ist nur noch Fallback, wenn niemand nachgekommen ist.
**X3 — minOut lag am Live-Quote**, gegen den sich ein Sandwich vorpositionieren kann. Jetzt gilt das
Minimum aus Live-Quote und TWAP-Bewertung als Basis; der TWAP ist in einem Block nicht bewegbar.
**X4 — `guarded` hob den Reentrancy-Schutz global auf, solange `inSwap` stand.** Jetzt ist die
Ausnahme auf `msg.sender == swapRouter` verengt; `burn` nutzt denselben Guard statt des alten.
**X5 — `enableAutoSwap` setzte `isExempt[this]` an `setExempt` vorbei** und konnte `reserve_`
jederzeit umbiegen. Jetzt an `exemptControlRenounced` gebunden, und das Ziel ist nach der ersten
Konfiguration fixiert ("reserve is fixed").
**X6 — nach `executeVrf` konnte die alte Quelle offene Requests nicht mehr erfuellen**; laufende
Mints verfielen mit den $99. Neu: `reclaimStuckMint(reqId)` nach STUCK_AFTER (3 Tage) — der
unrevealte Agent wird stillgelegt und die Mint-Gebuehr an den Zahler erstattet.
  BETRIEBSHINWEIS: `reserve` muss dem Agenten eine USDG-Allowance geben, sonst schlaegt die
  Erstattung fehl.

## Runde 15 — Folgefunde in den frischen Fixes (Y-Serie)
Beide neuen Punkte stammen aus meinen eigenen Aenderungen der Vorrunde.
**Y1 — `reap()` konnte die Erstattung zerstoeren.** LIFE und STUCK_AFTER sind beide 3 Tage, `reap`
ist permissionless und setzte `dead`, `reclaimStuckMint` verlangte `!dead`: wer zuerst reapte, machte
aus einem erstattbaren Mint fuer Gaskosten einen verlorenen $99. Fix: `dead` sperrt die Erstattung
nicht mehr; das Loeschen des Requests ist der Einmal-Schutz. Der Reap wird nachgeholt, falls noch offen.
**Y2 — die TWAP-Basis nahm die falsche Seite.** `min(Live-Quote, TWAP)` akzeptiert genau den
gedrueckten Spot, vor dem der Kommentar zu schuetzen behauptete. Jetzt `max(...)`. Bewusste Folge:
bei einem echten scharfen Kursrutsch pausiert die Umwandlung, bis der TWAP nachzieht — Verkaeufe
laufen weiter (try/catch). Deterministisch belegt in test/TwapFloor.t.sol: fairer Kurs wandelt,
gedrueckter wird verweigert, besserer wandelt, nach TWAP-Angleich laeuft es wieder.
**Y3 — `router_` und `spy_` waren weiter aenderbar.** Ein fremdes `swapSpy` mit luegendem balanceOf
haette die `out >= minOut`-Pruefung ausgehebelt. Beide sind jetzt wie die Reserve nach der ersten
Konfiguration fixiert.
**Y4 — Erstattungen ziehen per transferFrom von der Reserve.** Neu: `refundsReady()` als View, damit
die Multisig Allowance und Deckung pruefen kann, bevor jemand eine Erstattung braucht; steht im
Deploy-Log und in STATUS.md.

## Runde 16 — Z-Serie
**Z1 (hoch, mein Fehler aus X1) — Bounty wurde VOR dem `try` gezahlt.** Jeder Fehlschlag (TWAP-Floor
nach einem Dump, Router-Ausfall, SPY pausiert) wurde zur Bounty-Farm: rufen, scheitern, Bounty
behalten, wiederholen. Fix: Bounty nur im Erfolgszweig. Test: 200 Aufrufe am gedrueckten Spot
farmen exakt 0, ein erfolgreicher Aufruf zahlt genau einmal.
Dazu, wie empfohlen: die In-Transfer-Fallback-Konvertierung in `_move` ist ENTFERNT. Sie stellte
bei jedem Sell einen Protokoll-Verkauf vor die Order des Nutzers und kostete ~140k Gas pro Trade.
Konvertierung laeuft ausschliesslich ueber das permissionless `swapTax()` (Bots/Cron).
**Z3** — `setSwapParams` erlaubt jetzt hoechstens 0.5% der Reserve (vorher 5%) als Multisig-Hebel.
**setPair** ist einmalig ("pair is final").
**Z2** — effektive Slippage: die TWAP-Bewertung `amt*twap` ist ein Mid-Preis ohne 0.3% Pool-Fee
und ohne Impact, die Live-Quote enthaelt beides; die `max`-Basis ist damit praktisch immer der TWAP.
Bei 300 bps Toleranz lag die effektive Toleranz bei ~2.6%. Default auf 350 bps gesetzt, damit die
Konvertierung nicht schon bei kleinen Bewegungen pausiert.
Bot-Kompatibilitaet nach Z1: Worst-Case-Sell ohne Fallback-Konvertierung deutlich unter 400k Gas.

## Runde 17 — Abschluss
Externer Abschlussbericht (13 Runden, 07.–10.09.2026): **keine offenen Code-Findings.** Z1 verifiziert
(200 Fehlversuche farmen 0; Fork: Tax-Pot unveraendert), In-Transfer-Fallback entfernt, Worst-Case-Sell
362k Gas (vorher 536k). Verbleibend: Design-Entscheidungen (W-Term, Pot-Seed, Zufallsquelle) und die
Multisig-Vertrauensliste — beides Text, kein Code.

## Runde 18 — Zufallsquelle gebaut: HashChainSeed + Epochen-Seed im Agenten
Owner-Entscheidung: Pot wird jede Epoche geleert (Rule 1+2 verworfen); Zufall = vorab festgelegte
Hash-Kette, ein Seed pro Epoche, mit den zwei Keeper-Regeln (Withhold = alle verlieren; Kaution).
Sicherheitswirkung des Umbaus: die gesamte Klasse der VRF-Timing-Exploits (E1 Phantom-Shares,
E2 Sofort-Settle, X6/Y1 Stuck-Mint) ist STRUKTURELL weg — es gibt keine Requests mehr. Der Agent ist
mit 315 Zeilen kleiner als vorher (322) trotz neuem Tally.
Getestet (test/HashChainSeed.t.sol, test/IRSAgent.t.sol): Reveal muss zur Kette passen, kein Replay,
kein Reveal einer offenen Epoche; voller Ablauf Mint -> Reveal -> Attack -> Reveal -> Settle -> Claim
mit der echten Quelle; Zurueckhalten -> permissionless Slash -> Kaution in den Pot -> jeder verliert;
Mint in einer failed Epoche wird vom naechsten guten Seed enthuellt; nur der Keeper deckt auf, Kaution
darf nicht unter eine Strafe fallen; Tally seitenweise; Settle ohne Seed unmoeglich.
Invarianten-Handler ist jetzt selbst die Seed-Quelle und haelt zufaellig Epochen zurueck — Solvenz
und Allokation halten weiter. Deploy-Skript deployt die Quelle mit (KEEPER-Env), fuenf Ownerships.
NEU ZU AUDITIEREN (das eine ungeschriebene Kapitel, jetzt geschrieben): src/HashChainSeed.sol und die
Tally-/Reveal-Logik in IRSAgent.

## Runde 19 — K-Serie: das Zufallskapitel hielt nicht
**K1 (kritisch, mein Analysefehler).** Der `attackDigest` im Seed war kein Schutz, sondern ein
Grinding-Eingang: der Keeper kennt jedes Urbild und konnte den Digest mit eigenen Angriffen so lange
verlaengern, bis der Seed seine Agenten gewinnen liess (10 Agenten = 1.023 Kandidaten/Epoche, ~85% des
Pots, ohne je einen Reveal zu verpassen). Mein Satz "niemand kennt das Ergebnis vor Schluss" war fuer
den Keeper exakt falsch herum. Fix nach Auditor-Vorschlag: reveal-then-play — Urbild am Epochenanfang
enthuellen (oeffentlich, entscheidet allein nichts), Unvorhersagbarkeit aus einem Post-Close-Blockhash,
den kein Spieler steuert; Angreifer-Input aus dem Seed entfernt. Test testK1: der Keeper greift mit
eigenen Agenten an, der Seed haengt nur von Urbild + Close-Hash ab.
**K2 (hoch).** Slash von 1M RACKS war bei 69B Supply ~7 Cent — Zurueckhalten kostete nichts. Fix:
Slash = max(Floor, aktueller Pot), Kaution muss das decken, `attack()` verweigert bei Unterdeckung.
**K3.** Keeper 2h offline: Epoche faellt, alle verfehlen (gewollt). Keeper gibt auf: Mints blieben
unrevealed, $99 verloren. Fix: `reclaimUnrevealed` nach 7 Tagen mit Erstattung aus der Reserve.
Restvertrauen, explizit: der Close-Blockhash stammt vom RH-Sequencer (kein Stake). Entfernbar nur
ueber CCIP (proposeVrf-Pfad). chain.json ist als pot-wertiges Geheimnis im Runbook markiert.

## Runde 20 — C-Serie: dieselbe Luecke im zweiten Baustein
**C1 (kritisch, mein Fehler von gestern).** `captureClose` nahm den Hash des VORBLOCKS der ersten
Transaktion nach Epochenende — permissionless und lazy. Mit oeffentlichem Urbild rechnet ein Spieler
fuer jeden neuen Block den Kandidaten-Seed aus und fasst die Epoche erst an, wenn ihm das Ergebnis
gefaellt (PoC: 185 Bloecke warten, 100% des Pots). "no single party picks the block" war falsch — die
erste Partei tat genau das. Fix nach Auditor-Vorschlag, zwei Schritte: der erste Toucher fixiert nur
eine ZUKUENFTIGE Blocknummer (Hash unbekannt), eine spaetere Transaktion innerhalb von 256 Bloecken
friert den Hash ein (nur festhalten, nicht waehlen); bei Verfall neue Zukunftsnummer. Tests testC1_*.
Keeper-Bot tickt 15 s statt 5 min, damit das Einfrieren innerhalb der ~64 s auf RH sicher passiert.
**C5 (mittel, das Y1-Muster erneut).** `reap` (3 Tage) sperrte `reclaimUnrevealed` (7 Tage) ueber
`!dead`. Fix: eigenes `refunded`-Flag als Einmal-Schutz, `dead` sperrt nicht. Test testC5.
**C6.** Reveal war bis 2h nach Schluss erlaubt — dann kannte der Keeper den Seed vor dem Reveal.
Jetzt nur bis Epochenende ("epoch over"); Slash ab Epochenende.
**C7.** `fundPot` kann den Pot ueber die Kaution heben und Angriffe sperren — Griefing auf eigene
Kosten, dokumentiert in STATUS.

## Nicht gefunden (geprueft)
- Flash-Loan-Manipulation des TWAP: Spot -75% in einem Block bewegt TWAP 0 bps (Stresstest).
- Cayman-Inflation: Index-basiert, keine Share-Ratio -> kein First-Depositor-Vektor.
- Rundungs-Inflation ueber viele Wraps: Ist-Delta-Messung schliesst Dust-Muenzung aus.
- Pool-Melt-Drift: Pool haelt wRACKS (fix), kein Rebasing-Leck (7d-Melt-Test).
