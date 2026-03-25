const std = @import("std");
const config = @import("config.zig");
const rpc = @import("rpc.zig");

const log = std.log.scoped(.auxpow);

/// AuxPoW Merkle tree magic bytes (standard merge mining marker).
pub const magic: [4]u8 = .{ 0xfa, 0xbe, 0x6d, 0x6d };

/// Maximum supported aux chains (2^5 Merkle tree).
pub const max_chains: usize = 32;

/// Commitment length in bytes: 4 magic + 32 root + 4 size + 4 nonce.
pub const commitment_len: usize = 44;

/// Per-chain aux block template state.
pub const ChainTemplate = struct {
    chain_id: []const u8,
    numeric_chain_id: i32 = 0, // from getauxblock "chainid" field
    hash: [32]u8 = std.mem.zeroes([32]u8),
    hash_hex: [64]u8 = std.mem.zeroes([64]u8),
    target: [32]u8 = std.mem.zeroes([32]u8),
    target_hex: [64]u8 = std.mem.zeroes([64]u8),
    diff: f64 = 0,
    slot: u32 = 0,
    valid: bool = false,

    rpc_client: rpc.Client,
    rpc_method: config.AuxChain.RpcMethod,
};

/// AuxPoW state for all configured aux chains.
pub const State = struct {
    allocator: std.mem.Allocator,
    chains: []ChainTemplate,

    merkle_root: [32]u8 = std.mem.zeroes([32]u8),
    tree_size: u32 = 0,
    tree_nonce: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, aux_configs: []const config.AuxChain) State {
        var chains = allocator.alloc(ChainTemplate, aux_configs.len) catch {
            log.err("failed to allocate aux chain state", .{});
            return .{
                .allocator = allocator,
                .chains = &.{},
            };
        };

        for (aux_configs, 0..) |cfg, i| {
            chains[i] = .{
                .chain_id = cfg.chain_id,
                .rpc_client = rpc.Client.init(allocator, cfg.host, cfg.port, cfg.user, cfg.pass),
                .rpc_method = cfg.rpc_method,
            };
        }

        // Compute tree size (smallest power of 2 >= chain count)
        var tree_size: u32 = 1;
        while (tree_size < aux_configs.len) {
            tree_size *= 2;
        }

        return .{
            .allocator = allocator,
            .chains = chains,
            .tree_size = tree_size,
        };
    }

    pub fn deinit(self: *State) void {
        for (self.chains) |*chain| {
            chain.rpc_client.deinit();
        }
        self.allocator.free(self.chains);
    }

    pub fn chain_count(self: *const State) usize {
        return self.chains.len;
    }

    /// Fetch fresh aux block templates from all aux chain daemons.
    pub fn refreshTemplates(self: *State, allocator: std.mem.Allocator) !void {
        for (self.chains) |*chain| {
            chain.valid = false;

            var parsed = switch (chain.rpc_method) {
                .getauxblock => chain.rpc_client.getAuxBlock(allocator),
                .createauxblock => chain.rpc_client.createAuxBlock(allocator, ""),
            } catch |err| {
                log.warn("failed to get aux template for {s}: {}", .{ chain.chain_id, err });
                continue;
            };
            defer parsed.deinit();

            const result = parsed.value.object.get("result") orelse continue;
            const result_obj = result.object;

            // Extract block hash
            if (result_obj.get("hash")) |hash_val| {
                const hash_str = hash_val.string;
                if (hash_str.len == 64) {
                    @memcpy(&chain.hash_hex, hash_str[0..64]);
                    _ = std.fmt.hexToBytes(&chain.hash, hash_str) catch continue;
                    // getauxblock returns hash in display format (big-endian hex).
                    // Keep as-is: Dogecoin's AuxPoW verification reverses the
                    // computed root before searching the coinbase, so the
                    // commitment must contain the root in display byte order.
                    chain.valid = true;
                }
            }

            // Extract numeric chain ID
            if (result_obj.get("chainid")) |cid_val| {
                if (cid_val == .integer) {
                    chain.numeric_chain_id = @intCast(cid_val.integer);
                }
            }

            // Extract target
            if (result_obj.get("target")) |target_val| {
                const target_str = target_val.string;
                if (target_str.len == 64) {
                    @memcpy(&chain.target_hex, target_str[0..64]);
                    _ = std.fmt.hexToBytes(&chain.target, target_str) catch {};
                }
            }

            // Compute difficulty from target
            chain.diff = diffFromTarget(&chain.target);

            log.info("aux template for {s}: hash={s} diff={d:.3}", .{
                chain.chain_id,
                chain.hash_hex,
                chain.diff,
            });
        }

        // Assign Merkle tree slots and rebuild root
        self.assignSlots();
        self.buildMerkleRoot();
    }

    /// Build aux fields as a JSON string to be merged into the getbase response.
    /// Returns null if no valid aux chains.
    pub fn auxFieldsJson(self: *const State, allocator: std.mem.Allocator) !?[]const u8 {
        var valid_count: usize = 0;
        for (self.chains) |chain| {
            if (chain.valid) valid_count += 1;
        }
        if (valid_count == 0) return null;

        var root_hex: [64]u8 = undefined;
        bytesToHex(&self.merkle_root, &root_hex);

        // Build per-chain JSON array entries (accumulate)
        var chains_json = try std.fmt.allocPrint(allocator, "", .{});
        for (self.chains, 0..) |chain, i| {
            if (!chain.valid) continue;
            const sep = if (chains_json.len > 0) "," else "";
            const new = try std.fmt.allocPrint(allocator,
                "{s}{s}{{\"chain_id\":\"{s}\",\"hash\":\"{s}\",\"target\":\"{s}\",\"diff\":{d:.6},\"slot\":{d}}}",
                .{ chains_json, sep, chain.chain_id, chain.hash_hex, chain.target_hex, chain.diff, i },
            );
            allocator.free(chains_json);
            chains_json = new;
        }
        defer allocator.free(chains_json);

        return try std.fmt.allocPrint(allocator,
            "\"aux_merkle_root\":\"{s}\",\"aux_tree_size\":{d},\"aux_tree_nonce\":{d},\"n_aux_chains\":{d},\"aux_chains\":[{s}]",
            .{ root_hex, self.tree_size, self.tree_nonce, valid_count, chains_json },
        );
    }

    /// Submit an aux block solve. Parse the data string and construct AuxPoW proof.
    pub fn submitAuxBlock(self: *State, allocator: std.mem.Allocator, data: []const u8) !void {
        // Parse "chain_id:aux_hash:coinbase_hex:header_hex:nonce"
        var iter = std.mem.splitScalar(u8, data, ':');
        const chain_id = iter.next() orelse return error.InvalidAuxSubmit;
        const aux_hash = iter.next() orelse return error.InvalidAuxSubmit;
        const coinbase_hex = iter.next() orelse return error.InvalidAuxSubmit;
        const header_hex = iter.next() orelse return error.InvalidAuxSubmit;
        _ = coinbase_hex;
        _ = header_hex;

        // Find the matching chain
        for (self.chains) |*chain| {
            if (std.mem.eql(u8, chain.chain_id, chain_id)) {
                log.info("submitting aux block for {s}: {s}", .{ chain_id, aux_hash });

                // TODO: Construct full AuxPoW proof from:
                // - Parent block header
                // - Parent coinbase transaction
                // - Coinbase Merkle branch
                // - Aux chain Merkle branch
                // Then submit via chain.rpc_client.submitAuxBlock()

                const result = chain.rpc_client.submitAuxBlock(allocator, aux_hash, "TODO_AUXPOW_HEX") catch |err| {
                    log.err("failed to submit aux block for {s}: {}", .{ chain_id, err });
                    return;
                };
                defer allocator.free(result);

                log.info("aux block submit result for {s}: {s}", .{ chain_id, result });
                return;
            }
        }

        log.warn("unknown aux chain: {s}", .{chain_id});
    }

    // --- Internal ---

    fn assignSlots(self: *State) void {
        // Compute deterministic slot from numeric chain ID using the
        // Namecoin/Dogecoin LCG algorithm (getExpectedIndex).
        for (self.chains) |*chain| {
            chain.slot = getExpectedIndex(self.tree_nonce, chain.numeric_chain_id, self.tree_size);
        }
        // TODO: detect and resolve slot collisions for production
    }

    fn buildMerkleRoot(self: *State) void {
        if (self.chains.len == 0) {
            self.merkle_root = std.mem.zeroes([32]u8);
            return;
        }

        // Build leaf nodes (tree_size slots, unused slots are zero-filled)
        // Hashes must be in INTERNAL byte order (LE) for SHA256d computation
        // to match Dogecoin's CheckMerkleBranch verification.
        var leaves: [max_chains][32]u8 = undefined;
        for (&leaves) |*leaf| {
            leaf.* = std.mem.zeroes([32]u8);
        }
        for (self.chains) |chain| {
            if (chain.valid and chain.slot < self.tree_size) {
                leaves[chain.slot] = chain.hash;
                std.mem.reverse(u8, &leaves[chain.slot]); // display → internal
            }
        }

        // Build tree bottom-up with double SHA-256
        var level_size: u32 = self.tree_size;
        while (level_size > 1) : (level_size /= 2) {
            var i: u32 = 0;
            while (i < level_size) : (i += 2) {
                dsha256_pair(&leaves[i], &leaves[i + 1], &leaves[i / 2]);
            }
        }

        // Root is in internal order; reverse to display order for commitment.
        // Dogecoin reverses its computed root before searching the coinbase,
        // so the commitment must contain display-order bytes.
        self.merkle_root = leaves[0];
        if (self.tree_size > 1) {
            std.mem.reverse(u8, &self.merkle_root);
        }
    }
};

