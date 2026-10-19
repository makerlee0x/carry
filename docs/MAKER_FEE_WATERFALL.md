# Maker fee waterfall (source of truth)

Locked with Maker Lee (Oct 5, 2026); fee split and order updated Oct 18, 2026 (Stage 1: no fixed rate, 40/40/20).
v2.5 funder-idle is historical only.

Accounting model (v3, live): [`ACCOUNTING_V3.md`](./ACCOUNTING_V3.md). v2.5 history: [`ACCOUNTING_V25.md`](./ACCOUNTING_V25.md).  
Product narrative: [`MAKER_V1_NOTES.md`](./MAKER_V1_NOTES.md).  
On-chain today: [`CARRY_CONTRACT.md`](../CARRY_CONTRACT.md) + [`CARRY_TESTNET.md`](../CARRY_TESTNET.md).

---

## Waterfall (on gross LP fees)

> **Live on testnet (`version()` = `v3.2-dualpool`).** No fixed coupon; lenders earn Morpho + Carry fee share. One-arg `settle` / `earlyExit` (no CoverMode).

Lenders earn **Morpho + Carry**: whatever the Steakhouse USDG Morpho vault pays on lender USDG
(through `CarryStrategy`, booked into the share price by `harvest`), plus a share of LP fees.
There is no stored rate, no floor and no coupon, so nothing is ever owed beyond fees.

Fees are split in a fixed order, treasury first, then senior, then junior (Maker, Oct 18, 2026):

```
treasury    = gross × treasuryCut                // base 20%; Boosted Level I-V 17.5/16.25/13.75/10/5%
seniorPerf  = gross × 0.40                        // SENIOR_PERF_CUT_WAD
junior      = gross − treasury − seniorPerf       // 40% at the base cut, more when boosted
```

Example on $10 of fees at the base cut: treasury $2, senior $4, junior $4.

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

## Shortfall cover

**Stage 1:** there is no lender coupon, so settle and early exit never need cover. Early exit returns all
MSTR and the junior's fee share at no cost; settle is the same at term. The `CoverMode` argument is kept
for the ABI and ignored; the accrual, floor and cover fields in the preview structs read zero.

**Stage 2 (matched capital in DualPool, not built yet):** if a position closes with pool value below the
senior's principal, the gap is covered in this order (Maker, Oct 18, 2026): position fees, then the Morpho
yield accrued on that position, then the backstop (the treasury balance). Lenders earn less Morpho yield
before they lose principal. The backstop target is 10% of active positions, as an operating goal only
(not enforced in the contract).

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

**Live on testnet PROXY** `0x24B799026AA7baa6856bCFD00c1Be1f583A83e35` (UUPS, **`v3.2-dualpool`**).  
Implementation: `0x14732623B077C656527ee5C87812AC23e98c58A5` · CarryStrategy `0x43ec…E6AE` · DualPoolHook `0xaf4a…6ac0`.  
See [`testnet-runs/2026-10-18-v32-upgrade.md`](./testnet-runs/2026-10-18-v32-upgrade.md).

Live surface: Maker waterfall, Morpho yield + Carry fee share (no fixed coupon), Boosted STRATEGY tiers via `boostHook`, gasCredit + auto-refund, one-arg earlyExit / settle, SellShares mock router, DualPool idle sleeve (MockMorpho), auto-compound, v3 lender pool, $25 min, junior market $25k, senior uncapped, matchCap.  
Real Steakhouse Morpho / idle productization: issue **#20**.

## Explicitly later

- Real Morpho sleeve on Robinhood (#20)
- LONG / creator fee share into Boosted (separate from treasury cut)
- Mainnet Uniswap router (testnet mock is live)
- Mainnet 4663
