/**
 * Boot log for loading panels. Fills every `.rt-boot` element (rendered by the bundle while data loads) with
 * real load status: config.json, the viem client, the first vault read over RPC, the oracle price, and the wallet.
 * Also fills the 404 page's `.rt-errlog` with the unresolved route.
 * Status comes from window.CarryChain.last (see carry-chain.js), so a line only says OK once that step happened.
 */
(function () {
  'use strict';

  let cfg = null, cfgErr = false;
  fetch('config.json', { cache: 'no-store' })
    .then((r) => r.json())
    .then((c) => { cfg = c; renderAll(); })
    .catch(() => { cfgErr = true; renderAll(); });

  const short = (a) => (a ? a.slice(0, 6) + '…' + a.slice(-4) : '');
  const host = (u) => { try { return new URL(u).host; } catch (e) { return ''; } };
  const OK = ['OK', 'ok'], WAIT = ['WAIT', 'wait'], ERR = ['ERR', 'err'];

  function lines() {
    const c = (cfg && cfg.chain) || {}, s = (window.CarryChain && window.CarryChain.last) || {};
    const v = s.vault, failed = !!s.error && !v;
    const out = [['CONFIG', cfg ? (c.chainName || 'chain') + ' · ' + (c.chainId || '') : 'config.json', cfg ? OK : cfgErr ? ERR : WAIT]];
    out.push(['VIEM', 'public client', s.ready ? OK : failed ? ERR : WAIT]);
    out.push(['RPC', host(c.rpcUrl) || 'rpc', v ? OK : failed ? ERR : WAIT]);
    out.push(['VAULT', short(c.vault) || 'vault', v ? (v.paused ? ['PAUSED', 'warn'] : OK) : failed ? ERR : WAIT]);
    out.push(['ORACLE', v && v.price > 0 ? 'MSTR $' + Number(v.price).toFixed(2) : 'MSTR / USD', v && v.price > 0 ? OK : failed ? ERR : WAIT]);
    out.push(['WALLET', s.account ? short(s.account) : 'not connected', s.account ? OK : ['—', 'idle']]);
    if (cfg && c.live === false) out.push(['MODE', 'demo balances and positions', ['DEMO', 'warn']]);
    if (failed) out.push(['ERROR', String(s.error).slice(0, 80), ERR]);
    return out;
  }

  function render(el) {
    const frag = document.createDocumentFragment();
    lines().forEach(([k, val, st], i) => {
      const row = document.createElement('div');
      row.className = 'rt-boot-line';
      row.style.animationDelay = i * 70 + 'ms';
      const key = document.createElement('span'); key.className = 'rt-boot-k'; key.textContent = '> ' + k;
      const v = document.createElement('span'); v.className = 'rt-boot-v'; v.textContent = val;
      const lead = document.createElement('span'); lead.className = 'rt-boot-lead';
      const s = document.createElement('span'); s.className = 'rt-boot-s rt-boot-' + st[1]; s.textContent = st[0];
      row.append(key, v, lead, s);
      frag.appendChild(row);
    });
    const cur = document.createElement('div');
    cur.className = 'rt-boot-line rt-boot-cursor';
    cur.textContent = '> ';
    frag.appendChild(cur);
    el.replaceChildren(frag);
    el.dataset.rt = '1';
  }

  // 404 page: resolve the requested route against the routes that do exist. The app rewrites the hash after it
  // routes to 404, so remember the last hash that was actually requested.
  const blank = (h) => !h || h === '#' || h === '#/';
  let requested = location.hash;
  const onNav = () => {
    if (!blank(location.hash)) requested = location.hash;
    setTimeout(() => document.querySelectorAll('.rt-errlog').forEach(renderErr), 0);   // panel may stay mounted across routes
  };
  window.addEventListener('hashchange', onNav);
  window.addEventListener('popstate', onNav);
  function renderErr(el) {
    const h = blank(location.hash) ? requested : location.hash;
    const route = blank(h) ? '/' : h.slice(1);
    const rows = [['RESOLVE', '#' + route, ['404', 'err']], ['HOME', '#', OK], ['MARKETS', '#markets', OK], ['DOCS', '#docs', OK]];
    el.replaceChildren(...rows.map(([k, val, st]) => {
      const row = document.createElement('div'); row.className = 'rt-boot-line';
      const a = document.createElement('span'); a.className = 'rt-boot-k'; a.textContent = '> ' + k;
      const b = document.createElement('span'); b.className = 'rt-boot-v'; b.textContent = val;
      const c = document.createElement('span'); c.className = 'rt-boot-lead';
      const d = document.createElement('span'); d.className = 'rt-boot-s rt-boot-' + st[1]; d.textContent = st[0];
      row.append(a, b, c, d); return row;
    }));
    el.dataset.rt = '1';
  }

  function renderAll() { document.querySelectorAll('.rt-boot').forEach(render); }

  // Panels mount and unmount with the bundle's loading state; render new ones as they appear.
  new MutationObserver(() => {
    document.querySelectorAll('.rt-boot:not([data-rt])').forEach(render);
    document.querySelectorAll('.rt-errlog:not([data-rt])').forEach(renderErr);
  }).observe(document, { childList: true, subtree: true });
  window.addEventListener('carrychain', renderAll);
})();
