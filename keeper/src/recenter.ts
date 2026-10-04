import { cfg } from './config.ts';
import type { RangePlan } from './ranges.ts';

export type RecenterSignal = {
  shouldRecenter: boolean;
  reasons: string[];
};

/**
 * Maker rules: roll after termDays, or when oracle/reference drifts
 * oracleDriftFromCenterPct of the way from center to the band edge (80% default).
 */
export function recenterSignal(opts: {
  nowMs: number;
  openedAtMs: number | null;
  refPrice: number;
  range: RangePlan;
}): RecenterSignal {
  const reasons: string[] = [];
  const termMs = cfg.recenterTermDays * 864e5;
  if (opts.openedAtMs != null && opts.nowMs - opts.openedAtMs >= termMs) {
    reasons.push(`${cfg.recenterTermDays}d term elapsed`);
  }

  const half = Math.abs(opts.range.high - opts.range.center);
  if (half > 0) {
    const drift = Math.abs(opts.refPrice - opts.range.center);
    const driftPctOfHalf = (drift / half) * 100;
    if (driftPctOfHalf >= cfg.oracleDriftFromCenterPct) {
      reasons.push(
        `ref drift ${driftPctOfHalf.toFixed(1)}% of half-width ≥ ${cfg.oracleDriftFromCenterPct}%`
      );
    }
  }

  return { shouldRecenter: reasons.length > 0, reasons };
}
