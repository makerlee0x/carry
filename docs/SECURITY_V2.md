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
| Treasury / backstop withdraw | Owner-only `withdrawFromBackstop` / `withdrawTreasuryFees`; cannot pull below `totalSeniorPrincipal + remaining backstop`; MSTR untouched |
| Pause | Blocks new deposits; exits/claims/settle still work |
| Reentrancy | `ReentrancyGuardUpgradeable` on value-moving paths |
| Fee-on-transfer | Rejected on pulls |
| Approval race on deposit | Standard ERC-20 approve+deposit; user-controlled amounts |
| Morpho rate | Cap **≤5%**; rate **locked per position** at first match |
| Settle shortfall | Backstop first, then junior Wallet / IdleCarry / SellShares + treasury-on-cover (base 20% / Boosted 10%) |
| Early exit shortfall | Junior only (NO backstop); Wallet/Idle without cover **reverts** (position stays open); SellShares may close |
| Treasury cut | Base **20%**; Boosted MSTR (STRATEGY stake) **10%** on waterfall + cover |
| Senior yield | Time-weighted by deposit time (late seniors do not take full pre-arrival accrual) |
| Open-queue gas | Junior `gasCreditWei` ETH escrow + `matchCap` (default 25); auto-refund on Idle withdraw / settle / early exit |
| Auto-compound | Per-wallet `autoCompound`; exit capital+fees can reopen as Idle |
| SellShares AMM | `sellSharesRouter` interface; testnet stays `address(0)` (MSTR→seniors) |
| Forge suite | Green including Boosted 10%, cover revert, gas auto-refund, compound, AMM stub |

## Upgrade authority — mainnet plan

**Testnet** keeps a hot EOA owner for speed (accepted).

**Mainnet (Robinhood 4663 / any production CA):** do **not** leave upgrade + pause + rate + caps + treasury withdraw on a single EOA.

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
4. **Boosted** — STRATEGY stake-before-open (owner flag and/or `strategyToken` balance). Activates **10%** treasury cut on MSTR market. Creator fee share later; no fake STRATEGY yield minted.
5. **SellShares cover** — testnet: MSTR credited to seniors. Mainnet: set `sellSharesRouter` (`IMstrSellRouter` / Uniswap adapter). See [`SELL_SHARES_AMM.md`](./SELL_SHARES_AMM.md).
6. **Abandoned proxy** `0x0e4e59…` — first UUPS proxy contaminated by lost E2E keys; do not use. Leave funds alone until term settle or owner decides otherwise.
7. **v1 grant vault** `0x72A0…` — left unchanged; not the product CA.
8. **Time-weighted yield dust** — integer math rounds senior credits down; dust USDG/MSTR can remain in the vault (cannot overpay seniors).
9. **Open-queue gas** — junior on-chain `gasCredit` shipped (see [`GAS_CREDIT.md`](./GAS_CREDIT.md)). Off-chain idle DB not used.

## Keeper / ops

- Prefer deploy **paused**, sanity-read, then `unpause` for demos.
- `setMorphoRate` / caps / boost flags / `matchCap` / treasury withdraw are owner-only — treat the owner key as hot ops on testnet.
- Future upgrades: owner calls `upgradeToAndCall` on the **same proxy**; product CA does not change.
- Script: `contracts/script/UpgradeCarryVault.s.sol` (disarmed by default).
