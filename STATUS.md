# RACKS — Status

## ARCHITEKTUR-ENTSCHEIDUNG: Uniswap v2 (kein Wrapper, kein Hook)
Auf RH-Mainnet gegen die ECHTE Uniswap v2 verifiziert (Factory 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f,
Router02 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba).

Warum nicht v3/v4: beide leiten Reserven aus L und Preis ab und haben kein sync(). Fork-Beweis
(test/v4/RacksDirectInPool.t.sol): nach 7 Tagen Melt haelt der PoolManager 1.818 statt 3.000 RACKS,
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

### Deploy (script/Deploy.s.sol — NEU auf v2, gegen RH-Fork getestet)
Reihenfolge ist zwingend und wird per require geprueft:
1. Token/Vault/Agents + Wiring, mint, renounceMint
2. Pair anlegen, `setExempt(pair)` (Pflicht vor setPair), Liquiditaet seeden — das Trading-Gate ist
   noch zu, nur tax-exempte Adressen (Deployer) duerfen Pool-Token bewegen
3. `setPair(pair)` (setzt isDex + capExempt + pairIndex) + TwapOracle
4. `enableTrading()` ZULETZT -> Launch-Stunde startet
Selbstchecks am Ende: Pair melt-exempt, setPair gesetzt, isDex, capExempt, Tax-Wallet melt-exempt,
Orakel verdrahtet, Mint renounced, Trading an, maxWallet > 0.
Fork-Test test/v4/DeployScript.t.sol fuehrt das echte Skript aus und handelt danach: Kauf in der
Launch-Stunde OK, zweiter Kauf ueber dem Cap revertet, Kauf+Verkauf ueber einen Melt-Epochenwechsel
ohne Keeper OK.
NACH dem Launch: `transferOwnership(multisig)` + `acceptOwnership()`, dann `renounceExemptControl()`.

## OFFEN
1. v4-Schicht aus dem Repo entfernen (Contracts + Tests), sobald v2 final bestaetigt ist.
3. VRF: Chainlink VRF laeuft NICHT auf RH (nur Data Feeds/Streams/CCIP). Empfehlung: EIN Zufalls-Seed
   pro Epoche via CCIP-Relay von Arbitrum One; Treffer = hash(seed, agentId). Beseitigt zugleich die
   ganze Klasse der VRF-Timing-Exploits. Entscheidung offen.
4. Externes Audit vor Mainnet.
5. Frontend-Konstanten an die Contracts angleichen (siehe AUDIT.md).
