---
title: "Carry / Levered LP Vault — Contract Overview"
subtitle: "Robinhood Chain Testnet (46630) — for Maker Lee review"
---

# Carry / Levered LP Vault — Contract Overview

Grant and audit reference for `LeveredLpVault` on **Robinhood Chain Testnet (chain id 46630)**.

**Primary vault:** [`0x72A053120f03B10c5506d2325f92F59B0FfC36c8`](https://explorer.testnet.chain.robinhood.com/address/0x72A053120f03B10c5506d2325f92F59B0FfC36c8?tab=contract) (Sourcify verified)

---

## 1. Overview

Carry pairs a stock-token holder (**junior**) with a USDG lender (**senior**) into a **50/50 book**: junior posts MSTR, senior posts matching USDG. Equity tracks the stock while the book accrues LP fees over a fixed term. This vault is the **custody and accounting layer**.

- Junior deposits MSTR → **Open** until USDG matches, then **Active** for **7 days**.
- **4%** is the **pool-floor pace** for early-exit coupon math — not an extra tip on top of the maturity borrow fee.
- At **maturity**, seniors are owed principal + a **borrow fee** (`borrowAprWad`, capped at 5%, × term / year).
- **Early exit** closes the whole position: fees cover `principal × 4% × elapsed/365` when available; otherwise junior MSTR from the position covers the gap.
- Lenders withdraw **idle** USDG anytime; **matched** USDG unlocks via replacement liquidity or position close.

### Contract snapshot

| Item | Value |
| --- | --- |
| Contract | `LeveredLpVault` (non-upgradeable) |
| Tokens / oracle | Immutable `mstr`, `usdg`; immutable `IPriceOracle` |
| Term / borrow APR | Immutable `term` ≤ 7 days; `borrowAprWad` ≤ 5% WAD |
| Protocol cut | Immutable `protocolCutWad` ≤ 20% of each fee |
| Early-exit APR | Constant `EARLY_EXIT_APR_WAD = 0.04e18` |
| Pause / reentrancy | Owner pause gates deposits; `nonReentrant` on value paths |
| External LP | No PoolManager approvals; `joinPool` reverts |

Inventory is held inside the vault. `mark()` reports 2× equity vs an unlevered 50/50 √p comparison without moving inventory.

---

## 2. Actors

| Actor | Role | Key actions |
| --- | --- | --- |
| **Junior** (stock depositor) | Posts MSTR | `depositJunior`, `withdrawUnmatched`, `earlyExit`; receives leftover MSTR/fees on settle |
| **Senior** (lender) | Posts USDG | `depositSenior`, `withdrawSenior` (idle + claims) |
| **Owner / protocol** | Pause + rescue key | `pause`, `unpause`, `rescueToken` (non-principal only). Cannot set oracle/term/APR/cut; cannot pull MSTR/USDG |
| **Fee source** | Accrues LP fees | `accrueLpFee` / `MockFeePool.payFee` pushes USDG into the vault |
| **Anyone** | Keepers | `settle` after term (proceeds go to junior + seniors, not the caller) |

---

## 3. Lifecycle

1. **Deposit stock** — `depositJunior(mstrAmount)`. If no idle USDG → Open queue. If idle USDG ≥ oracle notional → match immediately (Active, `openedAt = now`).
2. **Lend USDG** — `depositSenior(amount)`. Credits senior principal; FIFO-matches Open juniors; each match sets `seniorPrincipal`, `entryPriceWad`, `openedAt`, increases `reservedSenior`.
3. **Active** — Position earns when matched. Timer = `term` from match.
4. **Fee accrual** — Caller pushes USDG via `accrueLpFee`. `protocolCutWad` → `backstop`; remainder → `position.feeUsdg`.
5. **Early exit** (junior, before term) — Coupon `principal × 0.04 × elapsed/365`. Fees first; gap → sell MSTR from position; return remaining shares. Releases `reservedSenior`.
6. **Maturity settle** (after term) — Borrow fee `principal × borrowApr × term/365`. Waterfall: position fees → backstop → minimum MSTR. Junior gets leftover MSTR + leftover fees.
7. **Lender replace / exit** — `freePrincipal(senior) = seniorPrincipal × freeSenior / totalSeniorPrincipal`. Extra senior deposits raise idle capacity. Matched size unlocks on early exit/settle when `reservedSenior` drops.

---

## 4. Function reference

### Admin

| Function | Who | Preconditions | Effects / funds |
| --- | --- | --- | --- |
| `pause()` | owner | — | `paused = true`; new deposits revert |
| `unpause()` | owner | — | `paused = false` |
| `rescueToken(token,to,amount)` | owner | `token ∉ {mstr,usdg}` | Transfers non-principal token |

### Junior

| Function | Who | Preconditions | Effects / funds |
| --- | --- | --- | --- |
| `depositJunior(mstrAmount)` | anyone (when unpaused) | amount > 0 | Pulls exact MSTR; enqueues Open; tries match |
| `withdrawUnmatched(positionId)` | position owner | Open, not settled | Returns all MSTR; no coupon |
| `earlyExit(positionId)` | position owner | Matched, before term, not settled | Closes position; coupon from fees; gap via MSTR from position; pushes leftover MSTR/USDG to junior |

### Senior

| Function | Who | Preconditions | Effects / funds |
| --- | --- | --- | --- |
| `depositSenior(amount)` | anyone (when unpaused) | amount > 0 | Pulls exact USDG; increases principal; FIFO match |
| `withdrawSenior(principalAmount)` | senior | `principalAmount ≤ freePrincipal` | Returns idle principal + claimable yield USDG + claimable MSTR |

### Fees / backstop

| Function | Who | Preconditions | Effects / funds |
| --- | --- | --- | --- |
| `accrueLpFee(positionId, amount)` | anyone | Matched, not settled | Pulls exact USDG; cut → backstop; rest → position |
| `fundBackstop(amount)` | anyone | amount > 0 | Pulls USDG into `backstop` |

### Settlement / views

| Function | Who | Preconditions | Effects / funds |
| --- | --- | --- | --- |
| `settle(positionId)` | anyone | Matched, term elapsed, not settled | Maturity waterfall; pushes to junior; credits senior accumulators |
| `previewEarlyExit` / `previewEarlyExitCoupon` | view | — | Coupon + share sale preview |
| `previewBorrowFee` / `previewSeniorAssets` / `previewMstrToCover` | view | — | Quoting helpers |
| `freeSenior` / `freePrincipal` / `isMatched` / `mark` | view | — | Capacity / MTM |
| `joinPool(bytes)` | anyone | — | Reverts `ExternalLpForbidden` |

Constructor immutables: `mstr`, `usdg`, `oracle`, `term`, `borrowAprWad`, `protocolCutWad`, `owner`.

---

## 5. Accounting

### What “whole” means

If fees accrue at the **4% floor** on LP notional for the week, then after the **20% protocol cut**, remaining fees cover the senior **borrow fee** so:

- Junior can withdraw **all shares** (and leftover fees), and
- Senior receives **principal + borrow fee** in USDG (or MSTR if the fee waterfall sold shares).

4% is **not** an extra tip to the lender on top of the borrow fee.

### Early-exit coupon

```
couponOwed = seniorPrincipal * EARLY_EXIT_APR_WAD * elapsed / (WAD * YEAR)
           = principal * 0.04 * elapsed_seconds / (365 days)
```

Waterfall:

1. `fromPositionFees = min(position.feeUsdg, couponOwed)`
2. `usdgGap = couponOwed - fromPositionFees`
3. If gap > 0: `mstrSold = ceil(gap / price)` from **this position’s MSTR** (credited to seniors)
4. Junior receives `mstrAmount - mstrSold` and any leftover fees

No external USDG pull from the junior’s wallet on early exit.

### Maturity borrow fee

```
borrowFeeOwed = seniorPrincipal * borrowAprWad * term / (WAD * YEAR)
```

Deploy constants: borrow APR **5%**, term **7 days**, protocol cut **20%**.

Waterfall: position fees → backstop → minimum junior MSTR. Leftover fees go to junior as `juniorYield`.

### Senior claims

On settle/early exit, USDG paid toward fees increases `accYieldPerPrincipal`; sold MSTR increases `accMstrPerPrincipal`. Seniors harvest via `withdrawSenior`.

---

## 6. Security model

| Control | Behavior |
| --- | --- |
| Pause | Blocks `depositJunior` / `depositSenior` only. Exit, settle, and withdraw remain available |
| Owner powers | Pause/unpause + rescue of non-principal tokens |
| Owner cannot | Withdraw MSTR/USDG, change oracle/term/APR/cut, or pull principal via rescue |
| Reentrancy | `nonReentrant` on deposits, withdraws, fees, early exit, settle, rescue |
| CEI | State + events updated before external token pushes on exit paths |
| Fee-on-transfer | Rejected (`FeeOnTransfer`) on pulls |
| External LP | `joinPool` forbidden; no PoolManager allowance |
| Oracle | Immutable oracle address on the vault |

### Invariants

1. `reservedSenior ≤ totalSeniorPrincipal`
2. Settled positions never pay twice (`settled` latch)
3. Owner rescue cannot touch `mstr` / `usdg`
4. Matched MSTR leaves only via junior payout or senior MSTR claims after sale-to-cover
5. No external PoolManager approvals from the vault

---

## 7. Threat notes

| Attack / misuse | Mitigation | Test |
| --- | --- | --- |
| Random drains senior/junior funds | No open withdraw; settle pays owners not caller | `test_randomAddressCannotPullFunds` |
| Owner steals principal via rescue | `PrincipalToken` revert | `test_ownerCannotStealPrincipal` |
| Double early exit / settle | `AlreadySettled` | `test_earlyExitCannotDoubleExit` |
| Attacker early-exits someone else | `NotJunior` | `test_earlyExitOnlyJunior` |
| Early exit after term | `TermElapsed`; must `settle` | `test_earlyExitBlockedAfterTerm` |
| Fee on unmatched position | `NotMatched` | `test_accrueFeesRequiresMatched` |
| Deposit while paused | `Paused` | `test_pauseBlocksNewDeposits` |
| External LP beside vault | `ExternalLpForbidden` | `test_externalCannotLpBesideVault` |
| Lender pulls matched USDG | `InsufficientFree` until replace/close | `test_lenderReplaceUnlocksExit` |
| Reentrancy on token callbacks | `nonReentrant` | Covered by modifier on value paths |
| Fee-on-transfer silent credit | Balance delta check | `FeeOnTransfer` in `_pullExact` |
| Wrong-chain broadcast | Deploy script refuses chain ids 4663 and 1 | `DeployCarryTestnet` guards |

---

## 8. Carry UI → contract mapping

| Carry screen / control | Vault call | Notes |
| --- | --- | --- |
| Deposit MSTR / Deposit {sym} | `mstr.approve` → `depositJunior(amount)` | Pause-gated; Open if no USDG |
| Position badge **Open** | `!isMatched(id)` | Unmatched; no fees yet |
| Position badge **Active** | `isMatched(id)` | 7-day timer from `openedAt` |
| Lend / deposit USDG (lender) | `usdg.approve` → `depositSenior(amount)` | FIFO-matches Open queue |
| Active position view | `positions(id)`, `mark(id)`, `previewEarlyExit(id)` | Read-only |
| **Withdraw Early** (stock) | `earlyExit(id)` | Junior only; fees then MSTR from position |
| Withdraw (Open / unmatched stock) | `withdrawUnmatched(id)` | Full MSTR back, no coupon |
| Withdraw after 7d / settle | `settle(id)` then junior already paid | Anyone can call settle |
| Lender withdraw **idle** | `withdrawSenior(freePrincipal(me))` | Available when idle > 0 |
| Lender withdraw **matched** | More `depositSenior` (replace) or wait for close | Else `InsufficientFree` |
| Fee / rewards display | Driven by `accrueLpFee` | USDG pushed into position fees |

---

## 9. Testnet addresses (Robinhood Chain Testnet 46630)

| Item | Value |
| --- | --- |
| Network | Robinhood Chain Testnet |
| Chain ID | **46630** |
| RPC | `https://rpc.testnet.chain.robinhood.com` |
| Explorer | `https://explorer.testnet.chain.robinhood.com` |

### Primary vault

| Name | Address | Explorer |
| --- | --- | --- |
| **LeveredLpVault** | `0x72A053120f03B10c5506d2325f92F59B0FfC36c8` | [verified](https://explorer.testnet.chain.robinhood.com/address/0x72A053120f03B10c5506d2325f92F59B0FfC36c8?tab=contract) |

### Supporting contracts

| Name | Address | Explorer |
| --- | --- | --- |
| mockMstr (stock token) | `0x762019309B536bbb89577422FaaFBeC9659f8728` | [verified](https://explorer.testnet.chain.robinhood.com/address/0x762019309B536bbb89577422FaaFBeC9659f8728?tab=contract) |
| mockUsdg | `0x25030Bff74764aD72b912276a603717DB1C00644` | [verified](https://explorer.testnet.chain.robinhood.com/address/0x25030Bff74764aD72b912276a603717DB1C00644?tab=contract) |
| mockOracle ($100 WAD) | `0xc74Af7E23A2B4b46B5Fe05E5c7c5ec0BB5dbc5B7` | [verified](https://explorer.testnet.chain.robinhood.com/address/0xc74Af7E23A2B4b46B5Fe05E5c7c5ec0BB5dbc5B7?tab=contract) |
| mockFeePool | `0xa4122524aD97Aab05cAC7F99c04Cd060D02F0771` | [verified](https://explorer.testnet.chain.robinhood.com/address/0xa4122524aD97Aab05cAC7F99c04Cd060D02F0771?tab=contract) |
| vaultOwner | `0xcA44F2dbB2D43b93b39F01B88E0f0e2966983c57` | [view](https://explorer.testnet.chain.robinhood.com/address/0xcA44F2dbB2D43b93b39F01B88E0f0e2966983c57) |

Deploy constants: term **7 days**, borrow APR **5%**, protocol cut **20%**, oracle **$100** WAD.

---

## Source paths

| Path | Role |
| --- | --- |
| `contracts/src/LeveredLpVault.sol` | Vault |
| `contracts/src/mocks/MockERC20.sol` | Testnet tokens |
| `contracts/src/mocks/MockOracle.sol` | Testnet price feed |
| `contracts/src/mocks/MockFeePool.sol` | Fee pusher |
| `contracts/test/LeveredLpVault.t.sol` | Foundry tests |
| `contracts/script/DeployCarryTestnet.s.sol` | RH testnet 46630 deploy |
| `CARRY_CONTRACT.md` | Full contract pack (repo root) |
| `CARRY_TESTNET.md` | Deploy addresses + explorer links |
