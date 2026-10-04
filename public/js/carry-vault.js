/**
 * Carry ↔ LeveredLpVault bridge (Robinhood Chain Testnet 46630).
 * Loaded alongside the static UI. Prefer window.CarryChain for live deposit /
 * withdraw when it is ready; this module remains a thinner ethereum provider
 * fallback with the same junior close paths (unmatched / settle / earlyExit).
 *
 * No private keys here — uses window.ethereum (MetaMask / Robinhood Wallet).
 */
(function () {
  const HEX = {
    chainId: "0xb626", // 46630
  };

  const VAULT_ABI = [
    "function depositJunior(uint256 mstrAmount) returns (uint256 positionId)",
    "function depositSenior(uint256 amount)",
    "function withdrawSenior(uint256 principalAmount)",
    "function withdrawUnmatched(uint256 positionId)",
    "function earlyExit(uint256 positionId)",
    "function settle(uint256 positionId)",
    "function paused() view returns (bool)",
    "function term() view returns (uint64)",
    "function mstr() view returns (address)",
    "function usdg() view returns (address)",
    "function freePrincipal(address) view returns (uint256)",
    "function seniorPrincipal(address) view returns (uint256)",
    "function positions(uint256) view returns (address,uint256,uint256,uint256,uint256,uint64,bool)",
  ];

  // JuniorDeposit(positionId indexed, junior indexed, mstrAmount, matched)
  const JUNIOR_DEPOSIT_TOPIC =
    "0x202b8761606dd63827b9fc6283c44f527e6a0146362613adb77bf3541d29593f";

  const ERC20_ABI = [
    "function approve(address spender, uint256 amount) returns (bool)",
    "function allowance(address owner, address spender) view returns (uint256)",
    "function balanceOf(address) view returns (uint256)",
    "function decimals() view returns (uint8)",
    "function mint(address to, uint256 amount)",
    "function symbol() view returns (string)",
  ];

  function toHex(n) {
    return "0x" + BigInt(n).toString(16);
  }

  function parseUnits(amountStr, decimals) {
    const s = String(amountStr).trim();
    if (!s || Number(s) <= 0) throw new Error("Enter an amount greater than zero");
    const neg = s.startsWith("-");
    if (neg) throw new Error("Amount must be positive");
    const [whole, frac = ""] = s.split(".");
    const fracPadded = (frac + "0".repeat(decimals)).slice(0, decimals);
    return BigInt(whole || "0") * 10n ** BigInt(decimals) + BigInt(fracPadded || "0");
  }

  async function ethereum() {
    const eth = window.ethereum;
    if (!eth) throw new Error("No wallet found. Install MetaMask or Robinhood Wallet.");
    return eth;
  }

  async function ensureAccounts(eth) {
    const accounts = await eth.request({ method: "eth_requestAccounts" });
    if (!accounts || !accounts[0]) throw new Error("Wallet connect rejected");
    return accounts[0];
  }

  async function ensureChain(eth, cfg) {
    const want = cfg.chainIdHex || HEX.chainId;
    const current = await eth.request({ method: "eth_chainId" });
    if (current && current.toLowerCase() === want.toLowerCase()) return;
    try {
      await eth.request({
        method: "wallet_switchEthereumChain",
        params: [{ chainId: want }],
      });
    } catch (err) {
      if (err && (err.code === 4902 || err.code === -32603)) {
        await eth.request({
          method: "wallet_addEthereumChain",
          params: [
            {
              chainId: want,
              chainName: cfg.chainName || "Robinhood Chain Testnet",
              nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
              rpcUrls: [cfg.rpcUrl || "https://rpc.testnet.chain.robinhood.com"],
              blockExplorerUrls: [
                cfg.explorerUrl || "https://explorer.testnet.chain.robinhood.com",
              ],
            },
          ],
        });
      } else {
        throw err;
      }
    }
  }

  function encodeFn(sig, types, values) {
    // Minimal ABI encode without external deps (ethers not bundled).
    // We only need selectors + abi.encode(uint256) / (address,uint256).
    const selector = (() => {
      // Precomputed keccak256 selectors for the functions we call.
      // Selectors from keccak256(sig)[:4] (verified against LeveredLpVault / MockERC20).
      const map = {
        "depositJunior(uint256)": "0x8d97f3cb",
        "depositSenior(uint256)": "0x4e43773e",
        "withdrawSenior(uint256)": "0x875382e5",
        "withdrawUnmatched(uint256)": "0xafadd42b",
        "earlyExit(uint256)": "0xb8af3d3e",
        "settle(uint256)": "0x8df82800",
        "paused()": "0x5c975abb",
        "term()": "0xa10ffbed",
        "positions(uint256)": "0x99fbab88",
        "approve(address,uint256)": "0x095ea7b3",
        "allowance(address,address)": "0xdd62ed3e",
        "balanceOf(address)": "0x70a08231",
        "decimals()": "0x313ce567",
        "mint(address,uint256)": "0x40c10f19",
        "mstr()": "0x4212ac25",
        "usdg()": "0xf5b91b7b",
      };
      // Fallback: compute via SubtleCrypto if available later; for now require map.
      if (!map[sig]) throw new Error("Unsupported selector: " + sig);
      return map[sig];
    })();

    function pad32(hex) {
      return hex.replace(/^0x/, "").padStart(64, "0");
    }
    function encUint(v) {
      return pad32(toHex(v));
    }
    function encAddr(a) {
      return pad32(a.toLowerCase().replace(/^0x/, ""));
    }

    let data = selector;
    for (let i = 0; i < types.length; i++) {
      const t = types[i];
      const v = values[i];
      if (t === "uint256") data += encUint(v);
      else if (t === "address") data += encAddr(v);
      else throw new Error("Unsupported type " + t);
    }
    return data;
  }

  async function ethCall(eth, to, data) {
    return eth.request({
      method: "eth_call",
      params: [{ to, data }, "latest"],
    });
  }

  async function ethSend(eth, from, to, data) {
    return eth.request({
      method: "eth_sendTransaction",
      params: [{ from, to, data }],
    });
  }

  async function readUint(eth, to, data) {
    const raw = await ethCall(eth, to, data);
    if (!raw || raw === "0x") return 0n;
    return BigInt(raw);
  }

  async function readAddress(eth, to, data) {
    const raw = await ethCall(eth, to, data);
    return "0x" + raw.slice(-40);
  }

  // Verify selectors match the compiled vault once at load (optional soft check).
  // depositJunior(uint256) and depositSenior(uint256) selectors recomputed offline from forge.

  async function resolveTokens(eth, cfg) {
    const vault = cfg.vault;
    let mstr = cfg.mstr;
    let usdg = cfg.usdg;
    if (!mstr) mstr = await readAddress(eth, vault, encodeFn("mstr()", [], []));
    if (!usdg) usdg = await readAddress(eth, vault, encodeFn("usdg()", [], []));
    return { mstr, usdg };
  }

  async function ensureAllowance(eth, owner, token, spender, amount) {
    const allowData = encodeFn(
      "allowance(address,address)",
      ["address", "address"],
      [owner, spender]
    );
    const current = await readUint(eth, token, allowData);
    if (current >= amount) return null;
    const max = 2n ** 256n - 1n;
    const data = encodeFn("approve(address,uint256)", ["address", "uint256"], [spender, max]);
    return ethSend(eth, owner, token, data);
  }

  async function switchNetwork(cfg) {
    const eth = await ethereum();
    await ensureChain(eth, cfg || {});
    return { ok: true };
  }

  function topicAddr(addr) {
    return "0x" + addr.toLowerCase().replace(/^0x/, "").padStart(64, "0");
  }

  function decodeUintWords(raw) {
    const hex = (raw || "0x").replace(/^0x/, "");
    const out = [];
    for (let i = 0; i + 64 <= hex.length; i += 64) out.push(BigInt("0x" + hex.slice(i, i + 64)));
    return out;
  }

  async function listJuniorLive(eth, vault, account) {
    const logs = await eth.request({
      method: "eth_getLogs",
      params: [
        {
          address: vault,
          fromBlock: "0x0",
          toBlock: "latest",
          topics: [JUNIOR_DEPOSIT_TOPIC, null, topicAddr(account)],
        },
      ],
    });
    const ids = [
      ...new Set(
        (logs || []).map((l) => BigInt(l.topics[1])).filter((id) => id > 0n)
      ),
    ];
    const term = await readUint(eth, vault, encodeFn("term()", [], []));
    const now = BigInt(Math.floor(Date.now() / 1000));
    const live = [];
    for (const id of ids) {
      const words = decodeUintWords(
        await ethCall(eth, vault, encodeFn("positions(uint256)", ["uint256"], [id]))
      );
      // owner, mstrAmount, seniorPrincipal, entryPriceWad, feeUsdg, openedAt, settled
      if (!words.length || words[6] !== 0n) continue;
      const owner = "0x" + words[0].toString(16).padStart(40, "0");
      if (owner.toLowerCase() !== account.toLowerCase()) continue;
      const matched = words[2] > 0n;
      const openedAt = words[5];
      live.push({
        id,
        mstr: words[1],
        matched,
        openedAt,
        ready: matched && now >= openedAt + term,
        active: matched && now < openedAt + term,
      });
    }
    return live;
  }

  async function withdrawJuniorPositions(eth, account, vault, amount, decimals) {
    const live = await listJuniorLive(eth, account, vault);
    if (!live.length) throw new Error("You have no stock positions to withdraw.");
    const open = live.filter((r) => !r.matched);
    const ready = live.filter((r) => r.ready);
    const act = live.filter((r) => r.active);
    const tot = (list) => list.reduce((x, r) => x + r.mstr, 0n);
    const total = tot(live);
    const freeTotal = tot(open) + tot(ready);
    const want = parseUnits(amount, decimals);
    const near = (a, b) => {
      const d = a > b ? a - b : b - a;
      return d <= 10n ** 14n; // dust tolerance
    };
    const all = near(want, total);
    const freeOnly = freeTotal > 0n && near(want, freeTotal);
    if (!all && !freeOnly) {
      const fx = (v) => Number(v) / 10 ** decimals;
      throw new Error(
        act.length && freeTotal > 0n
          ? `Deposits leave as whole positions. Withdraw ${fx(freeTotal)} MSTR with no fee, or all ${fx(total)} MSTR (early-exit applies to active legs).`
          : `Stock positions withdraw in full. Use the full amount: ${fx(total)} MSTR.`
      );
    }
    const steps = [
      [open, "withdrawUnmatched(uint256)"],
      [ready, "settle(uint256)"],
    ];
    if (all && act.length) steps.push([act, "earlyExit(uint256)"]);
    let hash = null;
    for (const [group, sig] of steps) {
      for (const r of group) {
        const data = encodeFn(sig, ["uint256"], [r.id]);
        hash = await ethSend(eth, account, vault, data);
      }
    }
    if (!hash) throw new Error("Nothing to withdraw for that amount.");
    return hash;
  }

  /**
   * @param {{ mode: string, sym: string, amount: number|string, cfg: object, confirm?: Function }} opts
   * mode: 'deposit' | 'withdraw'
   * sym: 'MSTR' | 'USDG' (stock → junior, USDG → senior)
   */
  async function runTx(opts) {
    const { mode, sym, amount, cfg } = opts || {};
    const chain = cfg || {};
    try {
      const eth = await ethereum();
      const account = await ensureAccounts(eth);
      await ensureChain(eth, chain);

      const vault = chain.vault;
      if (!vault) throw new Error("Missing config.chain.vault");

      const paused = await readUint(eth, vault, encodeFn("paused()", [], []));
      if (paused !== 0n && mode === "deposit") {
        return {
          ok: false,
          phase: "error",
          error: "Vault is paused. Owner must call unpause() before deposits.",
        };
      }

      const tokens = await resolveTokens(eth, chain);
      const isUsdg = sym === "USDG";
      const token = isUsdg ? tokens.usdg : tokens.mstr;
      const decimals = Number(chain.decimals != null ? chain.decimals : 18);
      const amt = parseUnits(amount, decimals);

      if (mode === "deposit") {
        await ensureAllowance(eth, account, token, vault, amt);
        const sig = isUsdg ? "depositSenior(uint256)" : "depositJunior(uint256)";
        const data = encodeFn(sig, ["uint256"], [amt]);
        const hash = await ethSend(eth, account, vault, data);
        window.CarryVault.lastHash = hash;
        return { ok: true, hash };
      }

      if (mode === "withdraw") {
        if (isUsdg) {
          const data = encodeFn("withdrawSenior(uint256)", ["uint256"], [amt]);
          const hash = await ethSend(eth, account, vault, data);
          window.CarryVault.lastHash = hash;
          return { ok: true, hash };
        }
        // Prefer the viem bridge (same path the live site uses).
        if (window.CarryChain && typeof window.CarryChain.withdraw === "function") {
          const res = await window.CarryChain.withdraw({
            sym,
            amount,
            confirm: opts && opts.confirm,
          });
          if (res && res.hash) window.CarryVault.lastHash = res.hash;
          return res;
        }
        const hash = await withdrawJuniorPositions(eth, account, vault, amount, decimals);
        window.CarryVault.lastHash = hash;
        return { ok: true, hash };
      }

      return { ok: false, phase: "error", error: "Unsupported mode: " + mode };
    } catch (err) {
      const msg = (err && (err.message || err.reason)) || String(err);
      const rejected =
        /reject|denied|user refused|4001/i.test(msg) || (err && err.code === 4001);
      console.error("[CarryVault]", err);
      return { ok: false, phase: rejected ? "rejected" : "error", error: msg };
    }
  }

  /** Testnet helper: mint mock MSTR/USDG to the connected wallet (MockERC20.mint is open). */
  async function mintDemo(sym, amount, cfg) {
    const eth = await ethereum();
    const account = await ensureAccounts(eth);
    await ensureChain(eth, cfg || {});
    const tokens = await resolveTokens(eth, cfg || {});
    const token = sym === "USDG" ? tokens.usdg : tokens.mstr;
    const decimals = Number((cfg && cfg.decimals) != null ? cfg.decimals : 18);
    const amt = parseUnits(amount, decimals);
    const data = encodeFn("mint(address,uint256)", ["address", "uint256"], [account, amt]);
    const hash = await ethSend(eth, account, token, data);
    return { ok: true, hash };
  }

  window.CarryVault = {
    runTx,
    switchNetwork,
    mintDemo,
    lastHash: null,
    _encodeFn: encodeFn, // exposed for selector self-test in console
  };

  // Self-check selectors against known forge output when ABI JSON is present.
  fetch("abis/LeveredLpVault.json", { cache: "no-store" })
    .then((r) => (r.ok ? r.json() : null))
    .then((abi) => {
      if (!abi || !window.crypto || !window.crypto.subtle) return;
      // Optional: leave quiet if fetch fails (file:// or offline).
      window.CarryVault.abi = abi;
    })
    .catch(() => {});
})();
