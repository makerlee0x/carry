# v3 maturity settle pack — positions #1 / #3 / #5

**Done 2026-10-18 ~10:18pm CDT.** Kept as the settle record + commands used that night.  
PROXY later upgraded to `v3.2-dualpool` — see [`testnet-runs/2026-10-18-v32-upgrade.md`](./testnet-runs/2026-10-18-v32-upgrade.md).

| Field | Value |
| --- | --- |
| Network | Robinhood Chain Testnet **46630** |
| Product PROXY | `0x24B799026AA7baa6856bCFD00c1Be1f583A83e35` |
| Impl at settle | `0x7BeED7F65A9D4aF4E67553d984800F6268a3778E` (`v3-lender-pool`) |
| Junior (all three) | `0x76339f8D6640D6dF94037D87c2c9503C98391803` |
| Term | 7d (`604800`) |
| CoverMode (at settle) | `0=Wallet`, `1=IdleCarry`, `2=SellShares` — removed on v3.2 (one-arg settle) |
| Default settle | `settle(id)` |

Outcomes: [`SETTLE_WATCH.md`](./SETTLE_WATCH.md).

## Maturity times (exact)

| Id | `openedAt` (unix) | Mature UTC | Mature **CDT** | Senior principal |
| --- | --- | --- | --- | --- |
| **#1** | 1791772514 | 2026-10-19 02:35:14 UTC | **2026-10-18 9:35:14 PM CDT** | 154.34 mUSDG |
| **#3** | 1791772652 | 2026-10-19 02:37:32 UTC | **2026-10-18 9:37:32 PM CDT** | 154.34 mUSDG |
| **#5** | 1791772738 | 2026-10-19 02:38:58 UTC | **2026-10-18 9:38:58 PM CDT** | 56.32 mUSDG (partial match) |

Settle order suggestion: **#1 → #3 → #5** as each clock passes.

## Env (no keys in this doc)

Same patterns as `scripts/run_v3_onchain.sh` / `CARRY_TESTNET.md`:

```bash
export PATH="$PATH:$HOME/.foundry/bin"
RPC=https://rpc.testnet.chain.robinhood.com
PROXY=0x24B799026AA7baa6856bCFD00c1Be1f583A83e35
# Load key only in your local shell — never commit:
#   source /path/to/.env.carry.deployer   # provides DEPLOYER_PRIVATE_KEY
# or:  KEY=$(tr -d ' \n\r' < /path/to/keyfile)
```

Anyone can settle when residual `coverUsdg == 0` after backstop. If cover remains, the **junior** must call with Wallet/Idle/SellShares.

## Steps per position (after its CDT time)

Replace `ID` with `1`, `3`, or `5`.

### 1) Dry-run preview (eth_call)

```bash
cast call $PROXY "previewSettle(uint256,uint8)((uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint8))" ID 1 --rpc-url $RPC
```

Read fields (Settlement struct order):

1. `mstrKept` 2. `mstrSold` 3. `accrual` 4. `seniorFloor` 5. `treasury` 6. `seniorPerf`  
7. `juniorYield` 8. **`fromBackstop`** 9. **`coverUsdg`** 10. `treasuryOnCover`  
11. `feeShortfallUsdg` 12. **`fromPool`** 13. `coverMode`

- Before maturity → expect revert `TermNotElapsed`.
- After maturity, if **`coverUsdg == 0`** → permissionless `settle(ID)` is fine.
- If **`coverUsdg > 0`** → junior must settle (approve USDG if Wallet).

### 2) Broadcast settle (default IdleCarry)

```bash
cast send $PROXY "settle(uint256)" ID --rpc-url $RPC --private-key "$DEPLOYER_PRIVATE_KEY"
# or junior key when coverUsdg > 0:
# cast send $PROXY "settle(uint256,uint8)" ID 0 --rpc-url $RPC --private-key "$JUNIOR_KEY"   # Wallet
```

### 3) Confirm

```bash
cast call $PROXY "positions(uint256)(address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,bool,bool,uint256,uint256,uint256)" ID --rpc-url $RPC
# settled == true (9th field)
```

Paste tx hashes into [`SETTLE_WATCH.md`](./SETTLE_WATCH.md) v3 section when done.

## Post-settle

Auto-compound reopened **#9 / #10 / #11**. PROXY since upgraded to **`v3.2-dualpool`** (impl `0x1473…58A5`); sell router + DualPool wired. Remaining product work for real Morpho: issue **#20**.

## Tonight checklist (completed)

- [x] Wait until **9:35:14 PM CDT** (or later) for #1
- [x] `previewSettle(1,1)` succeeds; note `coverUsdg` / `fromBackstop` / `fromPool`
- [x] `cast send … settle(1)` (or junior mode if cover needed)
- [x] Confirm `settled=true` for #1; record tx
- [x] Repeat for #3 at **9:37:32 PM CDT**, then #5 at **9:38:58 PM CDT**
- [x] Append outcomes to [`SETTLE_WATCH.md`](./SETTLE_WATCH.md)
- [x] Done **2026-10-18 ~10:18pm CDT** — txs in SETTLE_WATCH
