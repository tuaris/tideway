const std = @import("std");
const posix = std.posix;
const config = @import("config.zig");
const rpc = @import("rpc.zig");
const auxpow = @import("auxpow.zig");

const log = std.log.scoped(.http);

/// Shared proxy state protected by a mutex for thread-safe access.
const SharedState = struct {
    parent_rpc: rpc.Client,
    aux_state: auxpow.State,
    mutex: std.Thread.Mutex = .{},
};

/// HTTP JSON-RPC proxy server.
/// Sits between SeaTidePool's generator and the parent chain daemon.
/// Transparently proxies all RPCs, intercepting getblocktemplate to enrich
/// with aux chain data and submitauxblock for merge mining block submission.
pub fn serve(allocator: std.mem.Allocator, cfg: config.Config) !void {
    // Parse listen address
    const listen_hp = config.parseUrl(cfg.listen) catch {
        log.err("invalid listen address: {s}", .{cfg.listen});
        return error.InvalidListenAddress;
    };

    // Create TCP listener with direct IPv4 bind
    const sockfd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(sockfd);

    // SO_REUSEADDR
    try posix.setsockopt(sockfd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

    const addr = try std.net.Address.parseIp4(listen_hp.host, listen_hp.port);
    try posix.bind(sockfd, &addr.any, addr.getOsSockLen());
    try posix.listen(sockfd, 128);

    log.info("HTTP JSON-RPC proxy listening on {s}:{d}", .{ listen_hp.host, listen_hp.port });

    // Initialize shared state (parent RPC client + aux chain state)
    var shared = SharedState{
        .parent_rpc = rpc.Client.init(allocator, cfg.parent.host, cfg.parent.port, cfg.parent.user, cfg.parent.pass),
        .aux_state = auxpow.State.init(allocator, cfg.aux_chains),
    };
    defer shared.parent_rpc.deinit();
    defer shared.aux_state.deinit();

    log.info("threaded accept loop started (aux_chains={d})", .{shared.aux_state.chain_count()});

    // Threaded accept loop — one thread per connection
    while (true) {
        const conn = posix.accept(sockfd, null, null, 0) catch |err| {
            log.warn("accept failed: {}", .{err});
            continue;
        };

        const thread = std.Thread.spawn(.{}, connectionThread, .{ conn, &shared }) catch |err| {
            log.warn("thread spawn failed: {}, handling inline", .{err});
            // Fallback: handle inline if thread creation fails
            handleConnection(conn, &shared);
            continue;
        };
        thread.detach();
    }
}

/// Per-connection thread entry point.
fn connectionThread(conn: posix.socket_t, shared: *SharedState) void {
    handleConnection(conn, shared);
}

/// Handle a single connection: read request, dispatch, respond, close.
fn handleConnection(conn: posix.socket_t, shared: *SharedState) void {
    defer posix.close(conn);

    // Per-request arena allocator — freed when this function returns
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    handleHttpRequest(arena.allocator(), conn, shared) catch |err| {
        log.warn("HTTP handler error: {}", .{err});
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

    if (total == 0) return;

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
                const response_body = try handleGetBlockTemplate(allocator, body, &shared.parent_rpc, &shared.aux_state);
                defer allocator.free(response_body);
                try sendHttpResponse(conn, 200, response_body);
                return;
            }
        }

        if (std.mem.eql(u8, m, "submitauxblock")) {
            shared.mutex.lock();
            defer shared.mutex.unlock();
            // Custom method: handle aux block submission
            const response_body = try handleSubmitAuxBlock(allocator, body, &shared.aux_state);
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
    parent_rpc: *rpc.Client,
    aux_state: *auxpow.State,
) ![]const u8 {
    log.info("getblocktemplate: forwarding {d} bytes to parent", .{request_body.len});

    // Forward to parent daemon
    var response = try parent_rpc.rawCall(allocator, request_body);
    log.info("getblocktemplate: got {d} bytes from parent", .{response.len});

    // If aux chains configured, enrich the coinbaseaux.flags with AuxPoW commitment
    if (aux_state.chain_count() > 0) {
        // Refresh aux templates
        aux_state.refreshTemplates(allocator) catch |err| {
            log.warn("aux template refresh in getblocktemplate: {}", .{err});
        };

        // Build aux fields JSON and inject into coinbaseaux.flags
        if (try aux_state.auxFieldsJson(allocator)) |aux_fields| {
            defer allocator.free(aux_fields);

            // Also build the flags hex for coinbase commitment
            var root_hex: [64]u8 = undefined;
            auxpow.bytesToHex(&aux_state.merkle_root, &root_hex);

            var tree_size_hex: [8]u8 = undefined;
            const ts_le = std.mem.nativeToLittle(u32, aux_state.tree_size);
            auxpow.bytesToHex(std.mem.asBytes(&ts_le), &tree_size_hex);

            var tree_nonce_hex: [8]u8 = undefined;
            const tn_le = std.mem.nativeToLittle(u32, aux_state.tree_nonce);
            auxpow.bytesToHex(std.mem.asBytes(&tn_le), &tree_nonce_hex);

            // AuxPoW commitment: magic + root + tree_size + tree_nonce
            const commitment_hex = try std.fmt.allocPrint(allocator,
                "fabe6d6d{s}{s}{s}",
                .{ root_hex, tree_size_hex, tree_nonce_hex },
            );
            defer allocator.free(commitment_hex);

            // Inject aux fields + enriched flags into the response
            // Find "coinbaseaux" in response and enrich the flags value
            const enriched = try injectAuxData(allocator, response, commitment_hex, aux_fields);
            allocator.free(response);
            response = enriched;
        }
    }

    return response;
}

fn handleSubmitAuxBlock(
    allocator: std.mem.Allocator,
    request_body: []const u8,
    aux_state: *auxpow.State,
) ![]const u8 {
    // Parse the JSON-RPC params
    _ = request_body;
    // TODO: Extract params, construct AuxPoW proof, submit to aux daemon
    _ = aux_state;
    log.info("submitauxblock received (TODO: construct proof)", .{});

    return try allocator.dupe(u8, "{\"result\":null,\"error\":null,\"id\":0}");
}

/// Inject AuxPoW commitment into coinbaseaux.flags and add aux_chains fields
/// to a getblocktemplate JSON-RPC response.
fn injectAuxData(
    allocator: std.mem.Allocator,
    response: []const u8,
    commitment_hex: []const u8,
    aux_fields_json: []const u8,
) ![]const u8 {
    // Strategy: find "coinbaseaux":{"flags":"..."} and append commitment to flags value.
    // Then add aux_* fields before the final closing braces.
    var result = try allocator.dupe(u8, response);

    // 1. Enrich coinbaseaux.flags with AuxPoW commitment
    const flags_needle = "\"flags\":\"";
    if (std.mem.indexOf(u8, result, flags_needle)) |flags_idx| {
        const val_start = flags_idx + flags_needle.len;
        // Find closing quote of the flags value
        if (std.mem.indexOfScalarPos(u8, result, val_start, '"')) |val_end| {
            const old_flags = result[val_start..val_end];
            // New flags = old flags + commitment
            const new_flags = try std.fmt.allocPrint(allocator, "{s}{s}", .{ old_flags, commitment_hex });
            defer allocator.free(new_flags);

            // Rebuild the string with the new flags value
            const new_result = try std.fmt.allocPrint(allocator, "{s}{s}{s}",
                .{ result[0..val_start], new_flags, result[val_end..] },
            );
            allocator.free(result);
            result = new_result;
        }
    }

    // 2. Add aux_* fields to the result object (inside the "result":{...} object)
    // Find the last }} in the response (closing result object + RPC wrapper)
    if (lastIndexOfSubstring(result, "}}")) |last_close| {
        const new_result = try std.fmt.allocPrint(allocator,
            "{s},{s}{s}",
            .{ result[0..last_close], aux_fields_json, result[last_close..] },
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
