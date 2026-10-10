# Settle watch — live matched position (do not early-exit)

Live 7-day **fully matched / Active** position on the product vault for end-of-term `settle` testing.

**Do not call `earlyExit` or `settle` until after maturity.** Leave open for the full term.

| Field | Value |
| --- | --- |
| Network | Robinhood Chain Testnet **46630** |
| Vault PROXY (product CA) | [`0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd`](https://explorer.testnet.chain.robinhood.com/address/0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd) |
| Implementation | [`0xC9C8d0741ce25cf46a8989f58AeC74dD8e0F1240`](https://explorer.testnet.chain.robinhood.com/address/0xC9C8d0741ce25cf46a8989f58AeC74dD8e0F1240) (`version` = `v2.2-maker-answers`) |
| **positionId** | **5** |
| State | Active (`isMatched` + `isFullyMatched` = true; `settled` = false) |
| Junior wallet (owner) | [`0xcA44F2dbB2D43b93b39F01B88E0f0e2966983c57`](https://explorer.testnet.chain.robinhood.com/address/0xcA44F2dbB2D43b93b39F01B88E0f0e2966983c57) |
| Senior wallet (lender) | same deployer address (pool senior) |
| Junior amount (MSTR) | `1e18` (1 mMSTR) |
| Senior principal (USDG) | `100e18` (100 mUSDG) — full match at oracle `$100` |
| **Gross LP fees on position** | `1e18` (1 mUSDG) — raw fee-in, no cut until settle |
| `term` | `604800` (7 days) |
| `morphoRateWad` (global) | `0.039e18` (3.9%) |
| `morphoRateLocked` on #5 | `0` (opened before rate-lock upgrade → uses live `morphoRateWad`) |
| `matchedAt` / `openedAt` | `1791603471` → **2026-10-10 03:37:51 UTC** |
| **Expected settle after** | `1792208271` → **2026-10-17 03:37:51 UTC** |

### Upgrade impact on #5 (v2.2)

Storage-additive UUPS upgrade keeps the same PROXY CA and position #5 state.

- Fees on #5 (`1e18`) **≫** 7-day Morpho accrual on `100e18` @ 3.9% (~`0.075e18`), so maturity settle should **not** need backstop or SellShares cover.
- Junior keeps MSTR; waterfall pays senior floor/perf from fees; treasury cut → backstop.
- New settle SellShares path exists for **other** shortfall positions; #5 should remain a clean fee-covered settle.

### Tx links

| Step | Tx |
| --- | --- |
| mint MSTR | [`0x175899e51dcc9eda58439e0d0d39a7bbb5a75640bcfafd26f5f6e953ba97fea6`](https://explorer.testnet.chain.robinhood.com/tx/0x175899e51dcc9eda58439e0d0d39a7bbb5a75640bcfafd26f5f6e953ba97fea6) |
| mint USDG | [`0xba1d3fdb06fd586bd973f6ec63d99c6d378b87b34795c917d10f3d9b7c3a7101`](https://explorer.testnet.chain.robinhood.com/tx/0xba1d3fdb06fd586bd973f6ec63d99c6d378b87b34795c917d10f3d9b7c3a7101) |
| approve MSTR | [`0x5feaac693b1b174293a5b043c8cdd0a2037e617a611a9247f979e22c5d1828c6`](https://explorer.testnet.chain.robinhood.com/tx/0x5feaac693b1b174293a5b043c8cdd0a2037e617a611a9247f979e22c5d1828c6) |
| approve USDG | [`0xfa0952e7b25e885391c767dfd22a4d089b27ce07af7f3469d63ee820503ddfa4`](https://explorer.testnet.chain.robinhood.com/tx/0xfa0952e7b25e885391c767dfd22a4d089b27ce07af7f3469d63ee820503ddfa4) |
| `depositSenior(100e18)` | [`0x97a42865623d02909ad823beee44b9e7a6216edf00aecd560c27f7c5a71022da`](https://explorer.testnet.chain.robinhood.com/tx/0x97a42865623d02909ad823beee44b9e7a6216edf00aecd560c27f7c5a71022da) |
| `depositJunior(1e18)` → position **5** | [`0x8834b69b4631da3ceded13c1472591388a0af1c63606f96edd13869fa61b422a`](https://explorer.testnet.chain.robinhood.com/tx/0x8834b69b4631da3ceded13c1472591388a0af1c63606f96edd13869fa61b422a) |
| UUPS upgrade → `v2.1-maker-fixes` | [`0xb77cef0aa5584ba850c3f02e05d1845280caf20e6e90880376a7235c6398434a`](https://explorer.testnet.chain.robinhood.com/tx/0xb77cef0aa5584ba850c3f02e05d1845280caf20e6e90880376a7235c6398434a) |
| `setDepositCaps($25k/$2.5k)` | [`0x8a92de75abfc410a6c0948bc0f64008790637173094d34aff9cf6e122f6c3fa6`](https://explorer.testnet.chain.robinhood.com/tx/0x8a92de75abfc410a6c0948bc0f64008790637173094d34aff9cf6e122f6c3fa6) |
| `payFee` 1 mUSDG onto #5 | [`0x010f29cd78e9f739915c021500fcdbd8bd11a55d63f4b95884878f39df1dedac`](https://explorer.testnet.chain.robinhood.com/tx/0x010f29cd78e9f739915c021500fcdbd8bd11a55d63f4b95884878f39df1dedac) |
| Deploy impl `v2.2-maker-answers` | [`0x02729db8c05a5e531e14785a1614dc6d7031da85cf81d2c622ba3ad3dbca214d`](https://explorer.testnet.chain.robinhood.com/tx/0x02729db8c05a5e531e14785a1614dc6d7031da85cf81d2c622ba3ad3dbca214d) |
| UUPS upgrade → `v2.2-maker-answers` | [`0xa48ed0624be35cc6ab445ecc0cc70ac47c570677e5113697d884c4ed22b9fa25`](https://explorer.testnet.chain.robinhood.com/tx/0xa48ed0624be35cc6ab445ecc0cc70ac47c570677e5113697d884c4ed22b9fa25) |

### After maturity

Anyone may call `settle(5)` (default SellShares for any residual after backstop) once `block.timestamp >= openedAt + term`. With current fees on #5, residual cover should be zero — junior keeps all MSTR; waterfall runs on the 1 mUSDG fee. Until maturity, `TermNotElapsed` is expected.
