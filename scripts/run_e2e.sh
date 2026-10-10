#!/usr/bin/env bash
# Committed E2E runner (no keys). Ephemeral wallets live in gitignored contracts/.e2e/.
# Usage: CARRY_DEPLOYER_KEY_FILE=/path/to/.deployer.key ./scripts/run_e2e.sh
set -euo pipefail
export PATH="$PATH:$HOME/.foundry/bin"

RPC=https://rpc.testnet.chain.robinhood.com
# Product v2 PROXY (clean book). First proxy 0x0e4e… contaminated by lost E2E keys — leave alone.
PROXY=0xc80108649B3ba2e5B040c79DDE3af0cB979b72bd
MSTR=0x762019309B536bbb89577422FaaFBeC9659f8728
USDG=0x25030Bff74764aD72b912276a603717DB1C00644
FEEPOOL=0xa4122524aD97Aab05cAC7F99c04Cd060D02F0771
OWNER=0xcA44F2dbB2D43b93b39F01B88E0f0e2966983c57

export DEPLOYER_PRIVATE_KEY
KEY_FILE="${CARRY_DEPLOYER_KEY_FILE:-}"
if [ -z "$KEY_FILE" ]; then
  for c in     "/Users/meador/carry/contracts/.deployer.key"     "/Users/meador/StockTokenSwap/contracts/.deployer.key"; do
    if [ -f "$c" ]; then KEY_FILE="$c"; break; fi
  done
fi
if [ -z "$KEY_FILE" ] || [ ! -f "$KEY_FILE" ]; then
  echo "Missing deployer key file (set CARRY_DEPLOYER_KEY_FILE). Keys are gitignored." >&2
  exit 1
fi
DEPLOYER_PRIVATE_KEY=$(tr -d ' \n\r' < "$KEY_FILE")

E2E_DIR="$(cd "$(dirname "$0")/.." && pwd)/contracts/.e2e"
mkdir -p "$E2E_DIR"
chmod 700 "$E2E_DIR"

# Reuse existing ephemeral wallets (do not regenerate — loses keys mid-run).
JUNIOR=$(cat "$E2E_DIR/junior.addr")
SENIOR=$(cat "$E2E_DIR/senior.addr")
DONOR=$(cat "$E2E_DIR/donor.addr")
JUNIOR_KEY=$(cat "$E2E_DIR/junior.key")
SENIOR_KEY=$(cat "$E2E_DIR/senior.key")
DONOR_KEY=$(cat "$E2E_DIR/donor.key")
echo "junior_addr=$JUNIOR"
echo "senior_addr=$SENIOR"
echo "donor_addr=$DONOR"
echo "proxy=$PROXY"

sendq() {
  cast send "$@" --rpc-url "$RPC" >/dev/null
}

for to in "$JUNIOR" "$SENIOR" "$DONOR"; do
  bal=$(cast balance "$to" --rpc-url "$RPC")
  if [ "$bal" = "0" ]; then
    sendq "$to" --value 300000000000000 --private-key "$DEPLOYER_PRIVATE_KEY"
  fi
done
echo "gas_funded=ok"

MSTR_AMT=1000000000000000000
SENIOR_FULL=100000000000000000000
SENIOR_HALF=50000000000000000000
FEE_GROSS=268500000000000000

sendq "$MSTR" "mint(address,uint256)" "$JUNIOR" "$MSTR_AMT" --private-key "$DEPLOYER_PRIVATE_KEY"
sendq "$USDG" "mint(address,uint256)" "$SENIOR" "$SENIOR_FULL" --private-key "$DEPLOYER_PRIVATE_KEY"
sendq "$USDG" "mint(address,uint256)" "$JUNIOR" 5000000000000000000 --private-key "$DEPLOYER_PRIVATE_KEY"
sendq "$USDG" "mint(address,uint256)" "$DONOR" 10000000000000000000 --private-key "$DEPLOYER_PRIVATE_KEY"
echo "minted=ok"

RESULTS=/tmp/carry_e2e_results.txt
: > "$RESULTS"
pass() { echo "PASS $1" | tee -a "$RESULTS"; }
fail() { echo "FAIL $1 :: $2" | tee -a "$RESULTS"; }

PAUSED=$(cast call "$PROXY" "paused()(bool)" --rpc-url "$RPC")
if [ "$PAUSED" = "false" ]; then pass "unpaused"; else fail "unpaused" "$PAUSED"; fi

