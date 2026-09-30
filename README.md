# Carry site

![Carry home page](docs/home.png)

Carry pays you trading fees on stock tokens that would otherwise sit idle in a wallet. Deposit any stock token on Robinhood Chain and Carry pairs it 1:1 with USDG in a Uniswap v4 pool, runs the position at 2x, keeps it in range with an automated hook, and pays you a share of every swap. Unused USDG earns a minimum yield in Morpho vaults.

Static, single-file build of the Carry marketing site and app prototype. All 11 pages use hash routing (`#home`, `#markets`, `#market`, `#analytics`, `#strategy-coin`, `#dashboard`, `#positions`, `#vault`, `#docs`, `#deposit`, `#advanced`; docs sections deep-link as `#docs/fees`), so no server rewrites are needed. `#deposit` opens the deposit modal over the dashboard.

## Run locally

```bash
npm run dev
# open http://localhost:3000
```

## Push to GitHub

```bash
git init
git add .
git commit -m "Carry site"
git branch -M main
git remote add origin https://github.com/<you>/carry-site.git
git push -u origin main
```

## Deploy on Vercel

1. In Vercel, click **Add New → Project** and import the GitHub repo.
2. Framework preset: **Other**. Build command: leave empty. Output directory: `public` (already set in `vercel.json`).
3. Deploy.

Or from the CLI: `npx vercel --prod`.

## Geoblock (simulated)

Deposits of stock tokens and USDG are gated; STRATEGY staking and the rest of the site are not. The gate is controlled by `public/config.json`, which is read at page load and never exposed as a front-end control:

```json
{ "geoblock": { "enabled": true, "simulateRegion": "allowed" } }
```

- `enabled: false` turns the gate off.
- `simulateRegion: "allowed"` shows an eligibility attestation the user must tick before depositing.
- `simulateRegion: "restricted"` shows the "isn't available in your region" notice and disables the deposit button.

Region detection is simulated for now. A real check (for example the `x-vercel-ip-country` header in an edge function) would replace `simulateRegion`.

## Simulated states

`public/config.json` also drives the demo states under `simulate` (read at page load, no front-end controls):

| Key | Values | Effect |
| --- | --- | --- |
| `data` | `ok`, `loading`, `error` | `loading` holds the skeleton loaders forever; `error` shows the "Couldn't load data" card with Try again |
| `loadingMs` | number | How long the loading skeleton shows on first load and on retry |
| `network` | `ok`, `wrong` | `wrong` shows the wrong-network banner and turns deposit buttons into "Switch to Robinhood Chain" |
| `tx` | `success`, `rejected`, `error` | Outcome of deposit, withdraw and stake confirmations |
| `connect` | `success`, `rejected`, `error` | Outcome of the wallet connect (Privy) step |

With `geoblock.simulateRegion` set to `restricted`, a connected wallet also sees the "Deposits aren't available in your region" banner on the Dashboard, Positions and Vault pages. Unknown hashes show the 404 page.

## Notes

- The 3D Coin Terminal is archived in `archive/coin-terminal/` (not deployed). The nav item **Analytics** has two sub-pages: **Analytics** (`#analytics`, also reachable as `/analytics`) shows protocol stats, and **Strategy Coin** (`#strategy-coin`, also `/strategy-coin`) is the coin page with Market, News and Pools tabs. The old `#strategy` and `#terminal` links redirect to `#strategy-coin`. Both pages render from placeholder data in the site source: the coin page from the `COINS` object, the Analytics page from generated series (`anBase()`), so swap in the API feed there. The Swap button opens a simulated built-in DEX (ETH ⇄ STRATEGY at a placeholder rate); it follows the `simulate` states in `config.json`. Placeholders to replace: GeckoTerminal pool links, the Relay bridge link, the ETH/USD rate, article summaries, and all analytics figures. The `#terminal-embed-news` and `#terminal-embed-pools` containers are where data-provider embeds go.
- `public/index.html` is a compiled bundle. Make design changes in the source design file and re-export; don't hand-edit the bundle.
- Market, position and token data are sample values, and wallet actions are simulated. Nothing connects to a chain yet.
- Disclaimers are placeholders pending legal review.
