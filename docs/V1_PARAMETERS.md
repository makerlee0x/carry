# Carry V1 parameters

Machine-readable source: [`contracts/config/mainnet.json`](../contracts/config/mainnet.json).  
UI mirror: `product` in [`public/config.json`](../public/config.json).  
Product narrative: [`MAKER_V1_NOTES.md`](./MAKER_V1_NOTES.md).

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
| Morpho APY (display) | 3.9% | ui-display |
| Junior / senior targets | 5% / 12% | ui-display |
| Early-exit / claim floor | 4% | on-chain + ui-display |
| Maker UI ranges | MSTR ±32%, NVDA ±8% | ui-display |
| Research ranges | ±1× five-session; 2× overnight; 3× weekend | research |
| Recenter | 7d term + 80% oracle drift from center | ui-display |
| Inventory band | 5% | product-target |
| Launch caps | $25k total / $2.5k per wallet | ui-display |
| Treasury seed | ≥10% of cap | product-target |
| Testnet borrow APR | 5% (immutable on deployed vault) | on-chain |
| DualPool / Morpho sleeve | not on 46630 | on-chain |
