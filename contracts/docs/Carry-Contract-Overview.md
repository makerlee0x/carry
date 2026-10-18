---
title: "Carry / Levered LP Vault — Contract Overview"
subtitle: "Robinhood Chain Testnet (46630) — live UUPS v3-lender-pool"
---

# Carry / Levered LP Vault — Contract Overview

Grant and audit reference for `LeveredLpVault` on **Robinhood Chain Testnet (chain id 46630)**.

**Product vault (PROXY):** [`0x24B799026AA7baa6856bCFD00c1Be1f583A83e35`](https://explorer.testnet.chain.robinhood.com/address/0x24B799026AA7baa6856bCFD00c1Be1f583A83e35?tab=contract) (UUPS)  
**Implementation:** [`0x7BeED7F65A9D4aF4E67553d984800F6268a3778E`](https://explorer.testnet.chain.robinhood.com/address/0x7BeED7F65A9D4aF4E67553d984800F6268a3778E?tab=contract) (`version()` = **`v3-lender-pool`**)  
**Site:** [usecarry.io](https://usecarry.io)  
**Superseded v2.5 PROXY (history only):** `0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd`  
**v1 grant/history reference (not in use):** [`0x72A053120f03B10c5506d2325f92F59B0FfC36c8`](https://explorer.testnet.chain.robinhood.com/address/0x72A053120f03B10c5506d2325f92F59B0FfC36c8?tab=contract)

Full pack: [`../../CARRY_CONTRACT.md`](../../CARRY_CONTRACT.md). Accounting: [`../../docs/ACCOUNTING_V3.md`](../../docs/ACCOUNTING_V3.md).

This overview describes the source on `main`. The live implementation predates three merged changes: the EIP-170 fit (#3), rolling positions (#16) and `StrategyBoostHook` (#23). They reach testnet with the next owner-signed upgrade.

**Lender rate note.** The Morpho rate here is an owner-set testnet stub, not a promised APY. The mainnet lender return is being reworked to Morpho yield (floating) + Carry's share of fees, with no fixed rate or floor (issue #20, PR #21).

---

## 1. Overview

Carry pairs a stock-token holder (**junior**) with a USDG lender (**senior**) into a **50/50 book**: junior posts MSTR, lenders supply matching USDG from a shared pool. Equity tracks the stock while the book accrues LP fees. This vault is the **custody and accounting layer**.

- Junior deposits MSTR → **Idle** until pool USDG matches, then **Active**. Product states: Idle / Active / Boosted / Closed.
- Term is **7 days**; at term a position rolls rather than closing, and only the junior settles a healthy one. A position more than 32% below entry stops rolling; 48h after the last term boundary anyone can settle it.
- Senior accrual = principal × change in a floating rate index driven by `morphoRateWad` (testnet stub, cap **≤5%**).
- Fee waterfall runs only at `claimFees` / `earlyExit` / `settle` (no cut on fee-in).
- **Early exit** (first term only) cover: Wallet / IdleCarry / SellShares (junior only, NO backstop). **Settle:** backstop first, then junior cover; **default = IdleCarry**.
- Lenders hold shares in **one USDG pool**. Withdraw is instant when idle USDG covers it, else FIFO queue + `claimWithdraw()`.

### Contract snapshot

| Item | Value |
| --- | --- |
| Contract | `LeveredLpVault` / `LeveredLpVaultV2` (UUPS PROXY product CA) |
| Tokens / oracle | Immutable `mstr`, `usdg`; immutable `IPriceOracle` |
| Term / Morpho rate | Immutable `term` ≤ 7 days; `morphoRateWad` ≤ 5% (testnet stub) drives a floating `rateIndex` |
| Fee cuts | Treasury base 20% (Boosted cut from `boostHook`, capped at base) + senior perf 20% |
| Accounting | One lender pool (`totalSeniorAssets`), non-transferable internal shares; yield compounds into the pool |
| Caps | Min $25; senior pool uncapped; junior market $25k; **no per-wallet cap** on any market |
| Unpaid accrual | Carried on position when fees &lt; accrual |
| Pause / reentrancy | Owner pause gates deposits; `nonReentrant` on value paths |
| External LP | No PoolManager approvals; `joinPool` reverts |
| Runtime size | `main` ~23.4KB (under EIP-170); live impl ~29.6KB (testnet only) |

Inventory is held inside the vault. `mark()` reports 2× equity vs an unlevered 50/50 √p comparison without moving inventory.

---

## 2. Actors

| Actor | Role | Key actions |
| --- | --- | --- |
| **Junior** (stock depositor) | Posts MSTR | `depositJunior`, `withdrawUnmatched`, `earlyExit`, `claimFees`, `settle`, gasCredit, auto-compound |
| **Senior** (lender) | Posts USDG into the pool | `depositSenior`, `withdrawSenior` (instant or queued), `claimWithdraw` |
| **Owner / protocol** | Pause + upgrade + knobs | `pause`, `unpause`, UUPS upgrade, caps, `setBoostHook`, `setMorphoRate`; cannot pull MSTR/USDG principal |
| **Boost hook** | Maps STRATEGY stake to a treasury cut | `StrategyBoostHook.treasuryCutOf` (Level I-V, placeholder 17.5/16.25/13.75/10/5%) |
| **Fee source** | Accrues LP fees | `accrueLpFee` / `MockFeePool.payFee` |
| **Anyone** | Keepers | `settle` a position that stopped rolling, after the 48h grace |

---

## 3. Lifecycle

1. **Deposit stock** — `depositJunior(mstrAmount)`. Partial match OK; residual stays Idle.
2. **Lend USDG** — `depositSenior(amount)`. Mints pool shares; fills the withdraw queue, then FIFO-matches Idle juniors. First match snapshots the rate index, locks the treasury cut and starts the term clock.
3. **Active** — Accrual follows the floating rate index. At term the position rolls.
4. **Fee accrual** — `accrueLpFee` pulls raw USDG onto the position (no cut on fee-in).
5. **claimFees / early exit / settle** — Maker waterfall only here. Early exit: junior cover only (NO backstop). Settle: backstop first, then junior cover; default IdleCarry.
6. **Lender exit** — `withdrawSenior(assets)` instant when idle covers and the queue is empty; else queued, and `claimWithdraw()` pays the locked shares' value once filled.

---

## 4. Function reference

### Admin

| Function | Who | Preconditions | Effects / funds |
| --- | --- | --- | --- |
| `pause()` / `unpause()` | owner | — | Gates new deposits |
| `rescueToken(token,to,amount)` | owner | `token ∉ {mstr,usdg}` | Transfers non-principal token |
| Caps / boost / rate | owner | — | `setDepositCaps`, `setMinDepositUsdg`, `setBoostHook`, `setMorphoRate`, `setTreasuryCuts`, … |

### Junior

| Function | Who | Preconditions | Effects / funds |
| --- | --- | --- | --- |
| `depositJunior(mstrAmount)` | anyone (when unpaused) | min notional | Pulls MSTR; enqueues Idle; tries match |
| `withdrawUnmatched(positionId)` | position owner | Idle | Returns all MSTR; gasCredit refund |
| `earlyExit(positionId[, mode])` | position owner | Matched, first term | Maker waterfall; cover Wallet / Idle / SellShares |

### Senior

| Function | Who | Preconditions | Effects / funds |
| --- | --- | --- | --- |
| `depositSenior(amount)` | anyone (when unpaused) | min | Mints pool shares; fills queue; FIFO match |
| `withdrawSenior(assets)` | lender | `≤` free share value | Instant if idle covers and queue empty; else queued |
| `claimWithdraw()` | lender | queued request filled | Pays filled USDG |

### Fees / settle / views

| Function | Who | Preconditions | Effects / funds |
| --- | --- | --- | --- |
| `accrueLpFee` / `claimFees` / `fundBackstop` | see full pack | — | Raw fee-in; waterfall on claim |
| `settle(positionId[, mode])` | junior; anyone once a position stopped rolling | term elapsed | Default IdleCarry |
| `freePrincipal` / `convertToAssets` / `claimableWithdraw` / `currentRateIndex` / `isMatched` / `mark` | view | — | Pool, queue, rate, MTM |
| `joinPool(bytes)` | anyone | — | Reverts `ExternalLpForbidden` |

---

## 5. Accounting

```
accrual = unpaidSeniorAccrual
        + seniorPrincipal * (rateIndexNow - rateIndexSnapshot) / WAD
```

Waterfall at claim/exit/settle:

```
seniorFloor = min(gross, accrual)
treasury    = min(left, gross × cut)   // base 20%; Boosted cut from boostHook, capped at base
seniorPerf  = min(left, gross × 0.20)
junior      = remainder
```

Senior USDG goes to the lender pool (share price rises). See [`ACCOUNTING_V3.md`](../../docs/ACCOUNTING_V3.md). The `seniorFloor` / rate-index part is what the planned no-fixed-rate rework removes.

---

## 6. Security model

| Control | Behavior |
| --- | --- |
| Pause | Blocks deposits only; exits/settle/withdraw remain |
| Owner cannot | Pull MSTR/USDG principal via rescue |
| Reentrancy | `nonReentrant` on value paths |
| Fee-on-transfer | Rejected on pulls |
| External LP | Forbidden |
| Boost hook | Result capped at base cut; a bad hook can only lower Carry's take |
| Impl size | `main` under EIP-170; live testnet impl over it until upgraded |

Details: [`SECURITY_V3.md`](../../docs/SECURITY_V3.md).

---

## 7. Carry UI → contract mapping

| Carry screen / control | Vault call | Notes |
| --- | --- | --- |
| Deposit MSTR | `depositJunior` | Idle if no USDG; min $25 |
| Badge **Idle** / **Active** / **Boosted** / **Closed** | match + settled + boost flags | Not Open/Settled |
| Lend USDG | `depositSenior` | Pool shares; fills queue then FIFO match |
| Withdraw Early | `earlyExit(id, mode)` | Wallet / Idle / SellShares |
| Settle | `settle(id[, mode])` | Default IdleCarry |
| Lender withdraw | `withdrawSenior(assets)` / `claimWithdraw()` | Instant or queued |

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
| **LeveredLpVault (PROXY)** | `0x24B799026AA7baa6856bCFD00c1Be1f583A83e35` |
| implementation (`v3-lender-pool`) | `0x7BeED7F65A9D4aF4E67553d984800F6268a3778E` |
| CarryMath | `0x86b2f56e58c38f19559f28e1463f2dcac1c59344` |
| CarryPool | `0xf1d5cb8c25bc1b2ed147cb5f2f63ebfacddbdc07` |
| CarryCover | `0x99f1702044603df846a038d4c1fb8563a57e1ebd` |
| v2.5 PROXY (superseded) | `0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd` |
| v1 grant reference (not in use) | `0x72A053120f03B10c5506d2325f92F59B0FfC36c8` |

### Supporting contracts

| Name | Address |
| --- | --- |
| mockMstr | `0x762019309B536bbb89577422FaaFBeC9659f8728` |
| mockUsdg | `0x25030Bff74764aD72b912276a603717DB1C00644` |
| mockOracle ($100 WAD) | `0xc74Af7E23A2B4b46B5Fe05E5c7c5ec0BB5dbc5B7` |
| mockFeePool | `0xa4122524aD97Aab05cAC7F99c04Cd060D02F0771` |
| vaultOwner | `0xcA44F2dbB2D43b93b39F01B88E0f0e2966983c57` |

Live deploy settings: term **7 days**, `morphoRateWad` testnet stub (≤5%), treasury base **20%**, oracle **$100** WAD, min **$25**, senior pool uncapped, junior market **$25k**, no per-wallet cap.

---

## Source paths

| Path | Role |
| --- | --- |
| `contracts/src/LeveredLpVault.sol` | Vault |
| `contracts/src/StrategyBoostHook.sol` | Boosted treasury cut from STRATEGY stake |
| `CARRY_CONTRACT.md` | Full contract pack |
| `CARRY_TESTNET.md` | Deploy addresses and txs |
| `docs/ACCOUNTING_V3.md` | Live accounting model |
| `docs/testnet-runs/` | Dated on-chain test passes |
