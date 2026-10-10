# Junior gas credit (on-chain)

Maker pick (Oct 10, 2026): **junior fronts gas for senior deposit**, even when the
deposit leaves the junior unmatched / only partially matched. No off-chain DB path.

## How it works

| Piece | Behavior |
| --- | --- |
| `fundGasCredit()` | Junior sends ETH; credited to `gasCreditWei[junior]` |
| `withdrawGasCredit(amount)` | Junior pulls unused ETH back |
| `gasRefundWei` | Owner-set wei paid to senior per `depositSenior` (default `0.0001 ether`) |
| Sponsor | Open-queue head junior (`openHead`) at the start of `depositSenior` |
| Consume | After match attempt, vault pays `min(gasRefundWei, credit)` ETH to the senior |

If there is no open-queue junior, or that junior has zero credit, the senior pays their own gas (no refund).

## UX (Carry UI)

1. When a junior opens an Idle / waiting position, prompt: **“Prefund gas credit”** so lenders are not stuck paying queue gas alone.
2. Show `gasCreditWei(me)` and `gasRefundWei` on the position / lend screens.
3. On successful `depositSenior`, surface `GasCreditConsumed` (explorer / toast): senior received ETH refund from the waiting junior.
4. Allow junior to **withdraw unused credit** after Fully Matched or after canceling Idle.

This is **not** a full ERC-4337 paymaster. It is a clear on-chain ETH escrow the senior deposit can draw. Secure enough for RH testnet demos and Forge-covered.

## Security notes

- Refund amount capped by `gasRefundWei` and remaining credit.
- Credit decremented before the ETH transfer (CEI); `depositSenior` is `nonReentrant`.
- Bare `receive()` is not used; only `fundGasCredit` accepts ETH.
- Owner can set `gasRefundWei = 0` to disable refunds without an upgrade.
