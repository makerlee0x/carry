# Settle watch — live matched positions (do not early-exit)

Live 7-day **fully matched / Active** positions on the product vault for end-of-term `settle` testing.

**Do not call `earlyExit` or `settle` until after maturity.** Leave open for the full term.

| Field | Position **#5** | Position **#6** |
| --- | --- | --- |
| Network | Robinhood Chain Testnet **46630** | same |
| Vault PROXY (product CA) | [`0xc801…72bd`](https://explorer.testnet.chain.robinhood.com/address/0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd) | same |
| State | Active, fully matched | Active, fully matched |
| Junior | deployer `0xcA44…3c57` | `0x7b0B…a549` |
| Senior funder(s) | deployer 100 mUSDG | lender A `0x6943…651c` 771.7 mUSDG |
| Junior amount | 1 mMSTR | 5 mMSTR |
| Senior principal | 100 mUSDG | 771.7 mUSDG |
| Gross LP fees | 1 mUSDG | 0 (unpaid accrual dust only) |
| `openedAt` (UTC) | 2026-10-10 03:37:51 UTC | 2026-10-11 02:07:41 UTC |
| **Settle after (UTC)** | **2026-10-17 03:37:51 UTC** | **2026-10-18 02:07:41 UTC** |
| **Settle after (Central)** | **2026-10-16 10:37:51 PM CDT** | **2026-10-17 9:07:41 PM CDT** |

### Upgrade impact (v2.5 funder-idle)

Storage-additive UUPS upgrade keeps the same PROXY CA. `migrateAccountingV25` seeds per-lender idle + funder slices; **does not** move #5/#6 principal, fees, or clocks.

- **#5:** Funder attribution = deployer 100. Fees `1e18` ≫ 7-day Morpho accrual on 100 @ 3.9%, so maturity settle should not need cover. Default settle path is now **IdleCarry** (USDG); with zero residual cover after backstop, settle stays permissionless.
- **#6:** Funder = A 771.7. After migration A idle = 228.3 (withdrawable); B (`0x2f1B…74Bf`) idle = 500 **fully** withdrawable (fixes live freePrincipal contamination). Do not settle/earlyExit before maturity.
- Global pro-rata freePrincipal / global TW yield index removed going forward; yield credits go to position funders only.
- Do **not** call `earlyExit` / `settle` on #5 before **2026-10-16 10:37:51 PM Central**, or on #6 before **2026-10-17 9:07:41 PM Central**.

### Why #6 mattered (live bug)

Junior needed ~771 USDG. Lender A deposited 1000 (matched most). Lender B deposited 500 (should stay 100% idle). Old global freePrincipal let A over-withdraw and blocked B from full idle exit. v2.5 makes idle per-lender and attributes #6 entirely to A.

### Tx links (#5)

| Step | Tx |
| --- | --- |
| `depositSenior(100e18)` | [`0x97a4…22da`](https://explorer.testnet.chain.robinhood.com/tx/0x97a42865623d02909ad823beee44b9e7a6216edf00aecd560c27f7c5a71022da) |
| `depositJunior` → #5 | [`0x8834…422a`](https://explorer.testnet.chain.robinhood.com/tx/0x8834b69b4631da3ceded13c1472591388a0af1c63606f96edd13869fa61b422a) |
| `payFee` 1 mUSDG | [`0x010f…edac`](https://explorer.testnet.chain.robinhood.com/tx/0x010f29cd78e9f739915c021500fcdbd8bd11a55d63f4b95884878f39df1dedac) |

### After maturity

- Prefer `settle(id)` (default IdleCarry). If residual cover is needed, junior uses Wallet / IdleCarry; SellShares only if junior enabled it or chooses it explicitly.
- Until maturity, `TermNotElapsed` is expected.


### Position #7 (also Active — protect)

| Field | Value |
| --- | --- |
| positionId | **7** |
| Junior | `0x2f1B…74Bf` (also a senior funder) |
| Senior principal | 308.68 mUSDG |
| Funders (migrated) | A 230.299… then B 78.380… @ openedAt |
| `openedAt` UTC | 2026-10-11 02:40:38 UTC |
| **Settle after (Central)** | **2026-10-17 9:40:38 PM CDT** |

Do not earlyExit/settle #7 before maturity. Included in v2.5 `migrateAccountingV25`.
