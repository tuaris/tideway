# Tideway

Tideway is a merge mining (AuxPoW) generator for [ckpool](https://bitbucket.org/ckolivas/ckpool)-based mining pools. It replaces ckpool's internal generator thread with an external process that connects to a parent chain daemon plus multiple auxiliary chain daemons, enabling N-way merged mining over Unix sockets.

## How It Works

```
┌──────────────────────────┐
│  ckpool / SeaTidePool    │
│  Connector ◄─► Stratifier│──[Unix socket]──► /tmp/ckpool/generator
└──────────────────────────┘                          │
                                              ┌───────┴───────┐
                                              │   Tideway      │
                                              │                │
                                              │  Parent Daemon │──► litecoind
                                              │  Aux Daemons   │──► dogecoind
                                              │                │──► pepecoind
                                              │  AuxPoW Merkle │──► bellsd
                                              └────────────────┘
```

Tideway implements ckpool's generator Unix socket protocol. It:

1. Listens on the generator socket (e.g., `/tmp/ckpool/generator`)
2. Handles `getbase` requests by fetching block templates from the parent chain daemon and all configured aux chain daemons
3. Builds an AuxPoW Merkle tree from aux chain block hashes and includes the commitment in the response
4. Handles `submitblock` for parent chain block solves
5. Handles `submitauxblock` for aux chain block solves (constructs AuxPoW proofs and submits to aux daemons)
6. Exposes a ZMQ PULL socket for fire-and-forget messages (reconnect, loglevel, etc.)

Miners are unaware of merge mining — they receive standard Stratum work and submit shares normally.

## Requirements

- [Zig](https://ziglang.org/) 0.15+ (build)
- Parent chain daemon (bitcoind, litecoind, etc.) with RPC enabled
- Aux chain daemons with `getauxblock` or `createauxblock` RPC support
- [SeaTidePool](https://git.morante.net/TidePool/SeaTidePool) (has native external generator support), or ckpool with patches applied (see [Patching ckpool](#patching-ckpool))

## Building

```sh
zig build -Doptimize=ReleaseSafe
```

The binary is output to `zig-out/bin/tideway`.

### Cross-compile for FreeBSD

```sh
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-freebsd
```

## Configuration

Copy the sample config and edit:

```sh
cp config/tideway.conf.sample tideway.conf
```

See [doc/CONFIGURATION.md](doc/CONFIGURATION.md) for full reference.

### Minimal Example

```json
{
  "socket_path": "/tmp/ckpool/generator",
  "zmq_pull": "ipc:///tmp/ckpool/generator.zmq",
  "parent": {
    "url": "http://127.0.0.1:9332",
    "user": "litecoinrpc",
    "pass": "password",
    "poll_interval_ms": 100
  },
  "aux_chains": [
    {
      "chain_id": "dogecoin",
      "url": "http://127.0.0.1:22555",
      "user": "dogerpc",
      "pass": "password"
    }
  ]
}
```

## Running

```sh
# Start Tideway (creates generator socket)
./tideway -c tideway.conf

# Start ckpool/SeaTidePool with external generator enabled
./tidepoold -c tidepool.conf
```

Either service can start first — ckpool polls the generator socket until Tideway responds.

## Pool Compatibility

### SeaTidePool

SeaTidePool has **native external generator support** — no patches required. Add `"external_generator": true` to your SeaTidePool config and start Tideway.

### ckpool

Upstream ckpool requires a small patch to enable external generator support and AuxPoW coinbase commitments (~260 lines across 7 files).

**Quick apply:**

```sh
cd /path/to/ckpool
patch -p1 < /path/to/tideway/patches/ckpool-auxpow.patch
make clean && make
```

See [doc/CKPOOL_PATCHES.md](doc/CKPOOL_PATCHES.md) for a detailed walkthrough of each change.

**Summary of patch:**

| File | Lines | Purpose |
|------|-------|--------|
| `src/ckpool.c` | +45 | External generator config, poll thread, ZMQ PUSH init, send_proc wrapper |
| `src/ckpool.h` | +5 | `external_generator` flag, `zmq_gen_push` pointer |
| `src/auxpow.c` | +65 | New file: parse aux fields, insert coinbase commitment, check aux targets |
| `src/auxpow.h` | +30 | New file: `auxpow_t` struct, `aux_chain_t`, function prototypes |
| `src/stratifier.c` | +5 | Three one-line calls to auxpow functions + buffer resize |
| `src/stratifier.h` | +2 | Include `auxpow.h`, add `auxpow_t` field to workbase |
| `Makefile` | +1 | Add `auxpow.o` to build |

## Protocol

Tideway implements ckpool's generator Unix socket protocol. See [doc/PROTOCOL.md](doc/PROTOCOL.md) for the full message reference.

## License

BSD 2-Clause. See [LICENSE](LICENSE).
