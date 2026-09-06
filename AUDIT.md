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

## Nicht gefunden (geprueft)
- Flash-Loan-Manipulation des TWAP: Spot -75% in einem Block bewegt TWAP 0 bps (Stresstest).
- Cayman-Inflation: Index-basiert, keine Share-Ratio -> kein First-Depositor-Vektor.
- Rundungs-Inflation ueber viele Wraps: Ist-Delta-Messung schliesst Dust-Muenzung aus.
- Pool-Melt-Drift: Pool haelt wRACKS (fix), kein Rebasing-Leck (7d-Melt-Test).