// --- Merkle Branch & Proof Construction ---

pub const max_cb_branch_depth: usize = 20;
pub const max_aux_branch_depth: usize = 5; // log2(32)

/// Double SHA-256: SHA256(SHA256(data)).
pub fn dsha256(data: []const u8, out: *[32]u8) void {
    var h1 = std.crypto.hash.sha2.Sha256.init(.{});
    h1.update(data);
    var tmp: [32]u8 = undefined;
    h1.final(&tmp);
    var h2 = std.crypto.hash.sha2.Sha256.init(.{});
    h2.update(&tmp);
    h2.final(out);
}

/// Double SHA-256 of two 32-byte inputs concatenated.
fn dsha256_pair(a: *const [32]u8, b: *const [32]u8, out: *[32]u8) void {
    var h1 = std.crypto.hash.sha2.Sha256.init(.{});
    h1.update(a);
    h1.update(b);
    var tmp: [32]u8 = undefined;
    h1.final(&tmp);
    var h2 = std.crypto.hash.sha2.Sha256.init(.{});
    h2.update(&tmp);
    h2.final(out);
}

/// Compute the coinbase Merkle branch (sibling hashes for position 0).
/// txids are the non-coinbase transaction IDs from getblocktemplate.
/// The branch hashes are independent of the actual coinbase hash.
pub fn computeCbMerkleBranch(
    allocator: std.mem.Allocator,
    txids: []const [32]u8,
    branch: *[max_cb_branch_depth][32]u8,
) !usize {
    if (txids.len == 0) return 0; // coinbase only, no branch

    // Build leaves: [placeholder_for_coinbase, txid[0], txid[1], ...]
    const n_leaves = txids.len + 1;
    const leaves = try allocator.alloc([32]u8, n_leaves);
    defer allocator.free(leaves);
    leaves[0] = std.mem.zeroes([32]u8); // placeholder (value irrelevant)
    for (txids, 0..) |txid, i| {
        leaves[i + 1] = txid;
    }

    var depth: usize = 0;
    var idx: usize = 0; // coinbase is always at position 0
    var n: usize = n_leaves;

    while (n > 1) {
        // Record sibling hash
        const sibling = idx ^ 1;
        branch[depth] = if (sibling < n) leaves[sibling] else leaves[idx];
        depth += 1;

        // Compute next level in-place
        var next_n: usize = 0;
        var i: usize = 0;
        while (i < n) : (i += 2) {
            const right_idx = if (i + 1 < n) i + 1 else i;
            dsha256_pair(&leaves[i], &leaves[right_idx], &leaves[next_n]);
            next_n += 1;
        }
        n = next_n;
        idx /= 2;
    }

    return depth;
}

