# Merge Mining (AuxPoW) and Tideway

## Overview

Merge mining allows miners to simultaneously mine multiple blockchains using
the same proof of work. The miner performs work for a **parent chain** (e.g.,
Litecoin) and that same work can also be used to find blocks on one or more
**auxiliary chains** (e.g., Dogecoin, Pepecoin, Bellscoin). The auxiliary
chains accept the parent chain's proof of work as valid through a mechanism
called **Auxiliary Proof of Work (AuxPoW)**.

The key insight is that the miner does not do any extra hashing. The same
SHA-256d (or Scrypt, etc.) computation that searches for a valid parent block
also searches for valid aux blocks. Aux chains typically have much lower
difficulty than the parent, so shares that don't meet the parent target often
still solve an aux chain.

## How Tideway Fits In

Tideway is an HTTP JSON-RPC proxy that sits between the mining pool software
(SeaTidePool) and the parent chain daemon. The pool's generator connects to
Tideway thinking it is talking directly to the parent daemon (e.g., litecoind).

```
                          ┌─────────────┐
                          │  litecoind  │  Parent chain daemon
                          └──────▲──────┘
                                 │  JSON-RPC
                          ┌──────┴──────┐
                          │   Tideway   │  Merge mining proxy
                          └──────▲──────┘
                                 │  JSON-RPC (transparent)
                          ┌──────┴──────┐
                          │ SeaTidePool │  Mining pool
                          └──────▲──────┘
                                 │  Stratum
                          ┌──────┴──────┐
                          │   Miners    │
                          └─────────────┘

Tideway also connects to aux chain daemons:

          ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
          │  dogecoind   │  │ pepecoind    │  │   bellsd     │
          └──────▲───────┘  └──────▲───────┘  └──────▲───────┘
                 │                 │                  │
                 └────────────┬────┘──────────────────┘
                              │  JSON-RPC (getauxblock / createauxblock)
                       ┌──────┴──────┐
                       │   Tideway   │
                       └─────────────┘
```

Tideway intercepts two RPC methods:

- **`getblocktemplate`** — enriches the response with aux chain data
- **`submitauxblock`** — constructs AuxPoW proofs and submits to aux daemons

All other RPCs (getblockcount, validateaddress, submitblock, etc.) pass
through transparently.

## The Coinbase Transaction

Every block contains a special first transaction called the **coinbase**.
This is the transaction that creates new coins and pays the miner. Unlike
regular transactions, the coinbase has no real inputs — instead, it has a
**scriptsig** field (also called the coinbase data) where the miner can put
arbitrary data.

The coinbase scriptsig is the mechanism that ties merge mining together.

### Coinbase scriptsig Layout (SeaTidePool)

```
┌────────────────────────────────────────────────────────────────┐
│                    Coinbase scriptsig                          │
├──────────────────┬─────────────────────────────────────────────┤
│ Fixed header     │ 41 bytes (version, prev_out, etc.)         │
├──────────────────┼─────────────────────────────────────────────┤
│ Script length    │ 1 byte (total scriptsig length)            │
├──────────────────┼─────────────────────────────────────────────┤
│ Block height     │ Variable (BIP34 serialized number)         │
├──────────────────┼─────────────────────────────────────────────┤
│ Flags            │ Variable (from coinbaseaux.flags — this is │
│                  │ where the AuxPoW commitment lives)         │
├──────────────────┼─────────────────────────────────────────────┤
│ Timestamp        │ Variable (seconds + nanoseconds)           │
├──────────────────┼─────────────────────────────────────────────┤
│ Extranonce size  │ 1 byte (enonce1 + enonce2 length)          │
├──────────────────┼─────────────────────────────────────────────┤
│ Extranonce1      │ Variable (per-connection, set by pool)     │
├──────────────────┼─────────────────────────────────────────────┤
│ Extranonce2      │ Variable (per-share, set by miner)         │
├──────────────────┼─────────────────────────────────────────────┤
│ Pool name        │ Variable (e.g., "tidepool")                │
├──────────────────┼─────────────────────────────────────────────┤
│ btcsig           │ Variable (e.g., "/mined by tidepool/")     │
├──────────────────┼─────────────────────────────────────────────┤
│ Sequence         │ 4 bytes (0xffffffff)                       │
└──────────────────┴─────────────────────────────────────────────┘
```

The **flags** field is the key. Bitcoin Core's `getblocktemplate` RPC returns
a `coinbaseaux` object containing a `flags` hex string. The pool is expected
to include this data in the coinbase scriptsig. Tideway enriches this field
with the AuxPoW commitment before the pool ever sees it.

## The AuxPoW Commitment

The AuxPoW commitment is a 44-byte binary blob inserted into the coinbase
scriptsig (via the flags field). It tells aux chain nodes where to find the
proof that this coinbase commits to their block.

### Commitment Structure (44 bytes)

