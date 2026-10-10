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

## Early cover (junior short of senior accrual)

If the position is short of senior accrual on a manual early exit, the junior
covers. **User chooses** how to pay. Default order (do not reorder):

1. Wallet USDG
2. Idle USDG on Carry (unmatched senior deposit)
3. Sell shares from the position

Treasury also takes **20% of that senior fee** (subject to Boosted treasury cut).

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

## Maker-confirmed answers (5)

1. **morphoRate** = Steakhouse Morpho **native supply** APY (not Merkl).
2. **Fee split only** at `claimFees` / `earlyExit` / `settle` (not on fee-in).
3. **Early cover:** user decides; default order wallet USDG → Idle USDG on Carry → sell from position.
4. **Boosted:** must stake STRATEGY **before** open; cannot boost an already Active position (reopen to get boost). Future positions in that market are Boosted while staked. Boost goes to **Junior only**, funded by reduced treasury (as low as 10% by tier) + LONG creator fees later.
5. **Idle USDG Morpho on testnet** = APY stub from config for now (no real ERC-4626 sleeve this round).

---

## On-chain status

**Landed on testnet PROXY** `0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd` (UUPS): Maker waterfall at claimFees/earlyExit/settle, unpaid accrual carry, partial-match accrual checkpoint, no match-after-term, settle without selling junior MSTR, early cover chooser, Boosted treasury-tier stub, deposit caps. Implementation address in `public/config.json`.

### Early cover vs settle

- **Early exit:** user chooses Wallet / Idle Carry / SellShares when fees &lt; accrual.
- **Settle (maturity):** junior keeps all remaining MSTR; unpaid accrual covered from treasury/`backstop` only (no share sale).
- **SellShares + treasury shortfall (accepted testnet):** treasury still wants 20% of the cover amount. If junior leftover fees cannot pay that USDG slice, the unpaid treasury piece is credited to seniors as additional MSTR (no AMM on testnet).

## Explicitly later

- Real Morpho sleeve on Robinhood
- LONG creator fee share into Boosted
- STRATEGY stake token (beyond owner-set flag)
- Mainnet 4663
