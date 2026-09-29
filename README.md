# Carry site

![Carry home page](docs/home.png)

Carry pays you trading fees on stock tokens that would otherwise sit idle in a wallet. Deposit any stock token on Robinhood Chain and Carry pairs it 1:1 with USDG in a Uniswap v4 pool, runs the position at 2x, keeps it in range with an automated hook, and pays you a share of every swap. Unused USDG earns a minimum yield in Morpho vaults.

Static, single-file build of the Carry marketing site and app prototype. All 10 pages use hash routing (`#home`, `#markets`, `#market`, `#strategy`, `#dashboard`, `#positions`, `#vault`, `#docs`, `#deposit`, `#advanced`; docs sections deep-link as `#docs/fees`), so no server rewrites are needed. `#deposit` opens the deposit modal over the dashboard.

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

## Notes

- `public/coin-terminal-standalone.html` is the 3D Coin Terminal, embedded on the Strategy Coin page (`#strategy`). Add `?embed` to the URL to hide the drag hint. `public/assets/coin-terminal-front@2x.png` is its loading poster.
- `public/index.html` is a compiled bundle. Make design changes in the source design file and re-export; don't hand-edit the bundle.
- Market, position and token data are sample values, and wallet actions are simulated. Nothing connects to a chain yet.
- Disclaimers are placeholders pending legal review.
