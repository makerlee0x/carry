# Testnet checklist (v3 lender pool)

What has to pass on Robinhood Chain Testnet **46630** before the security pass and mainnet work.
Live product CA: `public/config.json` → `chain.vault` (`0x24B7…3e35`, `version() = v3.2-dualpool`).

Status key: ✅ passed · ❌ failed (link the issue) · ⬜ not run yet.
Anything that fails gets a GitHub issue; link it in the Notes column.

Last run: 2026-10-18 — [v2.5/v3 settles](./SETTLE_WATCH.md), [v3.2 upgrade + DualPool wire](./testnet-runs/2026-10-18-v32-upgrade.md), earlier [run 2026-10-18](./testnet-runs/2026-10-18.md).

## 1. Contracts (local)

| Check | How | Status | Notes |
| --- | --- | --- | --- |
| Forge suite | `cd contracts && forge test` | ✅ | **87/87** pass (incl. SixDecimalUsdg + invariants) |
| Deploy scripts stay disarmed | `test_broadcastDisarmed`, `test_carryTestnetScriptDisarmed` | ✅ | |
| Runtime size under EIP-170 (24,576 bytes) | `forge build --sizes` | ✅ | Live impl `0x1473…` **23,719** B after #22 per-wallet removal upgrade |
| Site index check | `npm run check` | ✅ | |

## 2. On-chain flows (v3 PROXY)

Run with real wallets on 46630. Record the tx hash for each pass. `scripts/run_v3_onchain.sh`
covers several of these; check its results into `docs/` when it runs, since today the only
record is a local `/tmp` file.

