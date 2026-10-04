# Carry keeper (dry-run skeleton)

Off-chain maintainer bot sketched from the Oct 2 research modules. **No private keys.**
Default mode is `--dry-run`: read Hyperliquid `xyz:MSTR`, compute session/ranges/recenter/inventory
signals, and log what a live keeper would do. It does **not** send DualPool `remark()` txs
(hook not on testnet 46630).

## Modules

| File | Role |
| --- | --- |
| `src/prices.ts` | Hyperliquid mid (info API); optional RH RPC oracle read |
| `src/session.ts` | Regular / pre / post / overnight / weekend |
| `src/ranges.ts` | Maker ±32% (default) or research session-vol bands via config flag |
| `src/recenter.ts` | 7d term + 80% oracle drift from center (Maker) |
| `src/inventory.ts` | 5% vault MSTR vs junior shares band |
| `src/guard.ts` | Gas / stale / safe-mode gates |
| `src/index.ts` | CLI entry |

Config numbers come from `../contracts/config/mainnet.json` and `../public/config.json` `product`.

## Run

```bash
cd keeper
npm run dry-run
# optional:
CARRY_RPC_URL=https://rpc.testnet.chain.robinhood.com npm run dry-run
```

Maintainer-operated key comes later; permissionless keeper is a research v2 goal.
