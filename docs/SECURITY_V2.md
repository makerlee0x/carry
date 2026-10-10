# LeveredLpVault v2 — security notes (Robinhood testnet)

Product CA = **UUPS proxy** `0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd`.  
Implementation `0xe8a8406d860aCd8c348377D5342bCAcD5770D84b`.  
Owner / upgrade authority: `0xcA44F2dbB2D43b93b39F01B88E0f0e2966983c57`.

## Clean (verified this deploy)

| Control | Status |
| --- | --- |
| No secrets in git | `.deployer.key`, `.env.carry*`, `contracts/.e2e/` gitignored |
| UUPS `_authorizeUpgrade` | `onlyOwner` |
| Owner = vanity deployer | `0xcA44…` |
| `rescueToken` | Reverts on MSTR/USDG (`PrincipalToken`) |
| Pause | Blocks new deposits; exits/claims/settle still work |
| Reentrancy | `ReentrancyGuardUpgradeable` on value-moving paths |
| Fee-on-transfer | Rejected on pulls |
| Approval race on deposit | Standard ERC-20 approve+deposit; user-controlled amounts |
| Forge suite | 29/29 green including upgrade smoke + $10k sheet waterfall |

## Residual testnet risks (accepted)

1. **MockOracle has `setPrice`** — owner/deployer can move mark for demos. Not a production oracle.
2. **MockERC20 `mint` is open to deployer** — test tokens only; anyone who holds the mint key can inflate demo balances.
3. **Public mempool / MEV** — testnet; no keeper private mempool. Fee donors and settle callers are public.
4. **Boosted** — stake-before-open **flag only**; no STRATEGY yield paid without a funding path.
5. **SellShares cover** — no AMM; MSTR is credited to seniors via accumulator (notional “sale”).
6. **Abandoned proxy** `0x0e4e59…` — first UUPS proxy contaminated by lost E2E keys; do not use. Leave funds alone until term settle or owner decides otherwise.
7. **v1 grant vault** `0x72A0…` — left unchanged; not the product CA.

## Keeper / ops

- Prefer deploy **paused**, sanity-read, then `unpause` for demos.
- `setMorphoRate` / caps / boost flags are owner-only — treat the owner key as hot ops, not a cold multisig yet.
- Future upgrades: owner calls `upgradeToAndCall` on the **same proxy**; product CA does not change.
