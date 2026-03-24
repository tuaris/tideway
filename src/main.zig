const std = @import("std");
const config = @import("config.zig");
const http = @import("http.zig");

const log = std.log.scoped(.tideway);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command-line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config_path: []const u8 = "tideway.conf";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-c") and i + 1 < args.len) {
            i += 1;
            config_path = args[i];
        } else if (std.mem.eql(u8, args[i], "-h") or std.mem.eql(u8, args[i], "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, args[i], "-v") or std.mem.eql(u8, args[i], "--version")) {
            const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
            _ = try stdout.write("tideway " ++ version ++ "\n");
            return;
        }
    }

    log.info("tideway {s} starting", .{version});

    // Load configuration
    const cfg = config.load(allocator, config_path) catch |err| {
        log.err("failed to load config {s}: {}", .{ config_path, err });
        std.process.exit(1);
    };
    defer cfg.deinit(allocator);

    log.info("parent chain: {s}:{d}", .{ cfg.parent.host, cfg.parent.port });
    log.info("aux chains: {d} configured", .{cfg.aux_chains.len});
    log.info("listen: {s}", .{cfg.listen});

    // Start the HTTP JSON-RPC proxy server
    http.serve(allocator, cfg) catch |err| {
        log.err("HTTP proxy server failed: {}", .{err});
        std.process.exit(1);
    };
}

fn printUsage() void {
    const usage =
        \\Usage: tideway [options]
        \\
        \\Options:
        \\  -c <path>    Configuration file (default: tideway.conf)
        \\  -h, --help   Show this help
        \\  -v, --version  Show version
        \\
    ;
    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    _ = stdout.write(usage) catch {};
}

pub const version = "0.1.0";

test {
    // Import all modules for testing
    _ = @import("config.zig");
    _ = @import("http.zig");
    _ = @import("rpc.zig");
    _ = @import("auxpow.zig");
}
