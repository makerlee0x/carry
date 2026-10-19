# Carry vault accounting v3 (lender pool)

**Money-safety rewrite of the lender side.** Replaces v2.5 per-lender `seniorIdle` + position funders + CarryBook.

## Product CAs

| Role | Address |
| --- | --- |
| **v3 product PROXY** | `0x24B799026AA7baa6856bCFD00c1Be1f583A83e35` (`public/config.json` → `chain.vault`) |
| Live implementation | `0x14732623B077C656527ee5C87812AC23e98c58A5` |
| CarryStrategy | `0x43ec7Ba95FecEBE51B6414f6E300B109E245E6AE` |
| DualPoolHook | `0xaf4a9225b27e48c9989726082014095474756ac0` |
| Superseded v2.5 PROXY | `0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd` |
| Version string | `v3.2-dualpool` |

v2.5 was **not** UUPS-upgraded in place; v3 is a **fresh UUPS PROXY**. v2.5 settle-watch positions #5/#6/#7 have since been settled on the superseded PROXY.

**Live = `main` path** after the 2026-10-18 UUPS upgrade (`docs/testnet-runs/2026-10-18-v32-upgrade.md`). No fixed Morpho coupon; matched inventory can sit in DualPool; idle can go through CarryStrategy → MockMorpho via `deployIdle`.

## Lender pool

- All lender USDG in one pool (`totalSeniorAssets`).
- Non-transferable internal `shares[user]`.
- Round in pool’s favor (deposit shares floor, withdraw shares ceil / assets floor).
- Virtual offset: `VIRTUAL_ASSETS=1`, `VIRTUAL_SHARES=1e6` (`CarryPool.sol`).
- `maxTotalSeniorUsdg = 0` (uncapped). Per-market junior cap kept.
- Senior yield from waterfall **compounds into the pool** (share price rises).
- Lenders paid only USDG (testnet sell-shares credits USDG notionally to pool; treasury cut → backstop).
- Idle Morpho yield on testnet: MockMorpho via CarryStrategy after `deployIdle` (owner). Real Steakhouse Morpho is issue **#20**.

## Withdrawals

1. Instant if `_idleUsdg() >= assets` and withdraw queue empty (`wqCumulativeRequested == wqCumulativeFulfilled`).
2. Else FIFO queue: cumulative requested/fulfilled + lazy `claimWithdraw()` (no fulfillment loops).
3. Queued lender keeps locked shares and earns until fulfilled.
4. Queue filled before new junior matching.
5. Lender withdraw never closes a junior position.

## Rate

- **v3.2:** no owner-set Morpho coupon. Lenders earn strategy/Morpho yield (when idle is deployed) plus Carry fee share at claim/exit/settle.
- Pre-v3.2 docs that mention `morphoRateWad` / fixed floor apply only to superseded `v3-lender-pool` history.
- Live impl: interest stops at maturity (`min(now, openedAt+term)`).
- *main*: positions roll at term; interest accrues until the position closes and only the junior settles a healthy one. Early exit stays inside the first term. A position more than 32% below entry stops rolling; 48h after the last term boundary anyone can settle it (a non-junior caller covers from fees and junior idle only, the rest is forgiven).
- *main*: a filled queued withdrawal pays what the locked shares are worth at claim time.
- **Planned:** the stored rate goes away. Lender return becomes Morpho yield (floating) + Carry's share of fees, with no floor or coupon (issue #20, PR #21, spec in progress).

## Removed vs v2.5

`seniorIdle`, idle-lender queue, `positionFunders`, `CarryBook`, `_rematchPositionFromIdle`, `seniorEarlyExit`, time-weighted + legacy yield indices.

## Cover (never forgiven)

**Early exit (no backstop):** fees → junior lender balance (share assets) → wallet USDG → sell-shares if opted. Treasury cut only on junior-paid cover.

**Maturity/settle:** backstop first → junior idle → wallet → sell-shares if opted → **pool-wide idle last resort**. Treasury cut only on junior-paid cover (not backstop/pool).

## Same-pass fixes

- `withdrawUnmatched` always pays wallet (no auto-compound reopen).
- Auto-compound under `$25` → wallet.
- Gas refund only when deposit matches, scaled to matched/deposited.
- `treasuryCutIsSet` flag (clear ≠ “set to 0” confusion for callers).
- Backstop withdraw floor: `totalSeniorAssets + backstop + totalUnsplitFees`.

## Boost (*main*)

The vault asks `boostHook.treasuryCutOf(junior, baseCut)` at match and caps the answer at the base cut, so a hook can only lower Carry's take. `StrategyBoostHook` maps `StrategyStaking.stakedOf` to Level I-V (placeholder 17.5 / 16.25 / 13.75 / 10 / 5%). The old owner-set boost stub is gone; its storage slots stay for an in-place upgrade.

## Caps

$25 min deposit/match, senior pool uncapped, junior market $25k, **no per-wallet cap** on any market.

## Size

Runtime impl measured in Forge (`test_runtimeSize_measured`). Live impl ~29.6k (deployed with the size limit disabled). On `main` the vault is ~24.4k, under EIP-170 (24,576).
