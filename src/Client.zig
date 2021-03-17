const std = @import("std");
const hzzp = @import("hzzp");
const wz = @import("wz");

const Heartbeat = @import("Client/Heartbeat.zig");
const https = @import("https.zig");
const format = @import("format.zig");
const json = @import("json.zig");
const util = @import("util.zig");

const agent = "zCord/0.0.1";

const Client = @This();

allocator: *std.mem.Allocator,

auth_token: []const u8,
intents: Intents,
presence: Presence,
connect_info: ?ConnectInfo,

ssl_tunnel: ?*https.Tunnel,
wz: WzClient,
wz_buffer: [0x1000]u8,
write_mutex: std.Thread.Mutex,

heartbeat: Heartbeat,

const WzClient = wz.base.client.BaseClient(https.Tunnel.Client.Reader, https.Tunnel.Client.Writer);
pub const JsonElement = json.Stream(WzClient.PayloadReader).Element;

const ConnectInfo = struct {
    heartbeat_interval_ms: u64,
    seq: usize,
    session_id: util.Fixbuf(0x100),
};

const Opcode = enum {
    /// An event was dispatched.
    dispatch = 0,
    /// Fired periodically by the client to keep the connection alive.
    heartbeat = 1,
    /// Starts a new session during the initial handshake.
    identify = 2,
    /// Update the client's presence.
    presence_update = 3,
    /// Used to join/leave or move between voice channels.
    voice_state_update = 4,
    /// Resume a previous session that was disconnected.
    @"resume" = 6,
    /// You should attempt to reconnect and resume immediately.
    reconnect = 7,
    /// Request information about offline guild members in a large guild.
    request_guild_members = 8,
    /// The session has been invalidated. You should reconnect and identify/resume accordingly.
    invalid_session = 9,
    /// Sent immediately after connecting, contains the heartbeat_interval to use.
    hello = 10,
    /// Sent in response to receiving a heartbeat to acknowledge that it has been received.
    heartbeat_ack = 11,
};

const Intents = packed struct {
    guilds: bool = false,
    guild_members: bool = false,
    guild_bans: bool = false,
    guild_emojis: bool = false,
    guild_integrations: bool = false,
    guild_webhooks: bool = false,
    guild_invites: bool = false,
    guild_voice_states: bool = false,
    guild_presences: bool = false,
    guild_messages: bool = false,
    guild_message_reactions: bool = false,
    guild_message_typing: bool = false,
    direct_messages: bool = false,
    direct_message_reactions: bool = false,
    direct_message_typing: bool = false,
    _pad: bool = undefined,

    fn toRaw(self: Intents) u16 {
        return @bitCast(u16, self);
    }

    fn fromRaw(raw: u16) Intents {
        return @bitCast(Intents, self);
    }
};

const Presence = struct {
    status: enum {
        online,
        dnd,
        idle,
        invisible,
        offline,

        pub fn jsonStringify(self: @This(), options: std.json.StringifyOptions, writer: anytype) !void {
            try writer.writeAll("\"");
            try writer.writeAll(@tagName(self));
            try writer.writeAll("\"");
        }
    } = .online,
    activities: []const Activity = &.{},
    since: ?u32 = null,
    afk: bool = false,
};

const Activity = struct {
    type: enum {
        Game = 0,
        Streaming = 1,
        Listening = 2,
        Custom = 4,
        Competing = 5,

        pub fn jsonStringify(self: @This(), options: std.json.StringifyOptions, writer: anytype) !void {
            try writer.print("{d}", .{@enumToInt(self)});
        }
    },
    name: []const u8,
};

pub fn create(args: struct {
    allocator: *std.mem.Allocator,
    auth_token: []const u8,
    intents: Intents,
    presence: Presence = .{},
}) !*Client {
    const result = try args.allocator.create(Client);
    errdefer args.allocator.destroy(result);
    result.allocator = args.allocator;

    result.auth_token = args.auth_token;
    result.intents = args.intents;
    result.presence = args.presence;
    result.connect_info = null;

    result.ssl_tunnel = null;
    result.write_mutex = .{};

    result.heartbeat = try Heartbeat.init(result);
    errdefer result.heartbeat.deinit();

    return result;
}

pub fn destroy(self: *Client) void {
    if (self.ssl_tunnel) |ssl_tunnel| {
        ssl_tunnel.deinit();
    }
    self.heartbeat.deinit();
    self.allocator.destroy(self);
}

