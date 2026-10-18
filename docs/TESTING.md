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

## Bug and product-rule tests

These pinned bugs from the v3 review and Maker's Oct 13 decisions. All pass since #3 (settle cover, pool last resort, sell-shares router, EIP-170) and the rules PR (auto-roll, underwater grace, queued withdraw value):

| Test | Rule it enforces |
| --- | --- |
| `test_settle_juniorWalletCover_isCreditedToLenders`, `test_settle_juniorIdleCover_isCreditedToLenders` | Cover the junior pays at settle goes to the lender pool, never stranded |
| `test_settle_poolLastResort_doesNotCostLenderPrincipal` | An uncoverable interest shortfall is **forgiven**; lender principal never pays it |
| `test_healthyPosition_autoRollsAtTerm` | Positions **auto-roll at term**: no hard maturity, stays matched, junior can keep claiming |
| `test_healthyRolledPosition_othersCannotSettle` | Only the junior closes a healthy rolled position |
| `test_underwater_onlyJuniorSettlesDuringGrace` | Below entry by more than the market range (MSTR −32%), the position stops rolling; inside the **48h grace** only the junior can settle |
| `test_underwater_carryCanSettleAfterGrace`, `test_underwater_lenderCanSettleAfterGrace` | After the grace anyone (junior, senior, Carry) can settle |
| `test_queuedWithdraw_paysValueAtPayout_notRequestTime` | A queued withdraw pays what the shares are worth **when paid**, not a USDG amount fixed at request time |
| `test_sellShares_noRouter_reverts` | Sell-shares with no router reverts instead of crediting USDG that doesn't exist |
| `invariant_books`, `invariant_lenderPrincipalNeverLost` | The fuzzer checks the books and lender principal across random sequences |
| `Eip170.t.sol: test_implFitsEip170` | Impl runtime ≤ 24,576 bytes (EIP-170) |

The tests use the current ABI. If the fix changes an entry point (for example a share-based `redeem` for the queue, or a per-market underwater threshold), update the test in the same PR and keep the rule it checks.

When adding a feature, add a lifecycle scenario for it and, if it moves money, a handler action.
