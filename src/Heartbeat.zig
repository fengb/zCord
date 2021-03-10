const std = @import("std");
const DiscordWs = @import("main.zig").DiscordWs;
const util = @import("util.zig");

const Heartbeat = @This();
handler: union(std.meta.Tag(Strategy)) {
    thread: *ThreadHandler,
    event_loop: *EventLoopHandler,
    callback: CallbackHandler,
},

pub const Message = enum { start, ack, stop, deinit };
pub const Strategy = union(enum) {
    thread,
    event_loop,
    callback: CallbackHandler,

    pub const default: Strategy = if (std.io.is_async) .event_loop else .thread;
};

pub fn init(allocator: *std.mem.Allocator, discord: *DiscordWs, strategy: Strategy) !Heartbeat {
    return Heartbeat{
        .handler = switch (strategy) {
            .thread => .{ .thread = try ThreadHandler.init(allocator, discord) },
            .event_loop => .{ .event_loop = try EventLoopHandler.init(allocator, discord) },
            .callback => |cb| .{ .callback = cb },
        },
    };
}

pub fn deinit(self: Heartbeat) void {
    switch (self.handler) {
        .thread => |thread| thread.deinit(),
        .event_loop => |loop| loop.deinit(),
        .callback => |cb| cb.func(cb.context, .deinit),
    }
}

pub fn send(self: Heartbeat, msg: Message) void {
    switch (self.handler) {
        .thread => |thread| thread.mailbox.putOverwrite(msg),
        .event_loop => |loop| loop.mailbox.putOverwrite(msg),
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

    fn init(allocator: *std.mem.Allocator, discord: *DiscordWs) !*ThreadHandler {
        const result = try allocator.create(ThreadHandler);
        errdefer allocator.destroy(result);
        result.allocator = allocator;
        result.mailbox = .{};
        result.thread = try std.Thread.spawn(HandlerArgs{ .ctx = result, .discord = discord }, handler);
        return result;
    }

    fn deinit(ctx: *ThreadHandler) void {
        ctx.mailbox.putOverwrite(.deinit);
        // Reap the thread
        ctx.thread.wait();
        ctx.allocator.destroy(ctx);
    }

    const HandlerArgs = struct { ctx: *ThreadHandler, discord: *DiscordWs };
    fn handler(args: HandlerArgs) void {
        var heartbeat_interval_ms: u64 = 0;
        var ack = false;
        while (true) {
            if (heartbeat_interval_ms == 0) {
                switch (args.ctx.mailbox.get()) {
                    .start => {
                        heartbeat_interval_ms = args.discord.connect_info.?.heartbeat_interval_ms;
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
                    if (nosuspend args.discord.sendCommand(.heartbeat, args.discord.connect_info.?.seq)) |_| {
                        std.debug.print(">> ♡\n", .{});
                        continue;
                    } else |_| {
                        std.debug.print("Heartbeat send failed. Reconnecting...\n", .{});
                    }
                } else {
                    std.debug.print("Missed heartbeat. Reconnecting...\n", .{});
                }

                std.os.shutdown(args.discord.ssl_tunnel.?.tcp_conn.handle, .both) catch |err| {
                    std.debug.print("Shutdown failed: {}\n", .{err});
                };
                heartbeat_interval_ms = 0;
            }
        }
    }
};

const EventLoopHandler = struct {
    allocator: *std.mem.Allocator,
    refcount: u32,
    ack: bool,
    mailbox: util.Mailbox(Message),
    timer_status: enum { sleep, active, dying },
    timer_frame: @Frame(timer),
    control_frame: @Frame(control),

    fn init(allocator: *std.mem.Allocator, discord: *DiscordWs) !*EventLoopHandler {
        const result = try allocator.create(EventLoopHandler);
        result.refcount = 0;
        result.timer_status = .sleep;
        result.mailbox = .{};
        result.timer_frame = async timer(result, discord);
        result.control_frame = async control(result, discord);
        return result;
    }

    fn deinit(ctx: *EventLoopHandler) void {}

    fn retain(ctx: *EventLoopHandler) void {
        ctx.refcount += 1;
    }

    fn release(ctx: *EventLoopHandler) void {
        ctx.refcount -= 1;
        if (ctx.refcount == 0) {
            suspend {
                ctx.allocator.destroy(ctx);
            }
        }
    }

    fn control(ctx: *EventLoopHandler, discord: *DiscordWs) void {
        ctx.retain();
        defer ctx.release();
        while (true) {
            suspend;
            switch (ctx.mailbox.get()) {
                .start => {
                    ctx.ack = true;

                    const old_status = ctx.timer_status;
                    ctx.timer_status = .active;
                    switch (old_status) {
                        .sleep => resume ctx.timer_frame,
                        .active => {},
                        .dying => unreachable,
                    }
                },
                .ack => ctx.ack = true,
                .stop => ctx.timer_status = .sleep,
                .deinit => {
                    const old_status = ctx.timer_status;
                    ctx.timer_status = .active;
                    switch (old_status) {
                        .sleep => resume ctx.timer_frame,
                        .active => {},
                        .dying => unreachable,
                    }
                    return;
                },
            }
        }
    }

    fn timer(ctx: *EventLoopHandler, discord: *DiscordWs) void {
        ctx.retain();
        defer ctx.release();
        while (true) {
            switch (ctx.timer_status) {
                .sleep => {
                    suspend {}
                },
                .active => {
                    const timeout_ms = discord.connect_info.?.heartbeat_interval_ms - 1000;
                    std.time.sleep(timeout_ms * std.time.ns_per_ms);

                    if (ctx.timer_status != .active) continue;

                    if (ctx.ack) {
                        ctx.ack = false;
                        if (discord.sendCommand(.heartbeat, discord.connect_info.?.seq)) |_| {
                            std.debug.print(">> ♡\n", .{});
                            continue;
                        } else |_| {
                            std.debug.print("Heartbeat send failed. Reconnecting...\n", .{});
                        }
                    } else {
                        std.debug.print("Missed heartbeat. Reconnecting...\n", .{});
                    }

                    std.os.shutdown(discord.ssl_tunnel.?.tcp_conn.handle, .both) catch |err| {
                        std.debug.print("Shutdown failed: {}\n", .{err});
                    };
                },
                .dying => return,
            }
        }
    }
};
