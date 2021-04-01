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
        .intents = .{ .guild_messages = true },
    });
    defer c.destroy();

    try c.ws(struct {
        pub fn handleDispatch(client: *zCord.Client, name: []const u8, data: zCord.JsonElement) !void {
            if (!std.mem.eql(u8, name, "MESSAGE_CREATE")) return;

            var msg_buffer: [0x1000]u8 = undefined;
            var msg: ?[]u8 = null;
            var channel_id: ?zCord.Snowflake(.channel) = null;

            while (try data.objectMatch(enum { content, channel_id })) |match| switch (match) {
                .content => |el_content| {
                    msg = el_content.stringBuffer(&msg_buffer) catch |err| switch (err) {
                        error.StreamTooLong => &msg_buffer,
                        else => |e| return e,
                    };
                    _ = try el_content.finalizeToken();
                },
                .channel_id => |el_channel| {
                    channel_id = try zCord.Snowflake(.channel).consumeJsonElement(el_channel);
                },
            };

            if (channel_id != null and msg != null and std.mem.eql(u8, msg.?, "Hello")) {
                var response = try client.sendMessage(channel_id.?, .{
                    .content = "World",
                });
                defer response.deinit();
            }
        }
    });
}
