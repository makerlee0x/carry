# Carry

![Carry home page](docs/home.png)

Carry pays you trading fees on stock tokens that would otherwise sit idle in a wallet. Deposit any stock token on Robinhood Chain and Carry pairs it 1:1 with USDG, runs the position at 2×, and pays you a share of fees.

This repo is the **working Carry app + contracts**:

- **UI** — static site in `public/` (hash-routed marketing + app prototype)
- **Vault** — `contracts/` Forge project (`LeveredLpVault`) on **Robinhood Chain Testnet (46630)**

| Deployed (46630) | Address |
| --- | --- |
| LeveredLpVault | [`0x72A053120f03B10c5506d2325f92F59B0FfC36c8`](https://explorer.testnet.chain.robinhood.com/address/0x72A053120f03B10c5506d2325f92F59B0FfC36c8) |
| mockMSTR | `0x762019309B536bbb89577422FaaFBeC9659f8728` |
| mockUSDG | `0x25030Bff74764aD72b912276a603717DB1C00644` |

## Run locally

```bash
npm install   # optional; scripts use npx serve
npm run dev
# open http://localhost:3000
```

Public chain settings live in `public/config.json` (`chain.live: true`). Example env vars (no secrets): `.env.example`.

### Live deposits (testnet)

When `chain.live` is true, MSTR / USDG **Deposit** (and USDG withdraw) call the vault via `window.ethereum`:

- Stock token (`MSTR`) → `depositJunior`
- `USDG` → `depositSenior`

Bridge: [`public/js/carry-vault.js`](public/js/carry-vault.js). Toggle demo-only mode with `"live": false` in `public/config.json`.

**Blockers before a real deposit succeeds:**

1. Vault is deployed **paused** — owner (`0xcA44…3c57`) must call `unpause()`.
2. Wallet needs testnet ETH from the [RH faucet](https://faucet.testnet.chain.robinhood.com).
3. Wallet needs mock tokens — `MockERC20.mint` is open; from the browser console after connect:  
   `CarryVault.mintDemo('MSTR', '10', /* chain cfg from config */) `  
   or mint via cast/explorer.

## Contracts

```bash
git submodule update --init --recursive
cd contracts && forge test
```

See [`CARRY_CONTRACT.md`](./CARRY_CONTRACT.md), [`CARRY_TESTNET.md`](./CARRY_TESTNET.md), and [`contracts/README.md`](./contracts/README.md).

**Never commit** private keys, `.deployer.key`, or `.env` files with secrets.

## Deploy on Vercel

1. Import this GitHub repo in Vercel.
2. Framework preset: **Other**. Build command: empty. Output directory: `public` (see `vercel.json`).
3. Deploy — or `npx vercel --prod`.

## Geoblock & simulate flags

`public/config.json` still drives geoblock and demo `simulate.*` states (loading, wrong network, etc.). See prior notes: `geoblock.simulateRegion`, `simulate.network`, `simulate.tx`. With `chain.live: true`, deposit/withdraw txs hit the vault instead of `simulate.tx`.

`analytics.simulate` (default `true`) fills the Analytics page with simulated protocol activity (users, volume, fees, deposits) that grows day by day and ticks up through the current day, with real vault activity added on top. Set it to `false` to show only static sample volume/APY plus the real vault data.

## Notes

- Pages use hash routing (`#home`, `#markets`, `#dashboard`, `#deposit`, …).
- `public/index.html` is a compiled bundle; live wiring is via `config.json` + `js/carry-vault.js` (minimal hooks in the bundle for `startTx` / network switch).
- DualPool / Morpho / STRATEGY production paths are not implemented in this vault yet.
- Disclaimers are placeholders pending legal review.
