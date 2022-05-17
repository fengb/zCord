const std = @import("std");
const Gateway = @import("../Gateway.zig");
const util = @import("../util.zig");

const log = std.log.scoped(.zCord);

const Heartbeat = @This();
handler: union(enum) {
    thread: *ThreadHandler,
    callback: CallbackHandler,
},

pub const Strategy = union(enum) {
    thread,
    callback: CallbackHandler,

    pub const default = Strategy.thread;
};

pub const Message = enum {
    start,
    ack,
    stop,
    deinit,
};

pub fn init(gateway: *Gateway, strategy: Strategy) !Heartbeat {
    return Heartbeat{
        .handler = switch (strategy) {
            .thread => .{ .thread = try ThreadHandler.create(gateway) },
            .callback => |cb| .{ .callback = cb },
        },
    };
}

pub fn deinit(self: Heartbeat) void {
    switch (self.handler) {
        .thread => |thread| thread.destroy(),
        .callback => {},
    }
}

pub fn send(self: Heartbeat, msg: Message) void {
    switch (self.handler) {
        .thread => |thread| thread.mailbox.putOverwrite(msg),
        .callback => |cb| cb.func(cb.context, msg),
    }
}

pub const CallbackHandler = struct {
    context: *anyopaque,
    func: fn (ctx: *anyopaque, msg: Message) void,
};

const ThreadHandler = struct {
    allocator: std.mem.Allocator,
    mailbox: util.Mailbox(Message),
    thread: std.Thread,

    fn create(gateway: *Gateway) !*ThreadHandler {
        const result = try gateway.allocator.create(ThreadHandler);
        errdefer gateway.allocator.destroy(result);
        result.allocator = gateway.allocator;

        result.mailbox = .{};
        result.thread = try std.Thread.spawn(.{}, handler, .{ result, gateway });
        return result;
    }

    fn destroy(ctx: *ThreadHandler) void {
        ctx.mailbox.putOverwrite(.deinit);
        // Reap the thread
        ctx.thread.join();
        ctx.allocator.destroy(ctx);
    }

    fn handler(ctx: *ThreadHandler, gateway: *Gateway) void {
        var active = true;
        var acked = true;
        while (true) {
            if (!active) {
                switch (ctx.mailbox.get()) {
                    .start => {
                        active = true;
                        acked = true;
                    },
                    .ack, .stop => {},
                    .deinit => return,
                }
            } else {
                if (ctx.mailbox.getWithTimeout(gateway.heartbeat_interval_ms * std.time.ns_per_ms)) |msg| {
                    switch (msg) {
                        .start => acked = true,
                        .ack => {
                            log.info("<< ♥", .{});
                            acked = true;
                        },
                        .stop => active = false,
                        .deinit => return,
                    }
                    continue;
                }

                if (acked) {
                    acked = false;
                    // TODO: actually check this or fix threads + async
                    if (nosuspend gateway.sendCommand(.{ .heartbeat = gateway.seq })) {
                        log.info(">> ♡", .{});
                        continue;
                    } else |_| {
                        log.info("Heartbeat send failed. Reconnecting...", .{});
                    }
                } else {
                    log.info("Missed heartbeat. Reconnecting...", .{});
                }

                gateway.ssl_tunnel.?.shutdown() catch |err| {
                    log.info("Shutdown failed: {}", .{err});
                };
                active = false;
            }
        }
    }
};
