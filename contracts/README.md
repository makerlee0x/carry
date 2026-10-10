# Carry contracts (LeveredLpVault)

Forge project for Carry’s custody + accounting vault on **Robinhood Chain Testnet (46630)**.

| Item | Value |
| --- | --- |
| Vault (PROXY / product CA) | `0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd` |
| Implementation | `0xe8a8406d860aCd8c348377D5342bCAcD5770D84b` |
| mockMSTR | `0x762019309B536bbb89577422FaaFBeC9659f8728` |
| mockUSDG | `0x25030Bff74764aD72b912276a603717DB1C00644` |
| v1 grant/history reference | `0x72A053120f03B10c5506d2325f92F59B0FfC36c8` |
| Status | Product vault is UUPS proxy; UI money paths use `public/config.json` → `chain.vault` |

## Setup

```bash
# Foundry: https://book.getfoundry.sh/getting-started/installation
git submodule update --init --recursive
cd contracts
forge test
```

## Docs

- [`../CARRY_CONTRACT.md`](../CARRY_CONTRACT.md) — product + security reference  
- [`../CARRY_TESTNET.md`](../CARRY_TESTNET.md) — deploy notes + addresses  
- [`docs/Carry-Contract-Overview.pdf`](./docs/Carry-Contract-Overview.pdf) — printable pack  

**Never commit** `.deployer.key`, `.env*`, or private keys. See repo-root `.env.example` for public addresses only.