| Flow | Expected | Status | Notes |
| --- | --- | --- | --- |
| `version()` on PROXY | `v3.2-dualpool` | ✅ | Live after 2026-10-18 upgrades; impl `0x1473…58A5` |
| Senior `depositSenior` ≥ $25 | Pool shares minted, idle USDG up | ✅ | `0xb9eb…8450`: 100 USDG → 1e26 shares |
| Senior deposit < $25 | Reverts | ✅ | Simulated (`eth_call`): `BelowMinDeposit`. No tx on chain. |
| Junior `depositJunior` with enough idle USDG | Position Active, 7-day timer starts | ✅ | `0xa516…fe82` (#1) |
| Junior deposit with no idle USDG | Position Idle until a senior deposit matches it | ✅ | #5 idle at `0x1209…4a9d`, matched by `0xed4d…b3e8` |
| Gas refund | Paid only when the deposit matched, scaled to the match | ✅ | `0xed4d…b3e8`: 0.0001 ETH for a 100%-matched deposit. Partial-match scaling not exercised. |
| Fee in (`MockFeePool.payFee` / `accrueLpFee`) | Fees accrue raw; split only at claim/exit/settle | ✅ | [`0xca00…03c3`](https://explorer.testnet.chain.robinhood.com/tx/0xca008cd5138450ec4bd509bb2d319b257be58bce2f1d085f2d7925757bc003c3): 20 USDG onto #6 raised `totalUnsplitFees` to 20.001 (with [`0xf239…8805`](https://explorer.testnet.chain.robinhood.com/tx/0xf23988684320efd8939590c3eb76c3bb87bcf828c1aaf56713c7998d30ca8805), 0.001 on #7); nothing split until claim |
| `claimFees` | Maker waterfall: senior floor → treasury → senior perf → junior | ✅ | [`0x6828…36ee`](https://explorer.testnet.chain.robinhood.com/tx/0x682897a4275f608274aece5a59ad4c3fed8e1ec9fd065be704f10c88467736ee) on 20 USDG: floor 0.0000422 (221 s of accrual), treasury 4.0, senior perf 4.0, junior 11.99996. Treasury 20% and perf 20% of gross, as documented. Treasury landed in `backstop` (0 → 4.0002), see finding C6 |
| Early exit (v3.2 one-arg) | `previewEarlyExit(id)` → `earlyExit(id)` | ✅ | Pre-v3.2 cover-mode txs still valid history; post-upgrade smoke [`0x1b45…23c7`](https://explorer.testnet.chain.robinhood.com/tx/0x1b45dee292918418a02a02c5b52bdfe8ae1721dfbc01bb9fc4145bdea56323c7) on pooled #12 |
| SellShares router set | Router non-zero after DualPool wire | ✅ | `sellSharesRouter` = `0x687f…424C` (MockMstrSellRouter) |
| `deployIdle` (owner) | Moves free USDG into CarryStrategy / MockMorpho | ✅ | [`0xc6ff…dd1f`](https://explorer.testnet.chain.robinhood.com/tx/0xc6ff34f1238cb4d291e16973127112c7f77f3b4a4e8ba0f055509c06d3b2dd1f) 50 USDG; `strategyDeployed=50e18` |
| Settle after term | Backstop first, then junior; default IdleCarry; permissionless when no cover | ✅ | v3 #1/#3/#5 settled 2026-10-18 ~10:18pm CDT; see section 5 |
| Settle before term | Reverts `TermNotElapsed` | ✅ | Simulated `settle(1)` from the junior: `TermNotElapsed`. No tx on chain. |
| Senior instant withdraw | Works when idle covers it and queue is empty | ✅ | `0x3cf3…396b` (25 USDG) |
| Senior withdraw when matched | Enters FIFO queue; claimable after positions close | ✅ | Queue [`0x9149…b902`](https://explorer.testnet.chain.robinhood.com/tx/0x9149f53442ce024e7b8366a2add73cc8a2cb1e966fdda2b41b8bd3a4f58fb902) (25 USDG); filled by `earlyExit(14)` [`0x6b71…716c`](https://explorer.testnet.chain.robinhood.com/tx/0x6b71e8be9052535ed709180c1ebdcd7b3cca50bc299086e1246095204220716c); `claimWithdraw` [`0xb579…ea03`](https://explorer.testnet.chain.robinhood.com/tx/0xb579b2487d5181060f437f961ae9537c3fe7162d17615f90dd54e60d3c9cea03) |
| Auto-compound on | Reopens position; payout under $25 goes to wallet | ✅ | Settle #1/#3/#5 reopened #9/#10/#11; earlyExit #12 reopened #13 into DualPool |
| `withdrawUnmatched` | Always to wallet, ignores auto-compound | ✅ | `0x0958…e563` with auto-compound on: MSTR left, no new position |
| Pause | Blocks new deposits; exits and withdrawals still work | ✅ | Pause [`0xf07f…3abe`](https://explorer.testnet.chain.robinhood.com/tx/0xf07f970ab6ff0affcaf36cea89e4803bdc1a4d09b6506919b9abdfefb5093abe): `depositSenior`/`depositJunior` revert `Paused`; `previewEarlyExit(13)` still works; unpause [`0xa8f4…9b2d`](https://explorer.testnet.chain.robinhood.com/tx/0xa8f407ebc7179ae7e4544c1262aa131604858aa984edffb8b6c1e5bc72969b2d) |
| Source verified on explorer | Impl shows verified source on Blockscout | ✅ | Live impl `0x1473…58A5` + CarryStrategy verified. MockMorpho + DualHook still unverified (bytecode / vendored hook package). |
| Two lenders, one junior | Each lender's idle and share NAV stay correct | ✅ | #3 funded by both lenders; shares read 215 + 150 = 365 = `totalSeniorAssets`. Re-check NAV after fees. |

## 3. Site against testnet

Browser pass 2026-10-18 (no wallet connected — deposit/match/early-exit still need MetaMask).

| Check | Expected | Status | Notes |
| --- | --- | --- | --- |
| Connect MetaMask on 46630 | Wrong-network prompt if on another chain | ⬜ | Needs wallet; Connect CTA present |
| Deposit and match from the UI | Card shows Idle → Active | ⬜ | Needs wallet |
| Early exit dialog | One-arg preview / exit (no CoverMode); shows amounts | ⬜ | Needs wallet; CoverMode gone from `testnet.html` / config |
| Positions / config against v3 PROXY | Live `config.json` = `v3.2-dualpool` impl `0x1473…` | ✅ | `www.usecarry.io/config.json` matches `main`; View contract → PROXY `0x24B7…3e35` |
| Light and dark mode, phone width | No broken layout | ✅ | Light toggle works; markets/dashboard OK at ~390px |
| Market request form | Posts to Apps Script or falls back | ❌ | Deployed `/exec` returns **403**; needs Google **Manage deployments → New version** (see `docs/market-requests/README.md`) |

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
| #1 | 2026-10-18 **9:35:14 PM CDT** | ✅ | Settled 10:18:18 PM CDT — [`0x14e1…430d`](https://explorer.testnet.chain.robinhood.com/tx/0x14e1264004b1e9f958c21fb954f405c0b77a64bbe08c3ee90ebc36e44d3e430d) |
| #3 | 2026-10-18 **9:37:32 PM CDT** | ✅ | Settled 10:18:22 PM CDT — [`0x6166…2ed2`](https://explorer.testnet.chain.robinhood.com/tx/0x6166e5614b37b3dfcab9e9d2036b38133fcd60e5228e800ec38eb8fca6dc2ed2) |
| #5 | 2026-10-18 **9:38:58 PM CDT** | ✅ | Settled 10:18:25 PM CDT — [`0x5a9d…3ac2`](https://explorer.testnet.chain.robinhood.com/tx/0x5a9d5367a8421ced8fb01cd172daca75388b26add00b4c62013b56a5e2783ac2). Auto-compound reopened #9/#10/#11 |
