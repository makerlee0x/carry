# Settle watch — live matched positions (do not early-exit)

> **Carry v3 note:** Positions **#5 / #6 / #7** below live on the **superseded v2.5** PROXY `0xc801…72bd`.
> Under v3 lender-pool they are **stale for the new product CA**. Do not treat them as v3 pool accounting.
>
> **v3 maturity (done):** matched positions **#1 / #3 / #5** on live PROXY `0x24B7…3e35` settled **Oct 18 ~10:18 PM CDT**.
> Live impl is now **`v3.2-dualpool`**. See **[V3 maturity watch](#v3-maturity-watch-live-proxy)** and [`V3_MATURITY_SETTLE.md`](./V3_MATURITY_SETTLE.md).

## v2.5 (superseded — settled)

Live 7-day **fully matched** positions on the **v2.5** vault for end-of-term `settle` testing.

**Maturity settle (2026-10-17):** #5, #6, and #7 all settled. #5/#7 permissionless IdleCarry; #6 permissionless after vault `backstop` covered residual shortfall (`coverUsdg=0`).

| Field | Position **#5** | Position **#6** |
| --- | --- | --- |
| Network | Robinhood Chain Testnet **46630** | same |
| Vault PROXY (product CA) | [`0xc801…72bd`](https://explorer.testnet.chain.robinhood.com/address/0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd) | same |
| State | **Settled** | **Settled** |
| Junior | deployer `0xcA44F2dbB2D43b93b39F01B88E0f0e2966983c57` | `0x7b0B5a326Aa4d95968e88654aF9b87624383A549` |
| Senior funder(s) | deployer 100 mUSDG | lender A `0x6943f0875AA9138F1E65a27Be48Af4312751651c` 771.7 mUSDG |
| Junior amount | 1 mMSTR | 5 mMSTR |
| Senior principal | 100 mUSDG | 771.7 mUSDG |
| Gross LP fees | 1 mUSDG | 0 (unpaid accrual dust only) |
| `openedAt` (UTC) | 2026-10-10 03:37:51 UTC | 2026-10-11 02:07:41 UTC |
| **Settle after (UTC)** | **2026-10-17 03:37:51 UTC** | **2026-10-18 02:07:41 UTC** |
| **Settle after (Central)** | **2026-10-16 10:37:51 PM CDT** | **2026-10-17 9:07:41 PM CDT** |
| **Settle status** | **Settled** (see below) | **Settled** (see below) |

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

### Settle outcomes (2026-10-17 ~11:52–11:57 PM CDT)

Signer: deployer `0xcA44…3c57` (permissionless where residual `coverUsdg=0` after backstop).

| Id | Result | Tx | Notes |
| --- | --- | --- | --- |
| **#5** | **SUCCESS** | [`0x8d87401634c0b9315a946c1d8f1c89afd3befeb51b0a1cb759f63e0182f8d41f`](https://explorer.testnet.chain.robinhood.com/tx/0x8d87401634c0b9315a946c1d8f1c89afd3befeb51b0a1cb759f63e0182f8d41f) | `settle(5)` IdleCarry; `Settled` emitted; `settled=true` |
| **#6** | **SUCCESS** | [`0x5662ba2923c761fab819ba4eb6434d4fe941fc9f88b2bb02359865eeb22c2322`](https://explorer.testnet.chain.robinhood.com/tx/0x5662ba2923c761fab819ba4eb6434d4fe941fc9f88b2bb02359865eeb22c2322) | `settle(6)` IdleCarry permissionless; vault `backstop` paid ~0.0868 USDG shortfall (`fromBackstop>0`, residual `coverUsdg=0`); `Settled` emitted; `settled=true`. Earlier “BLOCKED / needs junior key” was a **Settlement field-order misread** (fromBackstop vs coverUsdg). |
| **#7** | **SUCCESS** | [`0x3801215495116f3dafa0fc6482b1708b7ab2a19ad2260f2c23fae1caa74365f9`](https://explorer.testnet.chain.robinhood.com/tx/0x3801215495116f3dafa0fc6482b1708b7ab2a19ad2260f2c23fae1caa74365f9) | `settle(7)` IdleCarry; `Settled` emitted; `settled=true` |

Re-verified after #6: `#5`/`#6`/`#7` all `settled=true`. Backstop remaining ~0.3868 USDG.


### Position #7 (settled 2026-10-17)

| Field | Value |
| --- | --- |
| positionId | **7** |
| Junior | `0x2f1BB0AA6118f0c172A3d8b4d1D45b2F626E74Bf` (also a senior funder) |
| Senior principal | 308.68 mUSDG |
| Funders (migrated) | A 230.299… then B 78.380… @ openedAt |
| `openedAt` UTC | 2026-10-11 02:40:38 UTC |
| **Settle after (Central)** | **2026-10-17 9:40:38 PM CDT** |
| **Settled tx** | [`0x380121…65f9`](https://explorer.testnet.chain.robinhood.com/tx/0x3801215495116f3dafa0fc6482b1708b7ab2a19ad2260f2c23fae1caa74365f9) |

Included in v2.5 `migrateAccountingV25`.

---

## v3 maturity watch (live PROXY)

Product CA: [`0x24B799026AA7baa6856bCFD00c1Be1f583A83e35`](https://explorer.testnet.chain.robinhood.com/address/0x24B799026AA7baa6856bCFD00c1Be1f583A83e35) · live impl `0x1473…58A5` · `v3.2-dualpool` (settled while still on prior `v3-lender-pool` impl `0x7BeE…778E`).  
Full settle pack: [`V3_MATURITY_SETTLE.md`](./V3_MATURITY_SETTLE.md). Upgrade: [`testnet-runs/2026-10-18-v32-upgrade.md`](./testnet-runs/2026-10-18-v32-upgrade.md).

| Field | **#1** | **#3** | **#5** |
| --- | --- | --- | --- |
| Junior | `0x76339f8D6640D6dF94037D87c2c9503C98391803` | same | same |
| Senior principal | 154.34 mUSDG | 154.34 mUSDG | 154.34 mUSDG (fully matched at settle) |
| `openedAt` (unix) | 1791772514 | 1791772652 | 1791772738 |
| **Settle after (UTC)** | **2026-10-19 02:35:14 UTC** | **2026-10-19 02:37:32 UTC** | **2026-10-19 02:38:58 UTC** |
| **Settle after (CDT)** | **2026-10-18 9:35:14 PM CDT** | **2026-10-18 9:37:32 PM CDT** | **2026-10-18 9:38:58 PM CDT** |
| State | **Settled** | **Settled** | **Settled** |
| Settled at (CDT) | 2026-10-18 10:18:18 PM | 2026-10-18 10:18:22 PM | 2026-10-18 10:18:25 PM |
| Settle tx | [`0x14e1…430d`](https://explorer.testnet.chain.robinhood.com/tx/0x14e1264004b1e9f958c21fb954f405c0b77a64bbe08c3ee90ebc36e44d3e430d) | [`0x6166…2ed2`](https://explorer.testnet.chain.robinhood.com/tx/0x6166e5614b37b3dfcab9e9d2036b38133fcd60e5228e800ec38eb8fca6dc2ed2) | [`0x5a9d…3ac2`](https://explorer.testnet.chain.robinhood.com/tx/0x5a9d5367a8421ced8fb01cd172daca75388b26add00b4c62013b56a5e2783ac2) |

**Maturity settle (2026-10-18 ~10:18pm CDT):** deployer `0xcA44…3c57` permissionless `settle(id)` IdleCarry. `previewSettle` showed `coverUsdg=0` with accrual paid from vault `backstop` (`fromBackstop` ≈ 0.115 / 0.115 / 0.046 USDG). `Settled` events emitted; `settled=true` on #1/#3/#5.

**Auto-compound note:** junior had `autoCompound=true`, so settle reopened new matched positions **#9 / #10 / #11** (same junior, `openedAt` = settle timestamps). Original proof IDs #1/#3/#5 are closed; the rollovers are a separate 7d watch if desired.

### Quick cast (after each clock; no keys in repo)

```bash
export PATH="$PATH:$HOME/.foundry/bin"
RPC=https://rpc.testnet.chain.robinhood.com
PROXY=0x24B799026AA7baa6856bCFD00c1Be1f583A83e35
# v3.2 one-arg preview (post-upgrade):
cast call $PROXY "previewSettle(uint256)((uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256))" 9 --rpc-url $RPC
# cast send $PROXY "settle(uint256)" 9 --rpc-url $RPC --private-key "$DEPLOYER_PRIVATE_KEY"
```

Historical note: #1/#3/#5 settled with two-arg `previewSettle(id,1)` on the pre-upgrade ABI.
