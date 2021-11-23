const std = @import("std");

const Gateway = @import("Gateway.zig");
const https = @import("https.zig");
const discord = @import("discord.zig");
const json = @import("json.zig");
const util = @import("util.zig");

const log = std.log.scoped(.zCord);
const default_agent = "zCord/0.0.1";

const Client = @This();

allocator: *std.mem.Allocator,

auth_token: []const u8,
user_agent: []const u8,
intents: discord.Gateway.Intents,
presence: discord.Gateway.Presence,

pub fn init(args: struct {
    allocator: *std.mem.Allocator,
    auth_token: []const u8,
    user_agent: []const u8 = default_agent,
    intents: discord.Gateway.Intents = .{},
    presence: discord.Gateway.Presence = .{},
}) Client {
    return .{
        .allocator = args.allocator,
        .auth_token = args.auth_token,
        .user_agent = args.user_agent,
        .intents = args.intents,
        .presence = args.presence,
    };
}

pub fn startGateway(self: Client) !*Gateway {
    return Gateway.start(self);
}

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
                _ = try req.sendPrint("{}", .{json.format(body)});
            }
        },
        else => _ = try req.sendPrint("{}", .{json.format(body)}),
    }

    return req;
}

test {
    std.testing.refAllDecls(@This());
}
