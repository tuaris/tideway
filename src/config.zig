const std = @import("std");

const log = std.log.scoped(.config);

pub const AuxChain = struct {
    chain_id: []const u8,
    host: []const u8,
    port: u16,
    user: []const u8,
    pass: []const u8,
    rpc_method: RpcMethod,

    pub const RpcMethod = enum {
        /// Namecoin-style: getauxblock
        getauxblock,
        /// Newer style: createauxblock / submitauxblock
        createauxblock,
    };
};

pub const Config = struct {
    socket_path: []const u8,
    zmq_pull: []const u8,

    parent: struct {
        host: []const u8,
        port: u16,
        user: []const u8,
        pass: []const u8,
        poll_interval_ms: u32,
        zmq_hashblock: ?[]const u8,
    },

    aux_chains: []AuxChain,

    // Raw JSON source kept alive for string references
    raw_json: ?std.json.Parsed(std.json.Value),

    pub fn deinit(self: *const Config, allocator: std.mem.Allocator) void {
        _ = allocator;
        if (self.raw_json) |*parsed| {
            // parsed.deinit() would free the arena
            _ = parsed;
        }
    }
};

pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(contents);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{
        .allocate = .alloc_always,
    });

    const root = parsed.value.object;

    // Parse parent chain config
    const parent_obj = root.get("parent") orelse return error.MissingParentConfig;
    const parent_map = parent_obj.object;

    const parent_url = (parent_map.get("url") orelse return error.MissingParentUrl).string;
    const parent_host_port = try parseUrl(parent_url);

    // Parse aux chains — allocate directly since we know the count from JSON
    var aux_chains: []AuxChain = &.{};

    if (root.get("aux_chains")) |aux_val| {
        const items = aux_val.array.items;
        aux_chains = try allocator.alloc(AuxChain, items.len);
        for (items, 0..) |chain_val, idx| {
            const chain = chain_val.object;
            const chain_url = (chain.get("url") orelse continue).string;
            const chain_hp = try parseUrl(chain_url);

            const rpc_method_str = if (chain.get("rpc_method")) |m| m.string else "getauxblock";
            const rpc_method: AuxChain.RpcMethod = if (std.mem.eql(u8, rpc_method_str, "createauxblock"))
                .createauxblock
            else
                .getauxblock;

            aux_chains[idx] = .{
                .chain_id = (chain.get("chain_id") orelse continue).string,
                .host = chain_hp.host,
                .port = chain_hp.port,
                .user = if (chain.get("user")) |u| u.string else "",
                .pass = if (chain.get("pass")) |p| p.string else "",
                .rpc_method = rpc_method,
            };
        }
    }

    return Config{
        .socket_path = if (root.get("socket_path")) |s| s.string else "/tmp/ckpool/generator",
        .zmq_pull = if (root.get("zmq_pull")) |s| s.string else "ipc:///tmp/ckpool/generator.zmq",
        .parent = .{
            .host = parent_host_port.host,
            .port = parent_host_port.port,
            .user = if (parent_map.get("user")) |u| u.string else "",
            .pass = if (parent_map.get("pass")) |p| p.string else "",
            .poll_interval_ms = if (parent_map.get("poll_interval_ms")) |v| @intCast(v.integer) else 100,
            .zmq_hashblock = if (parent_map.get("zmq_hashblock")) |z| z.string else null,
        },
        .aux_chains = aux_chains,
        .raw_json = parsed,
    };
}

const HostPort = struct {
    host: []const u8,
    port: u16,
};

fn parseUrl(url: []const u8) !HostPort {
    // Parse "http://host:port" or "host:port"
    var remainder = url;
    if (std.mem.indexOf(u8, remainder, "://")) |idx| {
        remainder = remainder[idx + 3 ..];
    }

    // Split host:port
    if (std.mem.lastIndexOfScalar(u8, remainder, ':')) |colon| {
        const host = remainder[0..colon];
        const port_str = remainder[colon + 1 ..];
        const port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidPort;
        return .{ .host = host, .port = port };
    }

    // No port specified, default based on common chains
    return .{ .host = remainder, .port = 8332 };
}

test "parseUrl" {
    const hp1 = try parseUrl("http://127.0.0.1:9332");
    try std.testing.expectEqualStrings("127.0.0.1", hp1.host);
    try std.testing.expectEqual(@as(u16, 9332), hp1.port);

    const hp2 = try parseUrl("localhost:18332");
    try std.testing.expectEqualStrings("localhost", hp2.host);
    try std.testing.expectEqual(@as(u16, 18332), hp2.port);
}
