# Levered LP — what is in the repo, and what is still required

**Grant / Carry pack (current):** [`CARRY_CONTRACT.md`](./CARRY_CONTRACT.md) · deploy: [`CARRY_TESTNET.md`](./CARRY_TESTNET.md) (Robinhood testnet **46630**).  
Vault now includes Open→match, early exit, and lender replace/exit. Prefer those docs for the submission.

Broadcast did not happen. **Waiting on a deployer wallet from Dylan.** No contract addresses exist. Nothing was sent to Robinhood Chain mainnet (4663) or testnet (46630).

## Pinned product rules

These two rules are decided. They are not open questions.

1. **4% is the pool floor.** 4% is the floor the pool has to earn so that if both sides withdraw, they are whole, and so the lender still receives their borrow fee. It is not 4% paid to the lender as a separate promise. The demo math already models this: `floorLpFeeApr` is `0.04` on LP notional. After the 20% protocol cut, fees at that floor cover the borrow fee (`principal · 5% · 7 / 365`). The lender's receipt is principal plus that borrow fee. The settle card says the same thing.
2. **The term is a 7-day lock.** Fixed. The demo has no control that picks another term. 7 days is enough time for an S&P-style equity trend to bottom or reverse in a crash or a pump. The deploy script constant is `TERM = 7 days`. The vault still rejects a term above 7 days. Tests use a 1-hour term so the lock is short. That short test term is not a product choice.

Early exit, demo only, 27 Sep 2026. Contracts were not changed and were not broadcast. The planned window stays 7 days. The demo says the position is **active**, not locked. Lender owed on an early exit is `principal * 0.04 * (daysActive / 365)`. If LP fees already credited to the lender cover that, the stock side withdraws with no fee. If fees are short, the stock side pays the USDG difference and gets the shares back. That difference is the early termination fee. Do not charge the rest of the week on top of fees already earned. If the market is dumping, they can get the shares back to sell. If the hook and rebalancer hold up in testing, a fixed 7-day window might not be needed. Testing decides that. The 7-day plan stays. yieldz.io is only a possible later place for un-utilized USDG to earn. Deposits are not routed there, and the demo does not integrate it. A full withdraw at maturity still uses the 4% pool floor. The book stays 50/50 + hook. Simulation only. Deposits off.

Foundry was not in the repo. It is installed locally as Foundry 1.8.3 (`forge` 1.8.3) under `~/.foundry/bin`. Tests ran in the local EVM. The deploy script was not executed.

## What is in the repo

| Path | Role |
| --- | --- |
| `contracts/src/LeveredLpVault.sol` | 2× book. Junior MSTR, matching senior USDG, 7-day lock, borrow fee, protocol cut into a backstop, settlement waterfall. Constructor sets `paused = true`. Not upgradeable. Product term is fixed at 7 days. |
| `contracts/src/interfaces/IDualPoolAdapter.sol` | Interface only. The vault does not call it. |
| `contracts/src/interfaces/IPriceOracle.sol` | `mstrPriceWad()`. Oracle address is immutable. |
| `contracts/src/interfaces/IERC20Minimal.sol` | Transfer helper surface. |
| `contracts/src/oracle/FixedPriceOracle.sol` | Frozen price, no setter. Easy to misuse if someone unpauses against a stale number. |
| `contracts/src/mocks/MockERC20.sol` | Test token only. |
| `contracts/src/mocks/MockOracle.sol` | Test price with a setter. Do not deploy this. |
| `contracts/src/mocks/MockFeePool.sol` | Test pool. Pays a fake USDG fee in. Never takes inventory out. |
| `contracts/script/DeployLeveredLpVault.s.sol` | Targets chain id 4663 only. `broadcastArmed()` is `false`, so `run()` reverts before `vm.startBroadcast`. |
| `contracts/test/LeveredLpVault.t.sol` | The tests below. |
| `contracts/lib/forge-std` | Installed with `forge install foundry-rs/forge-std --no-git`. |
| `src/app/demo/levered-lp/page.tsx` and `src/components/earn/levered-loop-demo-client.tsx` | Simulation only. Mainnet deposits are off. No button sends MSTR. Copy says the planned window is 7 days active, shows early exit as the USDG gap versus 4% APR for days active, and keeps the 4% pool floor for a full withdraw. Site redeployed 27 Sep 2026. Contracts were not broadcast. |

Production constants in the script (used only if the script is later armed): term fixed at 7 days, borrow APR 5%, protocol cut 20%. Tests use a 1-hour term so the lock is short. That is not a selectable product term. The vault rejects a term above 7 days, an APR above 5%, or a protocol cut above 20%.

Tokens the script would use later, and does not touch tonight:

- MSTR `0xec262a75e413fAfD0dF80480274532C79D42da09`
- USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`
- PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`
- RPC `https://rpc.mainnet.chain.robinhood.com`
- Chain id `4663`

Ethereum mainnet is refused. The Ethereum DualPool factory `0x0000000000077769C332e0D3ed8bC8E02A0cE108` is not on 4663 and is not called.

## How the book works today