fn connect(self: *Client) !ConnectInfo {
    std.debug.assert(self.ssl_tunnel == null);
    self.ssl_tunnel = try https.Tunnel.init(.{
        .allocator = self.allocator,
        .host = "gateway.discord.gg",
    });
    errdefer self.disconnect();

    self.wz = wz.base.client.create(
        &self.wz_buffer,
        self.ssl_tunnel.?.client.reader(),
        self.ssl_tunnel.?.client.writer(),
    );

    // Handshake
    try self.wz.handshakeStart("/?v=6&encoding=json");
    try self.wz.handshakeAddHeaderValue("Host", "gateway.discord.gg");
    try self.wz.handshakeFinish();

    if (try self.wz.next()) |event| {
        std.debug.assert(event == .header);
    }

    var result = ConnectInfo{
        .heartbeat_interval_ms = 0,
        .seq = 0,
        .session_id = .{},
    };

    var flush_error: util.ErrorOf(self.wz.flushReader)!void = {};
    {
        var stream = json.stream(self.wz.reader());
        defer self.wz.flushReader() catch |err| {
            flush_error = err;
        };
        errdefer |err| std.debug.print("{}\n", .{stream.debugInfo()});

        const root = try stream.root();
        while (try root.objectMatchUnion(enum { op, d })) |match| switch (match) {
            .op => |el_op| {
                const op = try std.meta.intToEnum(Opcode, try el_op.number(u8));
                if (op != .hello) {
                    return error.MalformedHelloResponse;
                }
            },
            .d => |el_data| {
                while (try el_data.objectMatch("heartbeat_interval")) |hbi| {
                    result.heartbeat_interval_ms = try hbi.value.number(u32);
                }
            },
        };
    }
    try flush_error;

    if (result.heartbeat_interval_ms == 0) {
        return error.MalformedHelloResponse;
    }

    if (self.connect_info) |old_info| {
        try self.sendCommand(.@"resume", .{
            .token = self.auth_token,
            .seq = old_info.seq,
            .session_id = old_info.session_id.slice(),
        });
        result.session_id = old_info.session_id;
        result.seq = old_info.seq;
        return result;
    }

    try self.sendCommand(.identify, .{
        .compress = false,
        .intents = self.intents.toRaw(),
        .token = self.auth_token,
        .properties = .{
            .@"$os" = @tagName(std.Target.current.os.tag),
            .@"$browser" = agent,
            .@"$device" = agent,
        },
        .presence = self.presence,
    });

    if (try self.wz.next()) |event| {
        if (event.header.opcode == .Close) {
            try self.processCloseEvent();
        }
    }

    {
        var stream = json.stream(self.wz.reader());
        defer self.wz.flushReader() catch |err| {
            flush_error = err;
        };
        errdefer |err| std.debug.print("{}\n", .{stream.debugInfo()});

        const root = try stream.root();
        while (try root.objectMatchUnion(enum { t, s, op, d })) |match| switch (match) {
            .t => |el_type| {
                var name_buf: [0x100]u8 = undefined;
                const name = try el_type.stringBuffer(&name_buf);
                if (!std.mem.eql(u8, name, "READY")) {
                    return error.MalformedIdentify;
                }
            },
            .s => |el_seq| {
                if (try el_seq.optionalNumber(u32)) |seq| {
                    result.seq = seq;
                }
            },
            .op => |el_op| {
                const op = try std.meta.intToEnum(Opcode, try el_op.number(u8));
                if (op != .dispatch) {
                    return error.MalformedIdentify;
                }
            },
            .d => |el_data| {
                while (try el_data.objectMatch("session_id")) |session_match| {
                    const slice = try session_match.value.stringBuffer(&result.session_id.data);
                    result.session_id.len = slice.len;
                }
            },
        };
    }
    try flush_error;

    return result;
}

fn disconnect(self: *Client) void {
    if (self.ssl_tunnel) |ssl_tunnel| {
        ssl_tunnel.deinit();
        self.ssl_tunnel = null;
    }
}

pub fn run(self: *Client, ctx: anytype, handler: anytype) !void {
    var reconnect_wait: u64 = 1;
    while (true) {
        self.connect_info = self.connect() catch |err| switch (err) {
            error.AuthenticationFailed => |e| return e,
            error.CertificateVerificationFailed => |e| return e,
            else => {
                std.debug.print("Connect error: {s}\n", .{@errorName(err)});
                std.time.sleep(reconnect_wait * std.time.ns_per_s);
                reconnect_wait = std.math.min(reconnect_wait * 2, 30);
                continue;
            },
        };
        defer self.disconnect();

        reconnect_wait = 1;

        self.heartbeat.mailbox.putOverwrite(.start);
        defer self.heartbeat.mailbox.putOverwrite(.stop);

        self.listen(ctx, handler) catch |err| switch (err) {
            error.ConnectionReset => continue,
            else => |e| return e,
        };
    }
}