# Partial match
sendq "$USDG" "approve(address,uint256)" "$PROXY" "$SENIOR_HALF" --private-key "$SENIOR_KEY"
sendq "$PROXY" "depositSenior(uint256)" "$SENIOR_HALF" --private-key "$SENIOR_KEY"
sendq "$MSTR" "approve(address,uint256)" "$PROXY" "$MSTR_AMT" --private-key "$JUNIOR_KEY"
sendq "$PROXY" "depositJunior(uint256)" "$MSTR_AMT" --private-key "$JUNIOR_KEY"
ID=$(cast call "$PROXY" "nextPositionId()(uint256)" --rpc-url "$RPC")
ID=$((ID - 1))
echo "positionId=$ID"
MATCHED=$(cast call "$PROXY" "isMatched(uint256)(bool)" "$ID" --rpc-url "$RPC")
FULL=$(cast call "$PROXY" "isFullyMatched(uint256)(bool)" "$ID" --rpc-url "$RPC")
echo "matched=$MATCHED full=$FULL"
if [ "$MATCHED" = "true" ] && [ "$FULL" = "false" ]; then pass "partial_match"; else fail "partial_match" "matched=$MATCHED full=$FULL"; fi

REMAIN=$(python3 -c "print(int('$SENIOR_FULL')-int('$SENIOR_HALF'))")
sendq "$USDG" "approve(address,uint256)" "$PROXY" "$REMAIN" --private-key "$SENIOR_KEY"
sendq "$PROXY" "depositSenior(uint256)" "$REMAIN" --private-key "$SENIOR_KEY"
FULL2=$(cast call "$PROXY" "isFullyMatched(uint256)(bool)" "$ID" --rpc-url "$RPC")
if [ "$FULL2" = "true" ]; then pass "auto_match_on_senior"; else fail "auto_match_on_senior" "$FULL2"; fi

# Fee-in no cut
sendq "$USDG" "approve(address,uint256)" "$FEEPOOL" "$FEE_GROSS" --private-key "$DONOR_KEY"
sendq "$FEEPOOL" "payFee(address,uint256,uint256)" "$PROXY" "$ID" "$FEE_GROSS" --private-key "$DONOR_KEY"
BS=$(cast call "$PROXY" "backstop()(uint256)" --rpc-url "$RPC")
FEE_ON_POS=$(cast call "$PROXY" "positions(uint256)(address,uint256,uint256,uint256,uint256,uint256,uint64,uint64,bool,bool,uint256,uint256)" "$ID" --rpc-url "$RPC" | sed -n '6p' | awk '{print $1}')
echo "backstop_after_fee=$BS feeUsdg=$FEE_ON_POS"
if [ "$BS" = "0" ] && [ "$FEE_ON_POS" = "$FEE_GROSS" ]; then pass "fee_in_no_cut"; else fail "fee_in_no_cut" "bs=$BS fee=$FEE_ON_POS"; fi

# claimFees
sendq "$PROXY" "claimFees(uint256)" "$ID" --private-key "$JUNIOR_KEY"
BS2=$(cast call "$PROXY" "backstop()(uint256)" --rpc-url "$RPC")
FEE_AFTER=$(cast call "$PROXY" "positions(uint256)(address,uint256,uint256,uint256,uint256,uint256,uint64,uint64,bool,bool,uint256,uint256)" "$ID" --rpc-url "$RPC" | sed -n '6p' | awk '{print $1}')
echo "backstop_after_claim=$BS2 feeUsdg_after=$FEE_AFTER"
if [ "$FEE_AFTER" = "0" ] && [ "$BS2" != "0" ]; then pass "claimFees_waterfall"; else fail "claimFees_waterfall" "fee=$FEE_AFTER bs=$BS2"; fi

open_matched() {
  local amt_mstr=$1
  local amt_senior=$2
  sendq "$MSTR" "mint(address,uint256)" "$JUNIOR" "$amt_mstr" --private-key "$DEPLOYER_PRIVATE_KEY"
  sendq "$USDG" "mint(address,uint256)" "$SENIOR" "$amt_senior" --private-key "$DEPLOYER_PRIVATE_KEY"
  sendq "$USDG" "approve(address,uint256)" "$PROXY" "$amt_senior" --private-key "$SENIOR_KEY"
  sendq "$PROXY" "depositSenior(uint256)" "$amt_senior" --private-key "$SENIOR_KEY"
  sendq "$MSTR" "approve(address,uint256)" "$PROXY" "$amt_mstr" --private-key "$JUNIOR_KEY"
  sendq "$PROXY" "depositJunior(uint256)" "$amt_mstr" --private-key "$JUNIOR_KEY"
  local nid
  nid=$(cast call "$PROXY" "nextPositionId()(uint256)" --rpc-url "$RPC")
  echo $((nid - 1))
}

pos_settled() {
  cast call "$PROXY" "positions(uint256)(address,uint256,uint256,uint256,uint256,uint256,uint64,uint64,bool,bool,uint256,uint256)" "$1" --rpc-url "$RPC" | sed -n '9p' | awk '{print $1}'
}

