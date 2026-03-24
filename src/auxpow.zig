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
                    chain.valid = true;
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

        // Build per-chain JSON array entries
        var chains_json = try std.fmt.allocPrint(allocator, "", .{});
        for (self.chains, 0..) |chain, i| {
            if (!chain.valid) continue;
            const sep = if (chains_json.len > 0) "," else "";
            const new = try std.fmt.allocPrint(allocator,
                "{s}{{\"chain_id\":\"{s}\",\"hash\":\"{s}\",\"target\":\"{s}\",\"diff\":{d:.6},\"slot\":{d}}}",
                .{ sep, chain.chain_id, chain.hash_hex, chain.target_hex, chain.diff, i },
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
        // Simple sequential slot assignment for now.
        // A production implementation would hash chain_id to determine
        // the slot position in the Merkle tree.
        for (self.chains, 0..) |*chain, i| {
            chain.slot = @intCast(i);
        }
    }

    fn buildMerkleRoot(self: *State) void {
        if (self.chains.len == 0) {
            self.merkle_root = std.mem.zeroes([32]u8);
            return;
        }

        // Build leaf nodes (tree_size slots, unused slots are zero-filled)
        var leaves: [max_chains][32]u8 = undefined;
        for (&leaves) |*leaf| {
            leaf.* = std.mem.zeroes([32]u8);
        }
        for (self.chains) |chain| {
            if (chain.valid and chain.slot < self.tree_size) {
                leaves[chain.slot] = chain.hash;
            }
        }

        // Build tree bottom-up
        var level_size: u32 = self.tree_size;
        while (level_size > 1) : (level_size /= 2) {
            var i: u32 = 0;
            while (i < level_size) : (i += 2) {
                var hasher = std.crypto.hash.sha2.Sha256.init(.{});
                hasher.update(&leaves[i]);
                hasher.update(&leaves[i + 1]);
                var first_hash: [32]u8 = undefined;
                hasher.final(&first_hash);

                // Double SHA-256
                var hasher2 = std.crypto.hash.sha2.Sha256.init(.{});
                hasher2.update(&first_hash);
                hasher2.final(&leaves[i / 2]);
            }
        }

        self.merkle_root = leaves[0];
    }
};

/// Convert bytes to lowercase hex string.
fn bytesToHex(bytes: []const u8, out: []u8) void {
    const hex_chars = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
}

/// Compute difficulty from a 32-byte target (Bitcoin difficulty calculation).
fn diffFromTarget(target: *const [32]u8) f64 {
    // Bitcoin truediffone = 0x00000000FFFF << 208
    // diff = truediffone / target_as_bignum
    // Simple approximation: count leading zero bytes and compute from first non-zero
    var first_nonzero: usize = 0;
    while (first_nonzero < 32 and target[first_nonzero] == 0) {
        first_nonzero += 1;
    }
    if (first_nonzero >= 32) return std.math.inf(f64);

    const target_val: f64 = @floatFromInt(target[first_nonzero]);
    if (target_val == 0) return std.math.inf(f64);

    // Approximate: diff ≈ 2^(8*leading_zeros) * 256 / first_byte
    const shift: f64 = @floatFromInt(first_nonzero * 8);
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
