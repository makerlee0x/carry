/**
 * Carry chain module (viem). Reads the LeveredLpVault on Robinhood Chain Testnet and
 * handles the real MetaMask connection. It does not send transactions: deposits and
 * withdrawals prefer this module; carry-vault.js is a thinner fallback with the same flows.
 *
 * The UI listens for the "carrychain" window event; its detail is a snapshot:
 *   { ready, vault, account, chainId, ui, error }
 *   vault: { price, tvl, util, paused, termSec, aprPct, ... } (public data, no wallet needed)
 *   ui:    { wallet: { ETH, MSTR, USDG }, positions: [...] } in the shape the site already renders
 * window.CarryChain.last always holds the latest snapshot.
 */
(function () {
  'use strict';

  const VIEM = 'https://cdn.jsdelivr.net/npm/viem@2.57.2/+esm';
  const FLAG = 'carry_chain_disconnected';
  const REFRESH_MS = 20000;

  let viem, pub, cfg, vaultAbi, provider, chainDef;
  const S = { ready: false, vault: null, account: null, chainId: null, ui: null, raw: [], analytics: null, connectLink: null, error: null };

  const snapshot = () => ({ ready: S.ready, vault: S.vault, account: S.account, chainId: S.chainId, ui: S.ui, analytics: S.analytics, connectLink: S.connectLink, error: S.error });
  const emit = () => {
    window.CarryChain.last = snapshot();
    window.dispatchEvent(new CustomEvent('carrychain', { detail: window.CarryChain.last }));
  };
  const flag = (on) => { try { on ? localStorage.setItem(FLAG, '1') : localStorage.removeItem(FLAG); } catch (e) {} };
  const flagged = () => { try { return localStorage.getItem(FLAG) === '1'; } catch (e) { return false; } };

  // Prefer MetaMask when several wallets inject themselves.
  function findMetaMask() {
    const eth = window.ethereum;
    if (!eth) return null;
    if (Array.isArray(eth.providers)) return eth.providers.find((p) => p.isMetaMask && !p.isBraveWallet) || null;
    return eth.isMetaMask ? eth : null;
  }

  // ---- MetaMask on phones ---------------------------------------------------
  // Phone browsers have no injected wallet. MetaMask's SDK launches the MetaMask app through a deep link,
  // the user approves there, and the connection returns to this page. Loaded only when it is needed.
  const SDK_URL = 'https://esm.sh/@metamask/sdk@0.34.0?bundle';   // the ?bundle build; the plain browser builds of the SDK fail to start
  const SDK_FLAG = 'carry_mm_sdk';
  // A phone, even when the browser asks for the desktop site (its user agent then looks like a computer).
  const isMobile = () => {
    const ua = navigator.userAgent || '';
    if (/Android|iPhone|iPad|iPod|Mobile/i.test(ua)) return true;
    if (navigator.userAgentData && navigator.userAgentData.mobile) return true;
    if (navigator.maxTouchPoints > 1 && /Macintosh/.test(ua)) return true;   // iPad asking for the desktop site
    try { return navigator.maxTouchPoints > 0 && window.matchMedia('(pointer: coarse)').matches; } catch (e) { return false; }
  };
  const appLink = () => 'https://metamask.app.link/dapp/' + location.host + location.pathname + location.search + location.hash;
  let sdkP = null, sdkInst = null;
  function mobileProvider() {
    if (!sdkP) {
      sdkP = (async () => {
        const mod = await import(SDK_URL), Ctor = mod.MetaMaskSDK || mod.default;
        const sdk = new Ctor({ dappMetadata: { name: 'Carry', url: location.origin }, checkInstallationImmediately: false, logging: { sdk: false } });
        await sdk.init();
        let pr = sdk.getProvider(); const t0 = Date.now();
        while (!pr && Date.now() - t0 < 6000) { await new Promise((r) => setTimeout(r, 200)); pr = sdk.getProvider(); }
        if (!pr) throw new Error('MetaMask connector did not start.');
        sdkInst = sdk;
        return pr;
      })();
      sdkP.catch(() => { sdkP = null; });
    }
    return sdkP;
  }

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  // Forget the phone session completely: end it, and clear what the SDK keeps in this browser, so the next
  // connect opens a brand new channel instead of tripping over the old one ("channel already connected").
  async function resetSdk() {
    if (sdkInst) { try { await withTimeout(Promise.resolve(sdkInst.terminate()), 4000); } catch (e) {} }
    sdkInst = null; sdkP = null; provider = null; listening = false;
    try {
      for (const st of [localStorage, sessionStorage]) {
        for (const k of Object.keys(st)) if (/MMSDK|sdk-comm|metamask|providerType|^\.sdk/i.test(k) && k !== 'carry_last_wallet') st.removeItem(k);
      }
      localStorage.removeItem(SDK_FLAG);
    } catch (e) {}
  }
  const withTimeout = (p, ms, msg) => Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error(msg || 'timeout')), ms))]);
  let readyResolve; const readyP = new Promise((r) => { readyResolve = r; });   // resolves once the library and config have loaded

  const num = (v, d = 18) => Number(viem.formatUnits(v, d));
  const round = (n, dp) => Number(n.toFixed(dp));

  function leftText(sec) {
    if (sec <= 0) return 'ready to settle';
    const d = Math.floor(sec / 86400), h = Math.floor((sec % 86400) / 3600), m = Math.floor((sec % 3600) / 60);
    if (d > 0) return `${d}d ${h}h left`;
    if (h > 0) return `${h}h ${m}m left`;
    return `${Math.max(m, 1)}m left`;
  }

  // ---- Public vault data ---------------------------------------------------
  async function readVault() {
    const rd = (functionName, args = []) => pub.readContract({ address: cfg.vault, abi: vaultAbi, functionName, args });
    const [paused, term, apr, price, next, senior, reserved, free, backstop] = await Promise.all([
      rd('paused'), rd('term'), rd('borrowAprWad'),
      pub.readContract({ address: cfg.oracle, abi: viem.parseAbi(['function mstrPriceWad() view returns (uint256)']), functionName: 'mstrPriceWad' }),
      rd('nextPositionId'), rd('totalSeniorPrincipal'), rd('reservedSenior'), rd('freeSenior'), rd('backstop'),
    ]);
    const tvl = num(senior), res = num(reserved);
    S.vault = {
      paused, termSec: Number(term), aprPct: num(apr) * 100, price: num(price),
      tvl, matched: res, idle: num(free), backstop: num(backstop),
      util: tvl > 0 ? round((res / tvl) * 100, 1) : 0,
      positions: Number(next) - 1,
    };
  }

  // ---- Wallet data ---------------------------------------------------------
  async function readAccount() {
    if (!S.account) { S.ui = null; S.raw = []; return; }
    const a = S.account;
    const erc = viem.parseAbi(['function balanceOf(address) view returns (uint256)']);
    const rd = (functionName, args) => pub.readContract({ address: cfg.vault, abi: vaultAbi, functionName, args });
    const [eth, mstr, usdg, senior, free, yld, mstrClaim, logs] = await Promise.all([
      pub.getBalance({ address: a }),
      pub.readContract({ address: cfg.mstr, abi: erc, functionName: 'balanceOf', args: [a] }),
      pub.readContract({ address: cfg.usdg, abi: erc, functionName: 'balanceOf', args: [a] }),
      rd('seniorPrincipal', [a]), rd('freePrincipal', [a]),
      rd('seniorClaimableYield', [a]), rd('seniorClaimableMstr', [a]),
      vaultEvents({ eventName: 'JuniorDeposit', args: { junior: a } }),
    ]);

    const ids = [...new Set(logs.map((l) => l.args.positionId))];
    const raw = await Promise.all(ids.map(async (id) => {
      const [p, matched] = await Promise.all([rd('positions', [id]), rd('isMatched', [id])]);
      return { id, mstr: num(p[1]), senior: num(p[2]), fee: num(p[4]), openedAt: Number(p[5]), settled: p[6], matched };
    }));

    const now = Math.floor(Date.now() / 1000), term = S.vault.termSec, price = S.vault.price;
    const live = raw.filter((r) => !r.settled);
    S.raw = live;
    const positions = [];

    if (live.length) {
      const act = live.filter((r) => r.matched && r.openedAt + term > now);
      const rdy = live.filter((r) => r.matched && r.openedAt + term <= now);
      const opn = live.filter((r) => !r.matched);
      const mstrTotal = live.reduce((x, r) => x + r.mstr, 0), fees = live.reduce((x, r) => x + r.fee, 0);
      const sumOf = (list) => list.reduce((x, r) => x + r.mstr, 0);
      const matchedShares = sumOf(act) + sumOf(rdy), freeShares = sumOf(opn) + sumOf(rdy), activeShares = sumOf(act);
      let statusTxt, leftTxt, free_, earned = 0, days = 0;
      const parts = [];
      if (act.length) parts.push(act.length + (act.length === 1 ? ' active' : ' active'));
      if (rdy.length) parts.push(rdy.length + (rdy.length === 1 ? ' ready' : ' ready'));
      if (opn.length) parts.push(opn.length + (opn.length === 1 ? ' open' : ' open'));
      const mixed = [act.length > 0, rdy.length > 0, opn.length > 0].filter(Boolean).length > 1;
      if (act.length) {
        const soonest = Math.min(...act.map((r) => r.openedAt + term)), first = Math.min(...act.map((r) => r.openedAt));
        statusTxt = mixed ? ('Mixed · ' + parts.join(', ')) : 'Active';
        free_ = freeShares > 0;   // some legs may still withdraw without early-exit
        leftTxt = mixed
          ? (leftText(soonest - now) + ' on active · ' + round(freeShares, 4) + ' MSTR free of early-exit')
          : leftText(soonest - now);
        earned = Math.min(4, (4 * (now - first)) / term);
        days = Math.floor((now - first) / 86400);
      } else if (rdy.length) {
        statusTxt = mixed ? ('Mixed · ' + parts.join(', ')) : 'Ready to settle';
        free_ = true; leftTxt = mixed ? ('Term ended · ' + parts.join(', ')) : 'Term ended'; earned = 4;
        days = Math.floor((now - Math.min(...rdy.map((r) => r.openedAt))) / 86400);
      } else {
        statusTxt = 'Open'; free_ = true; leftTxt = 'Waiting for USDG';
      }
      positions.push({ sym: 'MSTR', shares: round(mstrTotal, 4), fees: round(fees, 4), days, earned: round(earned, 2), auto: false, real: true, statusTxt, leftTxt, free: free_, count: live.length,
        matchedPct: mstrTotal > 0 ? round((matchedShares / mstrTotal) * 100, 1) : 0, freeShares: round(freeShares, 4), activeShares: round(activeShares, 4),
        mixed, openShares: round(sumOf(opn), 4), readyShares: round(sumOf(rdy), 4) });
    }

    const seniorN = num(senior);
    if (seniorN > 0) {
      const freeN = num(free), matchedN = Math.max(seniorN - freeN, 0);
      positions.push({
        sym: 'USDG', shares: round(seniorN, 4), matched: round(matchedN, 4),
        fees: round(num(yld) + num(mstrClaim) * price, 4), days: 0, earned: 0, auto: false, real: true,
        statusTxt: matchedN > 0 ? 'Active' : 'Open', leftTxt: matchedN > 0 ? 'Unlocks on close' : 'Idle · withdrawable', free: matchedN === 0, count: 1,
      });
    }

    S.ui = { wallet: { ETH: round(num(eth), 5), MSTR: round(num(mstr), 4), USDG: round(num(usdg), 4) }, positions };
  }


  // ---- Protocol analytics (built from the vault's events) -------------------
  const blockTime = new Map();
  async function timeOf(blockNumber) {
    if (blockTime.has(blockNumber)) return blockTime.get(blockNumber);
    const b = await pub.getBlock({ blockNumber });
    const t = Number(b.timestamp) * 1000;
    blockTime.set(blockNumber, t);
    return t;
  }

  // The testnet RPC caps eth_getLogs spans (10M blocks, 100k when topics are OR'd), so a query from block 0
  // fails outright. Scan from the vault's deploy block in chunks; with no eventName, fetch every vault log
  // (address only, no topic filter) and decode them here.
  async function vaultEvents({ eventName, args }) {
    const head = await pub.getBlockNumber(), STEP = 9000000n, out = [];
    for (let from = BigInt(cfg.deployBlock || 0); from <= head; from += STEP) {
      const to = from + STEP - 1n < head ? from + STEP - 1n : head;
      if (eventName) out.push(...await pub.getContractEvents({ address: cfg.vault, abi: vaultAbi, eventName, args, fromBlock: from, toBlock: to }));
      else out.push(...viem.parseEventLogs({ abi: vaultAbi, logs: await pub.getLogs({ address: cfg.vault, fromBlock: from, toBlock: to }) }));
    }
    return out;
  }

  // Daily series for the last N days (local days, ending today) from the vault's own events.
  // Stock deposits are valued at the current oracle price: the chain keeps no price history.
  async function readAnalytics() {
    const N = 180, price = S.vault ? S.vault.price : 0;
    const logs = await vaultEvents({});
    const blocks = [...new Set(logs.map((l) => l.blockNumber))];
    for (let i = 0; i < blocks.length; i += 25) await Promise.all(blocks.slice(i, i + 25).map(timeOf));

    const today = new Date(); today.setHours(0, 0, 0, 0);
    const dayOf = (ms) => { const d = new Date(ms); d.setHours(0, 0, 0, 0); return N - 1 - Math.round((today - d) / 864e5); };   // index into the series
    const zero = () => Array(N).fill(0), arr = { dep: zero(), wd: zero(), fees: zero(), rev: zero(), earned: zero(), newU: zero(), dau: zero() };
    const daySets = Array.from({ length: N }, () => new Set()), seen = new Set(), matchedOf = new Map();
    const act = zero(), tot = zero(), stk = zero(), bsBal = zero(), bsIn = zero(), bsOut = zero();   // end-of-day matched USDG, total lent USDG, stock held (MSTR), backstop balance
    let runAct = 0, runTot = 0, runStock = 0, runBs = 0, allDep = 0, allFees = 0, users = 0;
    const add = (a, i, v) => { if (i >= 0 && i < N) a[i] += v; };
    const touch = (i, who) => { if (!who) return; const w = who.toLowerCase(); if (i >= 0 && i < N) daySets[i].add(w); if (!seen.has(w)) { seen.add(w); users++; add(arr.newU, i, 1); } };

    const sorted = logs.slice().sort((a, b) => Number(a.blockNumber - b.blockNumber) || a.logIndex - b.logIndex);
    let lastDay = -Infinity;
    const snap = (to) => { for (let d = Math.max(lastDay, 0); d <= Math.min(to, N - 1); d++) { act[d] = runAct; tot[d] = runTot; stk[d] = runStock; bsBal[d] = runBs; } };
    for (const l of sorted) {
      const i = dayOf(blockTime.get(l.blockNumber)), a = l.args || {};
      if (i > lastDay) { snap(i - 1); lastDay = i; }
      switch (l.eventName) {
        case 'JuniorDeposit': { const v = num(a.mstrAmount) * price; add(arr.dep, i, v); allDep += v; runStock += num(a.mstrAmount); touch(i, a.junior); break; }
        case 'SeniorDeposit': { const v = num(a.amount); add(arr.dep, i, v); allDep += v; runTot += v; touch(i, a.senior); break; }
        case 'SeniorWithdraw': { const v = num(a.principal); add(arr.wd, i, v); runTot -= v; touch(i, a.senior); break; }
        case 'UnmatchedWithdraw': add(arr.wd, i, num(a.mstrAmount) * price); runStock -= num(a.mstrAmount); touch(i, a.junior); break;
        case 'PositionMatched': { const v = num(a.seniorPrincipal); matchedOf.set(a.positionId, v); runAct += v; touch(i, a.junior); break; }
        case 'EarlyExit': add(arr.wd, i, (num(a.mstrReturned) + num(a.mstrSold)) * price); runStock -= num(a.mstrReturned) + num(a.mstrSold); runAct -= matchedOf.get(a.positionId) || 0; touch(i, a.junior); break;
        case 'Settled': add(arr.wd, i, (num(a.mstrKept) + num(a.mstrSold)) * price); runStock -= num(a.mstrKept) + num(a.mstrSold); { const o = num(a.fromBackstop); add(bsOut, i, o); runBs -= o; } runAct -= matchedOf.get(a.positionId) || 0; touch(i, a.junior); break;
        case 'BackstopFunded': { const v = num(a.amount); add(bsIn, i, v); runBs += v; break; }
        case 'LpFeeAccrued': { const g = num(a.gross); runBs += num(a.toBackstop); add(bsIn, i, num(a.toBackstop)); add(arr.fees, i, g); add(arr.rev, i, num(a.toBackstop)); add(arr.earned, i, num(a.toPosition)); allFees += num(a.toPosition); break; }
        default: break;
      }
    }
    snap(N - 1);
    // Newest-first transaction list for the Analytics table. Every row keeps its transaction hash.
    const EV = {
      JuniorDeposit: (a) => ({ k: 'dep', t: 'Deposit', n: num(a.mstrAmount), u: 'MSTR', who: a.junior, pid: a.positionId, note: a.matched ? 'Matched' : 'Waiting for USDG' }),
      SeniorDeposit: (a) => ({ k: 'dep', t: 'Deposit', n: num(a.amount), u: 'USDG', who: a.senior }),
      PositionMatched: (a) => ({ k: 'match', t: 'Matched', n: num(a.seniorPrincipal), u: 'USDG', who: a.junior, pid: a.positionId }),
      SeniorWithdraw: (a) => ({ k: 'wd', t: 'Withdraw', n: num(a.principal), u: 'USDG', who: a.senior }),
      UnmatchedWithdraw: (a) => ({ k: 'wd', t: 'Withdraw', n: num(a.mstrAmount), u: 'MSTR', who: a.junior, pid: a.positionId }),
      EarlyExit: (a) => ({ k: 'wd', t: 'Early exit', n: num(a.mstrReturned) + num(a.mstrSold), u: 'MSTR', who: a.junior, pid: a.positionId, note: 'Coupon ' + round(num(a.couponOwed), 2) + ' USDG' }),
      Settled: (a) => ({ k: 'wd', t: 'Settled', n: num(a.mstrKept) + num(a.mstrSold), u: 'MSTR', who: a.junior, pid: a.positionId, note: num(a.fromBackstop) > 0 ? 'Backstop paid ' + round(num(a.fromBackstop), 2) + ' USDG' : '' }),
      LpFeeAccrued: (a) => ({ k: 'fee', t: 'Fees', n: num(a.gross), u: 'USDG', pid: a.positionId, note: 'To position ' + round(num(a.toPosition), 2) + ' · backstop ' + round(num(a.toBackstop), 2) }),
      BackstopFunded: (a) => ({ k: 'bs', t: 'Backstop', n: num(a.amount), u: 'USDG', who: a.from }),
      PausedDeposits: (a) => ({ k: 'admin', t: a.paused ? 'Deposits paused' : 'Deposits resumed' }),
    };
    const events = [];
    for (const l of sorted.slice().reverse()) {
      const f = EV[l.eventName]; if (!f) continue;
      const e = f(l.args || {});
      events.push(Object.assign(e, { pid: e.pid != null ? String(e.pid) : '', who: e.who || '', note: e.note || '', ts: blockTime.get(l.blockNumber), hash: l.transactionHash, id: l.transactionHash + ':' + l.logIndex }));
      if (events.length >= 300) break;
    }
    // Live MSTR APY for stock holders: fees paid to positions, minus the lender's borrow cost, over the
    // matched stock-time (matched USDG x time) of the last 30 days. Needs 1+ day of history and some fees.
    let mstrApy = null;
    {
      const nowMs = Date.now(), apr = S.vault ? S.vault.aprPct / 100 : 0.05, evT = (l) => blockTime.get(l.blockNumber);
      const firstM = sorted.find((l) => l.eventName === 'PositionMatched');
      if (firstM) {
        const start = Math.max(nowMs - 30 * 864e5, evT(firstM)), m2 = new Map();
        let prevT = start, cur = 0, ms = 0, fee = 0, nFee = 0;
        for (const l of sorted) {
          const t = evT(l), a = l.args || {};
          if (t > start) { ms += cur * (t - prevT); prevT = t; }
          if (l.eventName === 'PositionMatched') { const v = num(a.seniorPrincipal); m2.set(String(a.positionId), v); cur += v; }
          else if (l.eventName === 'EarlyExit' || l.eventName === 'Settled') { cur -= m2.get(String(a.positionId)) || 0; m2.delete(String(a.positionId)); }
          else if (l.eventName === 'LpFeeAccrued' && t >= start) { fee += num(a.toPosition); nFee++; }
        }
        ms += cur * (nowMs - prevT);
        const stockDays = ms / 864e5, winDays = (nowMs - start) / 864e5;
        if (nFee > 0 && stockDays > 0 && winDays >= 1) mstrApy = { pct: round(Math.min(999, Math.max(0, (fee / stockDays * 365 - apr) * 100)), 1), days: round(winDays, 1), fees: round(fee, 2) };
      }
    }
    const inflow = arr.dep.map((v, i) => v - arr.wd[i]);
    const cumIn = []; inflow.reduce((x, v, i) => (cumIn[i] = x + v), 0);
    const cumU = []; arr.newU.reduce((x, v, i) => (cumU[i] = x + v), 0);
    S.analytics = {
      N, dep: arr.dep, wd: arr.wd, inflow, cumIn, newU: arr.newU, cumU, dau: daySets.map((x) => x.size),
      fees: arr.fees, rev: arr.rev, earned: arr.earned, active: act, inact: tot.map((t, i) => Math.max(t - act[i], 0)),
      bsIn, bsOut, bsBal, tvl: tot.map((t, i) => t + stk[i] * price),
      totals: { users, dep: allDep, earned: allFees }, events, explorer: cfg.explorerUrl || '', mstrApy, updated: Date.now(),
    };
  }

  // ---- Refresh -------------------------------------------------------------
  let busy = null;
  async function refresh(force) {
    if (busy) { if (!force) return busy; await busy; }   // forced: wait for the stale one, then read again
    busy = (async () => {
      try {
        await readVault();
        await readAccount();
        try { await readAnalytics(); } catch (e) { console.warn('[CarryChain] analytics', (e && (e.shortMessage || e.message)) || e); }
        S.error = null;
      } catch (e) {
        S.error = e.shortMessage || e.message || String(e);
      } finally { busy = null; emit(); }
    })();
    return busy;
  }

  // The RPC can lag a moment behind a confirmed receipt, so after a transaction we read again
  // until the wallet numbers differ from what they were before it (up to ~12s).
  const sig = () => JSON.stringify([S.ui, S.vault && S.vault.tvl]);
  async function settleAfterTx(before) {
    for (const wait of [0, 1500, 2500, 3500, 4500]) {
      if (wait) await new Promise((r) => setTimeout(r, wait));
      await refresh(true);
      if (sig() !== before) return;
    }
  }

  // Wait for a transaction to confirm, then refresh the numbers.
  async function afterTx(hash) {
    const before = sig();
    try { await pub.waitForTransactionReceipt({ hash, timeout: 60000 }); } catch (e) {}
    return settleAfterTx(before);
  }


  // ---- Transactions --------------------------------------------------------
  const REASONS = {
    Paused: 'The vault is paused by its owner, so new deposits are blocked.',
    ZeroAmount: 'Amount must be greater than zero.',
    InsufficientFree: 'That much USDG is still matched with stock deposits. Only idle USDG can be withdrawn until those positions close.',
    NotJunior: 'This position belongs to a different wallet.',
    NotMatched: 'This position has not been matched with USDG yet.',
    AlreadyMatched: 'This position is already matched, so it cannot be withdrawn without an early exit.',
    AlreadySettled: 'This position is already closed.',
    TermElapsed: 'The 7-day term has ended. Settle the position instead.',
    TermNotElapsed: 'The 7-day term has not ended yet.',
    BadPosition: 'Position not found.',
    FeeOnTransfer: 'This token takes a fee on transfer, which the vault rejects.',
  };
  function nice(e) {
    if (!e) return 'Transaction failed.';
    if (e.code === 4001 || /user rejected|user denied|rejected the request/i.test(e.message || '')) return 'You rejected the request in MetaMask. No funds were moved.';
    const hit = e.walk ? e.walk((x) => x && x.data && x.data.errorName) : null;
    const name = hit && hit.data && hit.data.errorName;
    if (name && REASONS[name]) return REASONS[name];
    if (/insufficient funds/i.test(e.message || '')) return 'Not enough ETH to pay for gas. Get some from the faucet.';
    return e.shortMessage || e.message || 'Transaction failed.';
  }
  const isRejected = (e) => !!e && (e.code === 4001 || /user rejected|user denied|rejected the request/i.test(e.message || ''));
  const fail = (e) => ({ ok: false, rejected: isRejected(e), error: e && e.userMessage ? e.userMessage : nice(e) });
  const user = (msg) => Object.assign(new Error(msg), { userMessage: msg });

  function guard() {
    if (!provider || !S.account) throw user('Connect MetaMask first.');
    if (S.chainId !== cfg.chainId) throw user('Switch MetaMask to Robinhood Chain Testnet first.');
  }
  const wallet = () => viem.createWalletClient({ account: S.account, chain: chainDef, transport: viem.custom(provider) });
  const ERC20 = () => viem.parseAbi([
    'function approve(address,uint256) returns (bool)',
    'function allowance(address,address) view returns (uint256)',
    'function balanceOf(address) view returns (uint256)',
    'function mint(address,uint256)',
  ]);
  const toWei = (amount) => {
    const raw = String(amount).trim();
    if (!/^\d*\.?\d+$/.test(raw)) throw user('Enter a valid amount.');
    const w = viem.parseUnits(raw, 18);
    if (w <= 0n) throw user('Amount must be greater than zero.');
    return w;
  };

  // Simulate first (gives readable reasons), send, wait for the receipt.
  async function send(call, step, label) {
    if (step) step(label);
    const { request } = await pub.simulateContract({ ...call, account: S.account });
    const hash = await wallet().writeContract(request);
    if (step) step('Waiting for confirmation…');
    const rcpt = await pub.waitForTransactionReceipt({ hash });
    if (rcpt.status !== 'success') throw user('The transaction reverted on chain.');
    return hash;
  }

  async function deposit({ sym, amount, onStep }) {
    try {
      guard();
      const wei = toWei(amount), token = sym === 'USDG' ? cfg.usdg : cfg.mstr, name = sym === 'USDG' ? 'mUSDG' : 'mMSTR';
      const bal = await pub.readContract({ address: token, abi: ERC20(), functionName: 'balanceOf', args: [S.account] });
      if (bal < wei) throw user(`Not enough ${name}. You have ${num(bal)}.`);
      const have = await pub.readContract({ address: token, abi: ERC20(), functionName: 'allowance', args: [S.account, cfg.vault] });
      if (have < wei) await send({ address: token, abi: ERC20(), functionName: 'approve', args: [cfg.vault, wei] }, onStep, 'Approve ' + name + ' in MetaMask…');
      const before = sig();
      const fn = sym === 'USDG' ? 'depositSenior' : 'depositJunior';
      const hash = await send({ address: cfg.vault, abi: vaultAbi, functionName: fn, args: [wei] }, onStep, 'Confirm the deposit in MetaMask…');
      await settleAfterTx(before);
      return { ok: true, hash, msg: sym === 'USDG' ? 'USDG deposited. It matches waiting stock deposits first-in-first-out.' : 'Deposit confirmed. Your position opens once USDG matches it.' };
    } catch (e) { return fail(e); }
  }

  async function withdraw({ sym, amount, onStep, confirm }) {
    try {
      guard();
      await refresh(true);
      const before = sig();
      if (sym === 'USDG') {
        let wei = toWei(amount);
        const free = await pub.readContract({ address: cfg.vault, abi: vaultAbi, functionName: 'freePrincipal', args: [S.account] });
        if (wei > free && wei - free < 10n ** 15n) wei = free;   // display rounding
        if (wei > free) throw user(`Only ${num(free).toLocaleString('en-US', { maximumFractionDigits: 4 })} USDG is idle and withdrawable. The rest is matched with stock deposits until those positions close.`);
        const hash = await send({ address: cfg.vault, abi: vaultAbi, functionName: 'withdrawSenior', args: [wei] }, onStep, 'Confirm the withdrawal in MetaMask…');
        await settleAfterTx(before);
        return { ok: true, hash, msg: 'USDG withdrawn, plus any claimable yield.' };
      }
      // Deposits show as one combined position, but the vault closes each deposit whole. Open and
      // matured deposits leave with no fee; deposits still inside their 7-day term pay the early-exit fee.
      const now = Math.floor(Date.now() / 1000), term = S.vault.termSec;
      if (!S.raw.length) throw user('You have no stock positions to withdraw.');
      const open = S.raw.filter((r) => !r.matched), ready = S.raw.filter((r) => r.matched && r.openedAt + term <= now), act = S.raw.filter((r) => r.matched && r.openedAt + term > now);
      const tot = (list) => list.reduce((x, r) => x + r.mstr, 0), fx = (n) => n.toLocaleString('en-US', { maximumFractionDigits: 4 });
      const total = tot(S.raw), freeTotal = tot(open) + tot(ready), want = Number(amount);
      const all = Math.abs(want - total) <= 1e-4, freeOnly = freeTotal > 0 && Math.abs(want - freeTotal) <= 1e-4;
      if (!all && !freeOnly) {
        throw user(act.length && freeTotal > 0
          ? `Deposits leave as whole positions. You can withdraw ${fx(freeTotal)} MSTR with no fee, or all ${fx(total)} MSTR (the early-exit fee applies to the ${fx(tot(act))} MSTR still inside its 7-day term).`
          : `Stock positions withdraw in full. Use the full amount: ${fx(total)} MSTR.`);
      }
      const steps = [[open, 'withdrawUnmatched', 'Confirm the withdrawal in MetaMask…'], [ready, 'settle', 'Confirm settlement in MetaMask…']];
      if (all && act.length) {
        const prev = await Promise.all(act.map((r) => pub.readContract({ address: cfg.vault, abi: vaultAbi, functionName: 'previewEarlyExit', args: [r.id] })));
        const sum = (k) => prev.reduce((x, p) => x + num(p[k]), 0);
        const fs = (n) => (n === 0 ? '0' : n < 0.0001 ? n.toFixed(9).replace(/0+$/, '') : fx(n));   // tiny amounts need more decimals to show up
        const sold = sum('mstrSold');
        const intro = `The early-exit fee applies to ${fx(tot(act))} MSTR that is still inside its 7-day term.` + (freeTotal > 0 ? ` The other ${fx(freeTotal)} MSTR leaves with no fee.` : '') +
          (sold > 0 ? " Position fees don't cover the lender's coupon, so a small amount of your stock is sold to pay it. It is not taken from the Assistance Fund." : '');
        const rows = [
          { k: 'Coupon owed to the lender', v: `${fs(sum('couponOwed'))} USDG` },
          { k: 'Paid from position fees', v: `${fs(sum('fromPositionFees'))} USDG` },
          { k: 'Stock sold to cover the rest', v: `${fs(sold)} MSTR` + (sold > 0 ? ` (≈ $${fs(sold * S.vault.price)})` : '') },
          { k: 'Stock returned to you', v: `${fs(sum('mstrReturned'))} MSTR` },
          { k: 'Fees returned to you', v: `${fs(sum('juniorLeftoverFees'))} USDG` },
        ];
        if (sum('feeShortfallUsdg') > 0) rows.push({ k: 'Fee shortfall', v: `${fx(sum('feeShortfallUsdg'))} USDG` });
        const ok = confirm ? await confirm({ title: 'Confirm early exit', intro, rows, confirmLabel: 'Confirm early exit' }) : false;   // no native dialogs: the site supplies the themed one
        if (!ok) throw user('Early exit cancelled. No funds were moved.');
        steps.push([act, 'earlyExit', 'Confirm the early exit in MetaMask…']);
      }
      let hash;
      for (const [group, fn, label] of steps) for (const r of group) hash = await send({ address: cfg.vault, abi: vaultAbi, functionName: fn, args: [r.id] }, onStep, label);
      await settleAfterTx(before);
      return { ok: true, hash, msg: all && act.length ? 'Withdrawn. The early-exit fee was applied to the portion still inside its term.' : 'Stock withdrawn to your wallet with no early-exit fee.' };
    } catch (e) { return fail(e); }
  }

  async function mint({ sym, amount, onStep }) {
    try {
      guard();
      const token = sym === 'USDG' ? cfg.usdg : cfg.mstr, before = sig();
      const hash = await send({ address: token, abi: ERC20(), functionName: 'mint', args: [S.account, toWei(amount)] }, onStep, 'Confirm in MetaMask…');
      await settleAfterTx(before);
      return { ok: true, hash, msg: 'Test tokens added to your wallet.' };
    } catch (e) { return fail(e); }
  }

  /// Claim fee surplus on active matched legs (claimFees). Needs vault bytecode that exposes claimFees.
  async function claimFees({ sym, onStep }) {
    try {
      guard();
      if (sym && sym !== 'MSTR') throw user(sym + ' fee claim is display-only on this testnet.');
      await refresh(true);
      const now = Math.floor(Date.now() / 1000), term = S.vault.termSec;
      const act = S.raw.filter((r) => r.matched && r.openedAt + term > now);
      if (!act.length) throw user('No active matched stock position to claim from.');
      const before = sig();
      let hash, claimed = 0;
      for (const r of act) {
        try {
          const prev = await pub.readContract({ address: cfg.vault, abi: vaultAbi, functionName: 'previewClaimFees', args: [r.id] });
          hash = await send({ address: cfg.vault, abi: vaultAbi, functionName: 'claimFees', args: [r.id] }, onStep, 'Confirm fee claim in MetaMask…');
          claimed += num(prev.toJunior != null ? prev.toJunior : prev[4]);
        } catch (e) {
          const msg = e.shortMessage || e.message || String(e);
          if (/ClaimThreshold|ZeroAmount|function|selector|returned no data|execution reverted/i.test(msg) && act.length === 1) {
            throw user('Claim-at-4% needs accrued fees above the pace threshold (and a vault that supports claimFees).');
          }
          if (!/ClaimThreshold|ZeroAmount/i.test(msg)) throw e;
        }
      }
      if (!hash) throw user('No position had claimable fee surplus above the 4% pace threshold yet.');
      await settleAfterTx(before);
      return { ok: true, hash, msg: 'Claimed ' + round(claimed, 4) + ' USDG fee surplus. Position stays open.' };
    } catch (e) { return fail(e); }
  }

  // ---- Connect -------------------------------------------------------------
  async function setAccounts(accts) {
    S.account = accts && accts[0] ? viem.getAddress(accts[0]) : null;
    if (provider) { try { S.chainId = parseInt(await withTimeout(provider.request({ method: 'eth_chainId' }), 5000), 16); } catch (e) {} }   // keep the last known chain if the wallet is slow
    emit();      // show the connected state right away; the heavy reads (balances, positions, analytics) follow
    refresh();
  }

  // The SDK opens the app itself, but a browser may block that when it is not a direct result of a tap.
  // So the connect link is also handed to the UI, which shows it as a button the user can tap.
  async function publishAppLink(sdk) {
    try {
      for (let i = 0; i < 40; i++) {
        let link = ''; try { link = sdk && sdk.getUniversalLink ? String(sdk.getUniversalLink() || '') : ''; } catch (e) { /* not started yet */ }
        if (/channelId=/.test(link)) { S.connectLink = link; emit(); return; }
        await sleep(150);
      }
    } catch (e) {}
  }

  async function connect(retried) {
    await readyP;
    if (!S.ready) return { ok: false, code: 'error', message: 'The blockchain library failed to load. Check your connection and reload.' };
    provider = findMetaMask();
    let viaApp = false;
    if (!provider) {
      if (!isMobile()) return { ok: false, code: 'nowallet', message: 'MetaMask not found. Install the MetaMask browser extension and reload.' };
      try { provider = await mobileProvider(); viaApp = true; }
      catch (e) {   // never send the page away on its own: report what failed and let the user choose
        if (!retried && /already connected|channel/i.test((e && e.message) || '')) { await resetSdk(); return connect(true); }
        S.connectLink = null; emit();
        return { ok: false, code: 'error', message: 'Could not start the MetaMask connection (' + ((e && e.message) || 'unknown error') + '). You can open this site inside the MetaMask app instead.' };
      }
    }
    try {
      const reqP = withTimeout(provider.request({ method: 'eth_requestAccounts' }), viaApp ? 120000 : 60000, 'no-response');
      if (viaApp) publishAppLink(sdkInst);   // gives the UI a link the user can tap to open the MetaMask app
      const accts = await reqP;
      S.connectLink = null;
      if (viaApp) { try { localStorage.setItem(SDK_FLAG, '1'); } catch (e) {} }
      flag(false);
      listen();
      await setAccounts(accts);
      return { ok: true, account: S.account };
    } catch (e) {
      S.connectLink = null; emit();
      if (!retried && viaApp && /already connected|channel/i.test((e && e.message) || '')) { await resetSdk(); return connect(true); }   // stale session: start a fresh one once
      if (e && (e.code === 4001 || /reject|denied/i.test(e.message || ''))) return { ok: false, code: 'rejected', message: 'Connection request was rejected in MetaMask.' };
      if (e && e.code === -32002) return { ok: false, code: 'error', message: 'A connection request is already open in MetaMask. Open the MetaMask app, approve or reject it, then try again.' };
      if (e && e.message === 'no-response') return { ok: false, code: 'error', message: 'MetaMask did not respond. Open the MetaMask app, check for a pending request, then try again.' };
      return { ok: false, code: 'error', message: (e && e.message) || 'Could not connect.' };
    }
  }

  // A site cannot disconnect MetaMask itself; forget the account locally.
  async function disconnect() {
    flag(true);
    S.account = null; S.ui = null; S.connectLink = null;
    if (sdkInst || sdkP) await resetSdk();   // the phone connection is ended for real, so the next connect starts clean
    emit();
  }

  let listening = false;
  function listen() {
    if (listening || !provider) return;
    listening = true;
    provider.on('accountsChanged', (a) => { if (!flagged()) setAccounts(a); });
    provider.on('chainChanged', (id) => { S.chainId = parseInt(id, 16); refresh(); });
  }

  // ---- Start ---------------------------------------------------------------
  // Restore an earlier connection without prompting. Wallets can answer slowly right after a page load,
  // so each call has a timeout and an empty answer is retried when this browser connected before.
  async function restoreWallet() {
    provider = findMetaMask();
    if (!provider && isMobile() && !flagged()) {   // back from the MetaMask app, the page may have reloaded
      let had = false; try { had = localStorage.getItem(SDK_FLAG) === '1'; } catch (e) {}
      if (had) { try { provider = await withTimeout(mobileProvider(), 8000); const live = provider.selectedAddress || (sdkInst && sdkInst.isAuthorized && await sdkInst.isAuthorized()); if (!live) provider = null; } catch (e) { provider = null; } }   // only restore a live session; never redirect on load
    }
    if (!provider) return;
    listen();
    try { S.chainId = parseInt(await withTimeout(provider.request({ method: 'eth_chainId' }), 4000), 16); } catch (e) {}
    if (flagged()) return;
    let before = false; try { before = !!localStorage.getItem('carry_last_wallet'); } catch (e) {}
    for (const wait of [0, 1200, 2500]) {
      if (wait) await sleep(wait);
      try {
        const accts = await withTimeout(provider.request({ method: 'eth_accounts' }), 4000);
        if (accts && accts[0]) { S.account = viem.getAddress(accts[0]); try { S.chainId = parseInt(await withTimeout(provider.request({ method: 'eth_chainId' }), 4000), 16); } catch (e) {} return; }
      } catch (e) {}
      if (!before) return;
    }
  }

  async function init() {
    const [mod, conf, abi] = await Promise.all([
      import(VIEM),
      fetch('config.json', { cache: 'no-store' }).then((r) => r.json()),
      fetch('abi/LeveredLpVault.json').then((r) => r.json()),
    ]);
    viem = mod; vaultAbi = abi; cfg = conf.chain;
    chainDef = viem.defineChain({
      id: cfg.chainId, name: cfg.chainName, nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
      rpcUrls: { default: { http: [cfg.rpcUrl] } },
    });
    pub = viem.createPublicClient({ chain: chainDef, transport: viem.http() });
    S.ready = true;

    readyResolve();
    refresh();   // public vault data does not need a wallet
    await restoreWallet();
    if (S.account) await refresh();
    setInterval(() => refresh(), REFRESH_MS);
    document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh(); });
  }

  // Switch (or add) the testnet through the connected wallet, then confirm by re-reading the chain.
  // On a phone the request is answered in the MetaMask app, which the SDK often cannot open by itself once the
  // tap is over (the request is only delivered; the user has to open the app). So the request is sent first thing,
  // inside the tap, a tap-to-open link is published for the UI, and the chain is polled until it matches.
  async function switchNetwork() {
    if (!provider) return { ok: false, error: 'Connect MetaMask first.' };
    const hex = '0x' + cfg.chainId.toString(16);
    let err = null;
    const add = () => provider.request({ method: 'wallet_addEthereumChain', params: [{ chainId: hex, chainName: cfg.chainName, nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 }, rpcUrls: [cfg.rpcUrl], blockExplorerUrls: cfg.explorerUrl ? [cfg.explorerUrl] : undefined }] });
    const ask = provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: hex }] }).catch((e) => {
      if (isRejected(e)) throw e;
      return add();   // chain unknown to the wallet (4902) or answered differently: adding it also switches
    });
    ask.catch((e) => { err = e; });
    if (sdkInst) publishAppLink(sdkInst);
    const readChain = async () => { try { const c = parseInt(await withTimeout(provider.request({ method: 'eth_chainId' }), 4000), 16); S.chainId = c; return c; } catch (e) { return S.chainId; } };
    const done = async () => { S.connectLink = null; await refresh(); };
    let settled = false; ask.then(() => { settled = true; }, () => {});
    for (let i = 0; i < 120; i++) {   // up to ~2 minutes
      if (err) { S.connectLink = null; emit(); const code = err && err.code ? ' (code ' + err.code + ')' : ''; return { ok: false, rejected: isRejected(err), error: isRejected(err) ? 'You rejected the network switch in MetaMask.' : nice(err) + code }; }
      if ((await readChain()) === cfg.chainId) { await done(); return { ok: true }; }
      if (settled && i > 2) { await sleep(800); if ((await readChain()) === cfg.chainId) { await done(); return { ok: true }; } }
      await sleep(1000);
    }
    S.connectLink = null; emit();
    return { ok: false, error: 'No answer from MetaMask. Open the MetaMask app, approve the network request, and come back (or switch to Robinhood Chain Testnet there yourself).' };
  }

  window.CarryChain = { last: snapshot(), connect, switchNetwork, disconnect, refresh, afterTx, leftText, deposit, withdraw, mint, claimFees, needsApp: () => isMobile() && !findMetaMask(), appLink };
  const initP = init();
  initP.catch((e) => { S.error = (e && e.message) || String(e); console.warn('[CarryChain]', (e && (e.shortMessage || e.message)) || e); readyResolve(); emit(); });
})();
