export type GuardDecision = {
  allowRemark: boolean;
  safeMode: boolean;
  reasons: string[];
};

/**
 * Dry-run gates only. Live DualPool remark() stays off until the hook exists.
 * Never holds or reads private keys.
 */
export function guardDecision(opts: {
  dryRun: boolean;
  priceAgeMs: number | null;
  staleAfterMs?: number;
  gasGwei?: number | null;
  maxGasGwei?: number;
}): GuardDecision {
  const reasons: string[] = [];
  const staleAfterMs = opts.staleAfterMs ?? 10 * 60_000;
  let safeMode = false;

  if (opts.dryRun) reasons.push('dry-run: no DualPool remark() txs');
  if (opts.priceAgeMs != null && opts.priceAgeMs > staleAfterMs) {
    safeMode = true;
    reasons.push(`reference stale (${Math.round(opts.priceAgeMs / 1000)}s > ${staleAfterMs / 1000}s)`);
  }
  if (opts.gasGwei != null && opts.maxGasGwei != null && opts.gasGwei > opts.maxGasGwei) {
    safeMode = true;
    reasons.push(`gas ${opts.gasGwei} gwei above max ${opts.maxGasGwei}`);
  }

  return {
    allowRemark: false, // skeleton never broadcasts
    safeMode,
    reasons,
  };
}
