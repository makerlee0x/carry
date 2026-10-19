# Security review — Carry v3 lender-pool (testnet)

Scope: `LeveredLpVault` / `LeveredLpVaultV2` at PROXY `0x24B7…3e35`, live impl `0x1473…58A5` (`v3.2-dualpool`, **23,719** B), DualPool + CarryStrategy wired. No API/key material in repo.

## Findings

| ID | Severity | Finding | Status |
| --- | --- | --- | --- |
| S1 | High (mainnet) | Live impl runtime **29602 > 24576** (EIP-170). | **Fixed live** — current impl **23,719** B under EIP-170 |
| S2 | Medium | Fresh PROXY (not in-place UUPS on v2.5). Old capital/#5–#7 stay on superseded PROXY; UI must not mix CAs. | Mitigated; v2.5 settles done |
| S3 | Medium | Testnet sell router is a mock; DualPool uses MockMorphoVault, not Steakhouse. | Accepted testnet residual |
| S4 | Low | Idle Morpho on testnet is MockMorpho via `deployIdle`; real Steakhouse sleeve is issue #20. | Open product (#20) |
| S5 | Low | `freePrincipal` returns share NAV of non-queued shares (includes matched exposure). Instant withdraw still gated by idle + empty queue. | Documented; UI shows free + queued claimable |
| S6 | Info | Upgrade auth: `onlyOwner` `_authorizeUpgrade`. Owner = deployer `0xcA44…3c57`. | OK |
| S7 | Info | Pause blocks new deposits; exits/withdraw/claimWithdraw not pause-gated. | OK |
| S8 | Info | Share inflation: virtual assets/shares offset; round pool-favor. Covered by Forge. | OK |
| S9 | Info | Withdraw queue: cumulative counters + lazy claim; no fulfillment loops. Queue filled before match. | OK |
| S10 | Info | Gas refund only when `matched > 0`, scaled. Proven on-chain. | OK |
| S11 | Info | No secrets in git (`.env*` gitignored). Deploy key local only. | OK |

## Verdict

**No critical/high on live testnet after the v3.2 upgrade.** Residuals: mock Morpho/router, explorer source verify, idle-sleeve productization (#20), superseded v2.5 isolation.

## Evidence anchors

- Forge: **87/87** green (`forge test`)
- Live `version()` = `v3.2-dualpool` (impl `0x1473…58A5`)
- Upgrade + DualPool smoke: `docs/testnet-runs/2026-10-18-v32-upgrade.md`
- Settles: `docs/SETTLE_WATCH.md`