fn processCloseEvent(self: *Client) !void {
    const event = (try self.wz.next()).?;

    const CloseEventCode = enum(u16) {
        UnknownError = 4000,
        UnknownOpcode = 4001,
        DecodeError = 4002,
        NotAuthenticated = 4003,
        AuthenticationFailed = 4004,
        AlreadyAuthenticated = 4005,
        InvalidSeq = 4007,
        RateLimited = 4008,
        SessionTimedOut = 4009,
        InvalidShard = 4010,
        ShardingRequired = 4011,
        InvalidApiVersion = 4012,
        InvalidIntents = 4013,
        DisallowedIntents = 4014,

        _,

        pub fn format(code: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.print("{d}: {s}", .{ @enumToInt(code), @tagName(code) });
        }
    };

    const code_num = std.mem.readIntBig(u16, event.chunk.data[0..2]);
    const code = @intToEnum(CloseEventCode, code_num);
    switch (code) {
        _ => {
            std.debug.print("Websocket close frame - {d}: unknown code. Reconnecting...\n", .{code_num});
            return error.ConnectionReset;
        },
        .UnknownError, .SessionTimedOut => {
            std.debug.print("Websocket close frame - {}. Reconnecting...\n", .{code});
            return error.ConnectionReset;
        },

        // Most likely user error
        .AuthenticationFailed => return error.AuthenticationFailed,
        .AlreadyAuthenticated => return error.AlreadyAuthenticated,
        .DecodeError => return error.DecodeError,
        .UnknownOpcode => return error.UnknownOpcode,
        .RateLimited => return error.WoahNelly,
        .DisallowedIntents => return error.DisallowedIntents,

        // We don't support these yet
        .InvalidSeq => unreachable,
        .InvalidShard => unreachable,
        .ShardingRequired => unreachable,
        .InvalidApiVersion => unreachable,

        // This library fucked up
        .NotAuthenticated => unreachable,
        .InvalidIntents => unreachable,
    }
}

fn listen(self: *Client, ctx: anytype, handler: anytype) !void {
    while (try self.wz.next()) |event| {
        switch (event.header.opcode) {
            .Text => {
                self.processChunks(self.wz.reader(), ctx, handler) catch |err| {
                    std.debug.print("Process chunks failed: {s}\n", .{err});
                };
                try self.wz.flushReader();
            },
            .Ping, .Pong => {},
            .Close => try self.processCloseEvent(),
            .Binary => return error.WtfBinary,
            else => return error.WtfWtf,
        }
    }

    std.debug.print("Websocket close frame - {{}}: no reason provided. Reconnecting...\n", .{});
    return error.ConnectionReset;
}

fn processChunks(self: *Client, reader: anytype, ctx: anytype, handler: anytype) !void {
    var stream = json.stream(reader);
    errdefer |err| std.debug.print("{}\n", .{stream.debugInfo()});

    var name_buf: [32]u8 = undefined;
    var name: ?[]u8 = null;
    var op: ?Opcode = null;

    const root = try stream.root();

    while (try root.objectMatchUnion(enum { t, s, op, d })) |match| switch (match) {
        .t => |el_type| {
            name = try el_type.optionalStringBuffer(&name_buf);
        },
        .s => |el_seq| {
            if (try el_seq.optionalNumber(u32)) |seq| {
                self.connect_info.?.seq = seq;
            }
        },
        .op => |el_op| {
            op = try std.meta.intToEnum(Opcode, try el_op.number(u8));
        },
        .d => |el_data| {
            switch (op orelse return error.DataBeforeOp) {
                .dispatch => {
                    std.debug.print("<< {d} -- {s}\n", .{ self.connect_info.?.seq, name });
                    try handler.handleDispatch(
                        ctx,
                        name orelse return error.DispatchWithoutName,
                        el_data,
                    );
                },
                .heartbeat_ack => self.heartbeat.mailbox.putOverwrite(.ack),
                else => {},
            }
            _ = try el_data.finalizeToken();
        },
    };
}

pub fn sendCommand(self: *Client, opcode: Opcode, data: anytype) !void {
    const ssl_tunnel = self.ssl_tunnel orelse return error.NotConnected;

    var buf: [0x1000]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "{s}", .{
        format.json(.{
            .op = @enumToInt(opcode),
            .d = data,
        }),
    });

    const held = self.write_mutex.acquire();
    defer held.release();

    try self.wz.writeHeader(.{ .opcode = .Text, .length = msg.len });
    try self.wz.writeChunk(msg);
}

fn makeRequest(self: *Client, method: https.Request.Method, path: []const u8, body: anytype) !https.Request {
    var req = try https.Request.init(.{
        .allocator = self.allocator,
        .host = "discord.com",
        .method = method,
        .path = path,
    });
    errdefer req.deinit();

    try req.client.writeHeaderValue("User-Agent", agent);
    try req.client.writeHeaderValue("Accept", "application/json");
    try req.client.writeHeaderValue("Content-Type", "application/json");
    try req.client.writeHeaderValue("Authorization", self.auth_token);

    try req.printSend("{}", .{format.json(body)});

    return req;
}

pub fn sendMessage(self: *Client, channel_id: u64, msg: struct { content: []const u8 }) !https.Request {
    var buf: [0x100]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/api/v6/channels/{d}/messages", .{channel_id});
    return self.makeRequest(.POST, path, msg);
}

test {
    std.testing.refAllDecls(@This());
}
