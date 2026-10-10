# Maker fee waterfall (source of truth)

Locked with Maker Lee (Oct 5, 2026). This supersedes older docs that describe a
flat **20% protocol cut on every fee-in**, a fixed **4% early-exit coupon**, and
**claimFees skimming surplus above a 4% pace**. The live UUPS product PROXY
implements this Morpho-rate waterfall (rate stub **3.9%**, owner cap **≤5%**,
locked per position at first match).

Product narrative: [`MAKER_V1_NOTES.md`](./MAKER_V1_NOTES.md).  
On-chain today: [`CARRY_CONTRACT.md`](../CARRY_CONTRACT.md) + [`CARRY_TESTNET.md`](../CARRY_TESTNET.md).

---

## Waterfall (on gross LP fees)

Senior accrual is the opportunity cost of supplying USDG on Carry instead of Morpho:

```
accrual = seniorPrincipal × morphoRate × elapsed / 365
```

`morphoRate` = **Steakhouse Morpho native supply APY** (not Merkl rewards).

Then, on **gross** LP fees for the period:

```
seniorFloor = min(gross, accrual)
left        = gross − seniorFloor
treasury    = min(left, gross × 0.20)
left        = left − treasury
seniorPerf  = min(left, gross × 0.20)
junior      = left − seniorPerf
senior      = seniorFloor + seniorPerf
```

When Boosted staking tiers cut treasury (as low as **10%** of gross by tier),
that reduced treasury share funds Junior boost; LONG creator fee share comes later.

---

## When the split runs

Fee split runs **only** at:

- `claimFees`
- `earlyExit`
- `settle`

**Not** on fee-in (`accrueLpFee`). Fees can accrue raw into the position; the
waterfall is applied at claim / exit / settle.

---

## Shortfall cover (early exit + settle)

If fees cannot cover senior accrual:

1. **Backstop first** (treasury/backstop USDG).
2. **Residual:** junior covers via user-chosen mode:
   - Wallet USDG
   - Idle USDG on Carry (unmatched senior deposit)
   - Sell shares from the position
3. **Treasury-on-cover:** treasury also takes **cut% of the residual shortfall**
   (default **same as waterfall treasury cut** — 20%, or Boosted 10%).  
   `coverTotal = residualShortfall + treasuryOnCover`.

Defaults assumed until Maker corrects:

- Treasury% on cover = same cut as waterfall (not a separate rate).
- Order = backstop → junior cover.
- Applies at **settle and early exit** (settle default mode = SellShares; Wallet/IdleCarry require junior caller).

### SellShares + treasury shortfall (accepted testnet)

If junior leftover fees cannot pay the USDG treasury-on-cover slice, the unpaid
treasury piece is credited to seniors as additional MSTR (no AMM on testnet).

---

## Senior yield timing

USDG (and SellShares MSTR) credits to seniors are **time-weighted by deposit time**:

```
weight_i = principal_i × (creditTime − joinedAt_i)
share_i  ∝ weight_i
```

A senior who deposits right before claim/settle does **not** take a full equal
share of pre-arrival accrual. Legacy equal-share index remains for pre-upgrade debt.

---

## $10k / $10k · 7-day example

Assume $10k senior principal + $10k junior book, 7 days elapsed, Morpho-rate
illustration **4%**, and gross LP fees earned at **7%** APR on the $20k book:

```
accrual @ 4%  = 10000 × 0.04 × 7/365 ≈ $7.67
gross @ 7%    = 20000 × 0.07 × 7/365 ≈ $26.85

seniorFloor   = 7.67
treasury      = 5.37   (20% of gross)
seniorPerf    = 5.37   (20% of gross)
junior        = 8.44
senior total  = 13.04
```

Use this as the fee-preview reference in the UI. Live rate on testnet is the
**3.9%** Morpho stub (sheet math above uses 4% for round numbers).

---

## Maker-confirmed answers (5) — Oct 5 sheet + later product Qs

1. **morphoRate** = Steakhouse Morpho **native supply** APY (not Merkl).
2. **Fee split only** at `claimFees` / `earlyExit` / `settle` (not on fee-in).
3. **Early/settle cover:** backstop first; then junior Wallet / Idle / SellShares; treasury% on residual cover.
4. **Boosted:** must stake STRATEGY **before** open; cannot boost an already Active position (reopen to get boost). Future positions in that market are Boosted while staked. Boost goes to **Junior only**, funded by reduced treasury (as low as 10% by tier) + LONG creator fees later.
5. **Idle USDG Morpho on testnet** = APY stub from config for now (no real ERC-4626 sleeve this round).
6. **Owner treasury withdraw** = yes (multisig eventually); `withdrawFromBackstop` / `withdrawTreasuryFees`.
7. **Late senior yield** = pro-rata by deposit time (time-weighted).
8. **Open-queue gas** = on-chain `matchCap` for now; Maker still picks junior-front-gas vs off-chain idle DB.

---

## On-chain status

**Landed on testnet PROXY** `0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd` (UUPS): Maker waterfall at claimFees/earlyExit/settle, unpaid accrual carry, partial-match accrual checkpoint, no match-after-term, settle/early shortfall cover with backstop-first + junior modes, time-weighted senior credits, owner backstop withdraw, `matchCap`, Boosted treasury-tier stub, deposit caps. Implementation address in `public/config.json`.

## Open-queue gas options (Maker pick)

| Option | Idea | This cut |
| --- | --- | --- |
| **A** | Junior fronts gas for senior deposit even if unmatched | Not fully implemented — document only |
| **B** | Idle juniors off-chain in DB until matched | Not fully implemented — document only |
| **Mitigation shipped** | `matchCap` / max match iterations per `depositSenior` | **Yes** (default 25; owner-settable) |

## Explicitly later

- Real Morpho sleeve on Robinhood
- LONG creator fee share into Boosted
- STRATEGY stake token (beyond owner-set flag)
- Full junior-front-gas or off-chain idle DB (Maker choice)
- Mainnet 4663
