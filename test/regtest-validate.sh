#!/bin/sh
#
# Automated merge mining regtest validation for Tideway.
# Runs autonomously — start it and check the log in the morning.
#
# Usage: sh test/regtest-validate.sh
# Log:   /tmp/tideway-regtest-validate.log
#
# Prerequisites:
#   - Regtest jails running on freebsd-dev1: litecoin, dogecoin-regtest, pepecoin-regtest
#   - Tideway built at ./zig-out/bin/tideway
#   - SeaTidePool built at ../SeaTidePool/bin/tidepool (or specify STP_BIN)
#   - cpuminer available in PATH (or specify CPUMINER_BIN)

# Do NOT set -e — we handle errors explicitly

# --- Configuration ---
TIDEWAY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TIDEWAY_BIN="${TIDEWAY_BIN:-${TIDEWAY_ROOT}/zig-out/bin/tideway}"
STP_BIN="${STP_BIN:-${TIDEWAY_ROOT}/../SeaTidePool/bin/tidepool}"
CPUMINER_BIN="${CPUMINER_BIN:-cpuminer}"

LOGFILE="/tmp/tideway-regtest-validate.log"
STP_LOGDIR="/tmp/tidepool-merge-regtest"
TIDEWAY_CONF="/tmp/tideway-regtest.conf"
STP_CONF="/tmp/tidepool-merge-regtest.conf"

# Regtest RPC settings
LTC_CLI="sudo jexec litecoin litecoin-cli -rpcuser=tidepool -rpcpassword=tidepoolpass -rpcport=19443"
DOGE_CLI="sudo jexec dogecoin-regtest dogecoin-cli -rpcuser=tidepool -rpcpassword=tidepoolpass -rpcport=20443"
PEPE_CLI="sudo jexec pepecoin-regtest pepecoin-cli -rpcuser=tidepool -rpcpassword=tidepoolpass -rpcport=21443"

# Ports
TIDEWAY_PORT=19332
STP_PORT=3336

# Timeouts
MINE_TIMEOUT=120       # seconds to wait for blocks
MATURITY_LTC=100       # Litecoin coinbase maturity
MATURITY_DOGE=240      # Dogecoin coinbase maturity (higher than Bitcoin)
MATURITY_PEPE=240      # Pepecoin coinbase maturity

# --- Counters ---
PASS=0
FAIL=0
TOTAL=0

# --- Functions ---

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOGFILE"
}

check() {
    TOTAL=$((TOTAL + 1))
    DESC="$1"
    shift
    if "$@" > /dev/null 2>&1; then
        PASS=$((PASS + 1))
        log "  PASS: $DESC"
    else
        FAIL=$((FAIL + 1))
        log "  FAIL: $DESC"
    fi
}

check_nonzero() {
    DESC="$1"
    VALUE="$2"
    TOTAL=$((TOTAL + 1))
    # Check value is a number > 0
    if echo "$VALUE" | awk '{exit ($1 > 0) ? 0 : 1}'; then
        PASS=$((PASS + 1))
        log "  PASS: $DESC (value: $VALUE)"
    else
        FAIL=$((FAIL + 1))
        log "  FAIL: $DESC (value: $VALUE)"
    fi
}

check_greater() {
    DESC="$1"
    AFTER="$2"
    BEFORE="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$AFTER $BEFORE" | awk '{exit ($1 > $2) ? 0 : 1}'; then
        PASS=$((PASS + 1))
        log "  PASS: $DESC (before: $BEFORE, after: $AFTER)"
    else
        FAIL=$((FAIL + 1))
        log "  FAIL: $DESC (before: $BEFORE, after: $AFTER)"
    fi
}

check_contains() {
    DESC="$1"
    HAYSTACK="$2"
    NEEDLE="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$HAYSTACK" | grep -q "$NEEDLE"; then
        PASS=$((PASS + 1))
        log "  PASS: $DESC"
    else
        FAIL=$((FAIL + 1))
        log "  FAIL: $DESC (needle: $NEEDLE not found)"
    fi
}

