# Carry V1 parameters

Machine-readable source: [`contracts/config/mainnet.json`](../contracts/config/mainnet.json).  
UI mirror: `product` in [`public/config.json`](../public/config.json).  
Product narrative: [`MAKER_V1_NOTES.md`](./MAKER_V1_NOTES.md).  
**Fee waterfall (source of truth):** [`MAKER_FEE_WATERFALL.md`](./MAKER_FEE_WATERFALL.md).

Layers:

- **ui-display** — shown in the app; not necessarily enforced on-chain
- **product-target** — research / Vault v2 / DualPool intent
- **on-chain** — true of the current testnet vault
- **research** — session-vol bands from the keeper report (conflicts with Maker UI ranges)

| Parameter | Value | Layer |
| --- | --- | --- |
| Hours | 24/7 | product-target |
| Base fee | 0.20% (limits 0.10–0.30%) | product-target |
| Surcharge cap | 3% | product-target |
| Dead bands | 0.25 / 0.45 / 0.45 / 0.60 / 1.00% | product-target |
| Morpho rate (Steakhouse native supply) | Floating, whatever the vault pays (Stage 1; no stored rate). Live proxy: 3.9% stub until upgraded | on-chain / ui-display |
| Junior / senior targets | 5% / 12% | ui-display |
| Fee split timing | claimFees / earlyExit / settle only | on-chain |
| Unpaid senior accrual | Removed in Stage 1 (nothing is owed beyond fees) | on-chain |
| Treasury share of fees | 20% default; Boosted Level I-V via `StrategyBoostHook` (placeholder **17.5 / 16.25 / 13.75 / 10 / 5%**), capped at base | on-chain (main; not yet on testnet impl) |
| Senior perf share of gross | **40%** (Stage 1; live proxy 20% until upgraded). Order: treasury, senior, junior | on-chain |
| Senior pool / yield | One USDG pool + internal shares; yield compounds into pool | on-chain |
| Early cover order | Removed in Stage 1 (early exit costs nothing). Stage 2 principal shortfall: fees → Morpho yield on the position → backstop | on-chain |
| Maturity settle | Stage 1: no cover needed (fees split, MSTR returned). Live proxy: backstop → junior idle → wallet → sell-shares until upgraded | on-chain |
| Early-exit / Morpho floor (UI) | Mirrors the testnet stub (`earlyExitFloorAprPct` / `morphoFloorAprPct`); goes away with the no-fixed-rate rework | ui-display |
| Maker UI ranges | MSTR ±32%, NVDA ±8% | ui-display |
| Research ranges | ±1× five-session; 2× overnight; 3× weekend | research |
| Recenter | 7d term + 80% oracle drift from center | ui-display |
| Term | 7d; on `main` positions roll at term until the junior settles; one more than 32% below entry stops rolling and anyone can settle it after a 48h grace | on-chain (main; not yet on testnet impl) |
| Inventory band | 5% | product-target |
| Launch caps | Senior **uncapped** (`maxTotalSeniorUsdg=0`); junior **$25k**; **$25** min | on-chain / ui-display |
| Per-wallet cap | **None, on any market** (maker, 2026-10-18) | product decision |
| Treasury seed | ≥10% of cap | product-target |
| DualPool / Morpho sleeve | not on 46630; Idle USDG Morpho = config stub rate | on-chain / ui-display |
| Product CA | Fresh UUPS PROXY for **v3-lender-pool** (see `public/config.json`). v2.5 `0xc801…72bd` superseded | on-chain |

### Stale figures (do not use)

- Flat **4% early-exit coupon** and immutable **5% borrow APR** on v1 grant bytecode (`0x72A0…`) — **not** live product.
- Any per-wallet cap (older research had $2,500) — dropped; there is no per-wallet cap.
- Boost tiers **15 / 10 / 5%** set by owner on the vault — replaced by `StrategyBoostHook` Level I-V.
- "Interest stops at maturity" — replaced on `main` by rolling positions.
- Global pro-rata `freePrincipal` / TW yield / v2.5 per-lender `seniorIdle` + funders — replaced by **v3 lender pool**.
- Product states **Open / Settled** — UI uses **Idle / Active / Boosted / Closed**.
- Locked-per-position Morpho rate — replaced by floating `rateIndex`.

The live testnet CA runs the Maker Morpho-rate waterfall on a stub rate (≤5% cap). Do not advertise a promised APY.
See [`ACCOUNTING_V3.md`](./ACCOUNTING_V3.md).
