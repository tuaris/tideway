const std = @import("std");
const log = std.log.scoped(.rpc);

/// JSON-RPC client for Bitcoin-like chain daemons.
pub const Client = struct {
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    user: []const u8,
    pass: []const u8,
    next_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16, user: []const u8, pass: []const u8) Client {
        return .{
            .allocator = allocator,
            .host = host,
            .port = port,
            .user = user,
            .pass = pass,
        };
    }

    pub fn deinit(self: *Client) void {
        _ = self;
    }

    pub fn reconnect(self: *Client) void {
        log.info("reconnecting to {s}:{d}", .{ self.host, self.port });
        // TCP connections are per-request, so reconnect is a no-op.
        // If we add persistent connections later, reset them here.
    }

    /// Call getblocktemplate on the parent chain daemon.
    pub fn getBlockTemplate(self: *Client, allocator: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
        const req =
            \\{"method":"getblocktemplate","params":[{"capabilities":["coinbasetxn","workid","coinbase/append"],"rules":["segwit"]}]}
        ;
        return try self.call(allocator, req);
    }

    /// Call getbestblockhash.
    pub fn getBestBlockHash(self: *Client, allocator: std.mem.Allocator) ![]const u8 {
        const req =
            \\{"method":"getbestblockhash","params":[]}
        ;
        var parsed = try self.call(allocator, req);
        defer parsed.deinit();

        const result = parsed.value.object.get("result") orelse return error.MissingResult;
        return try allocator.dupe(u8, result.string);
    }

    /// Call getblockcount.
    pub fn getBlockCount(self: *Client, allocator: std.mem.Allocator) !i64 {
        const req =
            \\{"method":"getblockcount","params":[]}
        ;
        var parsed = try self.call(allocator, req);
        defer parsed.deinit();

        const result = parsed.value.object.get("result") orelse return error.MissingResult;
        return result.integer;
    }

    /// Call getblockhash.
    pub fn getBlockHash(self: *Client, allocator: std.mem.Allocator, height: i64) ![]const u8 {
        var buf: [256]u8 = undefined;
        const req = try std.fmt.bufPrint(&buf, "{{\"method\":\"getblockhash\",\"params\":[{d}]}}", .{height});
        return try self.callGetString(allocator, req);
    }

    /// Call submitblock.
    pub fn submitBlock(self: *Client, allocator: std.mem.Allocator, block_hex: []const u8) ![]const u8 {
        // Build request with block hex data
        var req_buf = std.ArrayList(u8).init(allocator);
        defer req_buf.deinit();
        try req_buf.appendSlice("{\"method\":\"submitblock\",\"params\":[\"");
        try req_buf.appendSlice(block_hex);
        try req_buf.appendSlice("\"]}");

        var parsed = try self.call(allocator, req_buf.items);
        defer parsed.deinit();

        const result = parsed.value.object.get("result") orelse return error.MissingResult;
        if (result == .null) {
            return try allocator.dupe(u8, "accepted");
        }
        return try allocator.dupe(u8, result.string);
    }

    /// Call validateaddress.
    pub fn validateAddress(self: *Client, allocator: std.mem.Allocator, addr: []const u8) ![]const u8 {
        var buf: [512]u8 = undefined;
        const req = try std.fmt.bufPrint(&buf, "{{\"method\":\"validateaddress\",\"params\":[\"{s}\"]}}", .{addr});

        var parsed = try self.call(allocator, req);
        defer parsed.deinit();

        const result = parsed.value.object.get("result") orelse return error.MissingResult;
        // Return the full result JSON for the stratifier to parse
        var list = std.ArrayList(u8).init(allocator);
        errdefer list.deinit();
        try result.jsonStringify(.{}, list.writer());
        return try list.toOwnedSlice();
    }

    /// Call testmempoolaccept (for checktxn).
    pub fn testMempoolAccept(self: *Client, allocator: std.mem.Allocator, txn_hex: []const u8) ![]const u8 {
        var req_buf = std.ArrayList(u8).init(allocator);
        defer req_buf.deinit();
        try req_buf.appendSlice("{\"method\":\"testmempoolaccept\",\"params\":[[\"");
        try req_buf.appendSlice(txn_hex);
        try req_buf.appendSlice("\"]]}");

        var parsed = try self.call(allocator, req_buf.items);
        defer parsed.deinit();

        const result = parsed.value.object.get("result") orelse return error.MissingResult;
        var list = std.ArrayList(u8).init(allocator);
        errdefer list.deinit();
        try result.jsonStringify(.{}, list.writer());
        return try list.toOwnedSlice();
    }

    /// Call getauxblock (Namecoin-style) on an aux chain daemon.
    pub fn getAuxBlock(self: *Client, allocator: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
        const req =
            \\{"method":"getauxblock","params":[]}
        ;
        return try self.call(allocator, req);
    }

    /// Call createauxblock (newer style) on an aux chain daemon.
    pub fn createAuxBlock(self: *Client, allocator: std.mem.Allocator, address: []const u8) !std.json.Parsed(std.json.Value) {
        var buf: [512]u8 = undefined;
        const req = try std.fmt.bufPrint(&buf, "{{\"method\":\"createauxblock\",\"params\":[\"{s}\"]}}", .{address});
        return try self.call(allocator, req);
    }

    /// Submit an aux block with AuxPoW proof.
    pub fn submitAuxBlock(self: *Client, allocator: std.mem.Allocator, block_hash: []const u8, auxpow_hex: []const u8) ![]const u8 {
        var req_buf = std.ArrayList(u8).init(allocator);
        defer req_buf.deinit();
        try req_buf.appendSlice("{\"method\":\"submitauxblock\",\"params\":[\"");
        try req_buf.appendSlice(block_hash);
        try req_buf.appendSlice("\",\"");
        try req_buf.appendSlice(auxpow_hex);
        try req_buf.appendSlice("\"]}");

        return try self.callGetString(allocator, req_buf.items);
    }

    // --- Internal ---

    fn call(self: *Client, allocator: std.mem.Allocator, request: []const u8) !std.json.Parsed(std.json.Value) {
        const response_body = try self.httpPost(allocator, request);
        defer allocator.free(response_body);

        return try std.json.parseFromSlice(std.json.Value, allocator, response_body, .{
            .allocate = .alloc_always,
        });
    }

    fn callGetString(self: *Client, allocator: std.mem.Allocator, request: []const u8) ![]const u8 {
        var parsed = try self.call(allocator, request);
        defer parsed.deinit();

        const result = parsed.value.object.get("result") orelse return error.MissingResult;
        if (result == .string) {
            return try allocator.dupe(u8, result.string);
        }
        // Return JSON representation for non-string results
        var list = std.ArrayList(u8).init(allocator);
        errdefer list.deinit();
        try result.jsonStringify(.{}, list.writer());
        return try list.toOwnedSlice();
    }

    fn httpPost(self: *Client, allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
        // Build HTTP/1.1 POST request manually for JSON-RPC
        var request_buf = std.ArrayList(u8).init(allocator);
        defer request_buf.deinit();

        // Request line + headers
        try request_buf.appendSlice("POST / HTTP/1.1\r\n");
        try std.fmt.format(request_buf.writer(), "Host: {s}:{d}\r\n", .{ self.host, self.port });
        try request_buf.appendSlice("Content-Type: application/json\r\n");
        try std.fmt.format(request_buf.writer(), "Content-Length: {d}\r\n", .{body.len});

        // Basic auth
        if (self.user.len > 0) {
            var auth_buf: [256]u8 = undefined;
            const auth_plain = try std.fmt.bufPrint(&auth_buf, "{s}:{s}", .{ self.user, self.pass });
            var encoded_buf: [512]u8 = undefined;
            const encoded = std.base64.standard.Encoder.encode(&encoded_buf, auth_plain);
            try std.fmt.format(request_buf.writer(), "Authorization: Basic {s}\r\n", .{encoded});
        }

        try request_buf.appendSlice("Connection: close\r\n\r\n");
        try request_buf.appendSlice(body);

        // Connect and send
        const address = try std.net.Address.resolveIp(self.host, self.port);
        const stream = try std.net.tcpConnectToAddress(address);
        defer stream.close();

        try stream.writeAll(request_buf.items);

        // Read response
        var response = std.ArrayList(u8).init(allocator);
        errdefer response.deinit();

        var read_buf: [8192]u8 = undefined;
        while (true) {
            const n = stream.read(&read_buf) catch break;
            if (n == 0) break;
            try response.appendSlice(read_buf[0..n]);
        }

        // Find the body (after \r\n\r\n)
        const raw = try response.toOwnedSlice();
        if (std.mem.indexOf(u8, raw, "\r\n\r\n")) |header_end| {
            const body_start = header_end + 4;
            const result = try allocator.dupe(u8, raw[body_start..]);
            allocator.free(raw);
            return result;
        }

        return raw;
    }
};
