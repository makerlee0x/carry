# Carry docs index

Canonical pointers for what is **live** on Robinhood Chain Testnet **46630**.

## Live product

| Item | Value |
| --- | --- |
| Site | [usecarry.io](https://usecarry.io) (sync Vercel to latest main for v3 CA) |
| Product CA (UUPS PROXY) | [`0x24B799026AA7baa6856bCFD00c1Be1f583A83e35`](https://explorer.testnet.chain.robinhood.com/address/0x24B799026AA7baa6856bCFD00c1Be1f583A83e35) |
| Implementation | [`0x7BeED7F65A9D4aF4E67553d984800F6268a3778E`](https://explorer.testnet.chain.robinhood.com/address/0x7BeED7F65A9D4aF4E67553d984800F6268a3778E) (`version()` = **`v3-lender-pool`**) |
| Superseded v2.5 PROXY | [`0xc801…72bd`](https://explorer.testnet.chain.robinhood.com/address/0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd) — settle-watch only |
| v1 grant reference | `0x72A053…36c8` — **not in use** |
| UI config | [`../public/config.json`](../public/config.json) |

## Start here

| Doc | Role |
| --- | --- |
| [`ACCOUNTING_V3.md`](./ACCOUNTING_V3.md) | Live money-safety model: lender pool shares, withdraw queue, floating rate, cover order |
| [`SECURITY_V3.md`](./SECURITY_V3.md) | v3 security review + residual testnet risks |
| [`MAKER_REPLY_DYLAN.txt`](./MAKER_REPLY_DYLAN.txt) | Plain-text Maker update (evidence-based) |
| [`MAKER_FEE_WATERFALL.md`](./MAKER_FEE_WATERFALL.md) | Fee split at claim / earlyExit / settle |
| [`SETTLE_WATCH.md`](./SETTLE_WATCH.md) | v2.5 #5/#6/#7 settled + v3 #1/#3/#5 maturity watch |
| [`V3_MATURITY_SETTLE.md`](./V3_MATURITY_SETTLE.md) | Tonight’s v3 settle pack (times, cast, caveats) |
| [`TESTNET_CHECKLIST.md`](./TESTNET_CHECKLIST.md) | What must pass on testnet before the security pass and mainnet |
| [`GAS_CREDIT.md`](./GAS_CREDIT.md) | Gas credit (v3: refund only on match, scaled) |
| [`V1_PARAMETERS.md`](./V1_PARAMETERS.md) | Parameter table (ui-display / on-chain / research) |
| [`WORKSPACE.md`](./WORKSPACE.md) | Local workspace path for this Cursor session |
| [`ACCOUNTING_V25.md`](./ACCOUNTING_V25.md) | Historical v2.5 funder-idle model (superseded) |

## Repo-root contract packs

| Doc | Role |
| --- | --- |
| [`../CARRY_CONTRACT.md`](../CARRY_CONTRACT.md) | Grant / audit-oriented contract overview |
| [`../CARRY_TESTNET.md`](../CARRY_TESTNET.md) | Deploy + upgrade addresses on 46630 |
| [`../contracts/docs/README.md`](../contracts/docs/README.md) | Contracts docs index + printable overview |

## Historical / research (not live bytecode)

| Doc | Role |
| --- | --- |
| [`VAULT_V2_DELTA.md`](./VAULT_V2_DELTA.md) | Early research delta (many rows superseded by live UUPS v2.5) |
| [`contracts/LEVERED_LP_BUILD.md`](./contracts/LEVERED_LP_BUILD.md) | Earlier build log |
| [`SELL_SHARES_AMM.md`](./SELL_SHARES_AMM.md) | SellShares router stub notes |

**Do not** treat v1 grant vault `0x72A0…` (old 4%/5%/fee-in cut story) or abandoned proxy `0x0e4e59…` as the product CA.
