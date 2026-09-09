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

## Nicht gefunden (geprueft)
- Flash-Loan-Manipulation des TWAP: Spot -75% in einem Block bewegt TWAP 0 bps (Stresstest).
- Cayman-Inflation: Index-basiert, keine Share-Ratio -> kein First-Depositor-Vektor.
- Rundungs-Inflation ueber viele Wraps: Ist-Delta-Messung schliesst Dust-Muenzung aus.
- Pool-Melt-Drift: Pool haelt wRACKS (fix), kein Rebasing-Leck (7d-Melt-Test).
