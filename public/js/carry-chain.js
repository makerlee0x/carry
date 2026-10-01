/**
 * Carry chain module (viem). Reads the LeveredLpVault on Robinhood Chain Testnet and
 * handles the real MetaMask connection. It does not send transactions: deposits and
 * withdrawals still go through carry-vault.js.
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
  const S = { ready: false, vault: null, account: null, chainId: null, ui: null, error: null };

  const snapshot = () => ({ ready: S.ready, vault: S.vault, account: S.account, chainId: S.chainId, ui: S.ui, error: S.error });
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
    if (!S.account) { S.ui = null; return; }
    const a = S.account;
    const erc = viem.parseAbi(['function balanceOf(address) view returns (uint256)']);
    const rd = (functionName, args) => pub.readContract({ address: cfg.vault, abi: vaultAbi, functionName, args });
    const [eth, mstr, usdg, senior, free, yld, mstrClaim, logs] = await Promise.all([
      pub.getBalance({ address: a }),
      pub.readContract({ address: cfg.mstr, abi: erc, functionName: 'balanceOf', args: [a] }),
      pub.readContract({ address: cfg.usdg, abi: erc, functionName: 'balanceOf', args: [a] }),
      rd('seniorPrincipal', [a]), rd('freePrincipal', [a]),
      rd('seniorClaimableYield', [a]), rd('seniorClaimableMstr', [a]),
      pub.getContractEvents({ address: cfg.vault, abi: vaultAbi, eventName: 'JuniorDeposit', args: { junior: a }, fromBlock: 0n, toBlock: 'latest' }),
    ]);

    const ids = [...new Set(logs.map((l) => l.args.positionId))];
    const raw = await Promise.all(ids.map(async (id) => {
      const [p, matched] = await Promise.all([rd('positions', [id]), rd('isMatched', [id])]);
      return { id, mstr: num(p[1]), senior: num(p[2]), fee: num(p[4]), openedAt: Number(p[5]), settled: p[6], matched };
    }));

    const now = Math.floor(Date.now() / 1000), term = S.vault.termSec, price = S.vault.price;
    const live = raw.filter((r) => !r.settled);
    const positions = [];

    if (live.length) {
      const act = live.filter((r) => r.matched && r.openedAt + term > now);
      const rdy = live.filter((r) => r.matched && r.openedAt + term <= now);
      const opn = live.filter((r) => !r.matched);
      const mstrTotal = live.reduce((x, r) => x + r.mstr, 0), fees = live.reduce((x, r) => x + r.fee, 0);
      let statusTxt, leftTxt, free_, earned = 0, days = 0;
      if (act.length) {
        const soonest = Math.min(...act.map((r) => r.openedAt + term)), first = Math.min(...act.map((r) => r.openedAt));
        statusTxt = 'Active'; free_ = false;
        leftTxt = leftText(soonest - now) + (opn.length || rdy.length ? ` · ${opn.length + rdy.length} other` : '');
        earned = Math.min(4, (4 * (now - first)) / term);
        days = Math.floor((now - first) / 86400);
      } else if (rdy.length) {
        statusTxt = 'Ready to settle'; free_ = true; leftTxt = 'Term ended'; earned = 4;
        days = Math.floor((now - Math.min(...rdy.map((r) => r.openedAt))) / 86400);
      } else {
        statusTxt = 'Open'; free_ = true; leftTxt = 'Waiting for USDG';
      }
      positions.push({ sym: 'MSTR', shares: round(mstrTotal, 4), fees: round(fees, 4), days, earned: round(earned, 2), auto: false, real: true, statusTxt, leftTxt, free: free_, count: live.length });
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

  // ---- Refresh -------------------------------------------------------------
  let busy = null;
  function refresh() {
    if (busy) return busy;
    busy = (async () => {
      try {
        await readVault();
        await readAccount();
        S.error = null;
      } catch (e) {
        S.error = e.shortMessage || e.message || String(e);
      } finally { busy = null; emit(); }
    })();
    return busy;
  }

  // Wait for a transaction to confirm, then refresh the numbers.
  async function afterTx(hash) {
    try { await pub.waitForTransactionReceipt({ hash, timeout: 60000 }); } catch (e) {}
    return refresh();
  }


  // ---- Connect -------------------------------------------------------------
  async function setAccounts(accts) {
    S.account = accts && accts[0] ? viem.getAddress(accts[0]) : null;
    if (provider) S.chainId = parseInt(await provider.request({ method: 'eth_chainId' }), 16);
    await refresh();
  }

  async function connect() {
    try { await initP; } catch (e) {}
    if (!S.ready) return { ok: false, code: 'error', message: 'The blockchain library failed to load. Check your connection and reload.' };
    provider = findMetaMask();
    if (!provider) return { ok: false, code: 'nowallet', message: 'MetaMask not found. Install the MetaMask browser extension and reload.' };
    try {
      const accts = await provider.request({ method: 'eth_requestAccounts' });
      flag(false);
      listen();
      await setAccounts(accts);
      return { ok: true, account: S.account };
    } catch (e) {
      if (e && (e.code === 4001 || /reject|denied/i.test(e.message || ''))) return { ok: false, code: 'rejected', message: 'Connection request was rejected in MetaMask.' };
      return { ok: false, code: 'error', message: (e && e.message) || 'Could not connect.' };
    }
  }

  // A site cannot disconnect MetaMask itself; forget the account locally.
  async function disconnect() {
    flag(true);
    S.account = null; S.ui = null;
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

    provider = findMetaMask();
    if (provider) {
      listen();
      try {
        S.chainId = parseInt(await provider.request({ method: 'eth_chainId' }), 16);
        // Restore an earlier connection without prompting.
        if (!flagged()) {
          const accts = await provider.request({ method: 'eth_accounts' });
          if (accts && accts[0]) S.account = viem.getAddress(accts[0]);
        }
      } catch (e) {}
    }
    await refresh();
    setInterval(refresh, REFRESH_MS);
  }

  window.CarryChain = { last: snapshot(), connect, disconnect, refresh, afterTx, leftText };
  const initP = init();
  initP.catch((e) => { S.error = (e && e.message) || String(e); console.warn('[CarryChain]', e); emit(); });
})();
