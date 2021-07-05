const std = @import("std");
const zCord = @import("zCord");

pub fn main() !void {
    // This is a shared global and should never be reclaimed
    try zCord.root_ca.preload(std.heap.page_allocator);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var auth_buf: [0x100]u8 = undefined;
    const auth = try std.fmt.bufPrint(&auth_buf, "Bot {s}", .{std.os.getenv("DISCORD_AUTH") orelse return error.AuthNotFound});

    const c = try zCord.Client.create(.{
        .allocator = &gpa.allocator,
        .auth_token = auth,
        .intents = .{},
    });
    defer c.destroy();

    _ = try std.Thread.spawn(chaosMonkey, c);

    try c.ws(struct {
        pub fn handleConnect(_: *zCord.Client, info: zCord.Client.ConnectInfo) void {
            std.debug.print("Connected as {}\n", .{info.user_id});
        }

        pub fn handleDispatch(_: *zCord.Client, name: []const u8, data: zCord.JsonElement) !void {
            _ = name;
            _ = data;
        }
    });
}

fn chaosMonkey(client: *zCord.Client) void {
    while (true) {
        std.time.sleep(5 * std.time.ns_per_s);
        // This is *not* stable.
        if (client.ssl_tunnel) |ssl_tunnel| {
            ssl_tunnel.shutdown() catch |err| {
                std.debug.print("Shutdown error: {}\n", .{err});
            };
        }
    }
}
