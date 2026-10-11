# Contracts docs index

Canonical grant / audit pack (repo root) and live product pointers:

- [`../../CARRY_CONTRACT.md`](../../CARRY_CONTRACT.md) — overview, lifecycle, function reference, security, UI mapping  
- [`../../CARRY_TESTNET.md`](../../CARRY_TESTNET.md) — Robinhood testnet **46630** deploy + UUPS upgrades  
- [`../../docs/README.md`](../../docs/README.md) — docs index (accounting, waterfall, settle watch)  
- [`../../docs/ACCOUNTING_V25.md`](../../docs/ACCOUNTING_V25.md) — live v2.5 funder-idle model  
- [`../../docs/contracts/LEVERED_LP_BUILD.md`](../../docs/contracts/LEVERED_LP_BUILD.md) — earlier build log (superseded for Carry path)  
- [`Carry-Contract-Overview.md`](./Carry-Contract-Overview.md) — printable overview (markdown)  
- [`Carry-Contract-Overview.pdf`](./Carry-Contract-Overview.pdf) — printable pack (may lag; prefer `.md` / repo-root packs)

## Live product CA

| Item | Value |
| --- | --- |
| PROXY | `0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd` |
| Implementation | `0xe498F43ED10a37E22Fe046A3FDAAFD4E9080d0e8` |
| `version()` | **`v2.5-funder-idle`** |
| Site | [usecarry.io](https://usecarry.io) |
| v1 grant reference | `0x72A053…36c8` — **not in use** |

Source of truth for behavior: `../src/LeveredLpVault.sol` (UUPS implementation behind the product PROXY).  
UI money paths use `public/config.json` → `chain.vault` (PROXY) via `public/js/carry-chain.js` / `carry-vault.js`.
