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

    var gateway = try client.startGateway(.{
        .allocator = &gpa.allocator,
        .intents = .{ .guild_messages = true },
    });
    defer gateway.destroy();

    while (true) {
        processEvent(try gateway.recvEvent()) catch |err| {
            std.debug.print("{}\n", .{err});
        };
    }
}

fn processEvent(event: zCord.Gateway.Event) !void {
    switch (event) {
        .dispatch => |dispatch| {
            if (!std.mem.eql(u8, dispatch.name.constSlice(), "MESSAGE_CREATE")) return;

            var msg_buffer: [0x1000]u8 = undefined;
            var msg: ?[]u8 = null;
            var channel_id: ?zCord.Snowflake(.channel) = null;

            while (try dispatch.data.objectMatch(enum { content, channel_id })) |match| switch (match.key) {
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
        },
    }
}
