# Stage 2: matched capital into each market's DualPool pool

Written 2026-10-18 for maker and the contract dev. Builds on the pool flow spec and docs/MULTI_MARKET.md.

## What reading the hook showed

- `addLiquidity` mints shares pro-rata to the pool's reserves, so a deposit must match the pool's current token ratio. A 50/50-by-value position usually leaves a little of one token over.
- Trading fees are charged by Uniswap v4 straight into the reserves. The hook keeps no fee counter, so "fees earned" can't be read on chain on its own: a pool share's value moves with both fees and price.
- `removeLiquidity` is blocked for `minDepositBlocks` after the depositor's last deposit. The vault's strategy is one depositor for every position in a market, so any lock would freeze closes whenever a new position opens.

## How Stage 2 works

1. **One pool per market, one hook.** The owner opens a pool per stock on the DualPool hook and registers it with `setMarketPool(marketId, key)`. Markets without a pool keep today's Stage 1 flow, so markets can move over one at a time.
2. **Opening.** At match the vault sends the position's stock and its matched USDG to the strategy, which adds as much as the pool ratio allows. The position records its LP shares and how much of each token went in. Leftover stock stays in the vault for the position; leftover USDG stays in the lender pool, earning Morpho.
3. **Closing (settle or early exit).** The strategy removes the position's shares and returns `(USDG, stock)`. Then, in the agreed order:
   - Measure the position's trading result (see the decision below).
   - Treasury 20%, senior 40%, junior 40% of a positive result.
   - The senior is paid in USDG: the USDG it put in, plus Morpho yield on it, plus its 40%. Morpho yield is read from the Steakhouse vault's share price at open and at close, so it floats and nothing is stored as a rate.
   - If the USDG that came back is short, stock is sold through the router for the gap. If the pool is worth less than the senior's principal, the senior gives up its Morpho yield first, then the backstop covers the rest.
   - The junior gets everything left, in stock plus any USDG over.
4. **Lender NAV.** Matched senior USDG keeps counting at face value while in the pool (the senior is protected), and the gain or cover is booked at close.

## Defaults I'm taking (say if you want different)

- Carry pools run with `minDepositBlocks = 0`. The strategy isn't the hook owner, so external deposits have to be on. The lock is per depositor, and every new position is a deposit by the strategy, so any lock would stop all of that market's closes for a few blocks after each new match.
- A position enters its pool once it is fully matched. A partly matched position stays out of the pool (USDG earning Morpho, stock held) until it fills.
- The sell step uses the existing `sellSharesRouter` slot, one router for all markets. On testnet it's the mock router.
- The pool logic lives in a new strategy version, so the vault stays under the size limit (1,977 bytes spare today). The strategy has no owner and no upgrade path, as now.

## Built (branch claude/testnet-checks-ari49i)

Option A is built and tested against a real v4 PoolManager and the real hook: fees split 20/40/40, a price drop pays the senior in USDG by selling stock, and a crash past the range is covered by the backstop. The vault is at 23,605 bytes (971 spare) after dropping the ignored cover-mode overloads and the retired SellShares toggle. Previews (`previewSettle`, `previewEarlyExit`) still show only the fee-pool part for pooled positions.

## The one decision for maker: how "fees" are measured

- **A. Net result vs holding (recommended).** At close, compare what the pool share is worth with what the same USDG and stock would be worth if just held (USDG earning Morpho). Anything above that is the result split 40/40/20; anything below is absorbed by the junior first. Fully on chain, no keeper, works for every market. Trading fees and the pool's buy/sell effect are netted together, which matches "fees negate IL or add to the total".
- **B. Keeper reports fees.** An off-chain job reads each swap's fee and books it per position. Gross fees, but it trusts the keeper and adds an operations job per market.
- **C. Add fee counting to the hook.** Gross fees, on chain, but it changes the vendored hook and adds code to review in the Oct 26-30 window.
