import { cfg } from './config.ts';
import type { Session } from './session.ts';

export type RangePlan = {
  mode: 'maker' | 'research';
  halfWidthPct: number;
  center: number;
  low: number;
  high: number;
  note: string;
};

/** Maker UI bands by default; research session multipliers available via CARRY_RANGE_MODE=research. */
export function planRange(center: number, session: Session, fiveSessionMovePct = 10): RangePlan {
  if (cfg.rangeMode === 'research') {
    const base = fiveSessionMovePct * (cfg.research.regularMultOfFiveSession ?? 1);
    const mult =
      session === 'weekend' ? cfg.research.weekendMult ?? 3
        : session === 'overnight' ? cfg.research.overnightMult ?? 2
          : 1;
    const halfWidthPct = base * Number(mult);
    return {
      mode: 'research',
      halfWidthPct,
      center,
      low: center * (1 - halfWidthPct / 100),
      high: center * (1 + halfWidthPct / 100),
      note: `research ±${halfWidthPct.toFixed(1)}% (${session})`,
    };
  }

  const halfWidthPct = cfg.makerHalfWidthPct.MSTR;
  return {
    mode: 'maker',
    halfWidthPct,
    center,
    low: center * (1 - halfWidthPct / 100),
    high: center * (1 + halfWidthPct / 100),
    note: `maker MSTR ±${halfWidthPct}% (not user-set)`,
  };
}
