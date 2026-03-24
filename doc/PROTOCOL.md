# Generator Unix Socket Protocol

Tideway implements ckpool's generator Unix socket protocol. The stratifier sends newline-delimited text messages to the generator socket and reads a single-line response.

Each message is a short-lived connection: connect → send → read response → close.

## Message Reference

### ping

Health check. Used by the `extgen_poll` thread to detect when the external generator is ready.

**Request:** `ping`
**Response:** `pong`

### getbase

Request a block template (equivalent to `getblocktemplate` + AuxPoW data).

**Request:** `getbase`
**Response:** JSON object with standard GBT fields plus optional AuxPoW fields:

```json
{
  "previousblockhash": "00000000000000000002a7c4...",
  "target": "0000000000000000000456...",
  "version": 536870912,
  "curtime": 1711234567,
  "bits": "1a0fffff",
  "height": 850000,
  "coinbasevalue": 312500000,
  "coinbaseaux": {"flags": ""},
  "rules": ["csv", "segwit"],
  "transactions": [...],
  "diff": 12345678.90,
  "ntime": "660e4f07",
  "bbversion": "20000000",
  "nbit": "1a0fffff",

  "aux_merkle_root": "a1b2c3d4e5f6...",
  "aux_tree_size": 4,
  "aux_tree_nonce": 0,
  "n_aux_chains": 3,
  "aux_chains": [
    {
      "chain_id": "dogecoin",
      "hash": "...",
      "target": "0000ffff00000000...",
      "diff": 12345.678,
      "slot": 0
    }
  ]
}
```

When no aux chains are configured, the `aux_*` fields are omitted (backward compatible with unpatched ckpool).

### getbest

Get the best (most recent) parent chain block hash.

**Request:** `getbest`
**Response:** 64-character hex hash, or `notify` (if using ZMQ notifications), or `failed`

### getlast

Get the latest parent chain block hash by height.

**Request:** `getlast`
**Response:** 64-character hex hash, or `failed`

### submitblock

Submit a solved parent chain block.

**Request:** `submitblock:{block_hash}{separator}{block_hex_data}`
**Response:** Sends `block:{hash}` or `noblock:{hash}` to the stratifier socket

### checkaddr

Validate an address on the parent chain.

**Request:** `checkaddr:{address}`
**Response:** JSON object with `isvalid`, `isscript`, `iswitness` fields

### checktxn

Validate a transaction (coinbase check).

**Request:** `checktxn:{transaction_hex}`
**Response:** JSON result from `testmempoolaccept`

### submitauxblock (NEW — merge mining)

Submit an aux chain block solve. Sent via ZMQ PUSH (fire-and-forget) or Unix socket.

**Request:** `submitauxblock:{chain_id}:{aux_hash}:{coinbase_hex}:{header_hex}:{nonce}`
**Response:** None (fire-and-forget). Tideway constructs the AuxPoW proof internally and submits to the aux chain daemon.

### reconnect

Signal to refresh all daemon connections.

**Request:** `reconnect`
**Response:** None (fire-and-forget)

### loglevel

Set the log verbosity level.

**Request:** `loglevel={N}`
**Response:** None (fire-and-forget)

## ZMQ PULL Socket

In addition to the Unix socket, Tideway listens on a ZMQ PULL socket (default: `ipc:///tmp/ckpool/generator.zmq`) for fire-and-forget messages. This provides non-blocking, buffered delivery for:

- `submitauxblock`
- `submittxn`
- `reconnect`
- `loglevel`

The ZMQ transport is preferred for these messages because it survives brief disconnections (messages are queued) and doesn't block the sender.
