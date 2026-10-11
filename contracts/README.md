# Carry contracts (LeveredLpVault)

Forge project for Carry’s custody + accounting vault on **Robinhood Chain Testnet (46630)**.

| Item | Value |
| --- | --- |
| Vault (PROXY / product CA) | `0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd` |
| Implementation | `0xe498F43ED10a37E22Fe046A3FDAAFD4E9080d0e8` (`version()` = **`v2.5-funder-idle`**) |
| CarryBook library | `0x2988DFc48BE4AB47B40Ad151f1F213619cdB0794` |
| CarryMath library | `0x98574A1719E647775BE39Ec713B657c2CF27Adc5` |
| mockMSTR | `0x762019309B536bbb89577422FaaFBeC9659f8728` |
| mockUSDG | `0x25030Bff74764aD72b912276a603717DB1C00644` |
| v1 grant/history reference | `0x72A053120f03B10c5506d2325f92F59B0FfC36c8` (**not in use**) |
| Status | Product vault is UUPS proxy; UI money paths use `public/config.json` → `chain.vault` |

Live accounting: per-lender idle, FIFO funders, yield to position funders, $25 min, $25k market totals, no per-wallet cap, settle default IdleCarry, Boosted tiers, auto-compound, gasCredit. See [`../docs/ACCOUNTING_V25.md`](../docs/ACCOUNTING_V25.md).

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
- [`../docs/README.md`](../docs/README.md) — docs index  
- [`docs/Carry-Contract-Overview.pdf`](./docs/Carry-Contract-Overview.pdf) — printable pack (may lag markdown; prefer `.md` + repo-root packs for live truth)

**Never commit** `.deployer.key`, `.env*`, or private keys. See repo-root `.env.example` for public addresses only.
