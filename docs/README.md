# Carry docs index

Canonical pointers for what is **live** on Robinhood Chain Testnet **46630**.

## Live product

| Item | Value |
| --- | --- |
| Site | [usecarry.io](https://usecarry.io) |
| Product CA (UUPS PROXY) | [`0x24B799026AA7baa6856bCFD00c1Be1f583A83e35`](https://explorer.testnet.chain.robinhood.com/address/0x24B799026AA7baa6856bCFD00c1Be1f583A83e35) |
| Implementation | [`0x14732623B077C656527ee5C87812AC23e98c58A5`](https://explorer.testnet.chain.robinhood.com/address/0x14732623B077C656527ee5C87812AC23e98c58A5) (`version()` = **`v3.2-dualpool`**) |
| CarryStrategy | `0x43ec7Ba95FecEBE51B6414f6E300B109E245E6AE` |
| DualPoolHook | `0xaf4a9225b27e48c9989726082014095474756ac0` |
| Superseded v2.5 PROXY | [`0xc801…72bd`](https://explorer.testnet.chain.robinhood.com/address/0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd) — wind-down (settled) |
| v1 grant reference | `0x72A053…36c8` — **not in use** |
| Upgrade record | [`testnet-runs/2026-10-18-v32-upgrade.md`](./testnet-runs/2026-10-18-v32-upgrade.md) |
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
| [`testnet-runs/`](./testnet-runs/) | Dated on-chain test passes against the live v3 PROXY |
| [`WORKSPACE.md`](./WORKSPACE.md) | Local workspace path for this Cursor session |
| [`ACCOUNTING_V25.md`](./ACCOUNTING_V25.md) | Historical v2.5 funder-idle model (superseded) |
| [`SECURITY_V2.md`](./SECURITY_V2.md) | Historical v2.x security notes (superseded by `SECURITY_V3.md`) |

## Repo-root contract packs

| Doc | Role |
| --- | --- |
| [`../CARRY_CONTRACT.md`](../CARRY_CONTRACT.md) | Grant / audit-oriented contract overview |
| [`../CARRY_TESTNET.md`](../CARRY_TESTNET.md) | Deploy + upgrade addresses on 46630 |
| [`../contracts/docs/README.md`](../contracts/docs/README.md) | Contracts docs index + printable overview |

## Historical / research (not live bytecode)

| Doc | Role |
| --- | --- |
| [`VAULT_V2_DELTA.md`](./VAULT_V2_DELTA.md) | Early research delta (superseded by v2.5, then v3) |
| [`contracts/LEVERED_LP_BUILD.md`](./contracts/LEVERED_LP_BUILD.md) | Earlier build log |
| [`SELL_SHARES_AMM.md`](./SELL_SHARES_AMM.md) | SellShares router stub notes |

Lender rate: the Morpho rate in these docs is a testnet stub, not a promised APY. The mainnet lender return is being reworked to Morpho yield + Carry's share of fees with no fixed rate (issue #20, PR #21).

**Do not** treat v1 grant vault `0x72A0…` (old 4%/5%/fee-in cut story) or abandoned proxy `0x0e4e59…` as the product CA.
