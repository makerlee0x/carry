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
| Treasury share of fees | 20% default; Boosted STRATEGY tiers **15% / 10% / 5%** | on-chain |
| Senior perf share of gross | **40%** (Stage 1; live proxy 20% until upgraded). Order: treasury, senior, junior | on-chain |
| Senior pool / yield | One USDG pool + internal shares; yield compounds into pool | on-chain |
| Early cover order | Removed in Stage 1 (early exit costs nothing). Stage 2 principal shortfall: fees → Morpho yield on the position → backstop | on-chain |
| Maturity settle | backstop → junior idle → wallet → sell-shares → pool idle last resort | on-chain |
| Early-exit / Morpho floor (UI) | **3.9%** (`earlyExitFloorAprPct` / `morphoFloorAprPct`) | ui-display |
| Maker UI ranges | MSTR ±32%, NVDA ±8% | ui-display |
| Research ranges | ±1× five-session; 2× overnight; 3× weekend | research |
| Recenter | 7d term + 80% oracle drift from center | ui-display |
| Inventory band | 5% | product-target |
| Launch caps | Senior **uncapped** (`maxTotalSeniorUsdg=0`); junior **$25k**; **$25** min; no per-wallet cap | on-chain / ui-display |
| Treasury seed | ≥10% of cap | product-target |
| DualPool / Morpho sleeve | not on 46630; Idle USDG Morpho = config stub rate | on-chain / ui-display |
| Product CA | Fresh UUPS PROXY for **v3-lender-pool** (see `public/config.json`). v2.5 `0xc801…72bd` superseded | on-chain |

### Stale figures (do not use)

- Flat **4% early-exit coupon** and immutable **5% borrow APR** on v1 grant bytecode (`0x72A0…`) — **not** live product.
- Per-wallet **$2,500** cap — removed (`maxPerWalletUsdg=0`).
- Global pro-rata `freePrincipal` / TW yield / v2.5 per-lender `seniorIdle` + funders — replaced by **v3 lender pool**.
- Product states **Open / Settled** — UI uses **Idle / Active / Boosted / Closed**.
- Locked-per-position Morpho rate — replaced by floating `rateIndex`.

Live product CA uses Maker Morpho-rate waterfall at **3.9%** (≤5% cap). Do not advertise a promised APY.
See [`ACCOUNTING_V3.md`](./ACCOUNTING_V3.md).