# earlyExit SellShares
ID2=$(open_matched "$MSTR_AMT" "$SENIOR_FULL")
echo "position2=$ID2"
sleep 3
sendq "$PROXY" "earlyExit(uint256,uint8)" "$ID2" 2 --private-key "$JUNIOR_KEY"
if [ "$(pos_settled "$ID2")" = "true" ]; then pass "earlyExit_sellShares"; else fail "earlyExit_sellShares" "not settled"; fi

# earlyExit Wallet
ID3=$(open_matched "$MSTR_AMT" "$SENIOR_FULL")
echo "position3=$ID3"
sleep 3
sendq "$USDG" "mint(address,uint256)" "$JUNIOR" 1000000000000000000 --private-key "$DEPLOYER_PRIVATE_KEY"
sendq "$USDG" "approve(address,uint256)" "$PROXY" 1000000000000000000 --private-key "$JUNIOR_KEY"
sendq "$PROXY" "earlyExit(uint256,uint8)" "$ID3" 0 --private-key "$JUNIOR_KEY"
if [ "$(pos_settled "$ID3")" = "true" ]; then pass "earlyExit_wallet"; else fail "earlyExit_wallet" "not settled"; fi

# earlyExit IdleCarry
ID4=$(open_matched "$MSTR_AMT" "$SENIOR_FULL")
echo "position4=$ID4"
sendq "$USDG" "mint(address,uint256)" "$JUNIOR" 2000000000000000000 --private-key "$DEPLOYER_PRIVATE_KEY"
sendq "$USDG" "approve(address,uint256)" "$PROXY" 2000000000000000000 --private-key "$JUNIOR_KEY"
sendq "$PROXY" "depositSenior(uint256)" 2000000000000000000 --private-key "$JUNIOR_KEY"
sleep 3
sendq "$PROXY" "earlyExit(uint256,uint8)" "$ID4" 1 --private-key "$JUNIOR_KEY"
if [ "$(pos_settled "$ID4")" = "true" ]; then pass "earlyExit_idleCarry"; else fail "earlyExit_idleCarry" "not settled"; fi

# settle blocked before term on pos1
set +e
sendq "$PROXY" "settle(uint256)" "$ID" --private-key "$DONOR_KEY" 2>/tmp/settle_err.txt
RC=$?
set -e
if [ $RC -ne 0 ]; then pass "settle_blocked_before_term"; else fail "settle_blocked_before_term" "unexpected success"; fi

# cleanup pos1
sendq "$PROXY" "earlyExit(uint256,uint8)" "$ID" 2 --private-key "$JUNIOR_KEY"
pass "earlyExit_pos1_cleanup"

FREE_RAW=$(cast call "$PROXY" "freePrincipal(address)(uint256)" "$SENIOR" --rpc-url "$RPC")
FREE=$(echo "$FREE_RAW" | awk '{print $1}')
echo "senior_free=$FREE"
if [ "$FREE" != "0" ]; then
  sendq "$PROXY" "withdrawSenior(uint256)" "$FREE" --private-key "$SENIOR_KEY"
  pass "senior_withdraw"
else
  sendq "$PROXY" "withdrawSenior(uint256)" 0 --private-key "$SENIOR_KEY"
  pass "senior_withdraw_yield_only"
fi

RESERVED=$(cast call "$PROXY" "reservedSenior()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
echo "reserved_final=$RESERVED"
if [ "$RESERVED" = "0" ]; then pass "no_reserved_stuck"; else fail "no_reserved_stuck" "$RESERVED"; fi

set +e
sendq "$PROXY" "rescueToken(address,address,uint256)" "$USDG" "$OWNER" 1 --private-key "$DEPLOYER_PRIVATE_KEY" 2>/tmp/rescue_err.txt
RC=$?
set -e
if [ $RC -ne 0 ]; then pass "rescue_blocks_usdg"; else fail "rescue_blocks_usdg" "succeeded"; fi

# pause works
sendq "$PROXY" "pause()" --private-key "$DEPLOYER_PRIVATE_KEY"
PAUSED2=$(cast call "$PROXY" "paused()(bool)" --rpc-url "$RPC")
if [ "$PAUSED2" = "true" ]; then pass "pause_works"; else fail "pause_works" "$PAUSED2"; fi
# unpause again for product demo readiness
sendq "$PROXY" "unpause()" --private-key "$DEPLOYER_PRIVATE_KEY"
pass "unpause_restored"

echo "======== E2E SUMMARY ========"
cat "$RESULTS"
echo "PASS_COUNT=$(grep -c '^PASS' "$RESULTS" || true)"
echo "FAIL_COUNT=$(grep -c '^FAIL' "$RESULTS" || true)"