```
┌────────────┬──────────────────────────────────────┬────────────┬────────────┐
│   Magic    │          Merkle Root                 │ Tree Size  │ Tree Nonce │
│  4 bytes   │          32 bytes                    │  4 bytes   │  4 bytes   │
│ 0xfabe6d6d │  SHA-256d root of aux block hashes   │  LE uint32 │  LE uint32 │
└────────────┴──────────────────────────────────────┴────────────┴────────────┘
```

- **Magic** (`0xfabe6d6d`): A fixed marker that aux chain nodes scan for
  when validating an AuxPoW. This is how they locate the commitment within
  the coinbase. The bytes spell "fa be mm" (merge mining) in a loose
  hexadecimal mnemonic.

- **Merkle Root** (32 bytes): The root of a Merkle tree whose leaves are
  the block hashes of all aux chains being merge mined. This single hash
  commits to every aux chain simultaneously.

- **Tree Size** (4 bytes, little-endian): The number of leaf slots in the
  Merkle tree. Always a power of 2 (e.g., 1, 2, 4, 8, ..., 32). Unused
  slots are zero-filled.

- **Tree Nonce** (4 bytes, little-endian): A nonce that determines slot
  assignment. Combined with each chain's `chain_id`, it maps chains to
  unique slots in the tree. This prevents slot collisions between unrelated
  merge mining operations.

### Hex Representation

In the `coinbaseaux.flags` field (hex-encoded), the commitment looks like:

```
fabe6d6d <64 hex chars merkle root> <8 hex chars tree_size> <8 hex chars tree_nonce>
```

Total: 88 hex characters (44 bytes).

## The Aux Chain Merkle Tree

When merge mining N auxiliary chains, their block hashes are arranged as
leaves of a binary Merkle tree. The tree is built bottom-up using double
SHA-256 at each level, just like Bitcoin's transaction Merkle tree.

### Example: 3 Aux Chains (tree_size = 4)

```
                    Merkle Root
                   /           \
              H(0,1)           H(2,3)
             /      \         /      \
         Dogecoin  Pepecoin  Bells   0x00..00
         (slot 0)  (slot 1) (slot 2) (empty)
```

Each leaf is the 32-byte block hash returned by the aux chain daemon's
`getauxblock` or `createauxblock` RPC. Empty slots contain 32 zero bytes.

Internal nodes are computed as:

```
H(left, right) = SHA-256d(left || right)
```

where `SHA-256d(x) = SHA-256(SHA-256(x))`.

The Merkle root is what goes into the commitment. To prove that a specific
aux chain's block hash is in the tree, you provide a **Merkle branch** — the
sibling hashes at each level needed to recompute the root from the leaf.

## Data Flow: From Template to Block

### Step 1: Tideway Fetches Templates

On startup and periodically (via kqueue `EVFILT_TIMER`), Tideway calls each
aux chain daemon's RPC to get fresh aux block templates:

```
Tideway → dogecoind:  {"method": "getauxblock", "params": []}
Tideway → pepecoind:  {"method": "getauxblock", "params": []}
Tideway → bellsd:     {"method": "getauxblock", "params": []}
```

Each daemon returns a block hash and target:

```json
{
  "result": {
    "hash": "a1b2c3d4...64 hex chars...",
    "target": "0000ffff...64 hex chars..."
  }
}
```

The `hash` is the aux block that needs proof of work. The `target` defines
the difficulty threshold.

### Step 2: Tideway Builds the Merkle Tree

From the collected aux block hashes:

1. Compute `tree_size` = smallest power of 2 >= number of chains
2. Assign each chain to a slot (0, 1, 2, ...)
3. Build the Merkle tree bottom-up with double SHA-256
4. The root becomes the 32-byte Merkle root in the commitment

### Step 3: Pool Requests getblocktemplate

SeaTidePool's generator calls `getblocktemplate` through Tideway:

```
SeaTidePool → Tideway:  {"method": "getblocktemplate", "params": [...]}
Tideway     → litecoind: {"method": "getblocktemplate", "params": [...]}
litecoind   → Tideway:  {"result": { "coinbaseaux": {"flags": ""}, ... }}
```

Tideway enriches the response before forwarding it back:

1. **Appends** the 44-byte commitment (hex-encoded) to `coinbaseaux.flags`
2. **Adds** aux chain metadata fields to the result:
   - `aux_merkle_root` — hex Merkle root
   - `aux_tree_size` — tree leaf count
   - `aux_tree_nonce` — slot assignment nonce
   - `n_aux_chains` — number of active aux chains
   - `aux_chains` — array of per-chain details (chain_id, hash, target,
     diff, slot)

The enriched response reaches SeaTidePool, which includes the flags data in
the coinbase scriptsig as it normally would — without any special merge
mining code in the pool itself.

### Step 4: Pool Distributes Work to Miners

SeaTidePool constructs the coinbase (with the AuxPoW commitment embedded via
the flags), builds the block header, and sends stratum `mining.notify` jobs
to connected miners. The miners hash as usual.

### Step 5: Share Submission and Target Checking

When a miner submits a share, SeaTidePool:

