# Carry — Robinhood Testnet Deploy

Deploy notes for Robinhood Chain Testnet. Full product + security write-up: [`CARRY_CONTRACT.md`](./CARRY_CONTRACT.md).

**Do not broadcast without a deployer key Dylan provides in a local shell.** No keys in git. No mainnet.

---

## Network (verified)

| Item | Value |
| --- | --- |
| Network | **Robinhood Chain Testnet** |
| Chain ID | **46630** (`0xb626`) |
| Public RPC | `https://rpc.testnet.chain.robinhood.com` |
| Explorer | `https://explorer.testnet.chain.robinhood.com` |
| Faucet | `https://faucet.testnet.chain.robinhood.com` |
| Gas token | ETH (testnet) |
| Official docs | [Connecting to Robinhood Chain](https://docs.robinhood.com/chain/connecting/) |

Mainnet Robinhood Chain is **4663** — out of scope for this testnet pack.

### Uniswap on testnet

There is **no official Uniswap v3/v4 deployment on chain 46630** (confirmed by public RH toolkit notes as of mid-2026). Deploy **mocks + vault** only. DualPool efficiency is **not** required for the contest.

### Fallbacks (only if RH testnet is unreachable)

1. Local: `anvil` + `DeployCarryTestnet` dry-run (chain id 31337).  
2. Sepolia mocks — last resort; prefer documenting RH testnet in the grant form.

---

## What gets deployed

Script: `contracts/script/DeployCarryTestnet.s.sol`

| Contract | Purpose |
| --- | --- |
| `MockERC20` mMSTR | Fake stock token |
| `MockERC20` mUSDG | Fake USDG |
| `MockOracle` | $100 WAD demo price (**has setter** — testnet only) |
| `MockFeePool` | Pushes USDG fees into vault |
| `LeveredLpVault` | Carry flows; **starts paused** |

Script does **not** unpause, seed user funds, or deploy a hook. Refuses chain ids **4663** and **1**.

---

## Addresses (deployed 2026-10-01 on 46630)

Deployer / vaultOwner: [`0xcA44F2dbB2D43b93b39F01B88E0f0e2966983c57`](https://explorer.testnet.chain.robinhood.com/address/0xcA44F2dbB2D43b93b39F01B88E0f0e2966983c57)  
Vault **paused on-chain** (`paused() == true`). Script re-disarmed after broadcast.  
Source **verified** on explorer via Sourcify (exact match) for vault + mocks.

| Name | Address | Explorer (contract / code) |
| --- | --- | --- |
| mockMstr | `0x762019309B536bbb89577422FaaFBeC9659f8728` | [verified](https://explorer.testnet.chain.robinhood.com/address/0x762019309B536bbb89577422FaaFBeC9659f8728?tab=contract) |
| mockUsdg | `0x25030Bff74764aD72b912276a603717DB1C00644` | [verified](https://explorer.testnet.chain.robinhood.com/address/0x25030Bff74764aD72b912276a603717DB1C00644?tab=contract) |
| mockOracle | `0xc74Af7E23A2B4b46B5Fe05E5c7c5ec0BB5dbc5B7` | [verified](https://explorer.testnet.chain.robinhood.com/address/0xc74Af7E23A2B4b46B5Fe05E5c7c5ec0BB5dbc5B7?tab=contract) |
| mockFeePool | `0xa4122524aD97Aab05cAC7F99c04Cd060D02F0771` | [verified](https://explorer.testnet.chain.robinhood.com/address/0xa4122524aD97Aab05cAC7F99c04Cd060D02F0771?tab=contract) |
| vault | `0x72A053120f03B10c5506d2325f92F59B0FfC36c8` | [verified](https://explorer.testnet.chain.robinhood.com/address/0x72A053120f03B10c5506d2325f92F59B0FfC36c8?tab=contract) |
| vaultOwner | `0xcA44F2dbB2D43b93b39F01B88E0f0e2966983c57` | [view](https://explorer.testnet.chain.robinhood.com/address/0xcA44F2dbB2D43b93b39F01B88E0f0e2966983c57) |

Printable overview for review: [`contracts/docs/Carry-Contract-Overview.pdf`](./contracts/docs/Carry-Contract-Overview.pdf)

### Broadcast tx hashes

| Contract | Tx |
| --- | --- |
| mockMstr | [`0x62b518c10e82819aec50226642782d8096eedc1fead281f333529ede66fcb9da`](https://explorer.testnet.chain.robinhood.com/tx/0x62b518c10e82819aec50226642782d8096eedc1fead281f333529ede66fcb9da) |
| mockUsdg | [`0x67c7005e0b8bf604077141a73d5adf01801fbaf0d23bb099951f6b3c056dbe31`](https://explorer.testnet.chain.robinhood.com/tx/0x67c7005e0b8bf604077141a73d5adf01801fbaf0d23bb099951f6b3c056dbe31) |
| mockOracle | [`0x54b2be4cabdb2b0f2f7ac6261f4ba92f4b7a498c5e07af9f6b00a945fc3df7c2`](https://explorer.testnet.chain.robinhood.com/tx/0x54b2be4cabdb2b0f2f7ac6261f4ba92f4b7a498c5e07af9f6b00a945fc3df7c2) |
| mockFeePool | [`0xe6e834b5407bcac86f6e901408ceac2d37123cc5bea1c2f4cdbfa3f816430e1e`](https://explorer.testnet.chain.robinhood.com/tx/0xe6e834b5407bcac86f6e901408ceac2d37123cc5bea1c2f4cdbfa3f816430e1e) |
| vault | [`0x444e85ea4ab84816c68ca2defad343068f68758c019506a997d52bf4639f58e6`](https://explorer.testnet.chain.robinhood.com/tx/0x444e85ea4ab84816c68ca2defad343068f68758c019506a997d52bf4639f58e6) |

---

## Commands

```bash
export PATH="$PATH:$HOME/.foundry/bin"
cd contracts

# Tests
forge test

# Dry-run against RH testnet RPC (no key; broadcastArmed=false → no real txs)
forge script script/DeployCarryTestnet.s.sol \
  --rpc-url https://rpc.testnet.chain.robinhood.com \
  -vvvv

# Local anvil dry-run
anvil &
forge script script/DeployCarryTestnet.s.sol --rpc-url http://127.0.0.1:8545 -vvvv
```

### Broadcast (blocked until armed + key)

Dylan needs:

1. Testnet wallet with faucet ETH on **46630**  
2. `DEPLOYER_PRIVATE_KEY` only in local shell (never commit)  
3. **`VAULT_OWNER`** (required for live broadcast — pause key; prefer a wallet you control)  
4. Reviewed flip of `broadcastArmed()` → `true` in `DeployCarryTestnet.s.sol`

```bash
# AFTER arming the script in a reviewed change:
export DEPLOYER_PRIVATE_KEY=...    # local only
export VAULT_OWNER=0xYourOwner

forge script script/DeployCarryTestnet.s.sol:DeployCarryTestnet \
  --rpc-url https://rpc.testnet.chain.robinhood.com \
  --broadcast \
  --private-key $DEPLOYER_PRIVATE_KEY
```

Then owner calls `unpause()` when ready for deposits. Mint mock tokens via `MockERC20.mint`.

---

## Safety

- Vault deploys **paused**.  
- Owner cannot rescue MSTR/USDG.  
- No Yieldz. No mainnet custody of real Stock Tokens for this script.  
- `DeployLeveredLpVault.s.sol` (4663) stays **disarmed** — not used for Carry testnet.


## Additive vault params (pending redeploy)

Source now includes owner-settable **deposit caps** (`setDepositCaps`). The live address above was deployed before these getters/setters existed, so caps are **not** enforceable on that bytecode until Dylan redeploys and updates `public/config.json` + this address table. Until then UI caps remain display-only (`product.caps.enforcedOnChain: false`).

