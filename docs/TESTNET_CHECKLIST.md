# Testnet checklist (v3 lender pool)

What has to pass on Robinhood Chain Testnet **46630** before the security pass and mainnet work.
Live product CA: `public/config.json` → `chain.vault` (`0x24B7…3e35`, `version() = v3-lender-pool`).

Status key: ✅ passed · ❌ failed (link the issue) · ⬜ not run yet.
Anything that fails gets a GitHub issue; link it in the Notes column.

Last run: 2026-10-18 (read-only pass, then a transaction pass from the testnet-only wallet `0x090B…0809`). Full readout and tx links: [run 2026-10-18](./testnet-runs/2026-10-18.md).

## 1. Contracts (local)

| Check | How | Status | Notes |
| --- | --- | --- | --- |
| Forge suite | `cd contracts && forge test` | ✅ | 27/27 pass (25 vault, 2 deploy-script) |
| Deploy scripts stay disarmed | `test_broadcastDisarmed`, `test_carryTestnetScriptDisarmed` | ✅ | |
| Runtime size under EIP-170 (24,576 bytes) | `forge build --sizes` | ✅ | `main` is 24,432 bytes after #3, #23 and the #21 strategy wiring (144 spare). The live testnet impl is still 29,602 until it is upgraded (S1). |
| Site index check | `npm run check` | ✅ | |

## 2. On-chain flows (v3 PROXY)

Run with real wallets on 46630. Record the tx hash for each pass. `scripts/run_v3_onchain.sh`
covers several of these; check its results into `docs/` when it runs, since today the only
record is a local `/tmp` file.