/// Compute the aux chain Merkle branch for a given slot.
/// Rebuilds the tree from current chain hashes (same data as buildMerkleRoot).
pub fn getAuxMerkleBranch(state: *const State, slot: u32, branch: *[max_aux_branch_depth][32]u8) usize {
    if (state.tree_size <= 1) return 0;

    // Rebuild leaf nodes
    var leaves: [max_chains][32]u8 = undefined;
    for (&leaves) |*leaf| {
        leaf.* = std.mem.zeroes([32]u8);
    }
    for (state.chains) |chain| {
        if (chain.valid and chain.slot < state.tree_size) {
            leaves[chain.slot] = chain.hash;
        }
    }

    var depth: usize = 0;
    var idx: u32 = slot;
    var level_size: u32 = state.tree_size;

    while (level_size > 1) : (level_size /= 2) {
        // Record sibling
        const sibling = idx ^ 1;
        branch[depth] = leaves[sibling];
        depth += 1;

        // Compute next level in-place
        var i: u32 = 0;
        while (i < level_size) : (i += 2) {
            dsha256_pair(&leaves[i], &leaves[i + 1], &leaves[i / 2]);
        }
        idx /= 2;
    }

    return depth;
}

/// Compute the aux chain Merkle branch from a snapshot of hashes.
/// Used by submitauxblock to match the commitment built at GBT time.
/// Hashes in the snapshot are in display byte order; they are reversed
/// to internal order for SHA256d computation (matching Dogecoin's
/// CheckMerkleBranch verification).
pub fn getSnapshotMerkleBranch(
    snapshot: *const [max_chains][32]u8,
    tree_size: u32,
    slot: u32,
    branch: *[max_aux_branch_depth][32]u8,
) usize {
    if (tree_size <= 1) return 0;

    // Copy snapshot into mutable working array, reversing to internal order
    var leaves: [max_chains][32]u8 = undefined;
    for (0..tree_size) |i| {
        leaves[i] = snapshot[i];
        std.mem.reverse(u8, &leaves[i]); // display → internal
    }

    var depth: usize = 0;
    var idx: u32 = slot;
    var level_size: u32 = tree_size;

    while (level_size > 1) : (level_size /= 2) {
        const sibling = idx ^ 1;
        branch[depth] = leaves[sibling];
        depth += 1;

        var i: u32 = 0;
        while (i < level_size) : (i += 2) {
            dsha256_pair(&leaves[i], &leaves[i + 1], &leaves[i / 2]);
        }
        idx /= 2;
    }

    return depth;
}