1. Computes the block hash (SHA-256d or Scrypt of the header)
2. Checks if the hash meets the **parent chain target** → submit parent block
3. Checks if the hash meets any **aux chain target** → submit aux block

Step 3 is the merge mining payoff. A share at difficulty 1,000 that doesn't
meet Litecoin's difficulty of 30,000,000 might still meet Dogecoin's
difficulty of 500. That share solves a Dogecoin block.

This check happens in `auxpow_check_targets()` in SeaTidePool's stratifier:

```c
for (i = 0; i < aux->n_chains; i++) {
    if (diff >= aux->chains[i].diff * 0.999) {
        // This share solves aux chain i!
        submit_aux_block(ckp, aux, i, coinbase, cblen, ...);
    }
}
```

### Step 6: AuxPoW Proof Construction and Submission

When a share meets an aux chain's target, Tideway must construct an **AuxPoW
proof** and submit it to that aux chain's daemon. The proof contains
everything the aux chain node needs to verify:

```
┌──────────────────────────────────────────────────────────────┐
│                       AuxPoW Proof                           │
├──────────────────────────────────────────────────────────────┤
│ Parent coinbase transaction (raw bytes)                      │
│   Contains the AuxPoW commitment in its scriptsig            │
├──────────────────────────────────────────────────────────────┤
│ Coinbase Merkle branch                                       │
│   Proof that the coinbase is in the parent block's tx tree   │
│   (sibling hashes from coinbase leaf to tx Merkle root)      │
├──────────────────────────────────────────────────────────────┤
│ Parent block header (80 bytes)                               │
│   Contains the tx Merkle root that includes the coinbase     │
├──────────────────────────────────────────────────────────────┤
│ Aux chain Merkle branch                                      │
│   Proof that this chain's block hash is in the aux tree      │
│   (sibling hashes from leaf slot to aux Merkle root)         │
├──────────────────────────────────────────────────────────────┤
│ Aux tree index (slot number)                                 │
│ Aux tree nonce                                               │
└──────────────────────────────────────────────────────────────┘
```

The aux chain node verifies by:

1. Checking the parent block header hash meets its own target
2. Following the coinbase Merkle branch up to the header's Merkle root
3. Scanning the coinbase scriptsig for the `0xfabe6d6d` magic
4. Extracting the aux Merkle root from the commitment
5. Following the aux Merkle branch to verify this chain's block hash is
   committed in the aux tree

If all checks pass, the aux chain accepts the block.

## SegWit Compatibility

AuxPoW and SegWit coexist without conflict:

- **AuxPoW commitment**: Lives in the coinbase **scriptsig** (input side),
  carried via `coinbaseaux.flags`
- **SegWit witness commitment**: Lives in a coinbase **output** as an
  `OP_RETURN` data push

They occupy entirely different parts of the coinbase transaction.
Additionally, the AuxPoW proof uses the **legacy txid** Merkle tree (not the
wtxid tree), so witness data does not affect the coinbase Merkle branch
computation.

## Why a Proxy?

The JSON-RPC proxy approach (Tideway) has key advantages over modifying the
pool software directly:

- **Zero pool code changes for basic proxying** — the pool's generator
  thread runs unmodified, connecting to Tideway as if it were the parent
  daemon
- **Separation of concerns** — merge mining complexity lives in Tideway,
  not scattered across pool internals
- **N aux chains without pool restarts** — add/remove chains by
  reconfiguring Tideway
- **HAProxy-friendly** — daemon failover is handled upstream of Tideway, not
  inside it
- **Minimal SeaTidePool changes** — only ~113 lines of C added: parsing aux
  fields from the enriched GBT response, inserting the commitment into the
  coinbase, and checking aux targets at share time

## Glossary

- **Parent chain**: The blockchain whose proof of work is being performed
  (e.g., Litecoin). Its full difficulty must be met to find a parent block.
- **Auxiliary chain (aux chain)**: A blockchain that accepts the parent's
  proof of work via AuxPoW (e.g., Dogecoin). Usually has much lower
  difficulty.
- **AuxPoW (Auxiliary Proof of Work)**: A data structure proving that work
  done on the parent chain commits to an aux chain block.
- **Commitment**: The 44-byte blob in the coinbase scriptsig that ties the
  parent block to the aux Merkle tree.
- **Magic bytes** (`0xfabe6d6d`): Fixed 4-byte marker that aux nodes scan
  for in the coinbase to locate the commitment.
- **Aux Merkle tree**: A binary tree of aux chain block hashes. Its root is
  included in the commitment.
- **Merkle branch**: The set of sibling hashes needed to prove a leaf's
  membership in a Merkle tree.
- **coinbaseaux.flags**: A field in Bitcoin's `getblocktemplate` RPC response
  containing hex data the pool must include in the coinbase scriptsig.
  Tideway uses this as the injection point for the AuxPoW commitment.
- **getauxblock / createauxblock**: RPC methods on aux chain daemons that
  return an aux block hash and target for merge mining.
- **submitauxblock**: RPC method to submit a solved aux block with its AuxPoW
  proof.
