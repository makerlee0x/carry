# Carry docs index

Canonical pointers for what is **live** on Robinhood Chain Testnet **46630**.

## Live product

| Item | Value |
| --- | --- |
| Site | [usecarry.io](https://usecarry.io) |
| Product CA (UUPS PROXY) | [`0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd`](https://explorer.testnet.chain.robinhood.com/address/0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd) |
| Implementation | [`0xe498F43ED10a37E22Fe046A3FDAAFD4E9080d0e8`](https://explorer.testnet.chain.robinhood.com/address/0xe498F43ED10a37E22Fe046A3FDAAFD4E9080d0e8) (`version()` = **`v2.5-funder-idle`**) |
| v1 grant reference | `0x72A053…36c8` — **not in use** |
| UI config | [`../public/config.json`](../public/config.json) |

## Start here

| Doc | Role |
| --- | --- |
| [`ACCOUNTING_V25.md`](./ACCOUNTING_V25.md) | Live money-safety model: per-lender idle, FIFO funders, yield to position funders, caps, tiers |
| [`MAKER_FEE_WATERFALL.md`](./MAKER_FEE_WATERFALL.md) | Fee split at claim / earlyExit / settle |
| [`SECURITY_V2.md`](./SECURITY_V2.md) | Security notes for the UUPS product vault |
| [`SETTLE_WATCH.md`](./SETTLE_WATCH.md) | Live Active positions (#5 / #6 / #7) — do not early-exit before maturity; multi-lender idle fix |
| [`GAS_CREDIT.md`](./GAS_CREDIT.md) | Junior open-queue `gasCredit` ETH escrow |
| [`MAKER_V1_NOTES.md`](./MAKER_V1_NOTES.md) | Maker product rules + live vs intent |
| [`V1_PARAMETERS.md`](./V1_PARAMETERS.md) | Parameter table (ui-display / on-chain / research) |

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
