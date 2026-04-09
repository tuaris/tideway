# Merge Mining Regtest Validation

Pre-deployment test plan to verify end-to-end merge mining with Tideway,
including block rewards, wallet balances, and spendability.

## Prerequisites

Regtest jails on freebsd-dev1 (all `ip4=inherit`, `127.0.0.1`):

| Chain    | Jail             | RPC Port | ZMQ Port | RPC User  | RPC Pass      |
|----------|------------------|----------|----------|-----------|---------------|
| Litecoin | litecoin         | 19443    | 28335    | tidepool  | tidepoolpass  |
| Dogecoin | dogecoin-regtest | 20443    | 28336    | tidepool  | tidepoolpass  |
| Pepecoin | pepecoin-regtest | 21443    | 28337    | tidepool  | tidepoolpass  |

Software:
- SeaTidePool (installed from morante-plus package, or local build)
- Tideway (local build at `zig-out/bin/tideway`)
- cpuminer (any CPU miner that speaks Stratum)

## Setup

### 1. Start regtest daemons

```sh
sudo jexec litecoin         service litecoind start
sudo jexec dogecoin-regtest service dogecoind start
sudo jexec pepecoin-regtest service pepecoind start
```

### 2. Create wallets (if not already done)

```sh
# Litecoin
sudo jexec litecoin litecoin-cli -regtest -rpcuser=tidepool -rpcpassword=tidepoolpass createwallet "pool"
LTC_ADDR=$(sudo jexec litecoin litecoin-cli -regtest -rpcuser=tidepool -rpcpassword=tidepoolpass getnewaddress)
echo "Litecoin address: $LTC_ADDR"

# Dogecoin
sudo jexec dogecoin-regtest dogecoin-cli -regtest -rpcuser=tidepool -rpcpassword=tidepoolpass getnewaddress
# Note: getauxblock uses the daemon's default wallet address automatically

# Pepecoin
sudo jexec pepecoin-regtest pepecoin-cli -regtest -rpcuser=tidepool -rpcpassword=tidepoolpass getnewaddress
```

### 3. Generate initial blocks for maturity

Each chain needs 100+ blocks so that coinbases are mature and `getauxblock` works:

```sh
sudo jexec litecoin litecoin-cli -regtest -rpcuser=tidepool -rpcpassword=tidepoolpass generatetoaddress 110 $LTC_ADDR
sudo jexec dogecoin-regtest dogecoin-cli -regtest -rpcuser=tidepool -rpcpassword=tidepoolpass generate 210
sudo jexec pepecoin-regtest pepecoin-cli -regtest -rpcuser=tidepool -rpcpassword=tidepoolpass generate 210
```

### 4. Record initial balances

```sh
echo "=== Initial Balances ==="
echo -n "Litecoin: "; sudo jexec litecoin litecoin-cli -regtest -rpcuser=tidepool -rpcpassword=tidepoolpass getbalance
echo -n "Dogecoin: "; sudo jexec dogecoin-regtest dogecoin-cli -regtest -rpcuser=tidepool -rpcpassword=tidepoolpass getbalance
echo -n "Pepecoin: "; sudo jexec pepecoin-regtest pepecoin-cli -regtest -rpcuser=tidepool -rpcpassword=tidepoolpass getbalance
```

### 5. Start Tideway

```sh
cat > /tmp/tideway-regtest.conf << 'EOF'
{
  "listen": "127.0.0.1:19332",

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

./zig-out/bin/tideway -c /tmp/tideway-regtest.conf
```

### 6. Start SeaTidePool

```sh
cat > /tmp/tidepool-merge-regtest.conf << 'EOF'
{
    "btcd": [{
        "url": "127.0.0.1:19332",
        "auth": "tidepool",
        "pass": "tidepoolpass",
        "notify": true
    }],
    "btcaddress": "<LTC_ADDR from step 2>",
    "btcsig": "/tideway-regtest/",
    "serverurl": ["0.0.0.0:3336"],
    "mindiff": 0.001,
    "startdiff": 0.01,
    "zmqblock": "tcp://127.0.0.1:28335",
    "logdir": "/tmp/tidepool-merge-regtest",
    "pool_id": "litecoin-merge-regtest"
}
EOF

mkdir -p /tmp/tidepool-merge-regtest
./bin/tidepool -c /tmp/tidepool-merge-regtest.conf
```

