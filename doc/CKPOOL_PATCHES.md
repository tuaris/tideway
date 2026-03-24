# Patching ckpool/SeaTidePool for AuxPoW

This guide walks through the ~113-line patch required to add merge mining (AuxPoW) support to ckpool or SeaTidePool. These changes allow the pool to work with Tideway's enriched `getblocktemplate` responses.

Because Tideway is a transparent HTTP JSON-RPC proxy, no changes to `ckpool.c` or `ckpool.h` are needed. The pool's generator connects to Tideway as if it were the parent chain daemon — the only pool-side changes are parsing the aux fields, inserting the coinbase commitment, and checking aux targets at share time.

## Summary

| File | Lines | Purpose |
|------|-------|---------|
| `src/auxpow.c` | +100 | New file: parse aux fields, insert coinbase commitment, check aux targets, submit aux solves |
| `src/auxpow.h` | +53 | New file: `auxpow_t` struct, `aux_chain_t`, function prototypes |
| `src/stratifier.c` | +5 | Three one-line calls to auxpow functions + buffer resize |
| `src/stratifier.h` | +2 | Include `auxpow.h`, add `auxpow_t` field to workbase |
| `src/generator.c` | +3 | `submitauxblock` handler in generator loop |
| `Makefile` | +1 | Add `auxpow.o` to build |

**Total:** ~113 new lines, only 11 lines in existing files.

## Manual Walkthrough

### 1. New Files: `src/auxpow.h` and `src/auxpow.c`

These contain all merge mining logic — completely self-contained.

**`src/auxpow.h`** defines:
- `AUXPOW_MAX_CHAINS` (32) — maximum aux chains (2^5 Merkle tree)
- `AUXPOW_COMMITMENT_LEN` (44) — 4 magic + 32 root + 4 size + 4 nonce
- `aux_chain_t` — per-chain state: chain_id, hash, target, difficulty, Merkle slot
- `auxpow_t` — per-workbase merge mining state (n_chains, Merkle root, tree metadata, chain array)
- `auxpow_parse()` — parse optional aux fields from getblocktemplate JSON
- `auxpow_insert_commitment()` — write 44-byte AuxPoW commitment into coinbase scriptsig
- `auxpow_check_targets()` — compare share difficulty against all aux chain targets

**`src/auxpow.c`** implements:
- `auxpow_parse()` — extracts `aux_chains`, `aux_merkle_root`, `aux_tree_size`, `aux_tree_nonce` from the GBT JSON (added by Tideway). Safe no-op when aux fields are absent.
- `auxpow_insert_commitment()` — writes the 44-byte blob (`0xfabe6d6d` + Merkle root + tree_size LE + tree_nonce LE) into the coinbase scriptsig at the current offset. No-op when n_chains == 0.
- `auxpow_check_targets()` — iterates all aux chains, compares share difficulty against each target. On match, calls `submit_aux_block()`.
- `submit_aux_block()` (static) — formats the `submitauxblock` message with chain_id, aux hash, coinbase hex, parent header hex, and nonce, then sends it to the generator via `send_proc()`. The generator forwards it to Tideway, which constructs the AuxPoW proof and submits to the aux daemon.

### 2. `src/stratifier.h` (+2 lines)

```c
#include "auxpow.h"
```

Add `auxpow_t` field inside `struct workbase`:

```c
auxpow_t auxpow; /* Merge mining state (zero when not merge mining) */
```

### 3. `src/stratifier.c` (+5 lines)

Three one-line call sites and a buffer resize:

```c
/* After witness data check, before generate_coinbase(): */
auxpow_parse(&wb->auxpow, wb->json);

/* In generate_coinbase(), after flags, before enonce length byte: */
auxpow_insert_commitment(&wb->auxpow, wb->coinb1bin, &ofs);

/* After algo_share_diff(), before test_blocksolve(): */
auxpow_check_targets(client->ckp, &wb->auxpow, ret, coinbase, cblen,
                     swap, hash, nonce2, nonce, ntime32);
```

Also increase coinb1 buffer sizes to accommodate the 44-byte commitment:

```c
wb->coinb1 = ckzalloc(512);    /* was 256 */
wb->coinb1bin = ckzalloc(256); /* was 128 */
```

### 4. `src/generator.c` (+3 lines)

Add a `submitauxblock` handler in the generator's message loop to forward aux block submissions to the parent daemon (Tideway):

```c
if (!strncmp(buf, "submitauxblock:", 15)) {
    send_json_rpc(/* ... submitauxblock params ... */);
}
```

### 5. `Makefile` (+1 line)

Add `auxpow.o` to the object list.

## Verification

After patching, build and run without aux chains to verify no regressions:

```sh
make clean && make
./tidepoold -c your-existing-config.conf
```

The patch is backward compatible — when Tideway is not in front of the daemon (or has no aux chains configured), `auxpow_parse()` finds no aux fields in the GBT response and all three call sites are safe no-ops.