| Flow | Expected | Status | Notes |
| --- | --- | --- | --- |
| `version()` on PROXY | `v3-lender-pool` | ✅ | Read 2026-10-18; impl `0x7BeE…778E` |
| Senior `depositSenior` ≥ $25 | Pool shares minted, idle USDG up | ✅ | `0xb9eb…8450`: 100 USDG → 1e26 shares |
| Senior deposit < $25 | Reverts | ✅ | Simulated (`eth_call`): `BelowMinDeposit`. No tx on chain. |
| Junior `depositJunior` with enough idle USDG | Position Active, 7-day timer starts | ✅ | `0xa516…fe82` (#1) |
| Junior deposit with no idle USDG | Position Idle until a senior deposit matches it | ✅ | #5 idle at `0x1209…4a9d`, matched by `0xed4d…b3e8` |
| Gas refund | Paid only when the deposit matched, scaled to the match | ✅ | `0xed4d…b3e8`: 0.0001 ETH for a 100%-matched deposit. Partial-match scaling not exercised. |
| Fee in (`MockFeePool.payFee` / `accrueLpFee`) | Fees accrue raw; split only at claim/exit/settle | ✅ | [`0xca00…03c3`](https://explorer.testnet.chain.robinhood.com/tx/0xca008cd5138450ec4bd509bb2d319b257be58bce2f1d085f2d7925757bc003c3): 20 USDG onto #6 raised `totalUnsplitFees` to 20.001 (with [`0xf239…8805`](https://explorer.testnet.chain.robinhood.com/tx/0xf23988684320efd8939590c3eb76c3bb87bcf828c1aaf56713c7998d30ca8805), 0.001 on #7); nothing split until claim |
| `claimFees` | Maker waterfall: senior floor → treasury → senior perf → junior | ✅ | [`0x6828…36ee`](https://explorer.testnet.chain.robinhood.com/tx/0x682897a4275f608274aece5a59ad4c3fed8e1ec9fd065be704f10c88467736ee) on 20 USDG: floor 0.0000422 (221 s of accrual), treasury 4.0, senior perf 4.0, junior 11.99996. Treasury 20% and perf 20% of gross, as documented. Treasury landed in `backstop` (0 → 4.0002), see finding C6 |
| Early exit, Wallet USDG cover | `previewEarlyExit` → approve → `earlyExit(id, 0)` succeeds | ✅ | [`0xc098…fe4a`](https://explorer.testnet.chain.robinhood.com/tx/0xc09808ef280856ec9cbe22f570e6ef25681df4c48a31d07a03ccf7988425fe4a) (#8, 97.3 USDG matched, no fees): cover 4.0e-6 USDG pulled from the wallet, 1 MSTR returned |
| Early exit, Idle Carry cover | No wallet approve needed | ✅ | [`0x2583…01a3`](https://explorer.testnet.chain.robinhood.com/tx/0x258301625e60af1059c3e6ddfee3f93da77c16afdfa0c8b284c99e53663601a3) (#6, fees already claimed): cover 1.6e-5 USDG paid from the junior's own pool shares, 1 MSTR returned. No-cover case: [`0x79e4…a29d`](https://explorer.testnet.chain.robinhood.com/tx/0x79e4f9ac6d7a28d4274ee0a04bb92bf5e7f77463042da6771846c0e16d36a29d) (#7, fees 0.001 covered the accrual) |
| Early exit, SellShares (mode 2) | Testnet stub path completes | ⬜ | `sellSharesRouter` is `0x0` on v3; the owner `0xcA44…3c57` has to set it first (the testnet wallet is not the owner) |
| Settle after term | Backstop first, then junior; default IdleCarry; permissionless when no cover | ⬜ | v3 #1/#3/#5 mature 2026-10-19 02:35–02:39 UTC |
| Settle before term | Reverts `TermNotElapsed` | ✅ | Simulated `settle(1)` from the junior: `TermNotElapsed`. No tx on chain. |
| Senior instant withdraw | Works when idle covers it and queue is empty | ✅ | `0x3cf3…396b` (25 USDG) |
| Senior withdraw when matched | Enters FIFO queue; claimable after positions close | ⬜ | Queue works (`0x405d…cc10` → `0x9e88…aa57`), but it was filled by a new deposit, not a closing position. Re-check after settle. |
| Auto-compound on | Reopens position; payout under $25 goes to wallet | ⬜ | Enabled for the v3 junior; needs a settle/exit to test |
| `withdrawUnmatched` | Always to wallet, ignores auto-compound | ✅ | `0x0958…e563` with auto-compound on: MSTR left, no new position |
| Pause | Blocks new deposits; exits and withdrawals still work | ⬜ | Pause/unpause work (deploy + `0x6a23…7c`); blocking not tested. `paused()` = false now. |
| Source verified on explorer | Proxy and impl show verified source | ❌ | Both unverified as of 2026-10-18 |
| Two lenders, one junior | Each lender's idle and share NAV stay correct | ✅ | #3 funded by both lenders; shares read 215 + 150 = 365 = `totalSeniorAssets`. Re-check NAV after fees. |

## 3. Site against testnet

Not run: needs a browser wallet. From the cloud env, `usecarry.io` redirects to `www.usecarry.io`, which is still blocked.

| Check | Expected | Status | Notes |
| --- | --- | --- | --- |
| Connect MetaMask on 46630 | Wrong-network prompt if on another chain | ⬜ | |
| Deposit and match from the UI | Card shows Idle → Active | ⬜ | |
| Early exit dialog | Shows cover options and preview amounts | ⬜ | |
| Positions show after reload | Reads from the v3 PROXY, not the old v2.5 one | ⬜ | |
| Light and dark mode, phone width | No broken layout | ⬜ | |

## 4. Superseded v2.5 vault (wind-down)

Positions #5, #6 and #7 live on the old PROXY `0xc801…72bd`. See [`SETTLE_WATCH.md`](./SETTLE_WATCH.md).

| Position | Settle after (UTC) | Status | Notes |
| --- | --- | --- | --- |
| #5 | 2026-10-17 03:37:51 | ✅ | Settled 2026-10-18 04:52 UTC — [`0x8d8740…d41f`](https://explorer.testnet.chain.robinhood.com/tx/0x8d87401634c0b9315a946c1d8f1c89afd3befeb51b0a1cb759f63e0182f8d41f) |
| #6 | 2026-10-18 02:07:41 | ✅ | Settled 2026-10-18 04:59 UTC — [`0x5662ba…2322`](https://explorer.testnet.chain.robinhood.com/tx/0x5662ba2923c761fab819ba4eb6434d4fe941fc9f88b2bb02359865eeb22c2322) (backstop covered residual) |
| #7 | 2026-10-18 02:40:38 | ✅ | Settled 2026-10-18 04:52 UTC — [`0x380121…65f9`](https://explorer.testnet.chain.robinhood.com/tx/0x3801215495116f3dafa0fc6482b1708b7ab2a19ad2260f2c23fae1caa74365f9) |

## 5. v3 maturity watch (live PROXY)

Positions **#1 / #3 / #5** on `0x24B7…3e35`. Full commands: [`V3_MATURITY_SETTLE.md`](./V3_MATURITY_SETTLE.md).

| Position | Mature (CDT) | Status | Notes |
| --- | --- | --- | --- |
| #1 | 2026-10-18 **9:35:14 PM CDT** | ⬜ | Do not settle before; `previewSettle` → `TermNotElapsed` until then |
| #3 | 2026-10-18 **9:37:32 PM CDT** | ⬜ | |
| #5 | 2026-10-18 **9:38:58 PM CDT** | ⬜ | Partial match (56.32 mUSDG senior) |
