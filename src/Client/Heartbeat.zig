const std = @import("std");
const Client = @import("../Client.zig");
const util = @import("../util.zig");

const log = std.log.scoped(.zCord);

const Heartbeat = @This();
handler: union(enum) {
    thread: *ThreadHandler,
    callback: CallbackHandler,
},

pub const Message = enum { start, ack, stop, deinit };
pub const Strategy = union(enum) {
    thread,
    manual,
    callback: CallbackHandler,

    pub const default = Strategy.thread;
};

pub fn init(client: *Client, strategy: Strategy) !Heartbeat {
    return Heartbeat{
        .handler = switch (strategy) {
            .thread => .{ .thread = try ThreadHandler.init(client) },
            .callback => |cb| .{ .callback = cb },
            .manual => .{
                .callback = .{
                    .context = undefined,
                    .func = struct {
                        fn noop(ctx: *c_void, msg: Message) void {}
                    }.noop,
                },
            },
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
    thread: *std.Thread,

    fn init(client: *Client) !*ThreadHandler {
        const result = try client.allocator.create(ThreadHandler);
        errdefer client.allocator.destroy(result);
        result.allocator = client.allocator;

        try result.mailbox.init();
        errdefer result.mailbox.deinit();

        result.thread = try std.Thread.spawn(handler, .{ .ctx = result, .client = client });
        return result;
    }

    fn deinit(ctx: *ThreadHandler) void {
        ctx.mailbox.putOverwrite(.deinit);
        // Reap the thread
        ctx.thread.wait();
        ctx.mailbox.deinit();
        ctx.allocator.destroy(ctx);
    }

    fn handler(args: struct { ctx: *ThreadHandler, client: *Client }) void {
        var heartbeat_interval_ms: u64 = 0;
        var ack = false;
        while (true) {
            if (heartbeat_interval_ms == 0) {
                switch (args.ctx.mailbox.get()) {
                    .start => {
                        heartbeat_interval_ms = args.client.connect_info.?.heartbeat_interval_ms;
                        ack = true;
                    },
                    .ack, .stop => {},
                    .deinit => return,
                }
            } else {
                // Force fire the heartbeat earlier
                const timeout_ms = heartbeat_interval_ms - 1000;
                if (args.ctx.mailbox.getWithTimeout(timeout_ms * std.time.ns_per_ms)) |msg| {
                    switch (msg) {
                        .start => {},
                        .ack => {
                            std.debug.print("<< ♥\n", .{});
                            ack = true;
                        },
                        .stop => heartbeat_interval_ms = 0,
                        .deinit => return,
                    }
                    continue;
                }

                if (ack) {
                    ack = false;
                    // TODO: actually check this or fix threads + async
                    if (nosuspend args.client.sendCommand(.{ .heartbeat = args.client.connect_info.?.seq })) |_| {
                        std.debug.print(">> ♡\n", .{});
                        continue;
                    } else |_| {
                        std.debug.print("Heartbeat send failed. Reconnecting...\n", .{});
                    }
                } else {
                    std.debug.print("Missed heartbeat. Reconnecting...\n", .{});
                }

                std.os.shutdown(args.client.ssl_tunnel.?.tcp_conn.handle, .both) catch |err| {
                    std.debug.print("Shutdown failed: {}\n", .{err});
                };
                heartbeat_interval_ms = 0;
            }
        }
    }
};
