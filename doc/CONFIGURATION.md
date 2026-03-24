# Configuration Reference

Tideway reads a JSON configuration file (default: `tideway.conf`).

## Top-Level Options

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `listen` | string | `"127.0.0.1:8332"` | HTTP listen address and port for the JSON-RPC proxy |
| `zmq_pub` | string | null | ZMQ PUB endpoint for unified block notifications (not yet implemented) |

## Parent Chain (`parent`)

The parent chain daemon that Tideway proxies requests to.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `url` | string | **required** | JSON-RPC URL (e.g., `http://127.0.0.1:9332`) |
| `user` | string | `""` | RPC username |
| `pass` | string | `""` | RPC password |
| `poll_interval_ms` | integer | `100` | Aux chain template refresh interval in milliseconds (kqueue timer) |
| `zmq_hashblock` | string | null | ZMQ endpoint for block notifications (not yet implemented) |

## Auxiliary Chains (`aux_chains`)

Array of aux chain daemon configurations. When this array is non-empty, Tideway enriches `getblocktemplate` responses with AuxPoW data.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `chain_id` | string | **required** | Unique identifier for this chain (e.g., `"dogecoin"`) |
| `url` | string | **required** | JSON-RPC URL (e.g., `http://127.0.0.1:22555`) |
| `user` | string | `""` | RPC username |
| `pass` | string | `""` | RPC password |
| `rpc_method` | string | `"getauxblock"` | RPC method for aux templates: `"getauxblock"` (Namecoin-style) or `"createauxblock"` (newer) |

## Example

```json
{
  "listen": "127.0.0.1:9332",

  "parent": {
    "url": "http://127.0.0.1:19332",
    "user": "litecoinrpc",
    "pass": "password",
    "poll_interval_ms": 100
  },

  "aux_chains": [
    {
      "chain_id": "dogecoin",
      "url": "http://127.0.0.1:22555",
      "user": "dogerpc",
      "pass": "password",
      "rpc_method": "getauxblock"
    },
    {
      "chain_id": "pepecoin",
      "url": "http://127.0.0.1:33873",
      "user": "peperpc",
      "pass": "password"
    },
    {
      "chain_id": "bells",
      "url": "http://127.0.0.1:19918",
      "user": "bellsrpc",
      "pass": "password"
    }
  ]
}
```

## Pool Configuration

Point the pool's `btcd` URL at Tideway's listen address instead of the parent daemon. For SeaTidePool / ckpool:

```json
{
  "btcd": [{
    "url": "127.0.0.1:9332",
    "auth": "litecoinrpc",
    "pass": "password"
  }]
}
```

Tideway is transparent — the pool's generator connects to it as if it were the parent chain daemon. No special pool configuration flags are needed.
