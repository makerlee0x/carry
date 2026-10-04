import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '../..');

function loadJson(path: string): Record<string, unknown> {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch {
    return {};
  }
}

const mainnet = loadJson(join(root, 'contracts/config/mainnet.json'));
const publicCfg = loadJson(join(root, 'public/config.json'));
const product = (publicCfg.product || {}) as Record<string, unknown>;
const chain = (publicCfg.chain || {}) as Record<string, unknown>;
const ranges = (product.ranges || {}) as Record<string, { halfWidthPct?: number }>;
const recenter = (product.recenter || {}) as Record<string, number>;

export type RangeMode = 'maker' | 'research';

export const cfg = {
  rpcUrl: process.env.CARRY_RPC_URL || String(chain.rpcUrl || 'https://rpc.testnet.chain.robinhood.com'),
  vault: process.env.CARRY_VAULT_ADDRESS || String(chain.vault || ''),
  oracle: process.env.CARRY_ORACLE_ADDRESS || String(chain.oracle || ''),
  hyperliquidInfo: 'https://api.hyperliquid.xyz/info',
  hyperliquidCoin: 'xyz:MSTR',
  rangeMode: (process.env.CARRY_RANGE_MODE as RangeMode) || 'maker',
  makerHalfWidthPct: {
    MSTR: ranges.MSTR?.halfWidthPct ?? 32,
    NVDA: ranges.NVDA?.halfWidthPct ?? 8,
  },
  recenterTermDays: recenter.termDays ?? 7,
  oracleDriftFromCenterPct: recenter.oracleDriftFromCenterPct ?? 80,
  inventoryBandPct: Number(product.inventoryBandPct ?? 5),
  research: (mainnet.ranges as { research?: Record<string, number> } | undefined)?.research || {
    regularMultOfFiveSession: 1,
    overnightMult: 2,
    weekendMult: 3,
    moveTriggerOfHalfWidth: 0.8,
  },
  deadBandBps: (mainnet.fees as { deadBandBps?: Record<string, number> } | undefined)?.deadBandBps || {
    regular: 25,
    pre: 45,
    post: 45,
    overnight: 60,
    weekend: 100,
  },
};