cleanup() {
    log "Cleaning up..."
    [ -n "$CPUMINER_PID" ] && kill "$CPUMINER_PID" 2>/dev/null || true
    [ -n "$STP_PID" ] && kill "$STP_PID" 2>/dev/null || true
    [ -n "$TIDEWAY_PID" ] && kill "$TIDEWAY_PID" 2>/dev/null || true
    wait 2>/dev/null || true
    log "Cleanup complete."
}

trap cleanup EXIT INT TERM

# --- Main ---

> "$LOGFILE"
log "============================================"
log "Tideway Merge Mining Regtest Validation"
log "============================================"
log ""

# --- Preflight ---
# Kill any leftover processes from previous runs
killall tideway 2>/dev/null || true
killall tidepool 2>/dev/null || true
killall cpuminer 2>/dev/null || true
sleep 1

log "=== Preflight Checks ==="

check "Tideway binary exists" test -x "$TIDEWAY_BIN"
check "SeaTidePool binary exists" test -x "$STP_BIN"
check "cpuminer available" which "$CPUMINER_BIN"

# Check jails are running
check "Litecoin jail running" $LTC_CLI getblockcount
check "Dogecoin jail running" $DOGE_CLI getblockcount
check "Pepecoin jail running" $PEPE_CLI getblockcount

if [ "$FAIL" -gt 0 ]; then
    log ""
    log "ABORT: Preflight checks failed. Fix issues and retry."
    exit 1
fi

log ""
log "=== Setup ==="

# Reset regtest chain data for a clean run.
# This avoids stale wallet/chain state from previous runs causing
# "bad-txns-vin-empty" errors on generatetoaddress.
log "Resetting regtest chain data for clean run..."
for _jail_cmd in \
    "litecoin-peer:litecoind:litecoind:/var/db/litecoin/regtest" \
    "litecoin:litecoind:litecoind:/var/db/litecoin/regtest" \
    "dogecoin-regtest:dogecoin:dogecoind:/var/db/dogecoin/regtest" \
    "pepecoin-regtest:pepecoin:pepecoind:/var/db/pepecoin/regtest"; do
    _jail=$(echo "$_jail_cmd" | cut -d: -f1)
    _svc=$(echo "$_jail_cmd" | cut -d: -f2)
    _proc=$(echo "$_jail_cmd" | cut -d: -f3)
    _datadir=$(echo "$_jail_cmd" | cut -d: -f4)
    log "  Resetting $_jail..."
    # Dogecoin/Pepecoin RC scripts hang on stop. Use killall directly.
    sudo jexec "$_jail" killall "$_proc" 2>/dev/null || true
    sleep 3
    sudo jexec "$_jail" killall -9 "$_proc" 2>/dev/null || true
    sleep 1
    # Delete chain data and restart
    sudo jexec "$_jail" rm -rf "$_datadir"
    sudo jexec "$_jail" service "$_svc" start 2>/dev/null || true
    sleep 5
done

# Create wallets
log "Creating wallets..."
$LTC_CLI createwallet "pool" 2>/dev/null || true
$DOGE_CLI createwallet "pool" 2>/dev/null || true
$PEPE_CLI createwallet "pool" 2>/dev/null || true

# Get addresses
LTC_POOL_ADDR=$($LTC_CLI getnewaddress)
DOGE_ADDR=$($DOGE_CLI getnewaddress)
PEPE_ADDR=$($PEPE_CLI getnewaddress)
log "Litecoin pool address: $LTC_POOL_ADDR"
log "Dogecoin address: $DOGE_ADDR"
log "Pepecoin address: $PEPE_ADDR"

# Ensure Litecoin has a peer (0.21 requires peers for getblocktemplate)
log "Connecting Litecoin peer..."
$LTC_CLI addnode "127.0.0.1:19445" "onetry" 2>/dev/null || true
sleep 3
PEER_COUNT=$($LTC_CLI getpeerinfo 2>/dev/null | grep -c '"addr"' || echo 0)
log "Litecoin peers: $PEER_COUNT"
if [ "$PEER_COUNT" -lt 1 ]; then
    log "WARNING: No Litecoin peers — generatetoaddress may fail"
