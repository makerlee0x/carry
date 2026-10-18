# Markets: one lender pool, many stocks

Decided by maker on 2026-10-18:

- Idle USDG stays in one shared lender pool, for capital efficiency.
- Each stock token is its own market.
- There is no limit on how much lender USDG one stock may use.
- Per-token settings never live in the code.

## On chain (`LeveredLpVault`, `version()` = `v3.1-morpho-yield`)

These are shared by every market:

- Lender shares, the withdraw queue, Morpho parking (`CarryStrategy`), the backstop/treasury and the 40/40/20 fee split.
- One first-come matching queue across all markets.

These are set per market (`markets(id)`):

- Stock token and price oracle. The oracle implements `IPriceOracle.mstrPriceWad()` for its own token.
- `rangeDropWad`: how far below entry a position may fall before it stops rolling. MSTR uses 0.32e18; NVDA would be 0.08e18.
- An optional junior cap (`juniorCapUsdg`, 0 = none) and an `active` flag. Turning `active` off stops new juniors only, and open positions keep running.

Markets are managed by the owner:

- `addMarket(token, oracle, rangeDropWad, juniorCapUsdg)` adds a stock in one transaction, with no new contract and no upgrade.
- `setMarket(id, oracle, rangeDropWad, juniorCapUsdg, active)` changes those settings later.
- A stock token can belong to one market only. `rescueToken` refuses every market token.

How juniors and positions use it:

- Juniors call `depositJunior(marketId, amount)`. The old `depositJunior(amount)` still opens a market 0 (MSTR) position.
- Each position records its `marketId`, and exits return that market's token.
- Auto-compound reopens in the same market.

## Upgrading the live v3 proxy

Run `script/UpgradeV3Proxy.s.sol`, signed by the owner.

- It calls `upgradeToAndCall(newImpl, initializeMarkets())`, which registers the existing `mstr` / `oracle` as market 0 and carries over the junior total.
- The upgrade and `initializeMarkets` must land in the same transaction. Until then, market 0 has no token or oracle.
- The storage layout is unchanged, apart from 3 new slots taken from `__gap` (`markets`, `marketCount`, `isMarketToken`). `Position` gains `marketId` at the end, so older positions read market 0.
- Fork check: `TESTNET_RPC=https://rpc.testnet.chain.robinhood.com forge test --match-contract V3UpgradeFork` upgrades the live proxy on a fork and settles a live position through the new code.

App changes, for the UX thread:

- `positions(id)` returns one more field (`marketId`).
- Junior deposits for any market other than MSTR use the two-argument `depositJunior`.
