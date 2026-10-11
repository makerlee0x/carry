# Carry vault accounting v2.5 (funder-idle)

**CRITICAL money-safety rewrite.** Replaces global pro-rata `freePrincipal` and the global time-weighted yield index.

Product CA (unchanged): UUPS PROXY [`0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd`](https://explorer.testnet.chain.robinhood.com/address/0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd)  
Version: `v2.5-funder-idle`

## What was broken (live)

Old model:

```
freePrincipal(senior) = seniorPrincipal[senior] × freeSenior / totalSeniorPrincipal
```

Idle was a **global pool**. Lender B depositing 500 USDG while A was mostly matched on a ~771 USDG junior **contaminated** free shares:

| Lender | Principal | True idle | Old freePrincipal |
| --- | --- | --- | --- |
| A | 1000 | 228.3 | ~455.8 (too high) |
| B | 500 | 500 | ~227.9 (too low) |

B could not withdraw their full idle. A could withdraw capacity they did not post as idle. Global TW yield + `seniorJoinedAt=0` edge cases made attribution worse.

## New model

### 1. Per-lender idle

- `seniorIdle[lender]` = unmatched USDG belonging to that lender only.
- `freePrincipal(lender) = seniorIdle[lender]`.
- `withdrawSenior` pulls from **their idle only** (plus claimable yield / MSTR).

### 2. FIFO matching with attribution

- Idle lenders sit in a deposit-order queue (`idleHead` / `idleNext`).
- Matching consumes idle FIFO into open juniors (bounded by `matchCap`).
- Each match records a `FunderSlice { lender, amount, matchedAt }` on that position.
- Partial matches append additional funder slices.

### 3. Yield to position funders only

At `claimFees` / `earlyExit` / `settle` / `seniorEarlyExit`:

- Waterfall runs on **that position's** fees.
- `seniorTotal` USDG and SellShares MSTR split by **amount × time matched on THAT position**.
- Pure idle lenders (not funders of the position) earn nothing from it.
- Legacy global TW indices are frozen (no new credits); old claimable debts still checkpoint.

### 4. On close

Each funder's matched principal returns to **their** `seniorIdle` (withdrawable or auto-compound match).

### 5. IdleCarry

Burns only the junior's **own** `seniorIdle`. No cross-lender cover.

### 6. Gas / size bounds

| Knob | Value |
| --- | --- |
| Min deposit / match (junior notional + senior) | **$25** (`minDepositUsdg`, default 25e18) |
| `matchCap` | kept (default 25) |
| `maxPerWalletUsdg` | **0 = unlimited** (removed $2500) |
| Market totals | **$25k** senior / junior kept |

Matching below $25 does not start the 7-day clock (except completing an already-started residual).

## Caps, treasury, tiers

- Treasury cut is **% of fees / cover residual**, never of position size.
- Base cut: **20%**.
- Boosted STRATEGY stake **tiers** (owner-configurable via `setBoostTiers`):

| STRATEGY stake (stub) | Treasury cut of fees |
| --- | --- |
| 0 (no stake) | 20% |
| ≥ 100 | 15% |
| ≥ 1_000 | 10% |
| ≥ 10_000 | 5% |

Cut locks on the position at first match (`treasuryCutLocked`). Creator fee share is later.

## Settle / exit / auto-compound

- **Settle default** = `IdleCarry` (USDG path). SellShares only if junior enabled `sellSharesEnabled` or junior chooses it.
- Permissionless settle when residual cover after backstop is zero.
- **Senior early exit** (`seniorEarlyExit`): no senior early-withdraw fee; rematch junior from other idle when possible; treasury still cuts interest earned via waterfall.
- **Auto-compound**: claimFees compounds junior fee share to senior idle; full exit reopens Idle; senior early-exit + junior auto-compound rematches when idle allows.
- **Pause / caps do not block exits** (auto-compound reopen bypasses pause + deposit caps).
- Gas refunds: try-push ETH; on reject-ETH wallets credit `pendingEthCredit` (pull via `withdrawPendingEth`) so settle cannot brick.

## Live migration (#5 / #6)

`migrateAccountingV25` (owner, one-shot) seeds idle + funder slices without moving tokens.

| Position | Impact |
| --- | --- |
| **#5** | Still Active, 100 mUSDG / 1 mMSTR / 1 mUSDG fees. Funder = deployer 100 @ match time. Do **not** earlyExit/settle before maturity. Upgrade is storage-additive + migration only. |
| **#6** | Still Active, ~771.7 USDG / 5 MSTR. Funder = lender A 771.7. A idle 228.3; B idle 500 fully withdrawable after migration. unpaidSeniorAccrual / morphoRateLocked preserved. |

See [`SETTLE_WATCH.md`](./SETTLE_WATCH.md) for Central-time maturity windows.
