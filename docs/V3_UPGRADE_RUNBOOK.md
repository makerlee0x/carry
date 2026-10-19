# Runbook: upgrade the live testnet v3 proxy to v3.2-dualpool

For maker's dev (owner key) and the Testnet thread. Testnet 46630 only. Nothing here is a mainnet step.

This upgrades the live proxy `0x24B799026AA7baa6856bCFD00c1Be1f583A83e35` once to `main` (Stage 1 #27, multi-market #29, Stage 2 #30), then wires the Morpho strategy, the MSTR DualPool pool and the sell router.

> **DONE 2026-10-18 CDT.** Live `version() = v3.2-dualpool`. Record: [`docs/testnet-runs/2026-10-18-v32-upgrade.md`](./testnet-runs/2026-10-18-v32-upgrade.md). New impl `0x2A6b…A29D`, strategy `0x43ec…E6AE`, router `0x687f…424C`. Keep this runbook for rollback / re-wire.

## Do not start before

1. **v3 #1, #3 and #5 are settled and recorded.** ✅
2. **The site release is ready to go out right after the upgrade** (see "Site changes" below). ✅ ABIs + one-arg settle/earlyExit shipped with the upgrade commit.

## Who signs what

| Step | Signer | Why |
|---|---|---|
| Deploy the new vault implementation | anyone (the throwaway `0x090B…0809` is fine) | Plain contract deploy; it has no owner and does nothing until the proxy points at it |
| Deploy the new `CarryStrategy` | throwaway | Immutable, no owner; its constructor fixes the vault and the Morpho vault |
| Deploy and fund the testnet sell router (`MockMstrSellRouter`) | throwaway | Mock with public `setPrice`; mock USDG has a public mint |
| `upgradeToAndCall(newImpl, initializeMarkets())` | **owner `0xcA44…3c57`** | `onlyOwner` (UUPS) |
| `setStrategy`, `setMarketPool`, `setSellSharesRouter`, `deployIdle` | **owner** | `onlyOwner` |
| Smoke test (lend, junior, early exit) | throwaway | Ordinary user calls |
| DualPool hook settings | throwaway (current hook owner) | Pool `0xaf4a…6ac0` is already set up with external deposits on and `minDepositBlocks = 0`. No change is needed. |

The owner key is never shared with Claude. The dev runs the owner steps from their own machine.

## Addresses

| What | Address |
|---|---|
| Vault proxy (v3) | `0x24B799026AA7baa6856bCFD00c1Be1f583A83e35` |
| Current implementation (for rollback) | `0x7beed7f65a9d4af4e67553d984800f6268a3778e` (re-read before upgrading, see snapshot) |
| Owner | `0xcA44F2dbB2D43b93b39F01B88E0f0e2966983c57` |
| mockUSDG | `0x25030Bff74764aD72b912276a603717DB1C00644` (currency0) |
| mockMSTR | `0x762019309B536bbb89577422FaaFBeC9659f8728` (currency1) |
| Oracle | `0xc74Af7E23A2B4b46B5Fe05E5c7c5ec0BB5dbc5B7` (154.34) |
| MockMorphoVault (shared by hook and strategy) | `0x44785cca2218d9f2e785123363411f51dcfddd32` |
| DualPoolHook | `0xaf4a9225b27e48c9989726082014095474756ac0` |
| Pool key | `(USDG, MSTR, fee 3000, tickSpacing 60, hook 0xaf4a…6ac0)` |
| Old `CarryStrategy` `0x3b8c…850c` | **Do not use.** It predates `enterPool`/`exitPool`. |

## Steps

Set `R=https://rpc.testnet.chain.robinhood.com` and `V=0x24B799026AA7baa6856bCFD00c1Be1f583A83e35`. Owner commands are written as `--account owner`; use whatever signer the dev normally uses.

### 0. Snapshot (read-only, anyone)

```sh
cast implementation $V --rpc-url $R          # rollback target
for f in version totalSeniorAssets totalShares reservedSenior backstop totalUnsplitFees nextPositionId queueClaimable totalJuniorUsdg; do
  echo "$f $(cast call $V "$f()" --rpc-url $R)"; done
cast call $V 'positions(uint256)' 1 --rpc-url $R   # repeat for each live id
```

Save the output in `docs/testnet-runs/<date>.md`.

### 1. Dry-run the upgrade on a fork (anyone)

```sh
cd contracts
TESTNET_RPC=$R forge test --match-contract V3UpgradeFork -vv
PROXY=$V forge script script/UpgradeV3Proxy.s.sol --rpc-url $R      # dry-run, simulates as the owner
```

Both must pass and print `version v3.2-dualpool`, `marketCount 1`.

### 2. Upgrade (owner)

Pick one of two routes:

- **Script route.** Flip `broadcastArmed()` to `true` in `script/UpgradeV3Proxy.s.sol` locally (do not commit), then:
  ```sh
  PROXY=$V forge script script/UpgradeV3Proxy.s.sol --rpc-url $R --broadcast --account owner
  ```
- **Split route (cheaper for the owner).**
  1. The throwaway deploys the implementation: `forge create src/LeveredLpVaultV2.sol:LeveredLpVaultV2`.
  2. The owner sends one call:
     ```sh
     cast send $V 'upgradeToAndCall(address,bytes)' <NEW_IMPL> $(cast calldata 'initializeMarkets()') --rpc-url $R --account owner
     ```

The upgrade and `initializeMarkets()` must land in the same transaction. Until `initializeMarkets` runs, market 0 has no token or oracle.

### 3. Deploy the strategy and router (throwaway)

```sh
forge create src/CarryStrategy.sol:CarryStrategy --constructor-args $V 0x44785cca2218d9f2e785123363411f51dcfddd32 --rpc-url $R --broadcast
forge create src/mocks/MockMstrSellRouter.sol:MockMstrSellRouter --constructor-args 0x25030Bff74764aD72b912276a603717DB1C00644 --rpc-url $R --broadcast
cast send <ROUTER> 'setPrice(address,uint256)' 0x762019309B536bbb89577422FaaFBeC9659f8728 154340000000000000000 --rpc-url $R
cast send 0x25030Bff74764aD72b912276a603717DB1C00644 'mint(address,uint256)' <ROUTER> 100000000000000000000000 --rpc-url $R
```

The strategy must use the same MockMorphoVault as the hook. The senior's Morpho entitlement is read from it.

### 4. Wire it (owner)

```sh
cast send $V 'setStrategy(address)' <STRATEGY> --rpc-url $R --account owner
cast send $V 'setSellSharesRouter(address)' <ROUTER> --rpc-url $R --account owner
cast send $V 'setMarketPool(uint256,(address,address,uint24,int24,address))' 0 \
  '(0x25030Bff74764aD72b912276a603717DB1C00644,0x762019309B536bbb89577422FaaFBeC9659f8728,3000,60,0xaf4a9225b27e48c9989726082014095474756ac0)' \
  --rpc-url $R --account owner
# optional: park idle lender USDG in Morpho
cast send $V 'deployIdle(uint256)' <AMOUNT> --rpc-url $R --account owner
```

From here, every newly fully matched MSTR position goes into the pool. Positions matched before the upgrade stay out of the pool until they close.

## Verify after (read-only, then a smoke test)

- `version()` is `"v3.2-dualpool"`, `marketCount()` is 1, and `markets(0)` shows mockMSTR, the oracle, range 0.32e18 and active.
- `totalSeniorAssets`, `totalShares`, `nextPositionId`, `backstop` and every live `positions(id)` match the snapshot.
- `strategy()`, `sellSharesRouter()` and `marketPool(0)` return the new addresses and key.
- **Smoke test (throwaway):**
  1. Mint mock tokens.
  2. `depositSenior` about 200 USDG.
  3. `depositJunior(0, 1e18)` MSTR (about $154, fully matched).
  4. Check that `positionPoolShares(id) > 0` and `poolDeployed()` is about 154.
  5. `earlyExit(id)` returns about 1 MSTR, `poolDeployed()` goes back to 0, and NAV is not lower.
- Record the tx hashes in `docs/testnet-runs` and tick the Stage 2 rows in `docs/TESTNET_CHECKLIST.md`.

## Rollback

- **Soft stop (owner, any time).** `setMarketPool(0, (0,0,0,0,0))` stops new positions from entering the pool. Positions already in it still close normally.
- **Full rollback (owner).** `upgradeToAndCall(<old impl from the snapshot>, 0x)`.
  - This is safe only while no position is in a pool (`poolDeployed() == 0`) and no market other than 0 exists. The old code can't see pool shares or `marketId`.
  - If positions are pooled, soft stop first and let them close (or early-exit), then roll back.
  - `initializeMarkets` is a one-time reinitializer, so re-upgrading forward later does not need it again. Use plain `upgradeToAndCall(newImpl, 0x)`.

## Site changes that must go live together (UX rework thread has them)

- Regenerate `public/abi/LeveredLpVault.json` and `public/abis/LeveredLpVault.json` from `main`.
- Removed functions:
  - `settle(uint256,uint8)`, `earlyExit(uint256,uint8)`, `previewSettle(uint256,uint8)`, `previewEarlyExit(uint256,uint8)`: use the one-argument versions.
  - `setSellSharesEnabled`.
  - `previewSeniorAssets(uint256,uint256)`.
- `positions(id)` returns one more field (`marketId`, last). `depositJunior(marketId, amount)` is added; the one-argument version still means market 0.
- `testnet.html`: drop the Wallet / IdleCarry / SellShares cover picker and the accrual and cover copy. There is no fixed rate since #27.
- APY copy (`carry-chain.js`, `testnet.html`): lender yield is "Morpho + Carry". There is no fixed floor and no 4% coupon.
- Optional new views: `positionPoolShares(id)`, `poolDeployed()`, `marketPool(id)`, `markets(id)`, `marketCount()`.
- Note in the UI: for pooled positions, `previewSettle` and `previewEarlyExit` show only the fee-pool part. The pool share is split at close.
