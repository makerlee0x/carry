# Market requests → Google Sheet

The markets page form ("Support for more Stock Tokens coming soon") sends each request to a Google Sheet through a
small Apps Script web app. Until `product.marketRequestUrl` in `public/config.json` is set, the form opens a
prefilled GitHub issue instead (`.github/ISSUE_TEMPLATE/market_request.yml`), so it works either way.

Each row: timestamp, token, contract address, why. A hidden `website` field catches bots; rows that fill it are dropped.

## Setup (needs your Google account, about 5 minutes)

1. Create a new Google Sheet (for example "Carry market requests"). The script adds a `Requests` tab with headers on the first request.
2. In the sheet, open **Extensions → Apps Script**, delete the starter code, paste in
   [`market-request-script.gs`](./market-request-script.gs) and save.
3. Click **Deploy → New deployment**, pick type **Web app**, set **Execute as: Me** and **Who has access: Anyone**,
   then **Deploy** and approve the permissions prompt (it only needs this one sheet).
4. Copy the **Web app URL** (ends in `/exec`) and put it in `public/config.json` as `product.marketRequestUrl`.
5. Push that change, then submit a test request on the markets page and check that a row lands in the sheet.

If you edit the script later, use **Deploy → Manage deployments → Edit → New version** so the same URL keeps working.
