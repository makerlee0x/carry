# Carry V1 — Maker rules + research sync

Product rules locked with Maker Lee, set next to the Oct 2 research zips
(`Carry LP Keeper Research`, `Carry Pool v1 Build Plan`). This is the living
spec for UI copy and config. On-chain testnet today is the UUPS product vault
(`version()` = **`v2.5-funder-idle`**) on Robinhood Chain Testnet **46630**
(no DualPool, no Morpho sleeve). Site: [usecarry.io](https://usecarry.io).

**Fee waterfall (source of truth):** [`MAKER_FEE_WATERFALL.md`](./MAKER_FEE_WATERFALL.md).  
**Accounting (v2.5):** [`ACCOUNTING_V25.md`](./ACCOUNTING_V25.md).  
Those docs supersede older claimFees / flat 4%-pace / protocol-cut-on-fee-in /
global freePrincipal product stories.

---

## Maker-locked product rules

| Topic | Rule |
| --- | --- |
| USDG yield story | Show **Morpho APY** (Steakhouse **native supply**, not Merkl) and **Carry APY** for USDG. Morpho is day-1 critical in product copy. Testnet Idle USDG Morpho = **APY stub** from config until a real sleeve ships. |
| Ranges | **Not user-set.** Market-specific from historical backtest. UI: **MSTR ±32%**, **NVDA ±8%**. |
| Recenter | After **7 days**, and sooner if oracle drifts **80%** from range center. |
| Term / rollover | 7-day active window; position rolls over to recenter. Auto-rollover / compound is product intent; wire when vault supports it. |
| Fees | Accrue raw on fee-in. **Split only** at `claimFees` / `earlyExit` / `settle` via Maker waterfall (senior Morpho accrual floor → treasury → senior perf → junior). See [`MAKER_FEE_WATERFALL.md`](./MAKER_FEE_WATERFALL.md). |
| Early cover | User chooses; default **wallet USDG → Idle USDG on Carry → sell from position**. |
| Position states | Only **Idle / Active / Boosted / Closed**. Open→Idle (unmatched); Settled→Closed. “Early fee due” is a frontend label only. |
| Boosted | Stake STRATEGY **before** open (MSTR market first). Cannot boost an already Active position (reopen). On-chain: owner `setBoostStakeAmount` / `setBoostTiers` stub; live STRATEGY token wire later. Junior only; treasury cut of **fees** locks at first match (base 20%; tiers 15/10/5%). LONG creator fee share later (separate). |
| Multi-position | Extra MSTR deposit = new vault position; frontend combines into one MSTR card. |
| Caps | Day-1: **$25k** market totals senior/junior, **$25** min deposit/match, **no per-wallet cap** (`maxPerWalletUsdg=0`). Older research $2.5k/wallet is **not** live. |
| Treasury | Base **20% of fees** at split and on shortfall cover. Boosted tiers reduce cut. Target ≥ **10%** of book/cap (Vault v2 / option B). |
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
- Morpho rate stub ~**3.9%** (Steakhouse USDG **native supply** APY; not Merkl)
- Junior/senior **targets** 5% / 12%
- Inventory band **5%**; Hyperliquid `xyz:MSTR` as off-hours reference
- Launch caps **$25k** total senior/junior, **$25** min, **no per-wallet cap** on live UUPS; treasury seed ≥10% of cap (product-target)
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
| Vault | **Live UUPS PROXY** `0xc801…72bd` / impl `v2.5-funder-idle` (`0xe498…d0e8`). Maker waterfall; per-lender idle; FIFO funders; settle default IdleCarry | Same product CA path; DualPool later |
| Pool | Fee donor / inventory held in vault | DualPool hook + keeper `remark()` |
| Morpho | UI + on-chain rate stub (Steakhouse native supply figure); no ERC-4626 sleeve | Steakhouse USDG sleeve on matched/idle USDG |
| Ranges / recenter | Display-only | Keeper + hook on mainnet |
| Fee claim without close | `claimFees` live on PROXY; waterfall at claim/exit/settle | Same |
| Boosted | On-chain stake tiers (treasury cut of fees); no STRATEGY yield minted | Live STRATEGY token + creator fee later |
| Caps | $25 min; $25k totals; no per-wallet cap | May reintroduce wallet caps later if Maker wants |
| v1 grant vault `0x72A0…` | Left on-chain; **not in use** | Archive only |

Do **not** imply DualPool or Morpho sleeves are executing on testnet. The site already
shows a testnet banner; keep copy factual and short. Do **not** advertise a promised APY —
Morpho / Carry display rates are stubs or realized fee-pace readouts, not guarantees.

Historical research delta (many rows superseded): [`VAULT_V2_DELTA.md`](./VAULT_V2_DELTA.md).
