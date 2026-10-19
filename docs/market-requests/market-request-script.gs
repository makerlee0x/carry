// Carry "Request a new market" form -> Google Sheet.
// Works as a **standalone** web app (not bound to a sheet). See docs/market-requests/README.md.
//
// The site posts with fetch(..., { mode: 'no-cors' }), so this script never needs CORS headers;
// it still returns JSON for anyone testing it by hand.

const SHEET_NAME = 'Requests';
const MAX_LEN = 500;
const PROP_SHEET_ID = 'SHEET_ID';

/**
 * Run once from the Apps Script editor (Run → setup).
 * Creates a spreadsheet if needed, stores its id, and logs the URL.
 */
function setup() {
  const props = PropertiesService.getScriptProperties();
  let id = props.getProperty(PROP_SHEET_ID);
  let ss;
  if (id) {
    try {
      ss = SpreadsheetApp.openById(id);
    } catch (e) {
      ss = null;
    }
  }
  if (!ss) {
    ss = SpreadsheetApp.create('Carry market requests');
    props.setProperty(PROP_SHEET_ID, ss.getId());
  }
  const sheet = ss.getSheetByName(SHEET_NAME) || ss.insertSheet(SHEET_NAME);
  if (sheet.getLastRow() === 0) {
    sheet.appendRow(['Timestamp', 'Token', 'Contract address', 'Why']);
  }
  Logger.log('Sheet URL: ' + ss.getUrl());
  Logger.log('SHEET_ID: ' + ss.getId());
}

function _spreadsheet_() {
  const props = PropertiesService.getScriptProperties();
  let id = props.getProperty(PROP_SHEET_ID);
  if (id) {
    try {
      return SpreadsheetApp.openById(id);
    } catch (e) {
      // Fall through and recreate.
    }
  }
  // Bound script fallback (Extensions → Apps Script from a sheet).
  const active = SpreadsheetApp.getActiveSpreadsheet();
  if (active) {
    props.setProperty(PROP_SHEET_ID, active.getId());
    return active;
  }
  const ss = SpreadsheetApp.create('Carry market requests');
  props.setProperty(PROP_SHEET_ID, ss.getId());
  return ss;
}

function doPost(e) {
  const p = (e && e.parameter) || {};
  // Honeypot: the site hides the "website" field, so only bots fill it. Pretend success and drop the row.
  if (p.website) return json_({ ok: true });
  const clean = (v) => String(v || '').replace(/[\r\n]+/g, ' ').trim().slice(0, MAX_LEN);
  // A leading = + - @ would run as a formula in Sheets; prefix it so it stays text.
  const safe = (v) => (/^[=+\-@]/.test(v) ? "'" + v : v);
  const token = clean(p.token);
  if (!token) return json_({ ok: false, error: 'token required' });

  const lock = LockService.getScriptLock();
  lock.waitLock(10000);
  try {
    const ss = _spreadsheet_();
    const sheet = ss.getSheetByName(SHEET_NAME) || ss.insertSheet(SHEET_NAME);
    if (sheet.getLastRow() === 0) sheet.appendRow(['Timestamp', 'Token', 'Contract address', 'Why']);
    sheet.appendRow([new Date(), safe(token), safe(clean(p.contract)), safe(clean(p.why))]);
  } finally {
    lock.releaseLock();
  }
  return json_({ ok: true });
}

function doGet() {
  return json_({ ok: true, info: 'Carry market requests: POST token, contract, why.' });
}

function json_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}
