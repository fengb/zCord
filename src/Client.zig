const std = @import("std");
const zasp = @import("zasp");

const Gateway = @import("Gateway.zig");
const https = @import("https.zig");
const discord = @import("discord.zig");
const util = @import("util.zig");

const log = std.log.scoped(.zCord);
const default_agent = "zCord/0.0.1";

const Client = @This();

auth_token: []const u8,
user_agent: []const u8 = default_agent,

pub const startGateway = Gateway.start;

pub fn sendRequest(self: Client, allocator: *std.mem.Allocator, method: https.Request.Method, path: []const u8, body: anytype) !https.Request {
    var req = try https.Request.init(.{
        .allocator = allocator,
        .host = "discord.com",
        .method = method,
        .path = path,
        .user_agent = self.user_agent,
    });
    errdefer req.deinit();

    try req.client.writeHeaderValue("Accept", "application/json");
    try req.client.writeHeaderValue("Content-Type", "application/json");
    try req.client.writeHeaderValue("Authorization", self.auth_token);

    switch (@typeInfo(@TypeOf(body))) {
        .Null => _ = try req.sendEmptyBody(),
        .Optional => {
            if (body == null) {
                _ = try req.sendEmptyBody();
            } else {
                _ = try req.sendPrint("{}", .{zasp.json.format(body)});
            }
        },
        else => _ = try req.sendPrint("{}", .{zasp.json.format(body)}),
    }

    return req;
}

test {
    std.testing.refAllDecls(@This());
}
