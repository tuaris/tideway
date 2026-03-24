# Tideway

Tideway is a merge mining (AuxPoW) proxy for [ckpool](https://bitbucket.org/ckolivas/ckpool)-based mining pools. It sits between the pool's generator and the parent chain daemon as a transparent HTTP JSON-RPC proxy, enriching block templates with auxiliary chain data to enable N-way merged mining.

## How It Works

```
                          ┌─────────────┐
                          │  litecoind  │  Parent chain daemon
                          └──────▲──────┘
                                 │  JSON-RPC
                          ┌──────┴──────┐
                          │   Tideway   │  Merge mining proxy
                          │             │
                          │  ┌────────┐ │──► dogecoind
                          │  │ AuxPoW │ │──► pepecoind
                          │  │ Merkle │ │──► bellsd
                          │  └────────┘ │
                          └──────▲──────┘
                                 │  JSON-RPC (transparent)
                          ┌──────┴──────┐
                          │ SeaTidePool │  Mining pool
                          │  Generator  │
                          └──────▲──────┘
                                 │  Stratum
                          ┌──────┴──────┐
                          │   Miners    │
                          └─────────────┘
```

The pool's generator connects to Tideway thinking it is the parent chain daemon (e.g., litecoind). Tideway transparently proxies all JSON-RPC calls, intercepting two methods:

1. **`getblocktemplate`** — forwarded to the parent daemon, then enriched with AuxPoW commitment data (Merkle root of aux chain block hashes injected into `coinbaseaux.flags`) and aux chain metadata before returning to the pool
2. **`submitauxblock`** — constructs AuxPoW proofs and submits solved aux blocks to aux chain daemons

All other RPCs (`getblockcount`, `validateaddress`, `submitblock`, etc.) pass through unmodified. Miners are unaware of merge mining — they receive standard Stratum work and submit shares normally.

## Requirements

- [Zig](https://ziglang.org/) 0.15+ (build)
- Parent chain daemon (bitcoind, litecoind, etc.) with RPC enabled
- Aux chain daemons with `getauxblock` or `createauxblock` RPC support
- [SeaTidePool](https://git.morante.net/TidePool/SeaTidePool) with AuxPoW support, or ckpool with patches applied (see [Pool Compatibility](#pool-compatibility))

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
  "listen": "127.0.0.1:9332",
  "parent": {
    "url": "http://127.0.0.1:19332",
    "user": "litecoinrpc",
    "pass": "password"
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
# Start Tideway (listens for HTTP JSON-RPC connections)
./tideway -c tideway.conf

# Point the pool's btcd URL at Tideway instead of the parent daemon
./tidepoold -c tidepool.conf
```

In the pool config, set the `btcd` URL to Tideway's listen address. The pool's generator connects to Tideway as if it were the parent chain daemon.

## Pool Compatibility

### SeaTidePool

[SeaTidePool](https://git.morante.net/TidePool/SeaTidePool) has **native AuxPoW support** — no patches required. Point the `btcd` URL at Tideway and it works out of the box.

### ckpool

Upstream ckpool requires a small patch (~113 lines) to parse aux fields from the enriched `getblocktemplate` response, insert the AuxPoW commitment into the coinbase, and check aux chain targets at share time. No changes to `ckpool.c` or `ckpool.h` — the proxy approach means the generator runs unmodified.

See [doc/CKPOOL_PATCHES.md](doc/CKPOOL_PATCHES.md) for a detailed walkthrough.

## Documentation

- [doc/MERGE_MINING.md](doc/MERGE_MINING.md) — How merge mining (AuxPoW) works and how Tideway fits in
- [doc/CONFIGURATION.md](doc/CONFIGURATION.md) — Configuration file reference
- [doc/CKPOOL_PATCHES.md](doc/CKPOOL_PATCHES.md) — Pool-side patch walkthrough

## License

BSD 2-Clause. See [LICENSE](LICENSE).
