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

**Treasury cut is ALWAYS 20% of gross** (Maker Oct 10), including Boosted positions
and shortfall-cover paths. Boosted remains a stake-before-open flag for future LONG /
STRATEGY yield wiring; it does **not** reduce this cut.

---

## When the split runs

Fee split runs **only** at:

- `claimFees`
- `earlyExit`
- `settle`

**Not** on fee-in (`accrueLpFee`). Fees can accrue raw into the position; the
waterfall is applied at claim / exit / settle.

---

## Shortfall cover (settle vs early exit)

If fees cannot cover senior accrual:

### Settle (maturity / normal exit)

1. **Backstop first** (treasury/backstop USDG).
2. **Residual:** junior chooses Wallet USDG, IdleCarry, or SellShares.
3. **Treasury-on-cover:** ALWAYS **20%** of the residual shortfall.  
   `coverTotal = residualShortfall + treasuryOnCover`.

Settle default mode = SellShares (permissionless). Wallet / IdleCarry require the junior caller.

### Early exit (before term)

1. **Junior only** — Wallet / IdleCarry / SellShares.
2. **NO backstop** draw on early exit.
3. Treasury-on-cover still **20%** of the junior-covered shortfall.

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
3. **Settle cover:** backstop first; then junior Wallet / IdleCarry / SellShares; treasury-on-cover ALWAYS 20%.
3b. **Early exit cover:** junior only (NO backstop); same three modes; treasury-on-cover ALWAYS 20%.
4. **Boosted:** stake STRATEGY **before** open; flag only for now. Treasury cut stays **20%** (not reduced to 10%). LONG creator fee share later.
5. **Idle USDG Morpho on testnet** = APY stub from config for now (no real ERC-4626 sleeve this round).
6. **Owner treasury withdraw** = yes (multisig eventually); `withdrawFromBackstop` / `withdrawTreasuryFees`.
7. **Late senior yield** = pro-rata by deposit time (time-weighted).
8. **Open-queue gas** = junior on-chain `gasCredit` + `matchCap` (Maker chose junior-front-gas; no off-chain DB).

---

## On-chain status

**Landed on testnet PROXY** `0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd` (UUPS, `v2.3-maker-clarifications`): Maker waterfall at claimFees/earlyExit/settle, unpaid accrual carry, partial-match accrual checkpoint, no match-after-term, settle shortfall = backstop first then junior cover, early exit = junior only (no backstop), treasury cut ALWAYS 20%, junior `gasCredit` ETH escrow, time-weighted senior credits, owner backstop withdraw, `matchCap`, Boosted stake flag (no cut reduction), deposit caps. Implementation address in `public/config.json`.

## Open-queue gas (Maker chose A)

| Piece | Status |
| --- | --- |
| Junior `fundGasCredit` / `withdrawGasCredit` ETH escrow | **Shipped** — see [`GAS_CREDIT.md`](./GAS_CREDIT.md) |
| `depositSenior` draws `gasRefundWei` from open-queue junior | **Shipped** (even if only partial match) |
| `matchCap` bounds match iterations | **Shipped** (default 25) |
| Off-chain idle DB | **Rejected** for this path |

## Explicitly later

- Real Morpho sleeve on Robinhood
- LONG creator fee share into Boosted
- STRATEGY stake token (beyond owner-set flag)
- Mainnet SellShares via AMM (testnet keeps MSTR→seniors accounting)
- Mainnet 4663