### 7. Start CPU miner

```sh
cpuminer -a scrypt -o stratum+tcp://127.0.0.1:3336 -u $LTC_ADDR -p x --threads=1
```

---

## Test Cases

### Test 1: Aux Block Mined — Reward Visible and Spendable

**What to verify:** When a share meets an aux chain target, the aux daemon
accepts the block and the reward appears in the daemon's wallet.

**Steps:**

1. Mine with cpuminer until SeaTidePool logs show:
   ```
   Aux chain dogecoin block solve! diff X >= Y
   AUX BLOCK ACCEPTED for dogecoin!
   ```

2. Check Dogecoin balance increased:
   ```sh
   sudo jexec dogecoin-regtest dogecoin-cli -regtest -rpcuser=tidepool -rpcpassword=tidepoolpass getbalance
   ```

3. Mature the coinbase (generate 100 blocks on Dogecoin):
   ```sh
   sudo jexec dogecoin-regtest dogecoin-cli -regtest -rpcuser=tidepool -rpcpassword=tidepoolpass generate 100
   ```

4. Verify balance is spendable (send to self):
   ```sh
   DOGE_ADDR=$(sudo jexec dogecoin-regtest dogecoin-cli -regtest -rpcuser=tidepool -rpcpassword=tidepoolpass getnewaddress)
   sudo jexec dogecoin-regtest dogecoin-cli -regtest -rpcuser=tidepool -rpcpassword=tidepoolpass sendtoaddress $DOGE_ADDR 1.0
   ```

5. Confirm transaction:
   ```sh
   sudo jexec dogecoin-regtest dogecoin-cli -regtest -rpcuser=tidepool -rpcpassword=tidepoolpass generate 1
   sudo jexec dogecoin-regtest dogecoin-cli -regtest -rpcuser=tidepool -rpcpassword=tidepoolpass getbalance
   ```

**Expected:** Balance increases after aux block, send-to-self succeeds.

**Repeat for Pepecoin** with the pepecoin-regtest jail.

---

### Test 2: Parent Block Mined via Tideway — Reward Visible and Spendable

**What to verify:** When a share meets the parent chain (Litecoin) difficulty,
the block is submitted through Tideway → litecoind and the reward goes to
SeaTidePool's `btcaddress`.

**Steps:**

1. Mine with cpuminer until SeaTidePool logs show:
   ```
   BLOCK SOLVED!
   Block accepted!
   ```

2. Check Litecoin balance increased:
   ```sh
   sudo jexec litecoin litecoin-cli -regtest -rpcuser=tidepool -rpcpassword=tidepoolpass getbalance
   ```

3. Verify the block's coinbase pays to `btcaddress`:
   ```sh
   HEIGHT=$(sudo jexec litecoin litecoin-cli -regtest -rpcuser=tidepool -rpcpassword=tidepoolpass getblockcount)
   HASH=$(sudo jexec litecoin litecoin-cli -regtest -rpcuser=tidepool -rpcpassword=tidepoolpass getblockhash $HEIGHT)
   sudo jexec litecoin litecoin-cli -regtest -rpcuser=tidepool -rpcpassword=tidepoolpass getblock $HASH 2 | head -60
   ```
   Confirm coinbase vout[0] address matches `btcaddress`.

4. Verify the coinbase scriptsig contains `fabe6d6d` (AuxPoW commitment):
   ```sh
   # In the getblock verbosity=2 output, check the coinbase vin[0].coinbase hex
   # It should contain fabe6d6d followed by 64 hex chars (merkle root) + 8 + 8
   ```

