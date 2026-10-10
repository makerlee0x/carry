# LeveredLpVault v2 — security notes (Robinhood testnet)

Product CA = **UUPS proxy** `0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd`.  
Owner / upgrade authority (testnet): `0xcA44F2dbB2D43b93b39F01B88E0f0e2966983c57` (EOA).  
Implementation address: see `chain.vaultImplementation` in [`public/config.json`](../public/config.json).

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
| Morpho rate | Cap **≤5%**; rate **locked per position** at first match |
| Settle | Does **not** sell junior MSTR; shortfall from treasury/backstop only |
| Forge suite | Green including unpaid-accrual 1-wei case, settle no-sell, rate lock |

## Upgrade authority — mainnet plan

**Testnet** keeps a hot EOA owner for speed (accepted).

**Mainnet (Robinhood 4663 / any production CA):** do **not** leave upgrade + pause + rate + caps on a single EOA.

Recommended:

1. **Owner = multisig** (2-of-3 or 3-of-5; ops + Maker + independent).
2. **Timelock** in front of `upgradeToAndCall` (e.g. 24–72h) so bytecode changes are public before they land.
3. Optional: separate **guardian** for `pause()` only (faster than timelock), still multisig.
4. Document signer set + recovery; never reuse the testnet vanity key.

No need to migrate testnet ownership unless it is cheap and Maker wants the rehearsal.

## Residual testnet risks (accepted)

1. **MockOracle has `setPrice`** — owner/deployer can move mark for demos. Not a production oracle.
2. **MockERC20 `mint` is open to deployer** — test tokens only; anyone who holds the mint key can inflate demo balances.
3. **Public mempool / MEV** — testnet; no keeper private mempool. Fee donors and settle callers are public.
4. **Boosted** — stake-before-open **flag only**; no STRATEGY yield paid without a funding path.
5. **SellShares cover (early exit only)** — no AMM; MSTR is credited to seniors via accumulator (notional “sale”). Settle does not sell shares. If junior leftover fees cannot cover treasury’s 20% of the cover amount, the unpaid treasury slice is also settled as extra MSTR to seniors (testnet OK; no AMM to realize USDG for treasury).
6. **Abandoned proxy** `0x0e4e59…` — first UUPS proxy contaminated by lost E2E keys; do not use. Leave funds alone until term settle or owner decides otherwise.
7. **v1 grant vault** `0x72A0…` — left unchanged; not the product CA.
8. **Treasury / backstop withdraw** — **intended for testnet:** cuts stay in `backstop` to fund settle shortfalls. No owner `withdrawTreasury` / `withdrawBackstop`. Mainnet may add a multisig-gated withdraw later.
9. **Open-queue gas** — FIFO walk on senior deposit; large idle queues can be costly. Accepted for v1; keeper batching / queue caps later if needed.
10. **Late senior deposits** — yield uses a global `accYieldPerPrincipal` accumulator, so a senior who deposits right before a claim/settle can share yield that accrued earlier. **Accepted for v1.**

## Keeper / ops

- Prefer deploy **paused**, sanity-read, then `unpause` for demos.
- `setMorphoRate` / caps / boost flags are owner-only — treat the owner key as hot ops on testnet.
- Future upgrades: owner calls `upgradeToAndCall` on the **same proxy**; product CA does not change.
- Script: `contracts/script/UpgradeCarryVault.s.sol` (disarmed by default).
