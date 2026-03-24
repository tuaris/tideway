const std = @import("std");
const posix = std.posix;
const config = @import("config.zig");
const rpc = @import("rpc.zig");
const auxpow = @import("auxpow.zig");

const log = std.log.scoped(.socket);

/// Serve the ckpool generator Unix socket protocol.
/// This is the main event loop — blocks until shutdown.
pub fn serve(allocator: std.mem.Allocator, cfg: config.Config) !void {
    // Remove stale socket file if it exists
    std.fs.cwd().deleteFile(cfg.socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    // Create and bind Unix domain socket
    const addr = try std.net.Address.initUnix(cfg.socket_path);
    const sockfd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(sockfd);

    try posix.bind(sockfd, &addr.any, addr.getOsSockLen());
    try posix.listen(sockfd, 5);

    log.info("listening on {s}", .{cfg.socket_path});

    // Initialize RPC clients
    var parent_rpc = rpc.Client.init(allocator, cfg.parent.host, cfg.parent.port, cfg.parent.user, cfg.parent.pass);
    defer parent_rpc.deinit();

    // Initialize aux chain state
    var aux_state = auxpow.State.init(allocator, cfg.aux_chains);
    defer aux_state.deinit();

    // Accept loop
    while (true) {
        const conn = posix.accept(sockfd, null, null) catch |err| {
            log.warn("accept failed: {}", .{err});
            continue;
        };
        defer posix.close(conn);

        handleConnection(allocator, conn, &parent_rpc, &aux_state) catch |err| {
            log.warn("connection handler error: {}", .{err});
        };
    }
}

fn handleConnection(
    allocator: std.mem.Allocator,
    conn: posix.socket_t,
    parent_rpc: *rpc.Client,
    aux_state: *auxpow.State,
) !void {
    // Read the message (newline-delimited, like ckpool)
    var buf: [65536]u8 = undefined;
    const n = try posix.read(conn, &buf);
    if (n == 0) return;

    // Strip trailing newline
    var msg = buf[0..n];
    while (msg.len > 0 and (msg[msg.len - 1] == '\n' or msg[msg.len - 1] == '\r')) {
        msg = msg[0 .. msg.len - 1];
    }

    log.debug("received: {s}", .{msg});

    // Dispatch based on command prefix
    const response = dispatch(allocator, msg, parent_rpc, aux_state) catch |err| {
        log.warn("dispatch error for '{s}': {}", .{ msg, err });
        return sendResponse(conn, "failed");
    };
    defer if (response) |r| allocator.free(r);

    if (response) |r| {
        return sendResponse(conn, r);
    }
}

fn dispatch(
    allocator: std.mem.Allocator,
    msg: []const u8,
    parent_rpc: *rpc.Client,
    aux_state: *auxpow.State,
) !?[]const u8 {
    if (std.mem.eql(u8, msg, "ping")) {
        return try allocator.dupe(u8, "pong");
    }

    if (std.mem.eql(u8, msg, "getbase")) {
        return try handleGetbase(allocator, parent_rpc, aux_state);
    }

    if (std.mem.eql(u8, msg, "getbest")) {
        return try handleGetbest(allocator, parent_rpc);
    }

    if (std.mem.startsWith(u8, msg, "getlast")) {
        return try handleGetlast(allocator, parent_rpc);
    }

    if (std.mem.startsWith(u8, msg, "submitblock:")) {
        return try handleSubmitblock(allocator, msg[12..], parent_rpc);
    }

    if (std.mem.startsWith(u8, msg, "checkaddr:")) {
        return try handleCheckaddr(allocator, msg[10..], parent_rpc);
    }

    if (std.mem.startsWith(u8, msg, "checktxn:")) {
        return try handleChecktxn(allocator, msg[9..], parent_rpc);
    }

    if (std.mem.startsWith(u8, msg, "submitauxblock:")) {
        try handleSubmitauxblock(allocator, msg[15..], aux_state);
        return null;
    }

    if (std.mem.startsWith(u8, msg, "loglevel")) {
        // Acknowledge but no response needed
        return null;
    }

    if (std.mem.eql(u8, msg, "reconnect")) {
        log.info("reconnect requested — refreshing daemon connections");
        parent_rpc.reconnect();
        return null;
    }

    log.warn("unrecognised message: {s}", .{msg});
    return try allocator.dupe(u8, "unknown");
}

fn sendResponse(conn: posix.socket_t, msg: []const u8) !void {
    var iov = [_]posix.iovec_const{
        .{ .base = msg.ptr, .len = msg.len },
        .{ .base = "\n", .len = 1 },
    };
    _ = try posix.writev(conn, &iov);
}

// --- Command Handlers ---

fn handleGetbase(allocator: std.mem.Allocator, parent_rpc: *rpc.Client, aux_state: *auxpow.State) ![]const u8 {
    // Get parent chain block template
    var gbt_json = try parent_rpc.getBlockTemplate(allocator);
    defer gbt_json.deinit();

    // If aux chains are configured, fetch aux templates and add AuxPoW fields
    if (aux_state.chain_count() > 0) {
        try aux_state.refreshTemplates(allocator);
        try aux_state.injectAuxFields(allocator, &gbt_json);
    }

    // Serialize to JSON string for the stratifier
    return try serializeJson(allocator, gbt_json.value);
}

fn handleGetbest(allocator: std.mem.Allocator, parent_rpc: *rpc.Client) ![]const u8 {
    return try parent_rpc.getBestBlockHash(allocator);
}

fn handleGetlast(allocator: std.mem.Allocator, parent_rpc: *rpc.Client) ![]const u8 {
    const height = try parent_rpc.getBlockCount(allocator);
    return try parent_rpc.getBlockHash(allocator, height);
}

fn handleSubmitblock(allocator: std.mem.Allocator, data: []const u8, parent_rpc: *rpc.Client) ![]const u8 {
    // data format: "{hash}{block_hex}" — 64 char hash + block data
    if (data.len < 65) return error.InvalidSubmitblock;

    const block_hex = data[65..]; // skip hash + separator
    const result = try parent_rpc.submitBlock(allocator, block_hex);
    return result;
}

fn handleCheckaddr(allocator: std.mem.Allocator, addr: []const u8, parent_rpc: *rpc.Client) ![]const u8 {
    return try parent_rpc.validateAddress(allocator, addr);
}

fn handleChecktxn(allocator: std.mem.Allocator, txn_hex: []const u8, parent_rpc: *rpc.Client) ![]const u8 {
    return try parent_rpc.testMempoolAccept(allocator, txn_hex);
}

fn handleSubmitauxblock(allocator: std.mem.Allocator, data: []const u8, aux_state: *auxpow.State) !void {
    // data format: "chain_id:aux_hash:coinbase_hex:header_hex:nonce"
    try aux_state.submitAuxBlock(allocator, data);
}

fn serializeJson(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();
    try value.jsonStringify(.{}, list.writer());
    return try list.toOwnedSlice();
}
