# Contract testing

`contracts/test/` has two layers:

| Layer | Files | What it checks |
| --- | --- | --- |
| Unit | `LeveredLpVault.t.sol`, `DeployScripts.t.sol` | One function / rule at a time |
| Integration | `integration/Lifecycle.t.sol` | Full multi-wallet lifecycles through the UUPS proxy (7-day term, prod caps), checking the books after every step |
| Invariants | `integration/Invariants.t.sol` + `CarryHandler.sol` | Random sequences of lend / stake / fees / claim / early exit / settle / queue / time jumps |

## The books (`integration/CarryBase.sol`)

Must hold after every state change:

1. **Solvency:** vault USDG ≥ `totalSeniorAssets + backstop + totalUnsplitFees`.
2. **No stranded USDG:** the surplus over that is dust. USDG nobody is owed means a credit was dropped.
3. **MSTR:** vault MSTR == sum of open positions' `mstrAmount`.
4. `reservedSenior` == sum of open `seniorPrincipal`.
5. `totalShares` == sum of holder shares.
6. Queue fulfilled ≤ requested; `queueClaimable` ≤ pool.

Plus `invariant_lenderPrincipalNeverLost`: pool value + lender withdrawals ≥ lender deposits.

## Running

```bash
npm run test:contracts                              # same as the git hooks
cd contracts && FOUNDRY_PROFILE=ci forge test       # deeper fuzz, same as GitHub Actions
```

## Gates

- `.githooks/pre-commit`: runs the suite when staged files touch `contracts/`.
- `.githooks/pre-push`: `npm run check` plus the suite when pushed commits touch `contracts/`.
- Hooks are active once `npm install` runs (sets `core.hooksPath=.githooks`), or run `git config core.hooksPath .githooks`.
- `.github/workflows/contracts.yml`: runs on every push to `main` and every PR. Hooks can be skipped with `--no-verify`; CI can't. Make it a required check under branch protection.

## Known failing tests (v3 review, Oct 2026)

These fail on `v3-lender-pool` by design until the vault is fixed:

| Test | Bug |
| --- | --- |
| `test_settle_juniorWalletCover_isCreditedToLenders` | Settle cover the junior pays is never credited to the lender pool (`_applySettleCover`) |
| `test_settle_juniorIdleCover_isCreditedToLenders` | Same, idle-balance path |
| `test_settle_poolLastResort_doesNotCostLenderPrincipal` | Pool last resort cuts lender principal to pay lender interest |
| `test_abandonedPosition_canBeClosedAfterGrace` | Only the junior can settle a matured shortfall position; lender capital can be locked forever |
| `test_sellShares_noRouter_doesNotCreateFakeUsdg` | Testnet sell-shares stub credits the pool with USDG that doesn't exist (S3) |
| `invariant_books`, `invariant_lenderPrincipalNeverLost` | Fuzzer finds the first three independently |

When adding a feature, add a lifecycle scenario for it and, if it moves money, a handler action.
