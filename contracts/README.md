# Carry contracts (LeveredLpVault)

Forge project for Carry’s custody + accounting vault on **Robinhood Chain Testnet (46630)**.

| Item | Value |
| --- | --- |
| Vault (PROXY / product CA) | `0x24B799026AA7baa6856bCFD00c1Be1f583A83e35` |
| Implementation | `0x7BeED7F65A9D4aF4E67553d984800F6268a3778E` (`version()` = **`v3-lender-pool`**) |
| Libraries (CarryMath / CarryPool / CarryCover) | `0x86b2…9344` / `0xf1d5…dc07` / `0x99f1…1ebd` |
| mockMSTR | `0x762019309B536bbb89577422FaaFBeC9659f8728` |
| mockUSDG | `0x25030Bff74764aD72b912276a603717DB1C00644` |
| v2.5 PROXY (superseded, history only) | `0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd` |
| v1 grant/history reference | `0x72A053120f03B10c5506d2325f92F59B0FfC36c8` (**not in use**) |
| Status | Product vault is UUPS proxy; UI money paths use `public/config.json` → `chain.vault` |

Live accounting: one lender pool with internal shares (instant withdraw or FIFO queue + `claimWithdraw`), floating rate index on a testnet stub rate, Maker waterfall, $25 min, senior pool uncapped, junior market $25k, no per-wallet cap, settle default IdleCarry, auto-compound, gasCredit. See [`../docs/ACCOUNTING_V3.md`](../docs/ACCOUNTING_V3.md).

Source on `main` is ahead of the live impl: EIP-170 fit (#3, runtime ~23.4KB), rolling positions (#16) and `StrategyBoostHook` (#23, `src/StrategyBoostHook.sol`). Not yet upgraded on testnet.

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
- [`docs/Carry-Contract-Overview.md`](./docs/Carry-Contract-Overview.md) — printable overview (`.html` / `.pdf` rendered from it)

**Never commit** `.deployer.key`, `.env*`, or private keys. See repo-root `.env.example` for public addresses only.
