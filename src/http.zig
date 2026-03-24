const std = @import("std");
const posix = std.posix;
const config = @import("config.zig");
const rpc = @import("rpc.zig");
const auxpow = @import("auxpow.zig");

const log = std.log.scoped(.http);

const IDENT_LISTENER: usize = 0;
const IDENT_AUX_TIMER: usize = 1;

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

    // Create TCP listener
    const sockfd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
    defer posix.close(sockfd);

    // SO_REUSEADDR
    try posix.setsockopt(sockfd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

    const listen_z = try allocator.dupeZ(u8, listen_hp.host);
    defer allocator.free(listen_z);
    var port_buf: [8]u8 = undefined;
    const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{listen_hp.port});
    const port_z = try allocator.dupeZ(u8, port_str);
    defer allocator.free(port_z);

    var hints: std.c.addrinfo = std.mem.zeroes(std.c.addrinfo);
    hints.family = posix.AF.INET;
    hints.socktype = posix.SOCK.STREAM;
    hints.flags = .{ .PASSIVE = true };

    var ai_result: ?*std.c.addrinfo = null;
    const gai_ret = std.c.getaddrinfo(listen_z, port_z, &hints, &ai_result);
    if (@intFromEnum(gai_ret) != 0) return error.DnsResolutionFailed;
    defer std.c.freeaddrinfo(ai_result.?);

    const ai = ai_result.?;
    try posix.bind(sockfd, ai.addr.?, ai.addrlen);
    try posix.listen(sockfd, 128);

    log.info("HTTP JSON-RPC proxy listening on {s}:{d}", .{ listen_hp.host, listen_hp.port });

    // Initialize RPC client to parent daemon
    var parent_rpc = rpc.Client.init(allocator, cfg.parent.host, cfg.parent.port, cfg.parent.user, cfg.parent.pass);
    defer parent_rpc.deinit();

    // Initialize aux chain state
    var aux_state = auxpow.State.init(allocator, cfg.aux_chains);
    defer aux_state.deinit();

    // Create kqueue
    const kqfd = try posix.kqueue();
    defer posix.close(kqfd);

    // Register listener + timer
    var changelist: [2]posix.Kevent = undefined;
    changelist[0] = makeEvent(sockfd, posix.system.EVFILT.READ, posix.system.EV.ADD, IDENT_LISTENER);

    const timer_ms: isize = @intCast(cfg.parent.poll_interval_ms);
    changelist[1] = .{
        .ident = IDENT_AUX_TIMER,
        .filter = posix.system.EVFILT.TIMER,
        .flags = posix.system.EV.ADD,
        .fflags = 0,
        .data = timer_ms,
        .udata = IDENT_AUX_TIMER,
    };

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
                acceptAndHandle(allocator, sockfd, &parent_rpc, &aux_state);
            } else if (ev.udata == IDENT_AUX_TIMER) {
                refreshAuxTemplates(allocator, &aux_state);
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

fn acceptAndHandle(
    allocator: std.mem.Allocator,
    sockfd: posix.fd_t,
    parent_rpc: *rpc.Client,
    aux_state: *auxpow.State,
) void {
    while (true) {
        const conn = posix.accept(sockfd, null, null, 0) catch |err| {
            if (err == error.WouldBlock) break;
            log.warn("accept failed: {}", .{err});
            break;
        };

        handleHttpRequest(allocator, conn, parent_rpc, aux_state) catch |err| {
            log.warn("HTTP handler error: {}", .{err});
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

// --- HTTP Request Handling ---

fn handleHttpRequest(
    allocator: std.mem.Allocator,
    conn: posix.socket_t,
    parent_rpc: *rpc.Client,
    aux_state: *auxpow.State,
) !void {
    // Read HTTP request
    var buf: [4 * 1024 * 1024]u8 = undefined;
    var total: usize = 0;

    while (total < buf.len) {
        const n = posix.read(conn, buf[total..]) catch break;
        if (n == 0) break;
        total += n;

        // Check if we've received the full HTTP request (headers + body)
        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |header_end| {
            // Look for Content-Length to know when body is complete
            const headers = buf[0..header_end];
            if (findContentLength(headers)) |content_len| {
                const body_start = header_end + 4;
                const body_received = total - body_start;
                if (body_received >= content_len) break;
            } else {
                break; // No content-length, assume complete
            }
        }
    }

    if (total == 0) return;

    const request = buf[0..total];

    // Find the body (after \r\n\r\n)
    const header_end = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return;
    const body = request[header_end + 4 ..];

    if (body.len == 0) {
        try sendHttpResponse(conn, 400, "{\"error\":\"empty body\"}");
        return;
    }

    log.debug("JSON-RPC request: {d} bytes", .{body.len});

    // Parse the JSON-RPC method to decide routing
    const method = extractMethod(body);

    if (method) |m| {
        if (std.mem.eql(u8, m, "getblocktemplate")) {
            // Intercept: enrich with aux chain data
            const response_body = try handleGetBlockTemplate(allocator, body, parent_rpc, aux_state);
            defer allocator.free(response_body);
            try sendHttpResponse(conn, 200, response_body);
            return;
        }

        if (std.mem.eql(u8, m, "submitauxblock")) {
            // Custom method: handle aux block submission
            const response_body = try handleSubmitAuxBlock(allocator, body, aux_state);
            defer allocator.free(response_body);
            try sendHttpResponse(conn, 200, response_body);
            return;
        }
    }

    // Default: transparent proxy to parent daemon
    const response_body = try parent_rpc.rawCall(allocator, body);
    defer allocator.free(response_body);
    try sendHttpResponse(conn, 200, response_body);
}

fn sendHttpResponse(conn: posix.socket_t, status: u16, body: []const u8) !void {
    const status_text = if (status == 200) "OK" else "Bad Request";

    var header_buf: [512]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf,
        "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status, status_text, body.len },
    ) catch return error.HeaderTooLong;

    _ = try posix.write(conn, header);
    _ = try posix.write(conn, body);
}

fn findContentLength(headers: []const u8) ?usize {
    // Case-insensitive search for Content-Length header
    var i: usize = 0;
    while (i < headers.len) {
        // Find next line
        const line_end = std.mem.indexOf(u8, headers[i..], "\r\n") orelse headers.len - i;
        const line = headers[i .. i + line_end];

        if (line.len > 16 and isContentLengthHeader(line)) {
            // Extract value after ": "
            if (std.mem.indexOf(u8, line, ": ")) |colon| {
                const val_str = std.mem.trim(u8, line[colon + 2 ..], " ");
                return std.fmt.parseInt(usize, val_str, 10) catch null;
            }
        }
        i += line_end + 2;
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
    // Forward to parent daemon
    var response = try parent_rpc.rawCall(allocator, request_body);

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