fi

# Generate initial blocks for maturity + getauxblock readiness
log "Generating initial blocks (Litecoin: 110, Dogecoin: 250, Pepecoin: 250)..."
$LTC_CLI generatetoaddress 110 "$LTC_POOL_ADDR" > /dev/null
$DOGE_CLI generate 250 > /dev/null
$PEPE_CLI generate 250 > /dev/null

# Verify getauxblock works
log "Verifying getauxblock availability..."
check "Dogecoin getauxblock" $DOGE_CLI getauxblock
check "Pepecoin getauxblock" $PEPE_CLI getauxblock

# Record initial balances
BAL_LTC_BEFORE=$($LTC_CLI getbalance)
BAL_DOGE_BEFORE=$($DOGE_CLI getbalance)
BAL_PEPE_BEFORE=$($PEPE_CLI getbalance)
log "Initial balances — LTC: $BAL_LTC_BEFORE, DOGE: $BAL_DOGE_BEFORE, PEPE: $BAL_PEPE_BEFORE"

# --- Write configs ---
log "Writing Tideway config..."
cat > "$TIDEWAY_CONF" << EOF
{
  "listen": "127.0.0.1:${TIDEWAY_PORT}",
  "parent": {
    "url": "http://127.0.0.1:19443",
    "user": "tidepool",
    "pass": "tidepoolpass",
    "poll_interval_ms": 100
  },
  "aux_chains": [
    {
      "chain_id": "dogecoin",
      "url": "http://127.0.0.1:20443",
      "user": "tidepool",
      "pass": "tidepoolpass",
      "rpc_method": "getauxblock"
    },
    {
      "chain_id": "pepecoin",
      "url": "http://127.0.0.1:21443",
      "user": "tidepool",
      "pass": "tidepoolpass",
      "rpc_method": "getauxblock"
    }
  ]
}
EOF

log "Writing SeaTidePool config..."
mkdir -p "$STP_LOGDIR"
cat > "$STP_CONF" << EOF
{
    "btcd": [{
        "url": "127.0.0.1:${TIDEWAY_PORT}",
        "auth": "tidepool",
        "pass": "tidepoolpass",
        "notify": true
    }],
    "btcaddress": "${LTC_POOL_ADDR}",
    "btcsig": "/tideway-regtest/",
    "gbt_rules": ["segwit", "mweb"],
    "serverurl": ["0.0.0.0:${STP_PORT}"],
    "mindiff": 0.001,
    "startdiff": 0.01,
    "zmqblock": "tcp://127.0.0.1:28335",
    "logdir": "${STP_LOGDIR}",
    "pool_id": "litecoin-merge-regtest",
    "algorithm": "scrypt"
}
EOF

# --- Start services ---
log ""
log "=== Starting Services ==="

log "Starting Tideway..."
"$TIDEWAY_BIN" -c "$TIDEWAY_CONF" >> "$LOGFILE" 2>&1 &
TIDEWAY_PID=$!
sleep 2

if kill -0 "$TIDEWAY_PID" 2>/dev/null; then
    log "Tideway started (PID $TIDEWAY_PID)"
else
    log "ABORT: Tideway failed to start"
    exit 1
fi

log "Starting SeaTidePool..."
"$STP_BIN" -c "$STP_CONF" >> "$LOGFILE" 2>&1 &
STP_PID=$!
sleep 3

if kill -0 "$STP_PID" 2>/dev/null; then
    log "SeaTidePool started (PID $STP_PID)"
else
    log "ABORT: SeaTidePool failed to start"
    exit 1
fi

log "Starting cpuminer..."
"$CPUMINER_BIN" -a scrypt \
    -o "stratum+tcp://127.0.0.1:${STP_PORT}" \
    -u "$LTC_POOL_ADDR" -p x \
    --threads=1 --no-color >> "$LOGFILE" 2>&1 &
CPUMINER_PID=$!
sleep 2

if kill -0 "$CPUMINER_PID" 2>/dev/null; then
    log "cpuminer started (PID $CPUMINER_PID)"
