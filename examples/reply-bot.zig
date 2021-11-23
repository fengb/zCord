const std = @import("std");
const zCord = @import("zCord");

pub fn main() !void {
    // This is a shared global and should never be reclaimed
    try zCord.root_ca.preload(std.heap.page_allocator);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var auth_buf: [0x100]u8 = undefined;
    const auth = try std.fmt.bufPrint(&auth_buf, "Bot {s}", .{std.os.getenv("DISCORD_AUTH") orelse return error.AuthNotFound});

    const client = zCord.Client.init(.{
        .allocator = &gpa.allocator,
        .auth_token = auth,
        .intents = .{ .guild_messages = true },
    });

    const gateway = try client.startGateway();
    defer gateway.destroy();

    while (true) {
        switch (try gateway.recvEvent()) {
            .dispatch => |dispatch| {
                if (!std.mem.eql(u8, dispatch.name, "MESSAGE_CREATE")) return;
                const paths = try zCord.json.path.match(dispatch.data, struct {
                    @"channel_id": zCord.Snowflake(.channel),
                    @"content": std.BoundedArray(u8, 0x1000),
                });

                if (std.mem.eql(u8, paths.content.constSlice(), "Hello")) {
                    var buf: [0x100]u8 = undefined;
                    const path = try std.fmt.bufPrint(&buf, "/api/v6/channels/{d}/messages", .{paths.channel_id});

                    var req = try client.sendRequest(client.allocator, .POST, path, .{
                        .content = "World",
                    });
                    defer req.deinit();
                }
            },
        }
    }
}
