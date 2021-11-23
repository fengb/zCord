const std = @import("std");
const zCord = @import("zCord");

pub fn main() !void {
    // This is a shared global and should never be reclaimed
    try zCord.root_ca.preload(std.heap.page_allocator);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var auth_buf: [0x100]u8 = undefined;
    const auth = try std.fmt.bufPrint(&auth_buf, "Bot {s}", .{std.os.getenv("DISCORD_AUTH") orelse return error.AuthNotFound});

    const client = zCord.Client{
        .auth_token = auth,
    };

    const gateway = try client.startGateway(.{
        .allocator = &gpa.allocator,
        .intents = .{},
    });
    defer gateway.destroy();

    _ = try std.Thread.spawn(.{}, chaosMonkey, .{gateway});

    while (true) {
        _ = try gateway.recvEvent();
    }
}

fn chaosMonkey(gateway: *zCord.Gateway) void {
    while (true) {
        std.time.sleep(5 * std.time.ns_per_s);
        // This is *not* stable.
        if (gateway.ssl_tunnel) |ssl_tunnel| {
            ssl_tunnel.shutdown() catch |err| {
                std.debug.print("Shutdown error: {}\n", .{err});
            };
        }
    }
}
