---
title: "Carry / Levered LP Vault — Contract Overview"
subtitle: "Robinhood Chain Testnet (46630) — live UUPS v2.5-funder-idle"
---

# Carry / Levered LP Vault — Contract Overview

Grant and audit reference for `LeveredLpVault` on **Robinhood Chain Testnet (chain id 46630)**.

**Product vault (PROXY):** [`0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd`](https://explorer.testnet.chain.robinhood.com/address/0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd?tab=contract) (UUPS)  
**Implementation:** [`0xe498F43ED10a37E22Fe046A3FDAAFD4E9080d0e8`](https://explorer.testnet.chain.robinhood.com/address/0xe498F43ED10a37E22Fe046A3FDAAFD4E9080d0e8?tab=contract) (`version()` = **`v2.5-funder-idle`**)  
**Site:** [usecarry.io](https://usecarry.io)  
**v1 grant/history reference (not in use):** [`0x72A053120f03B10c5506d2325f92F59B0FfC36c8`](https://explorer.testnet.chain.robinhood.com/address/0x72A053120f03B10c5506d2325f92F59B0FfC36c8?tab=contract)

Full pack: [`../../CARRY_CONTRACT.md`](../../CARRY_CONTRACT.md). Accounting: [`../../docs/ACCOUNTING_V25.md`](../../docs/ACCOUNTING_V25.md).

---

## 1. Overview

Carry pairs a stock-token holder (**junior**) with a USDG lender (**senior**) into a **50/50 book**: junior posts MSTR, senior posts matching USDG. Equity tracks the stock while the book accrues LP fees over a fixed term. This vault is the **custody and accounting layer**.

- Junior deposits MSTR → **Idle** until USDG matches, then **Active** for **7 days**. Product states: Idle / Active / Boosted / Closed.
- Senior accrual = locked Morpho native supply rate (stub **3.9%**, owner cap **≤5%**) × elapsed.
- Fee waterfall runs only at `claimFees` / `earlyExit` / `settle` (no cut on fee-in).
- **Early exit** cover: Wallet / IdleCarry / SellShares (junior only, NO backstop). **Settle:** backstop first, then junior Wallet / IdleCarry / SellShares; **default = IdleCarry**.
- Lenders withdraw **their own idle** USDG anytime; matched USDG returns to that lender’s idle on close.

### Contract snapshot

| Item | Value |
| --- | --- |
| Contract | `LeveredLpVault` / `LeveredLpVaultV2` (UUPS PROXY product CA) |
| Tokens / oracle | Immutable `mstr`, `usdg`; immutable `IPriceOracle` |
| Term / Morpho rate | Immutable `term` ≤ 7 days; `morphoRateWad` ≤ 5%, locked at first match |
| Fee cuts | Treasury base 20% + Boosted STRATEGY tiers (15/10/5%) + senior perf 20% |
| Accounting | Per-lender idle; FIFO funders; yield to position funders |
| Caps | Min $25; market $25k senior/junior; no per-wallet cap |
| Unpaid accrual | Carried on position when fees &lt; accrual |
| Pause / reentrancy | Owner pause gates deposits; `nonReentrant` on value paths |
| External LP | No PoolManager approvals; `joinPool` reverts |

Inventory is held inside the vault. `mark()` reports 2× equity vs an unlevered 50/50 √p comparison without moving inventory.

---

## 2. Actors

| Actor | Role | Key actions |
| --- | --- | --- |
| **Junior** (stock depositor) | Posts MSTR | `depositJunior`, `withdrawUnmatched`, `earlyExit`, gasCredit, auto-compound |
| **Senior** (lender) | Posts USDG | `depositSenior`, `withdrawSenior` (own idle + claims), `seniorEarlyExit` |
| **Owner / protocol** | Pause + upgrade + knobs | `pause`, `unpause`, UUPS upgrade, caps/tiers; cannot pull MSTR/USDG principal |
| **Fee source** | Accrues LP fees | `accrueLpFee` / `MockFeePool.payFee` |
| **Anyone** | Keepers | `settle` after term when residual cover is zero |

---

## 3. Lifecycle

1. **Deposit stock** — `depositJunior(mstrAmount)`. Partial match OK; residual stays Idle.
2. **Lend USDG** — `depositSenior(amount)`. FIFO-matches Idle juniors; records funder slices; first match locks rate/cut and starts the term clock.
3. **Active** — Timer = `term` from first match. Accrual uses locked Morpho rate (≤5%).
4. **Fee accrual** — `accrueLpFee` pulls raw USDG onto the position (no cut on fee-in).
5. **claimFees / early exit / settle** — Maker waterfall only here. Early exit: junior cover only (NO backstop). Settle: backstop first, then junior cover; default IdleCarry.
6. **Lender exit** — `freePrincipal = seniorIdle` (own idle only); matched size returns to that lender’s idle on close.

---

## 4. Function reference

### Admin

| Function | Who | Preconditions | Effects / funds |
| --- | --- | --- | --- |
| `pause()` / `unpause()` | owner | — | Gates new deposits |
| `rescueToken(token,to,amount)` | owner | `token ∉ {mstr,usdg}` | Transfers non-principal token |
| Caps / tiers / rate | owner | — | `setDepositCaps`, `setMinDepositUsdg`, `setBoostTiers`, `setMorphoRate`, … |

### Junior

| Function | Who | Preconditions | Effects / funds |
| --- | --- | --- | --- |
| `depositJunior(mstrAmount)` | anyone (when unpaused) | min notional | Pulls MSTR; enqueues Idle; tries match |
| `withdrawUnmatched(positionId)` | position owner | Idle | Returns all MSTR; gasCredit refund |
| `earlyExit(positionId[, mode])` | position owner | Matched, before term | Maker waterfall; cover Wallet / Idle / SellShares |

### Senior

| Function | Who | Preconditions | Effects / funds |
| --- | --- | --- | --- |
| `depositSenior(amount)` | anyone (when unpaused) | min | Credits own idle; FIFO match |
| `withdrawSenior(principalAmount)` | senior | `≤ freePrincipal` (own idle) | Idle principal + claimable yield/MSTR |

### Fees / settle / views

| Function | Who | Preconditions | Effects / funds |
| --- | --- | --- | --- |
| `accrueLpFee` / `claimFees` / `fundBackstop` | see full pack | — | Raw fee-in; waterfall on claim |
| `settle(positionId[, mode])` | anyone / junior | term elapsed | Default IdleCarry; no MSTR sold unless SellShares |
| `seniorIdle` / `freePrincipal` / `isMatched` / `mark` | view | — | Per-lender idle / MTM |
| `joinPool(bytes)` | anyone | — | Reverts `ExternalLpForbidden` |

---

## 5. Accounting

```
accrual = unpaidSeniorAccrual
        + seniorPrincipal * morphoRateLocked * elapsed / (WAD * YEAR)
```

Waterfall at claim/exit/settle:

```
seniorFloor = min(gross, accrual)
treasury    = min(left, gross × cut)   // base 20%; Boosted tiers 15/10/5%
seniorPerf  = min(left, gross × 0.20)
junior      = remainder
```

v2.5: per-lender idle, FIFO funders, yield to position funders only. See [`ACCOUNTING_V25.md`](../../docs/ACCOUNTING_V25.md).

---

## 6. Security model

| Control | Behavior |
| --- | --- |
| Pause | Blocks deposits only; exits/settle/withdraw remain |
| Owner cannot | Pull MSTR/USDG principal via rescue |
| Reentrancy | `nonReentrant` on value paths |
| Fee-on-transfer | Rejected on pulls |
| External LP | Forbidden |
| Impl size | ~32KB exceeds EIP-170; OK on RH testnet; shrink before mainnet |

Details: [`SECURITY_V2.md`](../../docs/SECURITY_V2.md).

---

## 7. Carry UI → contract mapping

| Carry screen / control | Vault call | Notes |
| --- | --- | --- |
| Deposit MSTR | `depositJunior` | Idle if no USDG; min $25 |
| Badge **Idle** / **Active** / **Boosted** / **Closed** | match + settled + boost flags | Not Open/Settled |
| Lend USDG | `depositSenior` | Own idle + FIFO match |
| Withdraw Early | `earlyExit(id, mode)` | Wallet / Idle / SellShares |
| Settle | `settle(id[, mode])` | Default IdleCarry |
| Lender idle withdraw | `withdrawSenior(freePrincipal(me))` | Own idle only |

---

## 8. Testnet addresses (Robinhood Chain Testnet 46630)

| Item | Value |
| --- | --- |
| Network | Robinhood Chain Testnet |
| Chain ID | **46630** |
| RPC | `https://rpc.testnet.chain.robinhood.com` |
| Explorer | `https://explorer.testnet.chain.robinhood.com` |
| Site | [usecarry.io](https://usecarry.io) |

### Product vault (UUPS proxy)

| Name | Address |
| --- | --- |
| **LeveredLpVault (PROXY)** | `0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd` |
| implementation (`v2.5-funder-idle`) | `0xe498F43ED10a37E22Fe046A3FDAAFD4E9080d0e8` |
| CarryBook | `0x2988DFc48BE4AB47B40Ad151f1F213619cdB0794` |
| CarryMath | `0x98574A1719E647775BE39Ec713B657c2CF27Adc5` |
| v1 grant reference (not in use) | `0x72A053120f03B10c5506d2325f92F59B0FfC36c8` |

### Supporting contracts

| Name | Address |
| --- | --- |
| mockMstr | `0x762019309B536bbb89577422FaaFBeC9659f8728` |
| mockUsdg | `0x25030Bff74764aD72b912276a603717DB1C00644` |
| mockOracle ($100 WAD) | `0xc74Af7E23A2B4b46B5Fe05E5c7c5ec0BB5dbc5B7` |
| mockFeePool | `0xa4122524aD97Aab05cAC7F99c04Cd060D02F0771` |
| vaultOwner | `0xcA44F2dbB2D43b93b39F01B88E0f0e2966983c57` |

Live deploy constants: term **7 days**, Morpho rate stub **3.9%** (≤5%), treasury base **20%** + Boosted tiers, oracle **$100** WAD, min **$25**, market totals **$25k**, no per-wallet cap.

---

## Source paths

| Path | Role |
| --- | --- |
| `contracts/src/LeveredLpVault.sol` | Vault |
| `CARRY_CONTRACT.md` | Full contract pack |
| `CARRY_TESTNET.md` | Deploy + upgrade addresses |
| `docs/ACCOUNTING_V25.md` | Live accounting model |
| `docs/SETTLE_WATCH.md` | Live Active positions / multi-lender case |
