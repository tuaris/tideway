const std = @import("std");
const config = @import("config.zig");

const c = @cImport({
    @cInclude("zmq.h");
});

const log = std.log.scoped(.zmq);

const MAX_SUBS: usize = 33; // 1 parent + 32 aux chains

/// ZMQ block notification aggregator.
/// Subscribes to hashblock notifications from all chain daemons (parent + aux)
/// and republishes them on a single PUB endpoint for SeaTidePool to consume.
pub const Aggregator = struct {
    ctx: *anyopaque,
    pub_socket: *anyopaque,
    sub_sockets: [MAX_SUBS]?*anyopaque,
    sub_labels: [MAX_SUBS][]const u8,
    sub_count: usize,

    pub fn init(pub_endpoint: []const u8, cfg: config.Config) !Aggregator {
        var self: Aggregator = .{
            .ctx = undefined,
            .pub_socket = undefined,
            .sub_sockets = [_]?*anyopaque{null} ** MAX_SUBS,
            .sub_labels = [_][]const u8{""} ** MAX_SUBS,
            .sub_count = 0,
        };

        // Create ZMQ context
        self.ctx = c.zmq_ctx_new() orelse {
            log.err("zmq_ctx_new failed", .{});
            return error.ZmqContextFailed;
        };

        // Create PUB socket and bind
        self.pub_socket = c.zmq_socket(self.ctx, c.ZMQ_PUB) orelse {
            log.err("zmq_socket(PUB) failed", .{});
            return error.ZmqSocketFailed;
        };

        var pub_buf: [256]u8 = undefined;
        const pub_z = std.fmt.bufPrintZ(&pub_buf, "{s}", .{pub_endpoint}) catch
            return error.EndpointTooLong;
        if (c.zmq_bind(self.pub_socket, pub_z.ptr) != 0) {
            log.err("zmq_bind({s}) failed", .{pub_endpoint});
            return error.ZmqBindFailed;
        }

        log.info("ZMQ PUB bound to {s}", .{pub_endpoint});

        // Subscribe to parent chain hashblock notifications
        if (cfg.parent.zmq_hashblock) |endpoint| {
            try self.addSub(endpoint, "parent");
        }

        // Subscribe to aux chain hashblock notifications
        for (cfg.aux_chains) |chain| {
            if (chain.zmq_hashblock) |endpoint| {
                try self.addSub(endpoint, chain.chain_id);
            }
        }

        return self;
    }

    fn addSub(self: *Aggregator, endpoint: []const u8, label: []const u8) !void {
        if (self.sub_count >= MAX_SUBS) return error.TooManySubscriptions;

        const sock = c.zmq_socket(self.ctx, c.ZMQ_SUB) orelse {
            log.err("zmq_socket(SUB) failed for {s}", .{label});
            return error.ZmqSocketFailed;
        };

        var buf: [256]u8 = undefined;
        const endpoint_z = std.fmt.bufPrintZ(&buf, "{s}", .{endpoint}) catch
            return error.EndpointTooLong;
        if (c.zmq_connect(sock, endpoint_z.ptr) != 0) {
            log.err("zmq_connect({s}) failed for {s}", .{ endpoint, label });
            _ = c.zmq_close(sock);
            return error.ZmqConnectFailed;
        }

        // Subscribe to "hashblock" topic (9 bytes)
        const topic = "hashblock";
        _ = c.zmq_setsockopt(sock, c.ZMQ_SUBSCRIBE, topic, topic.len);

        self.sub_sockets[self.sub_count] = sock;
        self.sub_labels[self.sub_count] = label;
        self.sub_count += 1;

        log.info("ZMQ SUB connected to {s} ({s})", .{ endpoint, label });
    }

    /// Blocking poll loop — runs in its own thread.
    /// Receives hashblock notifications from all SUB sockets and forwards
    /// them to the PUB socket for SeaTidePool to consume.
    pub fn run(self: *Aggregator) void {
        if (self.sub_count == 0) {
            log.warn("no ZMQ subscriptions configured, aggregator exiting", .{});
            return;
        }

        // Build poll items array
        var poll_items: [MAX_SUBS]c.zmq_pollitem_t = undefined;
        for (0..self.sub_count) |i| {
            poll_items[i] = .{
                .socket = self.sub_sockets[i],
                .fd = 0,
                .events = c.ZMQ_POLLIN,
                .revents = 0,
            };
        }

        log.info("aggregator polling {d} subscription(s)", .{self.sub_count});

        while (true) {
            const rc = c.zmq_poll(&poll_items, @intCast(self.sub_count), -1);
            if (rc < 0) {
                // EINTR from signal — just retry
                continue;
            }

            for (0..self.sub_count) |i| {
                if (poll_items[i].revents & c.ZMQ_POLLIN != 0) {
                    self.forwardMessage(self.sub_sockets[i].?, self.sub_labels[i]);
                }
            }
        }
    }

    /// Forward all parts of a multipart ZMQ message from a SUB socket to the PUB socket.
    fn forwardMessage(self: *Aggregator, sub_sock: *anyopaque, label: []const u8) void {
        var parts: usize = 0;
        while (true) {
            var buf: [256]u8 = undefined;
            const nbytes = c.zmq_recv(sub_sock, &buf, buf.len, 0);
            if (nbytes < 0) break;

            // Check if more message parts follow
            var more: c_int = 0;
            var more_size: usize = @sizeOf(c_int);
            _ = c.zmq_getsockopt(sub_sock, c.ZMQ_RCVMORE, &more, &more_size);

            const flags: c_int = if (more != 0) c.ZMQ_SNDMORE else 0;
            _ = c.zmq_send(self.pub_socket, &buf, @intCast(nbytes), flags);
            parts += 1;

            if (more == 0) break;
        }

        if (parts > 0) {
            log.info("hashblock from {s} ({d} parts forwarded)", .{ label, parts });
        }
    }

    pub fn deinit(self: *Aggregator) void {
        for (0..self.sub_count) |i| {
            if (self.sub_sockets[i]) |sock| {
                _ = c.zmq_close(sock);
            }
        }
        _ = c.zmq_close(self.pub_socket);
        _ = c.zmq_ctx_destroy(self.ctx);
    }
};