5. Mature the coinbase and spend:
   ```sh
   sudo jexec litecoin litecoin-cli -regtest -rpcuser=tidepool -rpcpassword=tidepoolpass generatetoaddress 100 $LTC_ADDR
   LTC_ADDR2=$(sudo jexec litecoin litecoin-cli -regtest -rpcuser=tidepool -rpcpassword=tidepoolpass getnewaddress)
   sudo jexec litecoin litecoin-cli -regtest -rpcuser=tidepool -rpcpassword=tidepoolpass sendtoaddress $LTC_ADDR2 1.0
   sudo jexec litecoin litecoin-cli -regtest -rpcuser=tidepool -rpcpassword=tidepoolpass generatetoaddress 1 $LTC_ADDR
   ```

**Expected:** Parent block reward goes to pool's btcaddress, coinbase contains
`fabe6d6d` commitment, reward is spendable after maturity.

---

### Test 3: Simultaneous Parent + Aux Block Solve

**What to verify:** A single share can solve both the parent chain AND one or
more aux chains simultaneously. Both rewards are received.

**Note:** In regtest with very low difficulty, this should happen naturally —
most shares will exceed both the parent and aux targets.

**Steps:**

1. Record balances on all three chains before mining.

2. Mine a small number of blocks (cpuminer should solve quickly in regtest).

3. Check SeaTidePool logs for both:
   ```
   BLOCK SOLVED!          (parent)
   Aux chain dogecoin block solve!   (aux)
   ```
   occurring on the same share (same workinfoid/nonce).

4. Verify balances increased on ALL chains:
   ```sh
   echo -n "Litecoin: "; sudo jexec litecoin litecoin-cli -regtest -rpcuser=tidepool -rpcpassword=tidepoolpass getbalance
   echo -n "Dogecoin: "; sudo jexec dogecoin-regtest dogecoin-cli -regtest -rpcuser=tidepool -rpcpassword=tidepoolpass getbalance
   echo -n "Pepecoin: "; sudo jexec pepecoin-regtest pepecoin-cli -regtest -rpcuser=tidepool -rpcpassword=tidepoolpass getbalance
   ```

5. Mature and spend on each chain (repeat step 3-5 from Tests 1 and 2).

**Expected:** Single share produces rewards on parent + both aux chains. All
three rewards are independently spendable after maturity.

---

## Verification Checklist

| # | Test Case | Status |
|---|-----------|--------|
| 1a | Dogecoin aux block mined | ☐ |
| 1b | Dogecoin reward in wallet | ☐ |
| 1c | Dogecoin reward spendable (send to self) | ☐ |
| 1d | Pepecoin aux block mined | ☐ |
| 1e | Pepecoin reward in wallet | ☐ |
| 1f | Pepecoin reward spendable (send to self) | ☐ |
| 2a | Parent (Litecoin) block mined through Tideway | ☐ |
| 2b | Parent reward at btcaddress | ☐ |
| 2c | Coinbase scriptsig contains fabe6d6d commitment | ☐ |
| 2d | Parent reward spendable (send to self) | ☐ |
| 3a | Simultaneous parent + aux solve (same share) | ☐ |
| 3b | All three chain balances increased | ☐ |
| 3c | All three rewards independently spendable | ☐ |

## Troubleshooting

### getauxblock returns "not yet available"
Aux chains need enough blocks generated before getauxblock works (~200 for
Dogecoin/Pepecoin). Generate more blocks on the aux chain.

### No aux block solves
Regtest difficulty is extremely low — every share should solve aux chains.
If not, check Tideway logs for errors contacting aux daemons.

### "Aux POW missing chain merkle root in parent coinbase"
Snapshot race condition. Ensure Tideway is running the v0.2.0 ring buffer fix.

### Parent block rejected
Check that litecoind is receiving the block through Tideway (not directly).
Verify `btcd.url` in SeaTidePool config points at Tideway's listen address.

### Coinbase not spendable after 100 blocks
Litecoin regtest requires 100 confirmations for coinbase maturity.
Dogecoin requires 240 confirmations. Generate enough blocks.
