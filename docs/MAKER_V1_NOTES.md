# Carry V1 — Maker rules + research sync

Product rules locked with Maker Lee, set next to the Oct 2 research zips
(`Carry LP Keeper Research`, `Carry Pool v1 Build Plan`). This is the living
spec for UI copy and config. On-chain testnet today is still `LeveredLpVault`
on Robinhood Chain Testnet **46630** (no DualPool, no Morpho sleeve).

---

## Maker-locked product rules

| Topic | Rule |
| --- | --- |
| USDG yield story | Show **Morpho APY** and **Carry APY** for USDG (Morpho + Carry weighted). Morpho is day-1 critical in product copy. |
| Ranges | **Not user-set.** Market-specific from historical backtest. UI: **MSTR ±32%**, **NVDA ±8%**. |
| Recenter | After **7 days**, and sooner if oracle drifts **80%** from range center. |
| Term / rollover | 7-day active window; position rolls over to recenter. Auto-rollover / compound is product intent; wire when vault supports it. |
| Fees | **Compound or claim.** Claim when accrued fees hit the **4%** pace threshold; claim pays a claim fee and does **not** require a full close. |
| Multi-position | Extra MSTR deposit = new vault position; frontend combines into one MSTR card. |
| Caps | Day-1 TVL / per-wallet caps (research: launch ~$25k total / ~$2.5k per wallet). |
| Treasury | Protocol cut ~20% of fees; treasury target ≥ **10%** of book/cap (Vault v2 / option B). |
| Keeper | Maintainer-operated bot first; permissionless later. |
| Chain | Robinhood Chain. Testnet pack is **46630**; research DualPool path targets mainnet **4663**. |

---

## Research numbers (config source of truth)

Concrete values from the zips live in [`contracts/config/mainnet.json`](../contracts/config/mainnet.json)
and are mirrored under `product` in [`public/config.json`](../public/config.json).
Human-readable table: [`V1_PARAMETERS.md`](./V1_PARAMETERS.md).
Highlights:

- Base fee **0.20%** (Safe limits 0.10–0.30%); surcharge cap **3%**
- Dead bands (literal): regular 0.25%, pre/post 0.45%, overnight 0.60%, weekend 1.00%
- Morpho floor ~**3.9%** (Steakhouse USDG); junior/senior **targets** 5% / 12%
- Inventory band **5%**; Hyperliquid `xyz:MSTR` as off-hours reference
- Launch caps **$25k** total / **$2.5k** per wallet; treasury seed ≥10% of cap
- Research range bands: ±1× five-session expected move (wider overnight/weekend)

Label in config whether each value is **UI display**, **product target**, or **on-chain today**.

---

## Range conflict (explicit)

| Source | MSTR | NVDA / other |
| --- | --- | --- |
| **Maker (locked for UI)** | ±32% | ±8% |
| **Research (session-vol)** | ±1× five-session move (~±10% at 70% vol); 2× overnight; 3× weekend. Weekend/surge near ±32% is a stress case, not the default regular band. | Same framework per market once backtested |

**Until Maker picks:** UI and product copy follow Maker ±32% / ±8%. Research
session bands stay in config under `product.researchRanges` for keeper/DualPool work.

---

## What is live on testnet vs product intent

| Piece | Testnet 46630 today | Product intent |
| --- | --- | --- |
| Vault | `LeveredLpVault` custody + 7d term + 4% early-exit coupon | Vault v2 option B (share floor, Morpho-rate senior floor, treasury) |
| Pool | Fee donor / inventory held in vault | DualPool hook + keeper `remark()` |
| Morpho | UI display rates from config | Steakhouse USDG sleeve on matched USDG |
| Ranges / recenter | Display-only | Keeper + hook on mainnet |
| Fee claim without close | Demo UX until `claimFees` lands on vault | Claim at 4% threshold + claim fee |

Do **not** imply DualPool or Morpho are executing on testnet. The site already
shows a testnet banner; keep copy factual and short.

Vault v2 / option B delta vs today’s contract: [`VAULT_V2_DELTA.md`](./VAULT_V2_DELTA.md).