Juniors lock MSTR. Seniors deposit USDG. A junior open reserves USDG equal to the MSTR at the oracle price. Both balances stay in the vault. There is no AMM position, because the DualPool hook is not deployed.

Mark-to-market: 2× equity equals the value of the junior MSTR (it tracks holding). Unlevered 50/50 equity is `S · (2√r − 1)`. A test moves the price 4× and checks the 2× mark stays on the hold value while the unlevered mark does not.

Fees are USDG pushed in through `accrueLpFee`. 20% fills `backstop`. The rest sits on the position. At maturity, seniors are owed principal plus a borrow fee (`principal · 5% · term / 365 days`). Principal is their own USDG, still in the vault. The fee is paid in this order:

1. Position fees after the protocol cut.
2. Backstop.
3. The minimum junior MSTR that covers whatever fee is left, priced by the oracle. Rounded up by at most one raw unit.

Above water, juniors keep every MSTR plus leftover fees, and seniors withdraw principal plus the borrow fee. If the backstop covers the fee gap, no MSTR is sold. MSTR is sold only for the shortfall the backstop does not cover.

The owner can pause and unpause deposits and can rescue a token that is not MSTR or USDG. The owner cannot withdraw principal, change the oracle, the term, the APR, or the cut, or set an adapter. `dualPoolAdapter()` is `address(0)`. The vault never approves the PoolManager. `joinPool` always reverts. The contract is not a proxy.

One-sided USDG (senior posts 2×, junior MSTR stays escrow) is a comment in `LeveredLpVault.sol`. It is not compiled in and not tested.

Until a real hook is wired, a price drop does not swap inventory. Seniors do not eat AMM losses, and juniors are not relevered inside a pool. The on-chain gap is the borrow fee only.

## How to run the tests

```bash
export PATH="$PATH:$HOME/.foundry/bin"
cd contracts
forge test
```

Result on 25 Sep 2026, Foundry 1.8.3, Solc 0.8.28, local EVM:

**13 passed, 0 failed.**

- `test_depositBothSides`
- `test_accrueFees`
- `test_aboveWaterWithdraw`
- `test_belowWaterBackstopCoversGap`
- `test_belowWaterSellsMinimumJunior`
- `test_pauseBlocksNewDeposits`
- `test_randomAddressCannotPullFunds`
- `test_ownerCannotStealPrincipal`
- `test_startsPaused`
- `test_twoXTracksHoldCloserThanUnlevered`
- `test_externalCannotLpBesideVault`
- `test_broadcastDisarmed`
- `test_fixedOracleHasNoWriter`

If `contracts/lib/forge-std` is missing: `forge install foundry-rs/forge-std --no-git` from `contracts/`.

## Do not broadcast yet

`contracts/script/DeployLeveredLpVault.s.sol` reverts with `BroadcastBlocked` until `broadcastArmed()` is changed. That change waits on Dylan's deployer wallet. Do not put a private key in git, in the script, or in a committed env file.

This command must not be run tonight:

```bash
forge script script/DeployLeveredLpVault.s.sol \
  --rpc-url https://rpc.mainnet.chain.robinhood.com \
  --broadcast
```

When it is eventually armed, `run()` still reverts unless `block.chainid == 4663`. It reads `VAULT_OWNER` and `ORACLE_ADDRESS` from the environment, deploys the vault paused, does not unpause, does not seed funds, and does not deploy a hook.

## Still required to go live

1. **Waiting on a deployer wallet from Dylan.** This is the broadcast blocker. No key was provided and none is in the repo.
2. **Audit** `LeveredLpVault` before any unpause. Pause already starts as `true` and deposits revert while it is set.
3. **Reviewed price oracle.** Pass it as `ORACLE_ADDRESS`. It must not be writable by the vault owner. `MockOracle` is tests only. `FixedPriceOracle` has no setter, but a frozen snapshot will mis-settle if the market moves. Do not unpause against a stale price.
4. **Testnet is not the plan.** The only broadcast target is Robinhood Chain 4663. Not Ethereum mainnet.
5. **Unpause only after that review.** The owner key (prefer a multisig in `VAULT_OWNER`) is the pause key. Unpause is the moment deposits can take real MSTR and USDG.
6. **DualPool hook, byte-exact, after audit.** Use Uniswap's pinned DualPool bytecode from factory `0x0000000000077769C332e0D3ed8bC8E02A0cE108` on Ethereum, or a byte-exact copy pointed at PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`. The factory is not on 4663. Do not deploy a modified hook. Do not fork their audited hook and edit it.
7. **Point the vault at that hook.** Today the adapter is `address(0)` and there is no setter. Wiring it is a later change, with the vault as the only LP. External `joinPool` stays forbidden.
8. **Route swaps** so real LP fees call `accrueLpFee`. `MockFeePool` only mints a fake fee in tests.
9. **Seed inventory** after the reviewed unpause: junior MSTR and matching senior USDG. No seeding was done. No user funds were used.
10. **Then** deposits are live on 4663. The demo page still must not gain a button that sends real MSTR until that unpause is intentional.
