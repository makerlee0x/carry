# Carry vault accounting v3 (lender pool)

**Money-safety rewrite of the lender side.** Replaces v2.5 per-lender `seniorIdle` + position funders + CarryBook.

## Product CAs

| Role | Address |
| --- | --- |
| **v3 product PROXY (live after deploy)** | see `public/config.json` → `chain.vault` |
| Superseded v2.5 PROXY | `0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd` |
| Version string | `v3-lender-pool` |

v2.5 was **not** UUPS-upgraded in place: open settle-watch positions (#5/#6/#7) and ~4.1k senior USDG remain on the superseded PROXY. v3 is a **fresh UUPS PROXY**.

## Lender pool

- All lender USDG in one pool (`totalSeniorAssets`).
- Non-transferable internal `shares[user]`.
- Round in pool’s favor (deposit shares floor, withdraw shares ceil / assets floor).
- Virtual offset: `VIRTUAL_ASSETS=1`, `VIRTUAL_SHARES=1e6` (`CarryPool.sol`).
- `maxTotalSeniorUsdg = 0` (uncapped). Per-market junior cap kept.
- Senior yield from waterfall **compounds into the pool** (share price rises).
- Lenders paid only USDG (testnet sell-shares credits USDG notionally to pool; treasury cut → backstop).
- Idle Morpho yield: **display-only on testnet** (no on-chain credit until real Morpho sleeve).

## Withdrawals

1. Instant if `_idleUsdg() >= assets` and withdraw queue empty (`wqCumulativeRequested == wqCumulativeFulfilled`).
2. Else FIFO queue: cumulative requested/fulfilled + lazy `claimWithdraw()` (no fulfillment loops).
3. Queued lender keeps locked shares and earns until fulfilled.
4. Queue filled before new junior matching.
5. Lender withdraw never closes a junior position.

## Rate

- Global floating `rateIndex` advanced by owner-set `morphoRateWad` (testnet).
- Positions store `rateIndexSnapshot`; accrual = index delta × principal.
- Interest stops at maturity (`min(now, openedAt+term)`).

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

## Size

Runtime impl measured in Forge (`test_runtimeSize_measured`). **EIP-170 (24576) NOT met yet** (~29.6k). Mainnet path must shrink further before prod.
