# Testnet checklist (v3 lender pool)

What has to pass on Robinhood Chain Testnet **46630** before the security pass and mainnet work.
Live product CA: `public/config.json` → `chain.vault` (`0x24B7…3e35`, `version() = v3-lender-pool`).

Status key: ✅ passed · ❌ failed (link the issue) · ⬜ not run yet.
Anything that fails gets a GitHub issue; link it in the Notes column.

Last run: 2026-10-17.

## 1. Contracts (local)

| Check | How | Status | Notes |
| --- | --- | --- | --- |
| Forge suite | `cd contracts && forge test` | ✅ | 27/27 pass (25 vault, 2 deploy-script) |
| Deploy scripts stay disarmed | `test_broadcastDisarmed`, `test_carryTestnetScriptDisarmed` | ✅ | |
| Runtime size under EIP-170 (24,576 bytes) | `forge build --sizes` | ❌ | `LeveredLpVault` is 29,602 bytes. Blocks mainnet (security finding S1). |
| Site index check | `npm run check` | ✅ | |

## 2. On-chain flows (v3 PROXY)

Run with real wallets on 46630. Record the tx hash for each pass. `scripts/run_v3_onchain.sh`
covers several of these; check its results into `docs/` when it runs, since today the only
record is a local `/tmp` file.

| Flow | Expected | Status | Notes |
| --- | --- | --- | --- |
| `version()` on PROXY | `v3-lender-pool` | ⬜ | |
| Senior `depositSenior` ≥ $25 | Pool shares minted, idle USDG up | ⬜ | |
| Senior deposit < $25 | Reverts | ⬜ | |
| Junior `depositJunior` with enough idle USDG | Position Active, 7-day timer starts | ⬜ | |
| Junior deposit with no idle USDG | Position Idle until a senior deposit matches it | ⬜ | |
| Gas refund | Paid only when the deposit matched, scaled to the match | ⬜ | |
| Fee in (`MockFeePool.payFee` / `accrueLpFee`) | Fees accrue raw; split only at claim/exit/settle | ⬜ | |
| `claimFees` | Maker waterfall: senior floor → treasury → senior perf → junior | ⬜ | |
| Early exit, Wallet USDG cover | `previewEarlyExit` → approve → `earlyExit(id, 0)` succeeds | ⬜ | |
| Early exit, Idle Carry cover | No wallet approve needed | ⬜ | |
| Early exit, SellShares (mode 2) | Testnet stub path completes | ⬜ | |
| Settle after term | Backstop first, then junior; default IdleCarry; permissionless when no cover | ⬜ | |
| Settle before term | Reverts `TermNotElapsed` | ⬜ | |
| Senior instant withdraw | Works when idle covers it and queue is empty | ⬜ | |
| Senior withdraw when matched | Enters FIFO queue; claimable after positions close | ⬜ | |
| Auto-compound on | Reopens position; payout under $25 goes to wallet | ⬜ | |
| `withdrawUnmatched` | Always to wallet, ignores auto-compound | ⬜ | |
| Pause | Blocks new deposits; exits and withdrawals still work | ⬜ | |
| Two lenders, one junior | Each lender's idle and share NAV stay correct | ⬜ | Repeat of the v2.5 #6 bug case |

## 3. Site against testnet

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
| #5 | 2026-10-17 03:37:51 | ⬜ | Matured; ready to settle |
| #6 | 2026-10-18 02:07:41 | ⬜ | Multi-lender case |
| #7 | 2026-10-18 02:40:38 | ⬜ | |
