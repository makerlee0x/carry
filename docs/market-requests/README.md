# Market requests → Google Sheet

The markets page form ("Support for more Stock Tokens coming soon") sends each request to a Google Sheet through a
small Apps Script web app. Until `product.marketRequestUrl` in `public/config.json` is set, the form opens a
prefilled GitHub issue instead (`.github/ISSUE_TEMPLATE/market_request.yml`), so it works either way.

Each row: timestamp, token, contract address, why. A hidden `website` field catches bots; rows that fill it are dropped.

## Setup (standalone web app — about 5 minutes)

The script is written for a **standalone** Apps Script project (not opened from a sheet). It creates its own
spreadsheet on first run and stores the id in script properties (`SHEET_ID`).

1. Go to [script.google.com](https://script.google.com) → **New project**. Rename it (e.g. "Carry market requests").
2. Delete the starter code, paste in [`market-request-script.gs`](./market-request-script.gs), and save.
3. Select function **`setup`** in the toolbar → **Run**. Approve Sheets access when prompted.
   Check **Executions** / **Logs** for the Sheet URL and `SHEET_ID`.
4. **Deploy → New deployment** → type **Web app** → **Execute as: Me** → **Who has access: Anyone** → **Deploy**.
5. Copy the **Web app URL** (ends in `/exec`) into `public/config.json` as `product.marketRequestUrl`.
6. Push that config change, then submit a test request on the markets page and confirm a row lands in the sheet.

If you already deployed a broken standalone script, paste the new `.gs`, run **`setup` once**, then
**Deploy → Manage deployments → Edit → Version: New version** so the same `/exec` URL keeps working.

### Status (2026-10-18)

Live `product.marketRequestUrl` in `public/config.json` still points at the `/exec` web app, but
direct GET/POST to that URL returns **HTTP 403**. The markets form will look like it “sends”
(`mode: 'no-cors'`) without writing a sheet row. **Maker/owner:** open the Apps Script project →
paste current [`market-request-script.gs`](./market-request-script.gs) if drifted → **Deploy →
Manage deployments → Edit → New version** (Execute as Me, Anyone) → confirm a test POST returns JSON.

### Bound-to-sheet alternative

If you prefer: create a Google Sheet first, open **Extensions → Apps Script** from that sheet, paste the same
script, run `setup`, then deploy as a web app. `getActiveSpreadsheet()` will work and the script still stores `SHEET_ID`.
