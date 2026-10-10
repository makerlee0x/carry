# SellShares AMM (mainnet stub)

Maker (Oct 10 leftovers): mainnet SellShares goes through a Uniswap (or equivalent)
AMM to the user path. Testnet keeps MSTR credit to seniors.

## Interface

`contracts/src/interfaces/IMstrSellRouter.sol`

```
sellMstrForUsdg(mstrAmount, minUsdgOut, recipient) → usdgOut
```

Vault storage: `sellSharesRouter` (owner-set). Default / testnet: `address(0)`.

## Behavior

| `sellSharesRouter` | Path |
| --- | --- |
| `address(0)` (testnet) | Credit sold MSTR to seniors via time-weighted `accMstr*` (unchanged). |
| Non-zero (mainnet) | Approve router → swap MSTR→USDG to vault → pay senior shortfall + treasury-on-cover → remainder to junior (wallet or auto-compound). |

Slippage floor on-chain: 95% of oracle fair value (`minUsdgOut`).

## Test coverage

`MockMstrSellRouter` + `test_sellSharesRouter_mainnetPath_creditsUsdgNotMstr`.

## Mainnet rollout (later)

1. Deploy a real Uniswap V2/V3 router adapter implementing `IMstrSellRouter`.
2. Owner `setSellSharesRouter(adapter)` on the product PROXY (multisig + timelock on mainnet).
3. Keep testnet at `address(0)` so settle-watch and demos stay on MSTR credit.
