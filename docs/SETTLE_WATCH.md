# Settle watch — live matched position (do not early-exit)

Live 7-day **fully matched / Active** position on the product vault for end-of-term `settle` testing.

**Do not call `earlyExit` or `settle` until after maturity.** Leave open for the full term.

| Field | Value |
| --- | --- |
| Network | Robinhood Chain Testnet **46630** |
| Vault PROXY (product CA) | [`0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd`](https://explorer.testnet.chain.robinhood.com/address/0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd) |
| **positionId** | **5** |
| State | Active (`isMatched` + `isFullyMatched` = true; `settled` = false) |
| Junior wallet (owner) | [`0xcA44F2dbB2D43b93b39F01B88E0f0e2966983c57`](https://explorer.testnet.chain.robinhood.com/address/0xcA44F2dbB2D43b93b39F01B88E0f0e2966983c57) |
| Senior wallet (lender) | same deployer address (pool senior) |
| Junior amount (MSTR) | `1e18` (1 mMSTR) |
| Senior principal (USDG) | `100e18` (100 mUSDG) — full match at oracle `$100` |
| `term` | `604800` (7 days) |
| `morphoRateWad` | `0.039e18` (3.9%) |
| `matchedAt` / `openedAt` | `1791603471` → **2026-10-10 03:37:51 UTC** |
| **Expected settle after** | `1792208271` → **2026-10-17 03:37:51 UTC** |

### Tx links

| Step | Tx |
| --- | --- |
| mint MSTR | [`0x175899e51dcc9eda58439e0d0d39a7bbb5a75640bcfafd26f5f6e953ba97fea6`](https://explorer.testnet.chain.robinhood.com/tx/0x175899e51dcc9eda58439e0d0d39a7bbb5a75640bcfafd26f5f6e953ba97fea6) |
| mint USDG | [`0xba1d3fdb06fd586bd973f6ec63d99c6d378b87b34795c917d10f3d9b7c3a7101`](https://explorer.testnet.chain.robinhood.com/tx/0xba1d3fdb06fd586bd973f6ec63d99c6d378b87b34795c917d10f3d9b7c3a7101) |
| approve MSTR | [`0x5feaac693b1b174293a5b043c8cdd0a2037e617a611a9247f979e22c5d1828c6`](https://explorer.testnet.chain.robinhood.com/tx/0x5feaac693b1b174293a5b043c8cdd0a2037e617a611a9247f979e22c5d1828c6) |
| approve USDG | [`0xfa0952e7b25e885391c767dfd22a4d089b27ce07af7f3469d63ee820503ddfa4`](https://explorer.testnet.chain.robinhood.com/tx/0xfa0952e7b25e885391c767dfd22a4d089b27ce07af7f3469d63ee820503ddfa4) |
| `depositSenior(100e18)` | [`0x97a42865623d02909ad823beee44b9e7a6216edf00aecd560c27f7c5a71022da`](https://explorer.testnet.chain.robinhood.com/tx/0x97a42865623d02909ad823beee44b9e7a6216edf00aecd560c27f7c5a71022da) |
| `depositJunior(1e18)` → position **5** | [`0x8834b69b4631da3ceded13c1472591388a0af1c63606f96edd13869fa61b422a`](https://explorer.testnet.chain.robinhood.com/tx/0x8834b69b4631da3ceded13c1472591388a0af1c63606f96edd13869fa61b422a) |

### After maturity

Anyone may call `settle(5)` once `block.timestamp >= openedAt + term`. Proceeds go to junior + senior accounting — not the caller. Until then, `TermNotElapsed` is expected.
