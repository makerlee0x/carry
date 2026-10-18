# Contracts docs index

Canonical grant / audit pack (repo root) and live product pointers:

- [`../../CARRY_CONTRACT.md`](../../CARRY_CONTRACT.md) — overview, lifecycle, function reference, security, UI mapping  
- [`../../CARRY_TESTNET.md`](../../CARRY_TESTNET.md) — Robinhood testnet **46630** deploy + UUPS upgrades  
- [`../../docs/README.md`](../../docs/README.md) — docs index (accounting, waterfall, settle watch)  
- [`../../docs/ACCOUNTING_V3.md`](../../docs/ACCOUNTING_V3.md) — live v3 lender-pool model  
- [`../../docs/ACCOUNTING_V25.md`](../../docs/ACCOUNTING_V25.md) — superseded v2.5 funder-idle model  
- [`../../docs/contracts/LEVERED_LP_BUILD.md`](../../docs/contracts/LEVERED_LP_BUILD.md) — earlier build log (superseded for Carry path)  
- [`Carry-Contract-Overview.md`](./Carry-Contract-Overview.md) — printable overview (markdown)  
- [`Carry-Contract-Overview.pdf`](./Carry-Contract-Overview.pdf) / [`.html`](./Carry-Contract-Overview.html) — printable pack rendered from the markdown

## Live product CA

| Item | Value |
| --- | --- |
| PROXY | `0x24B799026AA7baa6856bCFD00c1Be1f583A83e35` |
| Implementation | `0x7BeED7F65A9D4aF4E67553d984800F6268a3778E` |
| `version()` | **`v3-lender-pool`** |
| Source on `main` | Ahead of the live impl (#3, #16, #23, #21); not yet upgraded |
| Superseded v2.5 PROXY | `0xc801…72bd` — history only |
| Site | [usecarry.io](https://usecarry.io) |
| v1 grant reference | `0x72A053…36c8` — **not in use** |

Source of truth for behavior: `../src/LeveredLpVault.sol` (UUPS implementation behind the product PROXY).  
UI money paths use `public/config.json` → `chain.vault` (PROXY) via `public/js/carry-chain.js` / `carry-vault.js`.
