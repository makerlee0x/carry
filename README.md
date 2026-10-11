# Carry

![Carry home page](docs/home.png)

Carry pays you trading fees on stock tokens that would otherwise sit idle in a wallet. Deposit any stock token on Robinhood Chain and Carry pairs it 1:1 with USDG, runs the position at 2×, and pays you a share of fees.

**Live site:** [usecarry.io](https://usecarry.io)

This repo is the **working Carry app + contracts**:

- **UI** — static site in `public/` (hash-routed marketing + app prototype)
- **Vault** — `contracts/` Forge project (`LeveredLpVaultV2`) on **Robinhood Chain Testnet (46630)**
- **Product rules** — Maker-locked notes + live accounting in [`docs/MAKER_V1_NOTES.md`](./docs/MAKER_V1_NOTES.md) and [`docs/ACCOUNTING_V25.md`](./docs/ACCOUNTING_V25.md)
- **Keeper** — dry-run skeleton in [`keeper/`](./keeper/) (Hyperliquid read, no keys, no DualPool txs)

## Live product (testnet 46630)

| Deployed | Address |
| --- | --- |
| LeveredLpVault (**PROXY** / product CA) | [`0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd`](https://explorer.testnet.chain.robinhood.com/address/0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd) |
| Implementation (`version()` = **`v2.5-funder-idle`**) | [`0xe498F43ED10a37E22Fe046A3FDAAFD4E9080d0e8`](https://explorer.testnet.chain.robinhood.com/address/0xe498F43ED10a37E22Fe046A3FDAAFD4E9080d0e8) |
| CarryBook library | `0x2988DFc48BE4AB47B40Ad151f1F213619cdB0794` |
| CarryMath library | `0x98574A1719E647775BE39Ec713B657c2CF27Adc5` |
| mockMSTR | `0x762019309B536bbb89577422FaaFBeC9659f8728` |
| mockUSDG | `0x25030Bff74764aD72b912276a603717DB1C00644` |
| v1 grant/history reference (**not in use**) | `0x72A053120f03B10c5506d2325f92F59B0FfC36c8` |

Upgradeability: **UUPS**. Future logic upgrades keep the same PROXY CA. UI money paths use `public/config.json` → `chain.vault` (PROXY).

### Live accounting (v2.5)

- Per-lender `seniorIdle` (not a global freePrincipal pool)
- FIFO idle queue + per-position funder slices
- Senior yield to **position funders** only (amount × time matched on that position)
- Min deposit / match **$25**; market totals **$25k** senior / junior; **no per-wallet cap** (`maxPerWalletUsdg = 0`)
- Settle default **IdleCarry** (USDG); Boosted STRATEGY stake **tiers**; auto-compound; junior `gasCredit`

Details: [`docs/ACCOUNTING_V25.md`](./docs/ACCOUNTING_V25.md) · settle watch: [`docs/SETTLE_WATCH.md`](./docs/SETTLE_WATCH.md) · security: [`docs/SECURITY_V2.md`](./docs/SECURITY_V2.md).

Docs index: [`docs/README.md`](./docs/README.md).

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

Bridge: [`public/js/carry-vault.js`](public/js/carry-vault.js) / [`public/js/carry-chain.js`](public/js/carry-chain.js). Toggle demo-only mode with `"live": false` in `public/config.json`.

**Blockers before a real deposit succeeds:**

1. Vault must be **unpaused** (owner `0xcA44…3c57`). Live PROXY is currently unpaused.
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

Production marketing/app: **usecarry.io**.

## Geoblock & simulate flags

`public/config.json` still drives geoblock and demo `simulate.*` states (loading, wrong network, etc.). See prior notes: `geoblock.simulateRegion`, `simulate.network`, `simulate.tx`. With `chain.live: true`, deposit/withdraw txs hit the vault instead of `simulate.tx`.

`analytics.simulate` (default `true`) fills the Analytics page with simulated protocol activity (users, volume, fees, deposits) that grows day by day and ticks up through the current day, with real vault activity added on top. Set it to `false` to show only static sample volume plus the real vault data.

`analytics.liveApy` (default `true`) switches the MSTR fee-pace figure from the sample number to one worked out from the vault's real fees: fees paid to positions minus the lender's Morpho-rate opportunity cost, over matched stock-time for the last 30 days (needs 1+ day of history, capped at 999%). That is a **realized fee-pace readout**, not a promised APY. The live value is always computed and available as `CarryChain.last.analytics.mstrApy` (`{ pct, days, fees }`) whether or not the flag is on. NVDA and the other markets stay simulated.

## Notes

- Pages use hash routing (`#home`, `#markets`, `#dashboard`, `#deposit`, …).
- Product position labels: **Idle / Active / Boosted / Closed** (not Open/Settled).
- `public/index.html` is a compiled bundle; live wiring is via `config.json` + `js/carry-vault.js` / `carry-chain.js`.
- DualPool / Morpho sleeve / live STRATEGY token wiring are **not** on testnet 46630 (Morpho rate and Idle USDG APY are config stubs; Boosted is an on-chain stake-tier stub).
- Disclaimers are placeholders pending legal review.
