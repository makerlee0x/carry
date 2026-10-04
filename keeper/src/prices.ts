import { cfg } from './config.ts';

export type PriceSnapshot = {
  source: 'hyperliquid' | 'oracle' | 'none';
  mid: number | null;
  at: number;
  note?: string;
};

/** Hyperliquid info API mid for xyz:MSTR (no websocket required for dry-run). */
export async function readHyperliquidMid(coin = cfg.hyperliquidCoin): Promise<PriceSnapshot> {
  const at = Date.now();
  try {
    // Stock perps live on the xyz dex; default allMids is the crypto book only.
    const res = await fetch(cfg.hyperliquidInfo, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ type: 'allMids', dex: 'xyz' }),
    });
    if (!res.ok) return { source: 'none', mid: null, at, note: `HL HTTP ${res.status}` };
    const mids = (await res.json()) as Record<string, string>;
    const raw = mids[coin] ?? mids['xyz:MSTR'] ?? mids['MSTR'];
    const mid = raw != null ? Number(raw) : NaN;
    if (!Number.isFinite(mid)) return { source: 'none', mid: null, at, note: `no mid for ${coin}` };
    return { source: 'hyperliquid', mid, at };
  } catch (e) {
    return { source: 'none', mid: null, at, note: e instanceof Error ? e.message : String(e) };
  }
}

/** Optional public oracle read (eth_call). No wallet, no keys. */
export async function readOracleMid(): Promise<PriceSnapshot> {
  const at = Date.now();
  if (!cfg.oracle) return { source: 'none', mid: null, at, note: 'no oracle address' };
  try {
    // cast sig "mstrPriceWad()"
    const data = '0x3220f7bb';
    const res = await fetch(cfg.rpcUrl, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        jsonrpc: '2.0',
        id: 1,
        method: 'eth_call',
        params: [{ to: cfg.oracle, data }, 'latest'],
      }),
    });
    const json = (await res.json()) as { result?: string; error?: { message: string } };
    if (json.error || !json.result || json.result === '0x') {
      return { source: 'none', mid: null, at, note: json.error?.message || 'empty oracle result' };
    }
    const wad = Number(BigInt(json.result)) / 1e18;
    return { source: 'oracle', mid: wad, at };
  } catch (e) {
    return { source: 'none', mid: null, at, note: e instanceof Error ? e.message : String(e) };
  }
}
