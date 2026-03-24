const std = @import("std");
const posix = std.posix;
const config = @import("config.zig");
const rpc = @import("rpc.zig");
const auxpow = @import("auxpow.zig");

const log = std.log.scoped(.socket);

const IDENT_LISTENER: usize = 0;
const IDENT_AUX_TIMER: usize = 1;
const IDENT_CLIENT_BASE: usize = 1000;

/// Serve the ckpool generator Unix socket protocol.
/// Uses kqueue for event-driven I/O (FreeBSD native).
pub fn serve(allocator: std.mem.Allocator, cfg: config.Config) !void {
    // Remove stale socket file if it exists
    std.fs.cwd().deleteFile(cfg.socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    // Create and bind Unix domain socket
    const addr = try std.net.Address.initUnix(cfg.socket_path);
    const sockfd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
    defer posix.close(sockfd);

    try posix.bind(sockfd, &addr.any, addr.getOsSockLen());
    try posix.listen(sockfd, 128);

    log.info("listening on {s}", .{cfg.socket_path});

    // Initialize RPC clients
    var parent_rpc = rpc.Client.init(allocator, cfg.parent.host, cfg.parent.port, cfg.parent.user, cfg.parent.pass);
    defer parent_rpc.deinit();

    // Initialize aux chain state
    var aux_state = auxpow.State.init(allocator, cfg.aux_chains);
    defer aux_state.deinit();

    // Create kqueue
    const kqfd = try posix.kqueue();
    defer posix.close(kqfd);

    // Register listening socket for read events (new connections)
    var changelist: [2]posix.Kevent = undefined;
    changelist[0] = makeEvent(sockfd, posix.system.EVFILT.READ, posix.system.EV.ADD, IDENT_LISTENER);

    // Register aux template refresh timer (fires every poll_interval_ms)
    const timer_ms: isize = @intCast(cfg.parent.poll_interval_ms);
    changelist[1] = .{
        .ident = IDENT_AUX_TIMER,
        .filter = posix.system.EVFILT.TIMER,
        .flags = posix.system.EV.ADD,
        .fflags = 0,
        .data = timer_ms,
        .udata = IDENT_AUX_TIMER,
    };

    // Apply initial registrations
    _ = try posix.kevent(kqfd, &changelist, &[0]posix.Kevent{}, null);

    log.info("kqueue event loop started (timer={d}ms, aux_chains={d})", .{
        cfg.parent.poll_interval_ms,
        aux_state.chain_count(),
    });

    // Main event loop
    var events: [64]posix.Kevent = undefined;
    while (true) {
        const n = try posix.kevent(kqfd, &[0]posix.Kevent{}, &events, null);

        for (events[0..n]) |ev| {
            if (ev.udata == IDENT_LISTENER) {
                // New connection on listening socket
                acceptAndHandle(allocator, sockfd, &parent_rpc, &aux_state);
            } else if (ev.udata == IDENT_AUX_TIMER) {
                // Timer fired — refresh aux chain templates
                refreshAuxTemplates(allocator, &aux_state);
            }
            // Future: ZMQ PULL fd events (IDENT_ZMQ_PULL)
        }
    }
}

fn makeEvent(fd: posix.fd_t, filter: i16, flags: u16, udata: usize) posix.Kevent {
    return .{
        .ident = @intCast(fd),
        .filter = filter,
        .flags = flags,
        .fflags = 0,
        .data = 0,
        .udata = udata,
    };
}

fn acceptAndHandle(
    allocator: std.mem.Allocator,
    sockfd: posix.fd_t,
    parent_rpc: *rpc.Client,
    aux_state: *auxpow.State,
) void {
    // Accept all pending connections (non-blocking socket)
    while (true) {
        const conn = posix.accept(sockfd, null, null) catch |err| {
            if (err == error.WouldBlock) break;
            log.warn("accept failed: {}", .{err});
            break;
        };

        handleConnection(allocator, conn, parent_rpc, aux_state) catch |err| {
            log.warn("connection handler error: {}", .{err});
        };
        posix.close(conn);
    }
}

fn refreshAuxTemplates(allocator: std.mem.Allocator, aux_state: *auxpow.State) void {
    if (aux_state.chain_count() == 0) return;
    aux_state.refreshTemplates(allocator) catch |err| {
        log.warn("aux template refresh failed: {}", .{err});
    };
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
