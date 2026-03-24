# Configuration Reference

Tideway reads a JSON configuration file (default: `tideway.conf`).

## Top-Level Options

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `socket_path` | string | `/tmp/ckpool/generator` | Path for the generator Unix domain socket |
| `zmq_pull` | string | `ipc:///tmp/ckpool/generator.zmq` | ZMQ PULL endpoint for fire-and-forget messages |

## Parent Chain (`parent`)

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `url` | string | **required** | JSON-RPC URL (e.g., `http://127.0.0.1:9332`) |
| `user` | string | `""` | RPC username |
| `pass` | string | `""` | RPC password |
| `poll_interval_ms` | integer | `100` | Block polling interval in milliseconds |
| `zmq_hashblock` | string | null | ZMQ endpoint for block notifications (e.g., `tcp://127.0.0.1:28332`) |

## Auxiliary Chains (`aux_chains`)

Array of aux chain daemon configurations.

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
  "socket_path": "/tmp/ckpool/generator",
  "zmq_pull": "ipc:///tmp/ckpool/generator.zmq",

  "parent": {
    "url": "http://127.0.0.1:9332",
    "user": "litecoinrpc",
    "pass": "password",
    "poll_interval_ms": 100,
    "zmq_hashblock": "tcp://127.0.0.1:28332"
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

## ckpool Configuration

When using Tideway with ckpool/SeaTidePool, add this to the pool config:

```json
{
  "external_generator": true,
  ...
}
```

This tells ckpool to skip spawning its internal generator thread and instead communicate with Tideway over the Unix socket.