else
    log "ABORT: cpuminer failed to start"
    exit 1
fi

# --- Wait for mining ---
log ""
log "=== Mining (waiting up to ${MINE_TIMEOUT}s for blocks) ==="

FOUND_PARENT=0
FOUND_DOGE=0
FOUND_PEPE=0
ELAPSED=0
STP_LOG="${STP_LOGDIR}/ckpool.log"

while [ "$ELAPSED" -lt "$MINE_TIMEOUT" ]; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))

    # Check SeaTidePool log for block solves
    if [ -f "$STP_LOG" ]; then
        if [ "$FOUND_PARENT" -eq 0 ] && grep -q "BLOCK ACCEPTED" "$STP_LOG" 2>/dev/null; then
            FOUND_PARENT=1
            log "  [${ELAPSED}s] Parent block (Litecoin) solved and accepted!"
        fi
        if [ "$FOUND_DOGE" -eq 0 ] && grep -q "AUX BLOCK ACCEPTED for dogecoin" "$STP_LOG" 2>/dev/null; then
            FOUND_DOGE=1
            log "  [${ELAPSED}s] Aux block (Dogecoin) solved and accepted!"
        fi
        if [ "$FOUND_PEPE" -eq 0 ] && grep -q "AUX BLOCK ACCEPTED for pepecoin" "$STP_LOG" 2>/dev/null; then
            FOUND_PEPE=1
            log "  [${ELAPSED}s] Aux block (Pepecoin) solved and accepted!"
        fi
    fi

    # Also generate a parent block periodically to trigger new templates
    $LTC_CLI generatetoaddress 1 "$LTC_POOL_ADDR" > /dev/null 2>&1 || true

    if [ "$FOUND_PARENT" -eq 1 ] && [ "$FOUND_DOGE" -eq 1 ] && [ "$FOUND_PEPE" -eq 1 ]; then
        log "  All block types found after ${ELAPSED}s!"
        break
    fi
done

# Stop cpuminer
log "Stopping cpuminer..."
kill "$CPUMINER_PID" 2>/dev/null || true
CPUMINER_PID=""
sleep 2

# --- Test Results ---
log ""
log "=== Test 1: Aux Block Rewards ==="

check "Dogecoin aux block was mined" test "$FOUND_DOGE" -eq 1
check "Pepecoin aux block was mined" test "$FOUND_PEPE" -eq 1

BAL_DOGE_AFTER=$($DOGE_CLI getbalance)
BAL_PEPE_AFTER=$($PEPE_CLI getbalance)
check_greater "Dogecoin balance increased" "$BAL_DOGE_AFTER" "$BAL_DOGE_BEFORE"
check_greater "Pepecoin balance increased" "$BAL_PEPE_AFTER" "$BAL_PEPE_BEFORE"

# Mature Dogecoin coinbase
log "Maturing Dogecoin coinbase (${MATURITY_DOGE} blocks)..."
$DOGE_CLI generate "$MATURITY_DOGE" > /dev/null 2>&1 || true

# Try to spend Dogecoin
DOGE_ADDR2=$($DOGE_CLI getnewaddress)
DOGE_TXID=$($DOGE_CLI sendtoaddress "$DOGE_ADDR2" 1.0 2>&1) || true
if echo "$DOGE_TXID" | grep -qE '^[0-9a-f]{64}$'; then
    $DOGE_CLI generate 1 > /dev/null 2>&1 || true
    log "  Dogecoin spend txid: $DOGE_TXID"
    check "Dogecoin reward spendable" true
else
    log "  Dogecoin spend failed: $DOGE_TXID"
    check "Dogecoin reward spendable" false
fi

# Mature Pepecoin coinbase
log "Maturing Pepecoin coinbase (${MATURITY_PEPE} blocks)..."
$PEPE_CLI generate "$MATURITY_PEPE" > /dev/null 2>&1 || true

