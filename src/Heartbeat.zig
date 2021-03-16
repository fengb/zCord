const std = @import("std");
const Client = @import("main.zig").Client;
const util = @import("util.zig");

const Heartbeat = @This();
mailbox: util.Mailbox(enum { start, ack, stop, terminate }),
handler: *std.Thread,

pub fn init(client: *Client) !Heartbeat {
    return Heartbeat{
        .mailbox = .{},
        .handler = try std.Thread.spawn(client, threadHandler),
    };
}

pub fn deinit(self: *Heartbeat) void {
    self.mailbox.putOverwrite(.terminate);
    // Reap the thread
    self.handler.wait();
}

fn threadHandler(client: *Client) void {
    var heartbeat_interval_ms: u64 = 0;
    var ack = false;
    while (true) {
        if (heartbeat_interval_ms == 0) {
            switch (client.heartbeat.mailbox.get()) {
                .start => {
                    heartbeat_interval_ms = client.connect_info.?.heartbeat_interval_ms;
                    ack = true;
                },
                .ack, .stop => {},
                .terminate => return,
            }
        } else {
            // Force fire the heartbeat earlier
            const timeout_ms = heartbeat_interval_ms - 1000;
            if (client.heartbeat.mailbox.getWithTimeout(timeout_ms * std.time.ns_per_ms)) |msg| {
                switch (msg) {
                    .start => {},
                    .ack => {
                        std.debug.print("<< ♥\n", .{});
                        ack = true;
                    },
                    .stop => heartbeat_interval_ms = 0,
                    .terminate => return,
                }
                continue;
            }

            if (ack) {
                ack = false;
                if (client.sendCommand(.heartbeat, client.connect_info.?.seq)) |_| {
                    std.debug.print(">> ♡\n", .{});
                    continue;
                } else |_| {
                    std.debug.print("Heartbeat send failed. Reconnecting...\n", .{});
                }
            } else {
                std.debug.print("Missed heartbeat. Reconnecting...\n", .{});
            }

            std.os.shutdown(client.ssl_tunnel.?.tcp_conn.handle, .both) catch |err| {
                std.debug.print("Shutdown failed: {}\n", .{err});
            };
            heartbeat_interval_ms = 0;
        }
    }
}
