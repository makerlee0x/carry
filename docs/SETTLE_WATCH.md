# Settle watch — live matched position (do not early-exit)

Live 7-day **fully matched / Active** position on the product vault for end-of-term `settle` testing.

**Do not call `earlyExit` or `settle` until after maturity.** Leave open for the full term.

| Field | Value |
| --- | --- |
| Network | Robinhood Chain Testnet **46630** |
| Vault PROXY (product CA) | [`0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd`](https://explorer.testnet.chain.robinhood.com/address/0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd) |
| Implementation | [`0x09D2371be36b4910968f675d005e04825dCB74d6`](https://explorer.testnet.chain.robinhood.com/address/0x09D2371be36b4910968f675d005e04825dCB74d6) (`version` = `v2.4-maker-leftovers`) |
| CarryMath library | [`0x98574A1719E647775BE39Ec713B657c2CF27Adc5`](https://explorer.testnet.chain.robinhood.com/address/0x98574A1719E647775BE39Ec713B657c2CF27Adc5) |
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

### Upgrade impact on #5 (v2.4)

Storage-additive UUPS upgrade keeps the same PROXY CA and position #5 state.

- Fees on #5 (`1e18`) **≫** 7-day Morpho accrual on `100e18` @ 3.9% (~`0.075e18`), so maturity settle should **not** need backstop or junior cover.
- Junior keeps MSTR; waterfall pays senior floor/perf from fees; base treasury cut 20% → backstop (Boosted 10% only if position.boosted).
- v2.4 adds Boosted reduced cut, gasCredit auto-refund, early-exit cover revert, SellShares router stub, auto-compound; does **not** early-exit or settle #5.
- Post-upgrade check: still fully matched; feeUsdg `1e18`; settled=false.
- Do **not** call `earlyExit(5)` or `settle(5)` before **2026-10-17 03:37:51 UTC**.

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
| Deploy impl `v2.3-maker-clarifications` | [`0xa9c09925f1d51291115e7f7493e27ead6b358176822a904de8c2fbedd7f498d2`](https://explorer.testnet.chain.robinhood.com/tx/0xa9c09925f1d51291115e7f7493e27ead6b358176822a904de8c2fbedd7f498d2) |
| UUPS upgrade → `v2.3-maker-clarifications` | [`0x4de1bf90b5b3842d45b51f29f0cf494d388c3f3a6b72db6fc232f7d376a861d9`](https://explorer.testnet.chain.robinhood.com/tx/0x4de1bf90b5b3842d45b51f29f0cf494d388c3f3a6b72db6fc232f7d376a861d9) |
| Deploy CarryMath (v2.4) | [`0x8ad42eada5ecdb4d7be4c5c48f3d642808d75bb08b64bfb203ac3f704c869435`](https://explorer.testnet.chain.robinhood.com/tx/0x8ad42eada5ecdb4d7be4c5c48f3d642808d75bb08b64bfb203ac3f704c869435) |
| Deploy impl `v2.4-maker-leftovers` | [`0xfe569b44a49992a4e14551c2b6236882eef46cf639d83e229cbbed7b34ba168f`](https://explorer.testnet.chain.robinhood.com/tx/0xfe569b44a49992a4e14551c2b6236882eef46cf639d83e229cbbed7b34ba168f) |
| UUPS upgrade → `v2.4-maker-leftovers` | [`0xa6709631be59888a2fc0d1420116eb0b3edfa2ccc625a8bae8ed9d808f74f3b3`](https://explorer.testnet.chain.robinhood.com/tx/0xa6709631be59888a2fc0d1420116eb0b3edfa2ccc625a8bae8ed9d808f74f3b3) |

### After maturity

Anyone may call `settle(5)` (default SellShares for any residual after backstop) once `block.timestamp >= openedAt + term`. With current fees on #5, residual cover should be zero — junior keeps all MSTR; waterfall runs on the 1 mUSDG fee. Until maturity, `TermNotElapsed` is expected.
