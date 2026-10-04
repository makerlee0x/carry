/**
 * Carry keeper CLI — dry-run only. No private keys, no DualPool txs.
 *
 *   node --experimental-strip-types src/index.ts --dry-run
 */
import { cfg } from './config.ts';
import { readHyperliquidMid, readOracleMid } from './prices.ts';
import { sessionAt } from './session.ts';
import { planRange } from './ranges.ts';
import { recenterSignal } from './recenter.ts';
import { inventorySignal } from './inventory.ts';
import { guardDecision } from './guard.ts';

function hasFlag(name: string): boolean {
  return process.argv.includes(name);
}

async function main() {
  const dryRun = hasFlag('--dry-run') || !hasFlag('--live');
  if (!dryRun) {
    console.error('Live remark mode is not implemented. Use --dry-run.');
    process.exit(1);
  }

  console.log('[carry-keeper] dry-run start');
  console.log(JSON.stringify({
    rangeMode: cfg.rangeMode,
    rpcUrl: cfg.rpcUrl,
    vault: cfg.vault || null,
    oracle: cfg.oracle || null,
    hlCoin: cfg.hyperliquidCoin,
  }, null, 2));

  const hl = await readHyperliquidMid();
  const oracle = await readOracleMid();
  const session = sessionAt();
  const ref = hl.mid ?? oracle.mid;
  const center = ref ?? 0;
  const range = ref != null ? planRange(ref, session) : planRange(100, session);
  const openedAtMs = Date.now() - 3 * 864e5; // placeholder: 3 days into a 7d term
  const recenter = recenterSignal({
    nowMs: Date.now(),
    openedAtMs,
    refPrice: center || range.center,
    range,
  });
  const inventory = inventorySignal({ vaultMstr: null, juniorShares: null });
  const guard = guardDecision({
    dryRun: true,
    priceAgeMs: hl.mid != null ? 0 : null,
  });

  const report = {
    at: new Date().toISOString(),
    session,
    prices: { hyperliquid: hl, oracle },
    range,
    recenter,
    inventory,
    guard,
    next: guard.allowRemark
      ? 'would call DualPool remark() (not available)'
      : 'log only — no txs; maintainer key later; DualPool hook required for remark',
  };

  console.log(JSON.stringify(report, null, 2));
  console.log('[carry-keeper] dry-run done');
}

main().catch((e) => {
  console.error('[carry-keeper] fatal', e instanceof Error ? e.message : e);
  process.exit(1);
});
