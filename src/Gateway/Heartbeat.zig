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

pub const Message = union(enum) {
    start: u64,
    ack,
    stop,
    deinit,
};

pub fn init(gateway: *Gateway, strategy: Strategy) !Heartbeat {
    return Heartbeat{
        .handler = switch (strategy) {
            .thread => .{ .thread = try ThreadHandler.init(gateway) },
            .callback => |cb| .{ .callback = cb },
        },
    };
}

pub fn deinit(self: Heartbeat) void {
    switch (self.handler) {
        .thread => |thread| thread.deinit(),
        .callback => |cb| cb.func(cb.context, .deinit),
    }
}

pub fn send(self: Heartbeat, msg: Message) void {
    switch (self.handler) {
        .thread => |thread| thread.mailbox.putOverwrite(msg),
        .callback => |cb| cb.func(cb.context, msg),
    }
}

pub const CallbackHandler = struct {
    context: *c_void,
    func: fn (ctx: *c_void, msg: Message) void,
};

const ThreadHandler = struct {
    allocator: *std.mem.Allocator,
    mailbox: util.Mailbox(Message),
    thread: std.Thread,

    fn init(gateway: *Gateway) !*ThreadHandler {
        const result = try gateway.allocator.create(ThreadHandler);
        errdefer gateway.allocator.destroy(result);
        result.allocator = gateway.allocator;

        try result.mailbox.init();
        errdefer result.mailbox.deinit();

        result.thread = try std.Thread.spawn(.{}, handler, .{ result, gateway });
        return result;
    }

    fn deinit(ctx: *ThreadHandler) void {
        ctx.mailbox.putOverwrite(.deinit);
        // Reap the thread
        ctx.thread.join();
        ctx.mailbox.deinit();
        ctx.allocator.destroy(ctx);
    }

    fn handler(ctx: *ThreadHandler, gateway: *Gateway) void {
        var heartbeat_interval_ms: u64 = 0;
        var acked = false;
        while (true) {
            if (heartbeat_interval_ms == 0) {
                switch (ctx.mailbox.get()) {
                    .start => |heartbeat| {
                        heartbeat_interval_ms = heartbeat;
                        acked = true;
                    },
                    .ack, .stop => {},
                    .deinit => return,
                }
            } else {
                // Force fire the heartbeat earlier
                const timeout_ms = heartbeat_interval_ms - 1000;
                if (ctx.mailbox.getWithTimeout(timeout_ms * std.time.ns_per_ms)) |msg| {
                    switch (msg) {
                        .start => |heartbeat| {
                            heartbeat_interval_ms = heartbeat;
                            acked = true;
                        },
                        .ack => {
                            log.info("<< ♥", .{});
                            acked = true;
                        },
                        .stop => heartbeat_interval_ms = 0,
                        .deinit => return,
                    }
                    continue;
                }

                if (acked) {
                    acked = false;
                    // TODO: actually check this or fix threads + async
                    if (nosuspend gateway.sendCommand(.{ .heartbeat = gateway.connect_info.?.seq })) |_| {
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
                heartbeat_interval_ms = 0;
            }
        }
    }
};
