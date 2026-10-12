# Security review — Carry v3 lender-pool (testnet)

Scope: `LeveredLpVault` / `LeveredLpVaultV2` at PROXY `0x24B7…3e35`, impl `0x7BeE…778E`, plus deploy auth, pause/exits, share math, withdraw queue, cover order, gas credit, caps. No API/key material in repo.

## Findings

| ID | Severity | Finding | Status |
| --- | --- | --- | --- |
| S1 | High (mainnet) | Impl runtime **29602 > 24576** (EIP-170). Deployed on testnet only via `--disable-code-size-limit`. | **Open** — NOT DONE for mainnet path |
| S2 | Medium | Fresh PROXY (not in-place UUPS on v2.5). Old capital/#5–#7 stay on superseded PROXY; UI must not mix CAs. | Mitigated by config + docs |
| S3 | Medium | Testnet sell-shares without router credits pool NAV from MSTR burn notionally; no real AMM USDG. Residual feeShortfall possible. | Accepted testnet residual |
| S4 | Low | Idle Morpho yield display-only (no on-chain credit). | By design (Maker) |
| S5 | Low | `freePrincipal` returns share NAV of non-queued shares (includes matched exposure). Instant withdraw still gated by idle + empty queue. | Documented; UI shows free + queued claimable |
| S6 | Info | Upgrade auth: `onlyOwner` `_authorizeUpgrade`. Owner = deployer `0xcA44…3c57`. | OK |
| S7 | Info | Pause blocks new deposits; exits/withdraw/claimWithdraw not pause-gated. | OK |
| S8 | Info | Share inflation: virtual assets/shares offset; round pool-favor. Covered by Forge. | OK |
| S9 | Info | Withdraw queue: cumulative counters + lazy claim; no fulfillment loops. Queue filled before match. | OK |
| S10 | Info | Gas refund only when `matched > 0`, scaled. Proven on-chain. | OK |
| S11 | Info | No secrets in git (`.env*` gitignored). Deploy key local only. | OK |

## Verdict

**No critical/high in shipped testnet surface except S1 size for mainnet.** Testnet residual risks: oversized bytecode, stub sell-shares, Morpho display-only, superseded v2.5 capital isolation.

## Evidence anchors

- Forge: 27/27 green (`forge test`)
- Live `version()` = `v3-lender-pool` (cast after deploy)
- On-chain multi-wallet: `/tmp/carry_v3_onchain_results.txt` + `scripts/run_v3_onchain.sh`
