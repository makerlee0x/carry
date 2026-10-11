# Maker fee waterfall (source of truth)

Locked with Maker Lee (Oct 5, 2026). Updated Oct 10 leftovers + **v2.5 funder-idle accounting**
(per-lender idle, FIFO funders, yield to position funders, settle default IdleCarry, boost tiers).

Accounting model (v2.5): [`ACCOUNTING_V25.md`](./ACCOUNTING_V25.md).  
Product narrative: [`MAKER_V1_NOTES.md`](./MAKER_V1_NOTES.md).  
On-chain today: [`CARRY_CONTRACT.md`](../CARRY_CONTRACT.md) + [`CARRY_TESTNET.md`](../CARRY_TESTNET.md).

---

## Waterfall (on gross LP fees)

Senior accrual is the opportunity cost of supplying USDG on Carry instead of Morpho:

```
accrual = seniorPrincipal × morphoRate × elapsed / 365
```

`morphoRate` = **Steakhouse Morpho native supply APY** (not Merkl rewards).

Then, on **gross** LP fees for the period:

```
seniorFloor = min(gross, accrual)
left        = gross − seniorFloor
treasury    = min(left, gross × treasuryCut)   // base 20%; Boosted MSTR 10%
left        = left − treasury
seniorPerf  = min(left, gross × 0.20)
junior      = left − seniorPerf
senior      = seniorFloor + seniorPerf
```

**Treasury cut surface (Maker Oct 10 leftovers):**

| Position / stake | Treasury cut of **fees** (not position size) |
| --- | --- |
| Active (no STRATEGY stake) | **20%** (`treasuryCutWad`) |
| Boosted tiers (STRATEGY stake stub, owner-configurable) | 15% / 10% / 5% at ≥100 / ≥1k / ≥10k |
| Legacy `setBoostStaked` without amount | flat **10%** (`boostedTreasuryCutWad`) |

Creator fee boost is **later** and is **not** this cut. Cut locks at first match (`treasuryCutLocked`).

---

## When the split runs

Fee split runs **only** at:

- `claimFees`
- `earlyExit`
- `settle`

**Not** on fee-in (`accrueLpFee`). Fees can accrue raw into the position; the
waterfall is applied at claim / exit / settle.

---

## Shortfall cover (settle vs early exit)

If fees cannot cover senior accrual:

### Settle (maturity / normal exit)

1. **Backstop first** (treasury/backstop USDG).
2. **Residual:** junior chooses Wallet USDG, IdleCarry, or SellShares.
3. **Treasury-on-cover:** same base/Boosted cut as waterfall.  
   `coverTotal = residualShortfall + treasuryOnCover`.

Settle default mode = **IdleCarry** (USDG path). Permissionless when residual cover is zero.
Wallet / IdleCarry with cover require the junior. SellShares requires junior opt-in (`sellSharesEnabled`) or junior caller.

### Early exit (before term)

1. **Junior only** — Wallet / IdleCarry / SellShares.
2. **NO backstop** draw on early exit.
3. Fees apply to cover first; then Wallet pull / Idle burn.
4. If junior cannot cover with USDG/fees and does **not** choose SellShares →
   **REVERT** (`JuniorCoverRequired`); position stays open.

### SellShares

| Network | Behavior |
| --- | --- |
| Testnet (`sellSharesRouter == 0`) | Extra MSTR credited to seniors (time-weighted). |
| Mainnet (router set) | `IMstrSellRouter` Uniswap AMM stub: swap MSTR→USDG, cover seniors/treasury, remainder to junior (or auto-compound). |

---

## Auto-compound

`setAutoCompound(bool)` per wallet:

- **On:** `claimFees` compounds junior fee share into senior idle; full exit / Idle withdraw reopens MSTR as junior Idle and USDG as senior idle; if senior early-exits, junior with auto-compound rematches when idle allows. Pause and deposit caps do **not** block exit compounds.
- **Off:** yield and capital go to the wallet on withdraw.

---

## Gas credit auto-refund

Unused `gasCreditWei` is **auto-refunded** to the junior on:

- `withdrawUnmatched` (Idle cancel)
- `settle`
- `earlyExit` (when the position closes)

See [`GAS_CREDIT.md`](./GAS_CREDIT.md).

---

## Senior yield timing

USDG (and testnet SellShares MSTR) credits to seniors are **time-weighted by deposit time**:

```
weight_i = principal_i × (creditTime − joinedAt_i)
share_i  ∝ weight_i
```

---

## On-chain status

**Landed on testnet PROXY** `0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd` (UUPS, `v2.4-maker-leftovers`):
Maker waterfall, Boosted MSTR reduced treasury cut (10%), STRATEGY stake path stub,
gasCredit + auto-refund on close, early-exit cover revert, SellShares router interface
(testnet router=0), auto-compound flag, time-weighted senior credits, matchCap, deposit caps.
Implementation address in `public/config.json`.

## Explicitly later

- Real Morpho sleeve on Robinhood
- LONG / creator fee share into Boosted (separate from treasury cut)
- Live STRATEGY stake token wiring beyond owner flag / balance config
- Mainnet Uniswap router deployment (interface + mock covered in Forge)
- Mainnet 4663