/// Serialize an AuxPoW proof in the CAuxPow binary format.
/// Returns heap-allocated binary proof (caller frees).
pub fn serializeProof(
    allocator: std.mem.Allocator,
    coinbase_raw: []const u8,
    cb_branch: []const [32]u8,
    aux_branch: []const [32]u8,
    chain_slot: u32,
    parent_header: *const [80]u8,
) ![]u8 {
    // Total size: coinbase + 32 hashBlock + (1 + cb*32) + 4 index + (1 + aux*32) + 4 index + 80 header
    const size = coinbase_raw.len + 32 + 1 + (cb_branch.len * 32) + 4 + 1 + (aux_branch.len * 32) + 4 + 80;
    const buf = try allocator.alloc(u8, size);
    var pos: usize = 0;

    // 1. Raw coinbase transaction (CMerkleTx::CTransaction)
    @memcpy(buf[pos..][0..coinbase_raw.len], coinbase_raw);
    pos += coinbase_raw.len;

    // 2. hashBlock (32 zero bytes — unused for AuxPoW)
    @memset(buf[pos..][0..32], 0);
    pos += 32;

    // 3. Coinbase Merkle branch (CompactSize + hashes)
    buf[pos] = @intCast(cb_branch.len);
    pos += 1;
    for (cb_branch) |hash| {
        @memcpy(buf[pos..][0..32], &hash);
        pos += 32;
    }

    // 4. Coinbase Merkle index (always 0 — coinbase is first tx)
    @memset(buf[pos..][0..4], 0);
    pos += 4;

    // 5. Aux chain Merkle branch (CompactSize + hashes)
    buf[pos] = @intCast(aux_branch.len);
    pos += 1;
    for (aux_branch) |hash| {
        @memcpy(buf[pos..][0..32], &hash);
        pos += 32;
    }

    // 6. Aux chain Merkle index (chain's slot in the tree)
    const slot_le = std.mem.nativeToLittle(u32, chain_slot);
    @memcpy(buf[pos..][0..4], std.mem.asBytes(&slot_le));
    pos += 4;

    // 7. Parent block header (80 bytes)
    @memcpy(buf[pos..][0..80], parent_header);
    pos += 80;

    return buf[0..pos];
}

/// Convert bytes to lowercase hex string.
pub fn bytesToHex(bytes: []const u8, out: []u8) void {
    const hex_chars = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
}

/// Compute deterministic slot index using the Namecoin/Dogecoin LCG algorithm.
/// Matches getExpectedIndex() in aux chain verification code exactly.
fn getExpectedIndex(nonce: u32, chain_id: i32, tree_size: u32) u32 {
    var rand: u32 = nonce;
    rand = rand *% 1103515245 +% 12345;
    rand +%= @bitCast(@as(i32, chain_id));
    rand = rand *% 1103515245 +% 12345;
    return rand % tree_size;
}

/// Compute difficulty from a 32-byte target in LITTLE-ENDIAN byte order
/// (as returned by getauxblock RPC — LSB at index 0, MSB at index 31).
fn diffFromTarget(target: *const [32]u8) f64 {
    // Find the most significant non-zero byte (scan from MSB end)
    var msb_pos: usize = 31;
    while (msb_pos > 0 and target[msb_pos] == 0) {
        msb_pos -= 1;
    }
    if (target[msb_pos] == 0) return std.math.inf(f64);

    const target_val: f64 = @floatFromInt(target[msb_pos]);
    if (target_val == 0) return std.math.inf(f64);

    // leading_zeros = number of zero bytes from the MSB end
    const leading_zeros: usize = 31 - msb_pos;

    // Approximate: diff ≈ 2^(8*leading_zeros) * 256 / first_nonzero_msb_byte
    const shift: f64 = @floatFromInt(leading_zeros * 8);
    return std.math.pow(f64, 2.0, shift) * 256.0 / target_val;
}

test "buildMerkleRoot with single chain" {
    // With one chain and tree_size=1, the root should be the chain's hash
    var state = State{
        .allocator = std.testing.allocator,
        .chains = &.{},
        .tree_size = 1,
    };
    state.buildMerkleRoot();
    try std.testing.expectEqual(std.mem.zeroes([32]u8), state.merkle_root);
}
