# Carry contracts (LeveredLpVault)

Forge project for Carry’s custody + accounting vault on **Robinhood Chain Testnet (46630)**.

| Item | Value |
| --- | --- |
| Vault | `0x72A053120f03B10c5506d2325f92F59B0FfC36c8` |
| mockMSTR | `0x762019309B536bbb89577422FaaFBeC9659f8728` |
| mockUSDG | `0x25030Bff74764aD72b912276a603717DB1C00644` |
| Status | Deployed **paused**; owner must `unpause()` before deposits |

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