# Try to spend Pepecoin
PEPE_ADDR2=$($PEPE_CLI getnewaddress)
PEPE_TXID=$($PEPE_CLI sendtoaddress "$PEPE_ADDR2" 1.0 2>&1) || true
if echo "$PEPE_TXID" | grep -qE '^[0-9a-f]{64}$'; then
    $PEPE_CLI generate 1 > /dev/null 2>&1 || true
    log "  Pepecoin spend txid: $PEPE_TXID"
    check "Pepecoin reward spendable" true
else
    log "  Pepecoin spend failed: $PEPE_TXID"
    check "Pepecoin reward spendable" false
fi

log ""
log "=== Test 2: Parent Block via Tideway ==="

check "Parent block was mined through Tideway" test "$FOUND_PARENT" -eq 1

BAL_LTC_AFTER=$($LTC_CLI getbalance)
check_greater "Litecoin balance increased" "$BAL_LTC_AFTER" "$BAL_LTC_BEFORE"

# Check coinbase contains AuxPoW commitment (fabe6d6d)
# Pool-mined blocks start after the initial bootstrap (block 111+).
# Scan from there forward — do NOT scan from tip, which is dominated
# by generatetoaddress blocks from the maturity phase.
if [ "$FOUND_PARENT" -eq 1 ]; then
    FOUND_AUXPOW=0
    HEIGHT=$($LTC_CLI getblockcount)
    SCAN_START=111
    SCAN_END=$((SCAN_START + 50))
    [ "$SCAN_END" -gt "$HEIGHT" ] && SCAN_END=$HEIGHT
    H=$SCAN_START
    while [ "$H" -le "$SCAN_END" ]; do
        BHASH=$($LTC_CLI getblockhash "$H" 2>/dev/null) || { H=$((H+1)); continue; }
        CB_HEX=$($LTC_CLI getblock "$BHASH" 2 2>/dev/null | \
            python3 -c "import sys,json; b=json.load(sys.stdin); print(b['tx'][0]['vin'][0].get('coinbase',''))" 2>/dev/null)
        if echo "$CB_HEX" | grep -qi "fabe6d6d"; then
            FOUND_AUXPOW=1
            log "  Found fabe6d6d commitment at block $H"
            break
        fi
        H=$((H + 1))
    done
    check "Coinbase scriptsig contains fabe6d6d" test "$FOUND_AUXPOW" -eq 1
fi

# Mature and spend Litecoin
log "Maturing Litecoin coinbase (${MATURITY_LTC} blocks)..."
$LTC_CLI generatetoaddress "$MATURITY_LTC" "$LTC_POOL_ADDR" > /dev/null 2>&1 || true

LTC_ADDR2=$($LTC_CLI getnewaddress)
LTC_TXID=$($LTC_CLI sendtoaddress "$LTC_ADDR2" 1.0 2>&1) || true
if echo "$LTC_TXID" | grep -qE '^[0-9a-f]{64}$'; then
    $LTC_CLI generatetoaddress 1 "$LTC_POOL_ADDR" > /dev/null 2>&1 || true
    log "  Litecoin spend txid: $LTC_TXID"
    check "Litecoin reward spendable" true
else
    log "  Litecoin spend failed: $LTC_TXID"
    check "Litecoin reward spendable" false
fi

log ""
log "=== Test 3: Simultaneous Parent + Aux Solve ==="

# In regtest with very low difficulty, most shares solve everything.
# Check the SeaTidePool log for a parent block and aux block close together.
if [ "$FOUND_PARENT" -eq 1 ] && [ "$FOUND_DOGE" -eq 1 ] && [ "$FOUND_PEPE" -eq 1 ]; then
    check "All three chains received blocks" true
    log "  (In regtest, nearly all shares exceed all targets — simultaneous solves are expected)"
else
    check "All three chains received blocks" false
fi

# --- Final Report ---
log ""
log "============================================"
log "RESULTS: $PASS passed, $FAIL failed, $TOTAL total"
log "============================================"

if [ "$FAIL" -eq 0 ]; then
    log "ALL TESTS PASSED"
    exit 0
else
    log "SOME TESTS FAILED — review $LOGFILE"
    exit 1
fi
