# Maker fee waterfall (source of truth)

Locked with Maker Lee (Oct 5, 2026). Updated for **live v3 lender pool** (shared pool shares, FIFO withdraw queue,
floating rate index, Maker waterfall unchanged, boost tiers). v2.5 funder-idle is historical only.

Accounting model (v3, live): [`ACCOUNTING_V3.md`](./ACCOUNTING_V3.md). v2.5 history: [`ACCOUNTING_V25.md`](./ACCOUNTING_V25.md).  
Product narrative: [`MAKER_V1_NOTES.md`](./MAKER_V1_NOTES.md).  
On-chain today: [`CARRY_CONTRACT.md`](../CARRY_CONTRACT.md) + [`CARRY_TESTNET.md`](../CARRY_TESTNET.md).

---

## Waterfall (on gross LP fees)

Senior accrual is the opportunity cost of supplying USDG on Carry instead of Morpho:

```
accrual = seniorPrincipal × morphoRate × elapsed / 365
```

`morphoRate` = **Steakhouse Morpho native supply APY** (not Merkl rewards).

> **Changing.** On testnet `morphoRate` is an owner-set stub, not a promised rate. The planned mainnet model drops the stored rate and the `seniorFloor`: lenders earn Morpho yield (floating) + their 20% `seniorPerf` share of fees (issue #20, PR #21,). Treasury and boost cuts stay as below.

Then, on **gross** LP fees for the period:

```
seniorFloor = min(gross, accrual)
left        = gross − seniorFloor
treasury    = min(left, gross × treasuryCut)   // base 20%; Boosted Level I-V 17.5/16.25/13.75/10/5%
left        = left − treasury
seniorPerf  = min(left, gross × 0.20)
junior      = left − seniorPerf
senior      = seniorFloor + seniorPerf
```

**Treasury cut surface (Maker Oct 10 leftovers):**

| Position / stake | Treasury cut of **fees** (not position size) |
| --- | --- |
| Active (no STRATEGY stake) | **20%** (`treasuryCutWad`) |
| Boosted Level I-V (`StrategyBoostHook`, reads `StrategyStaking.stakedOf`) | 17.5% / 16.25% / 13.75% / 10% / 5% at ≥25k / ≥100k / ≥500k / ≥2M / ≥10M STRATEGY |

The vault reads the cut from `boostHook` at match and caps it at the base cut. The owner swaps the hook with `setBoostHook` (multisig + timelock on mainnet).

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
| Testnet (`sellSharesRouter == 0`) | Extra MSTR credited to **position funders** (amount × time matched on that position). |
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

**v3 (live):** senior USDG yield compounds into the single lender pool (share price rises);
every lender earns pro-rata by pool shares. See [`ACCOUNTING_V3.md`](./ACCOUNTING_V3.md).

**v2.5 (superseded PROXY only):** USDG (and testnet SellShares MSTR) credits go to **that position’s funders only**,
weighted by amount × time matched on the position:

```
weight_i = funderAmount_i × (creditTime − matchedAt_i)
share_i  ∝ weight_i
```

Pure idle lenders (not funders of the position) earn nothing from it.
Legacy global TW indices are frozen (no new credits). See [`ACCOUNTING_V25.md`](./ACCOUNTING_V25.md).

---

## On-chain status

**Live on testnet PROXY** `0x24B799026AA7baa6856bCFD00c1Be1f583A83e35` (UUPS, **`v3-lender-pool`**). In v3, senior yield compounds into one lender pool instead of per-position funders (see [`ACCOUNTING_V3.md`](./ACCOUNTING_V3.md)); the waterfall itself is unchanged.  
Implementation: `0x7BeED7F65A9D4aF4E67553d984800F6268a3778E` (also in `public/config.json` → `chain.vaultImplementation`).  
Superseded v2.5 PROXY/impl (`0xc801…72bd` / `0xe498…d0e8`) is settle-watch history only.

Live (`main`; the testnet impl picks up rolling positions and `boostHook` at its next upgrade): Maker waterfall, Boosted STRATEGY **tiers** via `boostHook` (Level I-V), gasCredit + auto-refund,
early-exit cover revert, SellShares router interface (testnet router=0), auto-compound,
**v3 lender pool** (internal shares + FIFO withdraw queue + floating `rateIndex`),
settle cover path: backstop → junior idle/wallet/SellShares → pool idle last resort,
$25 min, junior market $25k, senior pool uncapped, no per-wallet cap, matchCap.
Idle Morpho sleeve is **not live** on testnet (`product.idleSleeveLive: false`).

## Explicitly later

- Real Morpho sleeve on Robinhood
- LONG / creator fee share into Boosted (separate from treasury cut)
- Live STRATEGY token address and a deployed `StrategyStaking` + `StrategyBoostHook`
- Mainnet Uniswap router deployment (interface + mock covered in Forge)
- Mainnet 4663
