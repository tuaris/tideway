# Patching ckpool for External Generator + AuxPoW

This guide walks through the ~153-line patch required to enable external generator support and merge mining (AuxPoW) in ckpool or SeaTidePool.

## Quick Apply

```sh
cd /path/to/ckpool
patch -p1 < /path/to/tideway/patches/ckpool-auxpow.patch
make clean && make
```

## Manual Walkthrough

### 1. New Files: `src/auxpow.h` and `src/auxpow.c`

These contain all merge mining logic — data structures, JSON parsing, coinbase commitment insertion, and aux target checking.

**`src/auxpow.h`** defines:
- `auxpow_t` — per-workbase merge mining state (Merkle root, tree metadata, per-chain info)
- `aux_chain_t` — per-chain target/hash/difficulty
- `auxpow_parse()` — parse optional aux fields from getbase JSON response
- `auxpow_insert_commitment()` — write 44-byte AuxPoW marker into coinbase scriptsig
- `auxpow_check_targets()` — compare share difficulty against all aux chain targets

**`src/auxpow.c`** implements these functions plus a static `submit_aux_block()` helper.

### 2. `src/ckpool.h` (+5 lines)

Add to `struct ckpool_instance`:

```c
bool external_generator;   /* Use external generator process (e.g., Tideway) */
void *zmq_gen_push;        /* ZMQ PUSH socket to external generator */
```

### 3. `src/ckpool.c` (+45 lines)

#### Config parsing (in `read_config()`)

```c
json_get_bool(&ckp->external_generator, json_conf, "external_generator");
```

#### Startup (in `main()`, replacing `prepare_child` for generator)

```c
if (ckp.external_generator) {
    /* Set up socket path for send_recv_proc() */
    ckp.generator.ckp = &ckp;
    ckp.generator.processname = "generator";
    ckp.generator.sockname = ckp.generator.processname;
    name_process_sockname(&ckp.generator.us, &ckp.generator);

    /* ZMQ PUSH for fire-and-forget messages */
    ckp.zmq_gen_push = zmq_socket(ckp.zmqctx, ZMQ_PUSH);
    zmq_connect(ckp.zmq_gen_push, "ipc:///tmp/ckpool/generator.zmq");

    /* Poll thread sets generator_ready when external generator responds */
    create_pthread(&pth_extgen, extgen_poll, &ckp);
} else {
    prepare_child(&ckp, &ckp.generator, generator, "generator");
}
```

#### External generator poll thread

```c
static void *extgen_poll(void *arg)
{
    ckpool_t *ckp = (ckpool_t *)arg;

    rename_proc("extgenpoll");
    while (!ckp->generator_ready) {
        char *resp = send_recv_proc(ckp->generator, "ping");
        if (resp && !strcmp(resp, "pong")) {
            ckp->generator_ready = true;
            LOGWARNING("External generator ready");
        } else {
            LOGDEBUG("Waiting for external generator on %s...",
                     ckp->generator.us.path);
        }
        dealloc(resp);
        if (!ckp->generator_ready)
            cksleep_ms(1000);
    }
    return NULL;
}
```

#### send_proc wrapper (in `_queue_proc()`)

Route fire-and-forget messages through ZMQ when targeting the external generator:

```c
if (ckp->external_generator && pi == &ckp->generator) {
    zmq_send(ckp->zmq_gen_push, msg, strlen(msg), ZMQ_DONTWAIT);
    return;
}
/* ... original _queue_proc code ... */
```

### 4. `src/stratifier.h` (+2 lines)

```c
#include "auxpow.h"
```

Add inside `struct genwork`:

```c
auxpow_t auxpow;
```

### 5. `src/stratifier.c` (+5 lines)

Three one-line call sites and a buffer resize:

```c
/* In update_base() / add_base(), after existing gbtbase parsing: */
auxpow_parse(&wb->auxpow, gbt->json);

/* In generate_coinbase(), after timestamp/random, before enonce length: */
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

### 6. `Makefile` (+1 line)

Add `auxpow.o` to the object list.

## Verification

After patching, build and run without `external_generator` to verify no regressions:

```sh
make clean && make
./tidepoold -c your-existing-config.conf
```

The patch is backward compatible — without `"external_generator": true` in the config, ckpool behaves exactly as before.
