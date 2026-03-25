const std = @import("std");
const posix = std.posix;
const config = @import("config.zig");
const rpc = @import("rpc.zig");
const auxpow = @import("auxpow.zig");
const zmq = @import("zmq.zig");

const log = std.log.scoped(.http);

// --- kqueue filter constants (FreeBSD stable ABI) ---
const EVFILT_READ: i16 = -1;
const EVFILT_TIMER: i16 = -7;
const EV_ADD: u16 = 0x0001;
const EV_ENABLE: u16 = 0x0004;
const NOTE_MSECONDS: u32 = 0x00000002;

// --- Event identification via udata ---
const UDATA_LISTENER: usize = 0;
const UDATA_AUX_TIMER: usize = 1;

// --- Worker pool sizing ---
const WORKER_COUNT: usize = 4;
const JOB_QUEUE_CAPACITY: usize = 64;

/// Shared proxy state protected by a mutex for thread-safe access.
const SharedState = struct {
    parent_rpc: rpc.Client,
    aux_state: auxpow.State,
    mutex: std.Thread.Mutex = .{},

    // Cached coinbase Merkle branch from the last GBT response.
    // Pre-computed from GBT transaction txids — independent of the actual coinbase hash.
    cb_branch: [auxpow.max_cb_branch_depth][32]u8 = undefined,
    cb_branch_depth: usize = 0,

    // Snapshot of aux chain state from the last GBT enrichment.
    // Used for proof branch computation in submitauxblock to match
    // the commitment that was placed in the coinbase.
    aux_snapshot_hashes: [auxpow.max_chains][32]u8 = undefined,
    aux_snapshot_tree_size: u32 = 0,
    aux_snapshot_count: usize = 0,

    // Flag: aux templates need refresh (set on first call and after
    // successful aux block submit or ZMQ hashblock from aux chain).
    // Each getauxblock call creates a NEW pending block in the aux
    // daemon, invalidating the previous hash. Only refresh when needed.
    aux_needs_refresh: bool = true,
};

/// A unit of work: one accepted TCP connection.
const Job = struct {
    conn: posix.socket_t,
};

/// Bounded FIFO queue with blocking pop via condition variable.
const JobQueue = struct {
    mutex: std.Thread.Mutex = .{},
    not_empty: std.Thread.Condition = .{},
    buf: [JOB_QUEUE_CAPACITY]Job = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,

    fn push(self: *JobQueue, job: Job) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.count == JOB_QUEUE_CAPACITY) {
            log.warn("job queue full, dropping connection", .{});
            posix.close(job.conn);
            return;
        }
        self.buf[self.tail] = job;
        self.tail = (self.tail + 1) % JOB_QUEUE_CAPACITY;
        self.count += 1;
        self.not_empty.signal();
    }

    fn pop(self: *JobQueue) Job {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.count == 0) {
            self.not_empty.wait(&self.mutex);
        }
        const job = self.buf[self.head];
        self.head = (self.head + 1) % JOB_QUEUE_CAPACITY;
        self.count -= 1;
        return job;
    }
};

/// Fixed-size thread pool that processes accepted connections.
const WorkerPool = struct {
    threads: [WORKER_COUNT]std.Thread = undefined,
    queue: JobQueue = .{},
    shared: *SharedState,

    fn start(self: *WorkerPool) !void {
        for (&self.threads) |*t| {
            t.* = try std.Thread.spawn(.{}, workerLoop, .{self});
        }
        log.info("worker pool: {d} threads started", .{WORKER_COUNT});
    }

    fn submit(self: *WorkerPool, conn: posix.socket_t) void {
        self.queue.push(.{ .conn = conn });
    }

    fn workerLoop(pool: *WorkerPool) void {
        while (true) {
            const job = pool.queue.pop();
            handleConnection(job.conn, pool.shared);
        }
    }
};

