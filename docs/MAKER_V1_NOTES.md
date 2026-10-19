# Carry V1 — Maker rules + research sync

Product rules locked with Maker Lee, set next to the Oct 2 research zips
(`Carry LP Keeper Research`, `Carry Pool v1 Build Plan`). This is the living
spec for UI copy and config. On-chain testnet today is the UUPS product vault
(`version()` = **`v3.2-dualpool`**, PROXY `0x24B7…3E35`) on Robinhood Chain Testnet **46630**
(DualPool + CarryStrategy/MockMorpho wired; real Steakhouse Morpho still #20). Site: [usecarry.io](https://usecarry.io).

**Fee waterfall (source of truth):** [`MAKER_FEE_WATERFALL.md`](./MAKER_FEE_WATERFALL.md).  
**Accounting (v3):** [`ACCOUNTING_V3.md`](./ACCOUNTING_V3.md) (v2.5 history: [`ACCOUNTING_V25.md`](./ACCOUNTING_V25.md)).  
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
| Fees | Accrue raw on fee-in. **Split only** at `claimFees` / `earlyExit` / `settle` via Maker waterfall (Morpho/strategy yield + Carry fee share → treasury → senior perf → junior). See [`MAKER_FEE_WATERFALL.md`](./MAKER_FEE_WATERFALL.md). |
| Early exit | One-arg `earlyExit(id)` on v3.2 (no CoverMode chooser). |
| Position states | Only **Idle / Active / Boosted / Closed**. Open→Idle (unmatched); Settled→Closed. “Early fee due” is a frontend label only. |
| Boosted | Stake STRATEGY **before** open (MSTR market first). Cannot boost an already Active position (reopen). On-chain (`main`): the vault reads the cut from a separate `StrategyBoostHook` (reads `StrategyStaking`); live STRATEGY token wire later. Junior only; treasury cut of **fees** locks at first match (base 20%; Level I-V placeholder 17.5/16.25/13.75/10/5%). LONG creator fee share later (separate). |
| Multi-position | Extra MSTR deposit = new vault position; frontend combines into one MSTR card. |
| Caps | **$25** min deposit/match, senior pool uncapped, junior market **$25k**. **No per-wallet cap on any market** (maker, 2026-10-18). |
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
- Morpho rate: testnet stub only (Steakhouse USDG **native supply**; not Merkl). Mainnet lender return = Morpho yield (floating) + Carry's share of fees, no fixed rate (issue #20, PR #21)
- Junior/senior **targets** 5% / 12%
- Inventory band **5%**; Hyperliquid `xyz:MSTR` as off-hours reference
- Launch caps: **$25** min, senior pool uncapped, junior market **$25k**, no per-wallet cap; treasury seed ≥10% of cap (product-target)
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
| Vault | **Live UUPS PROXY** `0x24B7…3E35` / impl `v3.2-dualpool` (`0x1473…58A5`). Maker waterfall; lender pool shares; FIFO withdraw queue | Same product CA |
| Pool | DualPoolHook wired (`0xaf4a…`); fee donor still available for demos | Keeper `remark()` + mainnet DualPool |
| Morpho | CarryStrategy → MockMorpho via `deployIdle`; UI APY still Steakhouse stub | Real Steakhouse USDG sleeve (#20) |
| Ranges / recenter | Display-only | Keeper + hook on mainnet |
| Fee claim without close | `claimFees` live on PROXY; waterfall at claim/exit/settle | Same |
| Boosted | `boostHook` treasury cut of fees (live ABI); no STRATEGY yield minted yet | Live STRATEGY token + creator fee later |
| Caps | $25 min; senior uncapped; junior $25k; no per-wallet cap | No per-wallet cap on any market |
| v1 grant vault `0x72A0…` | Left on-chain; **not in use** | Archive only |

DualPool + MockMorpho are live on testnet; real Steakhouse Morpho is not (#20). Keep copy
factual: do **not** advertise a promised APY — Morpho / Carry display rates are stubs or
realized fee-pace readouts, not guarantees.

Historical research delta (many rows superseded): [`VAULT_V2_DELTA.md`](./VAULT_V2_DELTA.md).
