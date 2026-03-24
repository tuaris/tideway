# HTTP JSON-RPC Proxy Protocol

Tideway is a transparent HTTP JSON-RPC proxy. The pool's generator connects to Tideway on its configured listen address and sends standard Bitcoin JSON-RPC requests over HTTP/1.1. Tideway forwards these to the parent chain daemon and returns the response.

Each request is a short-lived HTTP connection (Connection: close).

## Request Format

Standard HTTP POST with JSON-RPC body, identical to what the pool would send directly to the parent daemon:

```
POST / HTTP/1.1
Host: 127.0.0.1:9332
Content-Type: application/json
Content-Length: 90
Authorization: Basic <base64>

{"method":"getblocktemplate","params":[{"capabilities":["coinbasetxn","workid","coinbase/append"],"rules":["segwit"]}]}
```

Tideway also accepts ckpool's non-standard `\n` line endings (instead of `\r\n`).

## Response Format

Standard HTTP/1.1 response with JSON body. A trailing `\n` is appended to the body if not already present (required by ckpool's `read_socket_line()`).

## Intercepted Methods

### getblocktemplate

When aux chains are configured, Tideway enriches the `getblocktemplate` response before returning it to the pool.

**Enrichment:**

1. The 44-byte AuxPoW commitment (hex-encoded) is appended to the `coinbaseaux.flags` value
2. Aux chain metadata fields are added to the `result` object

**Added fields:**

```json
{
  "result": {
    "coinbaseaux": {"flags": "<original_flags><auxpow_commitment_hex>"},

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
}
```

When no aux chains are configured, the response passes through unmodified.

The pool parses `coinbaseaux.flags` and includes it in the coinbase scriptsig as it normally would — the AuxPoW commitment is carried transparently via this standard GBT mechanism.

### submitauxblock

Custom JSON-RPC method sent by the pool when a share meets an aux chain's target.

**Request:**

```json
{"method":"submitauxblock","params":["<chain_id>:<aux_hash>:<coinbase_hex>:<header_hex>:<nonce>"]}
```

**Response:**

```json
{"result":null,"error":null,"id":0}
```

Tideway constructs the full AuxPoW proof from the submitted data and forwards it to the appropriate aux chain daemon via `submitauxblock` RPC.

## Transparent Proxy Methods

All other JSON-RPC methods pass through to the parent chain daemon without modification. Common methods used by ckpool's generator:

| Method | Purpose |
|--------|---------|
| `getblockcount` | Block height polling |
| `getblockhash` | Block hash by height |
| `getbestblockhash` | Latest block hash |
| `validateaddress` | Address validation |
| `submitblock` | Parent block submission |
| `testmempoolaccept` | Coinbase transaction check |

## Implementation Notes

- Tideway uses a **kqueue event loop** on the main thread for event-driven accept and timer-based aux template refresh
- A **4-thread worker pool** processes requests concurrently (blocking I/O to parent daemon happens in worker threads)
- The aux chain template refresh interval is configurable via `poll_interval_ms`
- Request size limit: 256 KB
- Response size limit from parent daemon: 4 MB
