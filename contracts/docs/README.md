# Contracts docs index

Canonical grant / audit pack (repo root):

- [`../../CARRY_CONTRACT.md`](../../CARRY_CONTRACT.md) — overview, lifecycle, function reference, security, UI mapping  
- [`../../CARRY_TESTNET.md`](../../CARRY_TESTNET.md) — Robinhood testnet **46630** deploy only  
- [`../../docs/contracts/LEVERED_LP_BUILD.md`](../../docs/contracts/LEVERED_LP_BUILD.md) — earlier build log (superseded for Carry path)  
- [`Carry-Contract-Overview.pdf`](./Carry-Contract-Overview.pdf) — printable pack for review

Source of truth for behavior: `../src/LeveredLpVault.sol` (UUPS implementation behind the product PROXY).  
UI money paths use `public/config.json` → `chain.vault` (PROXY) via `public/js/carry-chain.js` / `carry-vault.js`.  
v1 `0x72A053…` is grant/history reference only — not the product CA.
