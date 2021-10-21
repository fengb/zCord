const std = @import("std");
const zCord = @import("zCord");

pub fn main() !void {
    // This is a shared global and should never be reclaimed
    try zCord.root_ca.preload(std.heap.page_allocator);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var auth_buf: [0x100]u8 = undefined;
    const auth = try std.fmt.bufPrint(&auth_buf, "Bot {s}", .{std.os.getenv("DISCORD_AUTH") orelse return error.AuthNotFound});

    const client = try zCord.Client.create(.{
        .allocator = &gpa.allocator,
        .auth_token = auth,
        .intents = .{ .guild_messages = true },
    });
    defer client.destroy();

    try client.ws({}, struct {
        pub fn handleDispatch(_: void, name: []const u8, data: zCord.JsonElement) !void {
            if (!std.mem.eql(u8, name, "MESSAGE_CREATE")) return;

            var msg_buffer: [0x1000]u8 = undefined;
            var msg: ?[]u8 = null;
            var channel_id: ?zCord.Snowflake(.channel) = null;

            while (try data.objectMatch(enum { content, channel_id })) |match| switch (match.key) {
                .content => {
                    msg = match.value.stringBuffer(&msg_buffer) catch |err| switch (err) {
                        error.StreamTooLong => &msg_buffer,
                        else => |e| return e,
                    };
                    _ = try match.value.finalizeToken();
                },
                .channel_id => {
                    channel_id = try zCord.Snowflake(.channel).consumeJsonElement(match.value);
                },
            };

            if (msg != null and channel_id != null) {
                std.debug.print(">> {d} -- {s}\n", .{ channel_id.?, msg.? });
            }
        }
    });
}
