# Vault v2 delta (spec only — no deploy)

Diff of current testnet [`LeveredLpVault`](../contracts/src/LeveredLpVault.sol) vs research
**Carry Vault v2 / option B** (Pool v1 Build Plan + Keeper Research, 2 Oct 2026).
Keeps the Maker conversation concrete without coding DualPool.

**Fee product truth** is now Maker’s Morpho-rate waterfall at claim/exit/settle only —
see [`MAKER_FEE_WATERFALL.md`](./MAKER_FEE_WATERFALL.md). Rows below that still say
“4% early-exit floor” or “20% cut on fee-in” describe **legacy live bytecode** or older
research wording; do not treat them as the current product split.

Frontend can keep the same function names (`depositJunior`, `depositSenior`,
`withdrawUnmatched`, `earlyExit`, `settle`, `withdrawSenior`) where possible.

---

## What stays

| Item | Current vault | V2 |
| --- | --- | --- |
| 7-day term | Yes (`term` immutable, ≤ 7d) | Yes |
| 4% early-exit floor | `EARLY_EXIT_APR_WAD = 4%` | Yes (claim path also uses 4% pace) |
| 20% protocol cut | `protocolCutWad` → backstop | Same cut → **treasury** |
| Junior / senior roles | MSTR junior, USDG senior | Same |
| Pause deposits | Owner pause/unpause | Safe pause (emergency) |

---

## What changes (option B)

| Topic | Current `LeveredLpVault` | Vault v2 |
| --- | --- | --- |
| Pool path | Inventory stays in vault; `joinPool` reverts; DualPool adapter unset | On match: `hook.addLiquidity`; on exit: `removeLiquidity` into DualPool |
| Morpho | None | Matched USDG in Steakhouse USDG (Morpho ERC-4626) between swaps |
| Senior yield | Fixed `borrowAprWad` (≤5%) maturity fee | **Floor = Morpho rate (~3.9%)** + target (12%) from surplus |
| Junior yield | Leftover MSTR + leftover USDG fees | **Floor = deposited shares**; target ~5% **paid in shares** |
| Payout order | Can sell junior MSTR to make senior whole (early exit / settle waterfall) | (1) junior shares floor (2) senior principal + Morpho floor (3) junior target (4) senior target (5) surplus → treasury. **No junior-sold-for-senior** |
| Backstop vs treasury | `backstop` funded by protocol cut | Named **treasury**; seed ≥10% of cap; TVL cap ≤ 10× treasury; pause deposits if treasury &lt; 5% of book |
| Caps | None on-chain | `maxTotalJuniorUsd`, `maxTotalSeniorUsd`, `maxPerWalletUsd` (Safe-set; launch $0 then ~$25k / $2.5k) |
| Settlement price | Live oracle `mstrPriceWad()` | Latest keeper-posted reference; settle never reverts on stale |
| Fee claim | Only via `earlyExit` / `settle` (closes position) | Claim accrued fees at 4% threshold **without** full close (+ claim fee) |
| Recenter / ranges | N/A on-chain | Keeper `remark()` + session ranges (Maker UI ±32%/±8% until he picks research bands) |

---

## Explicit non-goals for this doc

- No DualPool / hook deploy on testnet 46630
- No Vault v2 bytecode in this commit
- No mainnet 4663 addresses
- No change to live testnet vault address until a separate redeploy is broadcast

When implementing pieces on the current vault (caps, Morpho-floor placeholder,
`claimFees`), prefer additive owner-settable params and document any redeploy in
[`CARRY_TESTNET.md`](../CARRY_TESTNET.md).
