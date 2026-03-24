const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.rpc);

/// JSON-RPC client for Bitcoin-like chain daemons.
pub const Client = struct {
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    user: []const u8,
    pass: []const u8,

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
    }

    /// Call getblocktemplate on the parent chain daemon.
    pub fn getBlockTemplate(self: *Client, allocator: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
        return try self.call(allocator,
            \\{"method":"getblocktemplate","params":[{"capabilities":["coinbasetxn","workid","coinbase/append"],"rules":["segwit"]}]}
        );
    }

    /// Call getbestblockhash.
    pub fn getBestBlockHash(self: *Client, allocator: std.mem.Allocator) ![]const u8 {
        var parsed = try self.call(allocator,
            \\{"method":"getbestblockhash","params":[]}
        );
        defer parsed.deinit();
        const result = parsed.value.object.get("result") orelse return error.MissingResult;
        return try allocator.dupe(u8, result.string);
    }

    /// Call getblockcount.
    pub fn getBlockCount(self: *Client, allocator: std.mem.Allocator) !i64 {
        var parsed = try self.call(allocator,
            \\{"method":"getblockcount","params":[]}
        );
        defer parsed.deinit();
        const result = parsed.value.object.get("result") orelse return error.MissingResult;
        return result.integer;
    }

    /// Call getblockhash.
    pub fn getBlockHash(self: *Client, allocator: std.mem.Allocator, height: i64) ![]const u8 {
        const req = try std.fmt.allocPrint(allocator, "{{\"method\":\"getblockhash\",\"params\":[{d}]}}", .{height});
        defer allocator.free(req);
        return try self.callGetString(allocator, req);
    }

    /// Call submitblock.
    pub fn submitBlock(self: *Client, allocator: std.mem.Allocator, block_hex: []const u8) ![]const u8 {
        const req = try std.fmt.allocPrint(allocator, "{{\"method\":\"submitblock\",\"params\":[\"{s}\"]}}", .{block_hex});
        defer allocator.free(req);

        var parsed = try self.call(allocator, req);
        defer parsed.deinit();

        const result = parsed.value.object.get("result") orelse return error.MissingResult;
        if (result == .null) {
            return try allocator.dupe(u8, "accepted");
        }
        return try allocator.dupe(u8, result.string);
    }

    /// Call validateaddress.
    pub fn validateAddress(self: *Client, allocator: std.mem.Allocator, addr: []const u8) ![]const u8 {
        const req = try std.fmt.allocPrint(allocator, "{{\"method\":\"validateaddress\",\"params\":[\"{s}\"]}}", .{addr});
        defer allocator.free(req);
        return try self.callGetString(allocator, req);
    }

    /// Call testmempoolaccept (for checktxn).
    pub fn testMempoolAccept(self: *Client, allocator: std.mem.Allocator, txn_hex: []const u8) ![]const u8 {
        const req = try std.fmt.allocPrint(allocator, "{{\"method\":\"testmempoolaccept\",\"params\":[[\"{s}\"]]}}", .{txn_hex});
        defer allocator.free(req);
        return try self.callGetString(allocator, req);
    }

    /// Call getauxblock (Namecoin-style) on an aux chain daemon.
    pub fn getAuxBlock(self: *Client, allocator: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
        return try self.call(allocator,
            \\{"method":"getauxblock","params":[]}
        );
    }

    /// Call createauxblock (newer style) on an aux chain daemon.
    pub fn createAuxBlock(self: *Client, allocator: std.mem.Allocator, address: []const u8) !std.json.Parsed(std.json.Value) {
        const req = try std.fmt.allocPrint(allocator, "{{\"method\":\"createauxblock\",\"params\":[\"{s}\"]}}", .{address});
        defer allocator.free(req);
        return try self.call(allocator, req);
    }

    /// Submit an aux block with AuxPoW proof.
    pub fn submitAuxBlock(self: *Client, allocator: std.mem.Allocator, block_hash: []const u8, auxpow_hex: []const u8) ![]const u8 {
        const req = try std.fmt.allocPrint(allocator, "{{\"method\":\"submitauxblock\",\"params\":[\"{s}\",\"{s}\"]}}", .{ block_hash, auxpow_hex });
        defer allocator.free(req);
        return try self.callGetString(allocator, req);
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
        return try jsonToString(allocator, result);
    }

    fn jsonToString(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
    }

    fn httpPost(self: *Client, allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
        // Build HTTP/1.1 POST request
        var auth_header: []const u8 = "";
        var auth_alloc: ?[]const u8 = null;
        defer if (auth_alloc) |a| allocator.free(a);

        if (self.user.len > 0) {
            var auth_buf: [256]u8 = undefined;
            const auth_plain = try std.fmt.bufPrint(&auth_buf, "{s}:{s}", .{ self.user, self.pass });
            var encoded_buf: [512]u8 = undefined;
            const encoded = std.base64.standard.Encoder.encode(&encoded_buf, auth_plain);
            auth_alloc = try std.fmt.allocPrint(allocator, "Authorization: Basic {s}\r\n", .{encoded});
            auth_header = auth_alloc.?;
        }

        const http_req = try std.fmt.allocPrint(allocator,
            "POST / HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n{s}Connection: close\r\n\r\n{s}",
            .{ self.host, self.port, body.len, auth_header, body },
        );
        defer allocator.free(http_req);

        // Connect via POSIX sockets (FreeBSD native)
        const sockfd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        defer posix.close(sockfd);

        // Resolve host:port via getaddrinfo (libc)
        var port_buf: [8]u8 = undefined;
        const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{self.port});
        const host_z = try allocator.dupeZ(u8, self.host);
        defer allocator.free(host_z);
        const port_z = try allocator.dupeZ(u8, port_str);
        defer allocator.free(port_z);

        var hints: std.c.addrinfo = std.mem.zeroes(std.c.addrinfo);
        hints.family = posix.AF.INET;
        hints.socktype = posix.SOCK.STREAM;

        var result: ?*std.c.addrinfo = null;
        const gai_ret = std.c.getaddrinfo(host_z, port_z, &hints, &result);
        if (@intFromEnum(gai_ret) != 0) return error.DnsResolutionFailed;
        defer std.c.freeaddrinfo(result.?);

        const ai = result.?;
        try posix.connect(sockfd, ai.addr.?, ai.addrlen);

        // Send request
        _ = try posix.write(sockfd, http_req);

        // Read response (up to 4MB)
        var response_buf = try allocator.alloc(u8, 4 * 1024 * 1024);
        var total: usize = 0;

        while (total < response_buf.len) {
            const n = posix.read(sockfd, response_buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        }

        const raw = response_buf[0..total];

        // Find body after \r\n\r\n header separator
        if (std.mem.indexOf(u8, raw, "\r\n\r\n")) |header_end| {
            const body_start = header_end + 4;
            const result_body = try allocator.dupe(u8, raw[body_start..total]);
            allocator.free(response_buf);
            return result_body;
        }

        // No header separator found — return raw (shouldn't happen with valid HTTP)
        const result_raw = try allocator.dupe(u8, raw);
        allocator.free(response_buf);
        return result_raw;
    }
};
