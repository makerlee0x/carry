/**
 * Home page widgets. The bundle renders empty mount points on the home route; this fills them:
 *   [data-hm-receipt]   hero fee receipt, stamped in the viewer's own date, time and time zone
 *   [data-hm-calc]      earnings calculator (Hold / Borrow against it / Carry, and USDG vs onchain lending / neobank)
 *   [data-hm-backstop]  backstop balance from the vault read (window.CarryChain.last.vault.backstop)
 *   [data-hm-today]     today's date on the USDG rate panel
 * The home route mounts and unmounts with navigation, so new mount points are picked up by a MutationObserver.
 */
(function () {
  'use strict';

  const vault = () => ((window.CarryChain && window.CarryChain.last) || {}).vault || null;
  const usd = (n, signed) => (signed ? '+' : '') + '$' + Math.round(n).toLocaleString('en-US');
  const money = (n, dp) => '$' + n.toLocaleString('en-US', { minimumFractionDigits: dp, maximumFractionDigits: dp });
  const pad = (s, n, right) => { s = String(s); while (s.length < n) s = right ? s + ' ' : ' ' + s; return s; };

  // ---- Receipt ---------------------------------------------------------------
  // Sample trades across three pools until the pools report swaps; every swap pays the 0.3% pool fee.
  const FEE = 0.003, POOLS = ['MSTR', 'NVDA', 'QQQ'], W = 46;
  const hhmm = (d) => d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });
  // One receipt state for the page. The bundle runtime re-processes nodes added under its tree (it drops whitespace-only
  // text nodes and can swap elements for copies), so every render rewrites each receipt panel from this state.
  const receipt = { no: 184, total: 48210.55, rows: [[1, 'NVDA', 'BUY', 4120], [4, 'MSTR', 'SELL', 2860], [8, 'QQQ', 'BUY', 1940]].map(([ago, pool, side, size]) => ({ at: Date.now() - ago * 60000, pool, side, size })) };
  function renderReceipts() {
    const pres = document.querySelectorAll('[data-hm-receipt]');
    if (!pres.length) return;
    const d = new Date(), rule = '-'.repeat(W);
    let tz = '';
    try { tz = new Intl.DateTimeFormat([], { timeZoneName: 'short' }).formatToParts(d).find((p) => p.type === 'timeZoneName').value; } catch (e) {}
    const date = String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0') + '-' + d.getFullYear();
    const left = 'CARRY RECEIPT #' + String(receipt.no).padStart(6, '0'), when = date + ' ' + hhmm(d) + (tz ? ' ' + tz : '');
    const html = [
      left + pad(when, W - left.length), rule, 'TIME   POOL   SIDE          SIZE            FEE',
      ...receipt.rows.map((r) => hhmm(new Date(r.at)) + '  ' + pad(r.pool, 4, true) + '   ' + pad(r.side, 4, true) + pad(money(r.size, 0), 14) + pad('+' + money(r.size * FEE, 2), 15)),
      rule, 'TOTAL FEES' + pad(money(receipt.total, 2), W - 10),
    ].join('\n') + '\n<span class="thanks">THANK YOU FOR HOLDING<span class="cursor">_</span></span>';
    pres.forEach((pre) => { pre.innerHTML = html; });
  }
  setInterval(() => {
    if (!document.querySelector('[data-hm-receipt]')) return;
    const size = Math.round((800 + Math.random() * 6200) / 10) * 10;
    receipt.rows.unshift({ at: Date.now(), pool: POOLS[Math.floor(Math.random() * POOLS.length)], side: Math.random() < 0.5 ? 'BUY' : 'SELL', size });
    receipt.rows.length = 3; receipt.total += size * FEE; receipt.no += 1;
    renderReceipts();
  }, 7000);
  setInterval(renderReceipts, 30000);   // keeps the clock current between trades

  // ---- Calculator ------------------------------------------------------------
  // Illustrative reference rates per market (bear / neutral / bull). Earnings compound every 7-day term.
  const STEPS = [['1 month', 1 / 12], ['3 months', 0.25], ['6 months', 0.5], ['9 months', 0.75], ['1 year', 1], ['2 years', 2], ['3 years', 3],
    ['5 years', 5], ['7 years', 7], ['10 years', 10], ['15 years', 15], ['20 years', 20], ['25 years', 25], ['30 years', 30]];
  const MARKETS = ['Bear', 'Neutral', 'Bull'];
  const earn = (value, r, years) => value * (Math.pow(1 + r / 52, 52 * years) - 1);
  const MODES = {
    mstr: {
      reg: '', cta: 'Deposit Stocks', btn: 'hm-dep-stock', label: 'Your MSTR', min: 1, max: 5000, step: 1, def: 77, minTick: '1', maxTick: '5,000',
      toUsd: (a) => a * ((vault() && vault().price > 0) ? vault().price : 136), fmt: (a) => String(a),
      sub: (mo) => '<span class="mo">' + mo + '</span>/mo, without selling a share.',
      options: [
        { name: 'Hold', priceOnly: true, rates: [0, 0, 0], fill: 'var(--muted)', rows: (a) => [['Shares kept', a + ' MSTR'], ['Liquidation risk', 'None']],
          note: 'You keep any rise in the stock price, but your shares earn nothing on top.' },
        { name: 'Borrow against it', rates: [0.005, 0.015, 0.03], fill: 'var(--text)', rows: (a) => [['Shares kept', a + ' MSTR'], ['Liquidation risk', 'Yes', 'down']],
          note: 'You take a loan against your stock. A price drop can get it liquidated.' },
        { name: 'Carry', carry: true, rates: [0.07, 0.135, 0.22], rows: (a) => [['Shares kept', a + ' MSTR'], ['Liquidation risk', 'None']],
          note: 'You keep all your stock. Carry matches it 1:1 with USDG and you earn trading fees on 2x the size.' },
      ],
    },
    usdg: {
      reg: 'lend', cta: 'Deposit USDG', btn: 'hm-dep-usdg', label: 'Your USDG', min: 100, max: 100000, step: 100, def: 10000, minTick: '$100', maxTick: '$100,000',
      toUsd: (a) => a, fmt: (a) => usd(a),
      sub: (mo) => '<span class="mo">' + mo + '</span>/mo on your dollars.',
      options: [
        { name: 'Onchain Lending', rates: [0.039, 0.039, 0.039], fill: 'var(--muted)', rows: () => [['Paid in', 'USDG']], note: 'Your dollars are lent to borrowers onchain.' },
        { name: 'Neobank', rates: [0.06, 0.06, 0.06], fill: 'var(--text)', rows: () => [['Paid in', 'USDG']], note: 'Stablecoin yield inside a trading app.' },
        { name: 'Carry', carry: true, rates: [0.065, 0.142, 0.15], rows: () => [['Paid in', 'USDG']], note: 'Onchain lending yield plus a share of Carry\'s trading fees.' },
      ],
    },
  };
  const CALC_HTML =
    '<p class="eb">&gt; Calculator</p><h2>See What You Could Earn.</h2>' +
    '<div class="headrow"><div class="toggle" role="group" aria-label="What you deposit">' +
    '<button class="chip" type="button" data-k="mstr">MSTR</button><button class="chip" type="button" data-k="usdg">USDG</button></div>' +
    '<p class="sub" data-k="sub"></p></div>' +
    '<div class="panel"><div class="controls">' +
    '<div class="field"><div class="field-head"><label for="hm-amount" data-k="amountLabel"></label><span class="val"><span data-k="amountOut"></span><small data-k="usdOut"></small></span></div>' +
    '<input id="hm-amount" type="range" data-k="amount"><div class="ticks"><span data-k="minTick"></span><span data-k="maxTick"></span></div></div>' +
    '<div class="field"><div class="field-head"><label for="hm-time">Time</label><span class="val" data-k="timeOut"></span></div>' +
    '<input id="hm-time" type="range" min="0" max="13" step="1" data-k="time"><div class="ticks"><span>1m</span><span>30y</span></div></div>' +
    '<div class="field"><div class="field-head"><label for="hm-market">Market</label><span class="val" data-k="marketOut"></span></div>' +
    '<input id="hm-market" type="range" min="0" max="2" step="1" data-k="market"><div class="ticks"><span>Bear</span><span>Neutral</span><span>Bull</span></div></div>' +
    '<button class="cta" type="button" data-k="cta"></button></div>' +
    '<div class="chart"><div class="chart-label"><span>Est. earnings</span><span data-k="chartTime"></span></div>' +
    '<div class="chart-head"><div class="total" data-k="total"></div><div class="total-sub" data-k="totalSub"></div></div>' +
    '<svg data-k="chart" role="img" aria-label="Earnings over time for each option"></svg><div class="legend" data-k="legend"></div></div>' +
    '<div class="cards" data-k="cards"></div>' +
    '<p class="foot">*Illustrative reference rate: Rates vary, and earnings involve risk.<span data-k="lpNote"><br>LPing on your own, even single-sided, sells your shares as the price moves and adds impermanent loss. Carry pairs your stock for you.</span></p>' +
    '</div>';
  const WIDE = window.matchMedia('(min-width: 1101px)');
  const niceStep = (v) => { const p = Math.pow(10, Math.floor(Math.log10(v))); let best = p; [1, 2, 2.5, 5].forEach((k) => { if (k * p <= v) best = k * p; }); return best; };

  // The bundle runtime re-processes nodes added under its tree and can swap them for copies, which drops listeners
  // and closures. So the calculator keeps its state on the mount element (data-mode, data-amt-*) and listens on the
  // document.
  const q = (root, k) => root.querySelector('[data-k="' + k + '"]');
  function mountCalc(root) {
    root.dataset.rt = '1';
    root.dataset.amtMstr = MODES.mstr.def; root.dataset.amtUsdg = MODES.usdg.def;
    root.innerHTML = CALC_HTML;
    // Starting values are set here, not as value="" attributes: the runtime re-applies template attributes on its
    // refreshes, which snapped the time and market sliders back to their start.
    q(root, 'time').value = 1; q(root, 'market').value = 1;
    setMode(root, 'mstr');
  }

  function setMode(root, m) {
    const $ = (k) => q(root, k), M = MODES[m];
    root.dataset.mode = m;
    root.setAttribute('data-reg', M.reg);
    $('mstr').setAttribute('aria-pressed', String(m === 'mstr')); $('usdg').setAttribute('aria-pressed', String(m === 'usdg'));
    const a = $('amount'); a.min = M.min; a.max = M.max; a.step = M.step; a.value = root.dataset[m === 'mstr' ? 'amtMstr' : 'amtUsdg'];
    $('amountLabel').textContent = M.label; $('minTick').textContent = M.minTick; $('maxTick').textContent = M.maxTick;
    $('cta').textContent = M.cta; $('lpNote').hidden = m !== 'mstr';
    $('cards').innerHTML = M.options.map((o, i) => '<div class="card' + (o.carry ? ' carry' : '') + '"><div class="name">' + o.name + '</div><div class="big" data-k="big' + i + '"></div>' +
      '<div class="row"><span>Rate</span><b' + (o.carry ? ' class="up"' : '') + ' data-k="rate' + i + '"></b></div><div data-k="rows' + i + '"></div><div class="note">' + o.note + '</div></div>').join('');
    $('legend').innerHTML = M.options.slice().reverse().map((o) => '<span style="--c: ' + (o.fill || 'var(--acc)') + '">' + o.name + '</span>').join('');
    render(root);
  }

  function render(root) {
    const $ = (k) => q(root, k), mode = root.dataset.mode, M = MODES[mode], amt = +$('amount').value, [label, years] = STEPS[+$('time').value], mk = +$('market').value;
    root.dataset[mode === 'mstr' ? 'amtMstr' : 'amtUsdg'] = amt;
    const value = M.toUsd(amt), carry = M.options[M.options.length - 1];
    $('amountOut').textContent = M.fmt(amt);
    $('usdOut').textContent = mode === 'mstr' ? usd(value) : '';
    $('timeOut').textContent = label; $('chartTime').textContent = label; $('marketOut').textContent = MARKETS[mk];
    $('sub').innerHTML = M.sub(usd(value * carry.rates[mk] / 12));
    M.options.forEach((o, i) => {
      const r = o.rates[mk];
      $('big' + i).textContent = o.priceOnly ? 'Price gains only' : usd(earn(value, r, years), true);
      $('rate' + i).textContent = (Math.round(r * 1000) / 10) + '%' + (o.carry ? '*' : '');
      $('rows' + i).innerHTML = o.rows(amt).map((row) => '<div class="row"><span>' + row[0] + '</span><b' + (row[2] ? ' class="' + row[2] + '"' : '') + '>' + row[1] + '</b></div>').join('');
    });
    const others = M.options.slice(0, -1).filter((o) => o.rates[mk] > 0);
    $('total').textContent = usd(earn(value, carry.rates[mk], years), true);
    $('totalSub').innerHTML = 'Estimated with Carry over ' + label + '*' + (others.length ? ' · vs ' + others.map((o) => '<b>' + usd(earn(value, o.rates[mk], years), true) + '</b> ' + o.name.toLowerCase()).join(', ') : '');
    drawChart(q(root, 'chart'), value, years, M.options, mk);
  }

  // Forecast curve: earnings from today to the chosen time; the dollar axis scales to the Carry total.
  // The viewBox matches the drawn width so axis text stays 12px; desktop is flatter so the calculator fits one screen.
  function drawChart(svg, value, years, opts, mk) {
    const wide = WIDE.matches, W = Math.round(svg.getBoundingClientRect().width) || 960;
    const H = wide ? 350 : Math.round(Math.max(220, W * 0.6)), L = 4, R = wide ? 120 : 72, T = 36, B = 32, N = 60;
    const carry = opts[opts.length - 1], total = earn(value, carry.rates[mk], years), max = Math.max(total, 1) / 0.9;
    const x = (t) => L + (W - L - R) * t / years, y = (v) => T + (H - T - B) * (1 - v / max);
    const path = (r) => { let d = ''; for (let i = 0; i <= N; i++) { const t = years * i / N; d += (i ? 'L' : 'M') + x(t).toFixed(1) + ' ' + y(earn(value, r, t)).toFixed(1); } return d; };
    const area = (r) => path(r) + 'L' + x(years).toFixed(1) + ' ' + y(0).toFixed(1) + 'L' + x(0).toFixed(1) + ' ' + y(0).toFixed(1) + 'Z';
    let out = '';
    const step = niceStep(total / 3);
    for (let gv = step; gv < total * 0.97; gv += step) {
      const gy = y(gv).toFixed(1);
      out += '<line class="grid" stroke-dasharray="2 4" x1="' + L + '" x2="' + (W - R) + '" y1="' + gy + '" y2="' + gy + '"/><text class="axis" x="' + (W - R + 10) + '" y="' + (+gy + 4) + '">' + usd(gv) + '</text>';
    }
    out += '<text class="axis" x="' + (W - R + 10) + '" y="' + (y(0) + 4) + '">$0</text>';
    const mo = Math.round(years * 12), tStep = [1, 2, 3, 6, 12, 24, 36, 60, 120].filter((m) => mo / m <= 5)[0];
    const tl = (m) => (m % 12 ? m + 'MO' : (m / 12) + 'YR');
    for (let m = tStep; m < mo; m += tStep) {
      const gx = x(m / 12).toFixed(1);
      if (gx - L < 50 || x(years) - gx < 50) continue;   // keep clear of the "Today" and end labels
      out += '<line class="grid" stroke-dasharray="2 4" x1="' + gx + '" x2="' + gx + '" y1="' + T + '" y2="' + y(0) + '"/><text class="axis" text-anchor="middle" x="' + gx + '" y="' + (H - 8) + '">' + tl(m) + '</text>';
    }
    out += '<path d="' + area(carry.rates[mk]) + '" style="fill: var(--acc); fill-opacity: .16"/>';
    // Line-end labels sit above their line. A line ending too close under the one above gets no label, and neither does
    // any line on a narrow chart, where the label would cross the Carry curve; the legend and the line above the chart name them.
    let prevLineY = y(total);
    opts.slice(0, -1).filter((o) => o.rates[mk] > 0).sort((a, b) => b.rates[mk] - a.rates[mk]).forEach((o) => {
      const ey = y(earn(value, o.rates[mk], years)), roomy = wide && ey - prevLineY >= 40;
      prevLineY = ey;
      out += '<path d="' + area(o.rates[mk]) + '" style="fill: ' + o.fill + '; fill-opacity: .06"/>' +
        '<path d="' + path(o.rates[mk]) + '" fill="none" stroke-width="2.5" style="stroke: ' + o.fill + '"/>' +
        (roomy ? '<text class="axis" text-anchor="end" x="' + (x(years) - 10).toFixed(1) + '" y="' + (ey - 10).toFixed(1) + '" style="fill: ' + o.fill + '">' + usd(earn(value, o.rates[mk], years), true) + ' ' + o.name + '</text>' : '');
    });
    out += '<path d="' + path(carry.rates[mk]) + '" fill="none" stroke-width="2.5" stroke-linejoin="round" style="stroke: var(--acc)"/>';
    out += '<line x1="' + L + '" x2="' + (W - R) + '" y1="' + y(0) + '" y2="' + y(0) + '" style="stroke: var(--line-2)"/>';
    const endX = x(years), endY = y(total);
    out += '<circle cx="' + endX.toFixed(1) + '" cy="' + endY.toFixed(1) + '" r="5" style="fill: var(--acc); stroke: var(--ground)" stroke-width="2"/>';
    out += '<text class="axis" x="' + L + '" y="' + (H - 8) + '">Today</text>';
    out += '<text class="axis" text-anchor="end" x="' + endX.toFixed(1) + '" y="' + (H - 8) + '">' + tl(mo) + '</text>';
    out += '<text class="axis" text-anchor="end" x="' + (endX - 10).toFixed(1) + '" y="' + (endY - 10).toFixed(1) + '" style="fill: var(--ink)">' + usd(total, true) + ' Carry</text>';
    svg.setAttribute('viewBox', '0 0 ' + W + ' ' + H);
    svg.innerHTML = out;
  }

  document.addEventListener('click', (e) => {
    const b = e.target.closest && e.target.closest('[data-hm-calc] [data-k]'), root = b && b.closest('[data-hm-calc]');
    if (!root || !root.dataset.mode) return;
    if (b.dataset.k === 'mstr' || b.dataset.k === 'usdg') setMode(root, b.dataset.k);
    // The calculator's button opens the same deposit flow as the hero button for this side.
    else if (b.dataset.k === 'cta') { const dep = document.getElementById(MODES[root.dataset.mode].btn); if (dep) dep.click(); }
  });
  // On touch screens, a slider follows the finger from wherever it lands on the track, instead of only when the thumb
  // itself is grabbed (iOS Safari otherwise ignores drags that start off the thumb).
  const slideTo = (el, e) => {
    const r = el.getBoundingClientRect(), min = +el.min, max = +el.max, step = +el.step || 1;
    const f = Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)), v = min + Math.round(f * (max - min) / step) * step;
    if (+el.value !== v) { el.value = v; el.dispatchEvent(new Event('input', { bubbles: true })); }
  };
  let sliding = null;
  document.addEventListener('pointerdown', (e) => {
    if (e.pointerType === 'mouse' || !e.target.matches || !e.target.matches('[data-hm-calc] input[type=range]')) return;
    sliding = e.target; e.preventDefault(); slideTo(sliding, e);
  });
  document.addEventListener('pointermove', (e) => { if (sliding) { e.preventDefault(); slideTo(sliding, e); } });
  ['pointerup', 'pointercancel'].forEach((t) => document.addEventListener(t, () => { sliding = null; }));
  document.addEventListener('input', (e) => { const root = e.target.closest && e.target.closest('[data-hm-calc]'); if (root && root.dataset.mode) render(root); });
  const renderAll = () => document.querySelectorAll('[data-hm-calc][data-mode]').forEach(render);
  let rz = 0;
  window.addEventListener('resize', () => { clearTimeout(rz); rz = setTimeout(renderAll, 120); });
  window.addEventListener('carrychain', renderAll);   // the oracle price sets the MSTR dollar value

  // ---- Live figures ----------------------------------------------------------
  function fillLive() {
    const v = vault();
    document.querySelectorAll('[data-hm-backstop]').forEach((e) => { e.textContent = v && v.backstop != null ? money(v.backstop, 0) : '—'; });
    const today = new Date().toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
    document.querySelectorAll('[data-hm-today]').forEach((e) => { e.textContent = today; });
  }

  function scan() {
    if (document.querySelector('[data-hm-receipt]:empty')) renderReceipts();
    document.querySelectorAll('[data-hm-calc]:not([data-rt])').forEach(mountCalc);
    if (document.querySelector('[data-hm-backstop]:empty, [data-hm-today]:empty')) fillLive();
  }
  new MutationObserver(scan).observe(document, { childList: true, subtree: true });
  window.addEventListener('carrychain', fillLive);
  scan();
})();