/// HTTP JSON-RPC proxy server.
/// Uses kqueue for event-driven accept + periodic aux refresh timer.
/// Worker thread pool handles blocking request processing.
pub fn serve(allocator: std.mem.Allocator, cfg: config.Config) !void {
    // Parse listen address
    const listen_hp = config.parseUrl(cfg.listen) catch {
        log.err("invalid listen address: {s}", .{cfg.listen});
        return error.InvalidListenAddress;
    };

    // Create TCP listener
    const sockfd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(sockfd);

    // SO_REUSEADDR
    try posix.setsockopt(sockfd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

    const addr = try std.net.Address.parseIp4(listen_hp.host, listen_hp.port);
    try posix.bind(sockfd, &addr.any, addr.getOsSockLen());
    try posix.listen(sockfd, 128);

    log.info("HTTP JSON-RPC proxy listening on {s}:{d}", .{ listen_hp.host, listen_hp.port });

    // Initialize shared state (parent RPC + aux chains)
    var shared = SharedState{
        .parent_rpc = rpc.Client.init(allocator, cfg.parent.host, cfg.parent.port, cfg.parent.user, cfg.parent.pass),
        .aux_state = auxpow.State.init(allocator, cfg.aux_chains),
    };
    defer shared.parent_rpc.deinit();
    defer shared.aux_state.deinit();

    // Start worker thread pool
    var pool = WorkerPool{ .shared = &shared };
    try pool.start();

    // Start ZMQ block notification aggregator (if configured)
    var zmq_agg: ?zmq.Aggregator = null;
    zmq_blk: {
        const pub_endpoint = cfg.zmq_pub orelse break :zmq_blk;
        zmq_agg = zmq.Aggregator.init(pub_endpoint, cfg) catch |err| {
            log.err("ZMQ aggregator init failed: {}, continuing without ZMQ", .{err});
            break :zmq_blk;
        };
        const zmq_thread = std.Thread.spawn(.{}, zmq.Aggregator.run, .{&zmq_agg.?}) catch |err| {
            log.err("ZMQ thread spawn failed: {}, continuing without ZMQ", .{err});
            zmq_agg.?.deinit();
            zmq_agg = null;
            break :zmq_blk;
        };
        zmq_thread.detach();
    }

    // Create kqueue and register events
    const kq = try posix.kqueue();
    defer posix.close(kq);

    var changelist: [2]posix.Kevent = undefined;
    var n_changes: usize = 0;

    // Watch listener socket for incoming connections
    changelist[n_changes] = makeEvent(sockfd, EVFILT_READ, EV_ADD | EV_ENABLE, UDATA_LISTENER);
    n_changes += 1;

    // NOTE: No timer-driven aux template refresh. Each getauxblock call
    // creates a NEW pending block in the aux daemon and invalidates the
    // previous one. Proactive refresh would break proof submission by
    // invalidating hashes before shares can use them. Instead, aux
    // templates are refreshed inline in handleGetBlockTemplate.

    // Apply registrations (empty eventlist = return immediately)
    _ = try posix.kevent(kq, changelist[0..n_changes], &[0]posix.Kevent{}, null);

    log.info("kqueue event loop started (workers={d}, aux_chains={d})", .{
        WORKER_COUNT,
        shared.aux_state.chain_count(),
    });

    // Main event loop — single thread, no blocking I/O
    var eventlist: [16]posix.Kevent = undefined;
    while (true) {
        const n_events = posix.kevent(kq, &[0]posix.Kevent{}, &eventlist, null) catch |err| {
            log.warn("kevent failed: {}", .{err});
            continue;
        };

        for (eventlist[0..n_events]) |ev| {
            switch (ev.udata) {
                UDATA_LISTENER => {
                    // Accept pending connections (ev.data = backlog count)
                    var i: isize = 0;
                    while (i < ev.data) : (i += 1) {
                        const conn = posix.accept(sockfd, null, null, 0) catch |err| {
                            log.warn("accept failed: {}", .{err});
                            break;
                        };
                        pool.submit(conn);
                    }
                },
                UDATA_AUX_TIMER => {
                    // Refresh aux chain block templates on timer tick
                    shared.mutex.lock();
                    defer shared.mutex.unlock();
                    shared.aux_state.refreshTemplates(allocator) catch |err| {
                        log.warn("aux template refresh failed: {}", .{err});
                    };
                },
                else => {},
            }
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

fn makeTimerEvent(ident: usize, interval_ms: u32, flags: u16) posix.Kevent {
    return .{
        .ident = ident,
        .filter = EVFILT_TIMER,
        .flags = flags,
        .fflags = NOTE_MSECONDS,
        .data = @intCast(interval_ms),
        .udata = ident,
    };
}

/// Handle a single connection: read one request, dispatch, respond, close.
fn handleConnection(conn: posix.socket_t, shared: *SharedState) void {
    defer posix.close(conn);

    // Per-request arena allocator — freed when this function returns
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    handleHttpRequest(arena.allocator(), conn, shared) catch |err| {
        if (err == error.EndOfStream) return;
        log.warn("HTTP handler error: {}", .{err});
        sendHttpResponse(conn, 502, "{\"result\":null,\"error\":{\"code\":-1,\"message\":\"upstream connection failed\"},\"id\":null}") catch {};
    };
}

// --- HTTP Request Handling ---

fn handleHttpRequest(
    allocator: std.mem.Allocator,
    conn: posix.socket_t,
    shared: *SharedState,
) !void {
    // Read HTTP request (heap-allocated — too large for stack)
    const buf = try allocator.alloc(u8, 256 * 1024); // 256KB max request
    defer allocator.free(buf);
    var total: usize = 0;

    while (total < buf.len) {
        const n = posix.read(conn, buf[total..]) catch break;
        if (n == 0) break;
        total += n;

        log.debug("read {d} bytes (total: {d})", .{ n, total });

        // Check if we've received the full HTTP request (headers + body)
        // Support both \r\n\r\n (standard HTTP) and \n\n (ckpool uses plain \n)
        const sep = findHeaderSeparator(buf[0..total]);
        if (sep) |s| {
            const headers = buf[0..s.pos];
            const cl = findContentLength(headers);
            const body_start = s.pos + s.len;
            const body_received = total - body_start;
            log.debug("header_sep at {d} (len {d}), content_length={?d}, body_received={d}", .{ s.pos, s.len, cl, body_received });
            if (cl) |content_len| {
                if (body_received >= content_len) break;
            } else {
                break; // No content-length, assume complete
            }
        } else {
            log.debug("no header separator found yet", .{});
        }
    }

    if (total == 0) return error.EndOfStream;

    const request = buf[0..total];

    // Find the body (after header separator)
    const sep = findHeaderSeparator(request) orelse return;
    const body = request[sep.pos + sep.len ..];

    if (body.len == 0) {
        try sendHttpResponse(conn, 400, "{\"error\":\"empty body\"}");
        return;
    }

    log.debug("JSON-RPC request: {d} bytes", .{body.len});

    // Parse the JSON-RPC method to decide routing
    const method = extractMethod(body);

    if (method) |m| {
        if (std.mem.eql(u8, m, "getblocktemplate")) {
            shared.mutex.lock();
            defer shared.mutex.unlock();
            if (shared.aux_state.chain_count() > 0) {
                // Intercept only when aux chains configured; otherwise transparent proxy
                const response_body = try handleGetBlockTemplate(allocator, body, shared);
                defer allocator.free(response_body);
                try sendHttpResponse(conn, 200, response_body);
                return;
            }
        }

        if (std.mem.eql(u8, m, "submitauxblock")) {
            shared.mutex.lock();
            defer shared.mutex.unlock();
            const response_body = try handleSubmitAuxBlock(allocator, body, shared);
            defer allocator.free(response_body);
            try sendHttpResponse(conn, 200, response_body);
            return;
        }
    }

    // Default: transparent proxy to parent daemon
    // No mutex needed — rpc.Client.httpPost creates a new TCP socket per call
    // and only reads immutable config fields (host, port, user, pass)
    log.info("proxying {d}-byte request to parent daemon", .{body.len});
    const response_body = try shared.parent_rpc.rawCall(allocator, body);
    log.info("got {d}-byte response from parent, sending to client", .{response_body.len});
    defer allocator.free(response_body);
    try sendHttpResponse(conn, 200, response_body);
    log.info("response sent to client", .{});
}

fn sendHttpResponse(conn: posix.socket_t, status: u16, body: []const u8) !void {
    const status_text = if (status == 200) "OK" else "Bad Request";

    // Ensure body ends with \n (ckpool's read_socket_line requires line terminator)
    const needs_newline = body.len == 0 or body[body.len - 1] != '\n';
    const content_length = body.len + @as(usize, if (needs_newline) 1 else 0);

    var header_buf: [512]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf,
        "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status, status_text, content_length },
    ) catch return error.HeaderTooLong;

    _ = try posix.write(conn, header);
    _ = try posix.write(conn, body);
    if (needs_newline) {
        _ = try posix.write(conn, "\n");
    }
}

const HeaderSep = struct { pos: usize, len: usize };

/// Find the header/body separator — supports both \r\n\r\n (standard) and \n\n (ckpool)
fn findHeaderSeparator(data: []const u8) ?HeaderSep {
    // Check for standard \r\n\r\n first
    if (std.mem.indexOf(u8, data, "\r\n\r\n")) |pos| {
        return .{ .pos = pos, .len = 4 };
    }
    // Fallback: \n\n (ckpool sends plain \n line endings)
    if (std.mem.indexOf(u8, data, "\n\n")) |pos| {
        return .{ .pos = pos, .len = 2 };
    }
    return null;
}

fn findContentLength(headers: []const u8) ?usize {
    // Case-insensitive search for Content-Length header
    // Supports both \r\n and \n line endings
    var i: usize = 0;
    while (i < headers.len) {
        // Find next line (handle both \r\n and \n)
        const line_end = std.mem.indexOf(u8, headers[i..], "\n") orelse headers.len - i;
        var line = headers[i .. i + line_end];
        // Strip trailing \r if present
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }

        if (line.len > 14 and isContentLengthHeader(line)) {
            if (std.mem.indexOf(u8, line, ":")) |colon| {
                const val_str = std.mem.trim(u8, line[colon + 1 ..], " \t");
                return std.fmt.parseInt(usize, val_str, 10) catch null;
            }
        }
        i += line_end + 1;
    }
    return null;
}

fn isContentLengthHeader(line: []const u8) bool {
    const prefix = "content-length";
    if (line.len < prefix.len) return false;
    for (line[0..prefix.len], prefix) |a, b| {
        if (std.ascii.toLower(a) != b) return false;
    }
    return true;
}

/// Extract the "method" string from a JSON-RPC request body without full parsing.
fn extractMethod(body: []const u8) ?[]const u8 {
    // Fast scan for "method":"..." pattern
    const needle = "\"method\"";
    const idx = std.mem.indexOf(u8, body, needle) orelse return null;
    const after = body[idx + needle.len ..];

    // Skip whitespace and colon
    var pos: usize = 0;
    while (pos < after.len and (after[pos] == ' ' or after[pos] == ':' or after[pos] == '\t')) {
        pos += 1;
    }
    if (pos >= after.len or after[pos] != '"') return null;
    pos += 1; // skip opening quote

    // Find closing quote
    const start = pos;
    while (pos < after.len and after[pos] != '"') {
        pos += 1;
    }
    if (pos >= after.len) return null;

    return after[start..pos];
}

// --- Method-Specific Handlers ---

fn handleGetBlockTemplate(
    allocator: std.mem.Allocator,
    request_body: []const u8,
    shared: *SharedState,
) ![]const u8 {
    log.info("getblocktemplate: forwarding {d} bytes to parent", .{request_body.len});

    // Forward to parent daemon
    var response = try shared.parent_rpc.rawCall(allocator, request_body);
    log.info("getblocktemplate: got {d} bytes from parent", .{response.len});

    // Cache coinbase Merkle branch from GBT transactions (for submitauxblock proofs)
    cacheCbMerkleBranch(allocator, response, shared);

    // Enrich the coinbaseaux.flags with AuxPoW commitment
    if (shared.aux_state.chain_count() > 0) {
        // Only refresh aux templates when needed (first call, after successful
        // aux block submit, or after ZMQ hashblock from aux chain). Each
        // getauxblock call creates a NEW pending block, invalidating the old hash.
        if (shared.aux_needs_refresh) {
            shared.aux_state.refreshTemplates(allocator) catch |err| {
                log.warn("aux template refresh in getblocktemplate: {}", .{err});
            };
            shared.aux_needs_refresh = false;
        }

        // Snapshot aux hashes for proof construction in submitauxblock.
        // Must match the hashes used in the commitment below.
        shared.aux_snapshot_tree_size = shared.aux_state.tree_size;
        shared.aux_snapshot_count = shared.aux_state.chains.len;
        for (shared.aux_state.chains) |chain| {
            if (chain.valid and chain.slot < shared.aux_state.tree_size) {
                shared.aux_snapshot_hashes[chain.slot] = chain.hash;
            }
        }

        // Build aux fields JSON and inject into coinbaseaux.flags
        if (try shared.aux_state.auxFieldsJson(allocator)) |aux_fields| {
            defer allocator.free(aux_fields);

            // Also build the flags hex for coinbase commitment
            var root_hex: [64]u8 = undefined;
            auxpow.bytesToHex(&shared.aux_state.merkle_root, &root_hex);

            var tree_size_hex: [8]u8 = undefined;
            // AuxPoW spec: commitment stores tree_size-1. Verification adds 1
            // to get the modulus for getExpectedIndex slot computation.
            const ts_le = std.mem.nativeToLittle(u32, shared.aux_state.tree_size - 1);
            auxpow.bytesToHex(std.mem.asBytes(&ts_le), &tree_size_hex);

            var tree_nonce_hex: [8]u8 = undefined;
            const tn_le = std.mem.nativeToLittle(u32, shared.aux_state.tree_nonce);
            auxpow.bytesToHex(std.mem.asBytes(&tn_le), &tree_nonce_hex);

            // AuxPoW commitment: magic + root + tree_size + tree_nonce
            const commitment_hex = try std.fmt.allocPrint(allocator,
                "fabe6d6d{s}{s}{s}",
                .{ root_hex, tree_size_hex, tree_nonce_hex },
            );
            defer allocator.free(commitment_hex);

            // Inject aux fields + enriched flags into the response
            const enriched = try injectAuxData(allocator, response, commitment_hex, aux_fields);
            allocator.free(response);
            response = enriched;
        }
    }

    return response;
}

/// Extract transaction txids from a GBT JSON response and cache the
/// coinbase Merkle branch in shared state.
fn cacheCbMerkleBranch(allocator: std.mem.Allocator, response: []const u8, shared: *SharedState) void {
    // Parse the JSON response to extract transaction txids
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{
        .allocate = .alloc_always,
    }) catch return;
    defer parsed.deinit();

    const result_val = parsed.value.object.get("result") orelse return;
    if (result_val != .object) return;
    const txns_val = result_val.object.get("transactions") orelse {
        // No transactions — coinbase only, branch depth = 0
        shared.cb_branch_depth = 0;
        return;
    };
    if (txns_val != .array) return;
    const txns = txns_val.array.items;

    if (txns.len == 0) {
        shared.cb_branch_depth = 0;
        return;
    }

    // Extract txid hashes (binary, 32 bytes each)
    const txids = allocator.alloc([32]u8, txns.len) catch return;
    defer allocator.free(txids);
    var valid: usize = 0;

    for (txns) |txn_val| {
        if (txn_val != .object) continue;
        const txid_str = if (txn_val.object.get("txid")) |v| (if (v == .string) v.string else null) else null;
        if (txid_str == null or txid_str.?.len != 64) continue;
        _ = std.fmt.hexToBytes(&txids[valid], txid_str.?) catch continue;
        valid += 1;
    }

    shared.cb_branch_depth = auxpow.computeCbMerkleBranch(
        allocator,
        txids[0..valid],
        &shared.cb_branch,
    ) catch 0;

    log.info("cached coinbase Merkle branch: depth={d} from {d} transactions", .{ shared.cb_branch_depth, valid });
}

fn handleSubmitAuxBlock(
    allocator: std.mem.Allocator,
    request_body: []const u8,
    shared: *SharedState,
) ![]const u8 {
    // Extract the first string parameter from JSON-RPC body
    // Format: {"method":"submitauxblock","params":["chain_id:aux_hash:coinbase_hex:header_hex:nonce"]}
    const params_str = extractFirstStringParam(request_body) orelse {
        log.warn("submitauxblock: failed to extract params", .{});
        return try allocator.dupe(u8, "{\"result\":null,\"error\":{\"code\":-1,\"message\":\"invalid params\"},\"id\":null}");
    };

    // Parse colon-delimited fields: chain_id:aux_hash:coinbase_hex:header_hex:nonce
    var iter = std.mem.splitScalar(u8, params_str, ':');
    const chain_id = iter.next() orelse return error.InvalidAuxSubmit;
    const aux_hash = iter.next() orelse return error.InvalidAuxSubmit;
    const coinbase_hex = iter.next() orelse return error.InvalidAuxSubmit;
    const header_hex = iter.next() orelse return error.InvalidAuxSubmit;
    // nonce field ignored (already incorporated in header)

    log.info("submitauxblock for {s}: aux_hash={s}", .{ chain_id, aux_hash });

    // Find the matching chain
    var chain_idx: ?usize = null;
    for (shared.aux_state.chains, 0..) |chain, i| {
        if (std.mem.eql(u8, chain.chain_id, chain_id)) {
            chain_idx = i;
            break;
        }
    }
    if (chain_idx == null) {
        log.warn("submitauxblock: unknown chain {s}", .{chain_id});
        return try allocator.dupe(u8, "{\"result\":null,\"error\":{\"code\":-1,\"message\":\"unknown chain\"},\"id\":null}");
    }

    const chain = &shared.aux_state.chains[chain_idx.?];

    // Decode coinbase hex to binary
    if (coinbase_hex.len % 2 != 0) return error.InvalidAuxSubmit;
    const cb_raw = try allocator.alloc(u8, coinbase_hex.len / 2);
    defer allocator.free(cb_raw);
    _ = std.fmt.hexToBytes(cb_raw, coinbase_hex) catch return error.InvalidAuxSubmit;

    // Decode header hex to binary (must be 80 bytes = 160 hex chars)
    if (header_hex.len != 160) return error.InvalidAuxSubmit;
    var header_raw: [80]u8 = undefined;
    _ = std.fmt.hexToBytes(&header_raw, header_hex) catch return error.InvalidAuxSubmit;

    // ckpool/SeaTidePool sends the header as 'swap' (after flip_80), which
    // converts from stratum big-endian-per-word to standard little-endian
    // serialization. Use as-is — this IS the standard 80-byte block header.

    // Get aux chain Merkle branch from the SNAPSHOT (matches the commitment
    // that was placed in the coinbase at GBT enrichment time).
    var aux_branch: [auxpow.max_aux_branch_depth][32]u8 = undefined;
    const aux_depth = auxpow.getSnapshotMerkleBranch(
        &shared.aux_snapshot_hashes,
        shared.aux_snapshot_tree_size,
        chain.slot,
        &aux_branch,
    );

    // Serialize the AuxPoW proof
    const proof_bin = try auxpow.serializeProof(
        allocator,
        cb_raw,
        shared.cb_branch[0..shared.cb_branch_depth],
        aux_branch[0..aux_depth],
        chain.slot,
        &header_raw,
    );
    defer allocator.free(proof_bin);

    // Hex-encode the proof
    const proof_hex = try allocator.alloc(u8, proof_bin.len * 2);
    defer allocator.free(proof_hex);
    auxpow.bytesToHex(proof_bin, proof_hex);

    log.info("submitauxblock: proof {d} bytes for {s} (cb_branch={d}, aux_branch={d})", .{
        proof_bin.len, chain_id, shared.cb_branch_depth, aux_depth,
    });

    // Submit to aux chain daemon via RPC
    const result = chain.rpc_client.submitAuxBlock(allocator, aux_hash, proof_hex) catch |err| {
        log.err("submitauxblock RPC failed for {s}: {}", .{ chain_id, err });
        return try std.fmt.allocPrint(allocator,
            "{{\"result\":null,\"error\":{{\"code\":-1,\"message\":\"aux daemon RPC failed\"}},\"id\":null}}",
            .{},
        );
    };
    defer allocator.free(result);

    log.info("submitauxblock result for {s}: {s}", .{ chain_id, result });

    // If accepted, flag for aux template refresh on next GBT call
    if (std.mem.eql(u8, result, "true")) {
        shared.aux_needs_refresh = true;
        log.info("aux block accepted for {s}, will refresh templates on next GBT", .{chain_id});
    }

    return try std.fmt.allocPrint(allocator,
        "{{\"result\":\"{s}\",\"error\":null,\"id\":null}}",
        .{result},
    );
}

/// Extract the first string parameter from a JSON-RPC request body.
/// Finds "params":["..."] and returns the contents of the first string.
fn extractFirstStringParam(body: []const u8) ?[]const u8 {
    const needle = "\"params\"";
    const idx = std.mem.indexOf(u8, body, needle) orelse return null;
    const after = body[idx + needle.len ..];

    // Skip whitespace, colon, whitespace, opening bracket
    var pos: usize = 0;
    while (pos < after.len and (after[pos] == ' ' or after[pos] == ':' or after[pos] == '\t' or after[pos] == '[')) {
        pos += 1;
    }
    if (pos >= after.len or after[pos] != '"') return null;
    pos += 1; // skip opening quote

    // Find closing quote
    const start = pos;
    while (pos < after.len and after[pos] != '"') {
        pos += 1;
    }
    if (pos >= after.len) return null;

    return after[start..pos];
}

/// Inject AuxPoW commitment into coinbaseaux.flags and add aux_chains fields
/// to a getblocktemplate JSON-RPC response.
fn injectAuxData(
    allocator: std.mem.Allocator,
    response: []const u8,
    commitment_hex: []const u8,
    aux_fields_json: []const u8,
) ![]const u8 {
    var result = try allocator.dupe(u8, response);

    // 1. Enrich coinbaseaux.flags with AuxPoW commitment
    //    Handle both "flags":"..." (append) and "coinbaseaux":{} (insert key)
    const flags_needle = "\"flags\":\"";
    if (std.mem.indexOf(u8, result, flags_needle)) |flags_idx| {
        // flags key exists — append commitment to the value
        const val_start = flags_idx + flags_needle.len;
        if (std.mem.indexOfScalarPos(u8, result, val_start, '"')) |val_end| {
            const old_flags = result[val_start..val_end];
            const new_flags = try std.fmt.allocPrint(allocator, "{s}{s}", .{ old_flags, commitment_hex });
            defer allocator.free(new_flags);

            const new_result = try std.fmt.allocPrint(allocator, "{s}{s}{s}",
                .{ result[0..val_start], new_flags, result[val_end..] },
            );
            allocator.free(result);
            result = new_result;
        }
    } else if (std.mem.indexOf(u8, result, "\"coinbaseaux\":{}")) |empty_idx| {
        // coinbaseaux is empty object — replace with flags key
        const replace_start = empty_idx;
        const replace_end = empty_idx + "\"coinbaseaux\":{}".len;
        const new_result = try std.fmt.allocPrint(allocator,
            "{s}\"coinbaseaux\":{{\"flags\":\"{s}\"}}{s}",
            .{ result[0..replace_start], commitment_hex, result[replace_end..] },
        );
        allocator.free(result);
        result = new_result;
    } else if (std.mem.indexOf(u8, result, "\"coinbaseaux\":{")) |obj_idx| {
        // coinbaseaux has content but no flags — insert flags at start
        const insert_pos = obj_idx + "\"coinbaseaux\":{".len;
        const new_result = try std.fmt.allocPrint(allocator,
            "{s}\"flags\":\"{s}\",{s}",
            .{ result[0..insert_pos], commitment_hex, result[insert_pos..] },
        );
        allocator.free(result);
        result = new_result;
    }

    // 2. Add aux_* fields to the result object
    //    Find },"error" which marks the end of the result object in JSON-RPC
    if (lastIndexOfSubstring(result, "},\"error\"")) |result_end| {
        const new_result = try std.fmt.allocPrint(allocator,
            "{s},{s}{s}",
            .{ result[0..result_end], aux_fields_json, result[result_end..] },
        );
        allocator.free(result);
        result = new_result;
    }

    return result;
}

fn lastIndexOfSubstring(haystack: []const u8, needle: []const u8) ?usize {
    if (haystack.len < needle.len) return null;
    var i: usize = haystack.len - needle.len;
    while (true) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) return i;
        if (i == 0) break;
        i -= 1;
    }
    return null;
}

test "extractMethod" {
    const m1 = extractMethod("{\"method\":\"getblocktemplate\",\"params\":[]}");
    try std.testing.expectEqualStrings("getblocktemplate", m1.?);

    const m2 = extractMethod("{\"method\": \"submitblock\", \"params\": [\"00ab\"]}");
    try std.testing.expectEqualStrings("submitblock", m2.?);

    const m3 = extractMethod("{\"params\":[]}");
    try std.testing.expect(m3 == null);
}
