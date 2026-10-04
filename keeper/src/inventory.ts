import { cfg } from './config.ts';

export type InventorySignal = {
  bandPct: number;
  vaultMstr: number | null;
  juniorShares: number | null;
  gapPct: number | null;
  outsideBand: boolean;
  action: 'ok' | 'lean-buy-mstr' | 'lean-sell-mstr' | 'unknown';
  note: string;
};

/** Target: vault MSTR ≈ junior share count; lean quote if gap > inventoryBandPct. */
export function inventorySignal(opts: {
  vaultMstr: number | null;
  juniorShares: number | null;
}): InventorySignal {
  const bandPct = cfg.inventoryBandPct;
  if (opts.vaultMstr == null || opts.juniorShares == null || opts.juniorShares <= 0) {
    return {
      bandPct,
      vaultMstr: opts.vaultMstr,
      juniorShares: opts.juniorShares,
      gapPct: null,
      outsideBand: false,
      action: 'unknown',
      note: 'need vault MSTR and junior shares (dry-run placeholder)',
    };
  }
  const gapPct = ((opts.vaultMstr - opts.juniorShares) / opts.juniorShares) * 100;
  const outsideBand = Math.abs(gapPct) > bandPct;
  let action: InventorySignal['action'] = 'ok';
  if (outsideBand) action = gapPct > 0 ? 'lean-sell-mstr' : 'lean-buy-mstr';
  return {
    bandPct,
    vaultMstr: opts.vaultMstr,
    juniorShares: opts.juniorShares,
    gapPct,
    outsideBand,
    action,
    note: outsideBand
      ? `gap ${gapPct.toFixed(2)}% outside ±${bandPct}% band → ${action}`
      : `gap ${gapPct.toFixed(2)}% inside ±${bandPct}% band`,
  };
}
