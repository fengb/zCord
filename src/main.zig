const std = @import("std");
const hzzp = @import("hzzp");
const wz = @import("wz");

const Heartbeat = @import("Heartbeat.zig");
const format = @import("format.zig");
const request = @import("request.zig");
const util = @import("util.zig");

const agent = "zCord/0.0.1";

fn Buffer(comptime max_len: usize) type {
    return struct {
        data: [max_len]u8 = undefined,
        len: usize = 0,

        fn initFrom(data: []const u8) @This() {
            var result: @This() = undefined;
            std.mem.copy(u8, &result.data, data);
            result.len = data.len;
            return result;
        }

        fn slice(self: @This()) []const u8 {
            return self.data[0..self.len];
        }

        fn append(self: *@This(), char: u8) !void {
            if (self.len >= max_len) {
                return error.NoSpaceLeft;
            }
            self.data[self.len] = char;
            self.len += 1;
        }

        fn last(self: @This()) ?u8 {
            if (self.len > 0) {
                return self.data[self.len - 1];
            } else {
                return null;
            }
        }

        fn pop(self: *@This()) !u8 {
            return self.last() orelse error.Empty;
        }
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var auth_buf: [0x100]u8 = undefined;
    const auth = try std.fmt.bufPrint(&auth_buf, "Bot {s}", .{std.os.getenv("DISCORD_AUTH") orelse return error.AuthNotFound});

    var discord_ws = try DiscordWs.init(.{
        .allocator = &gpa.allocator,
        .auth_token = auth,
        .intents = .{ .guild_messages = true },
    });
    defer discord_ws.deinit();

    discord_ws.run({}, struct {
        fn handleDispatch(_: void, name: []const u8, data: anytype) !void {
            if (!std.mem.eql(u8, name, "MESSAGE_CREATE")) return;

            var msg_buffer: [0x1000]u8 = undefined;
            var msg: ?[]u8 = null;
            var channel_id: ?u64 = null;

            while (try data.objectMatchUnion(enum { content, channel_id })) |match| switch (match) {
                .content => |el_content| {
                    msg = el_content.stringBuffer(&msg_buffer) catch |err| switch (err) {
                        error.NoSpaceLeft => &msg_buffer,
                        else => |e| return e,
                    };
                    _ = try el_content.finalizeToken();
                },
                .channel_id => |el_channel| {
                    var buf: [0x100]u8 = undefined;
                    const channel_string = try el_channel.stringBuffer(&buf);
                    channel_id = try std.fmt.parseInt(u64, channel_string, 10);
                },
            };

            if (msg != null and channel_id != null) {
                std.debug.print(">> {d} -- {s}\n", .{ channel_id.?, msg.? });
            }
        }
    }) catch |err| switch (err) {
        error.AuthenticationFailed => |e| return e,
        else => @panic(@errorName(err)),
    };

    std.debug.print("Exited: {}\n", .{discord_ws.client});
}

pub const DiscordWs = struct {
    allocator: *std.mem.Allocator,

    auth_token: []const u8,
    intents: Intents,
    presence: Presence,
    connect_info: ?ConnectInfo,

    ssl_tunnel: ?*request.SslTunnel,
    client: wz.base.client.BaseClient(request.SslTunnel.Client.Reader, request.SslTunnel.Client.Writer),
    client_buffer: [0x1000]u8,
    write_mutex: std.Thread.Mutex,

    heartbeat: Heartbeat,

    const ConnectInfo = struct {
        heartbeat_interval_ms: u64,
        seq: usize,
        session_id: Buffer(0x100),
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

    pub fn init(args: struct {
        allocator: *std.mem.Allocator,
        auth_token: []const u8,
        intents: Intents,
        presence: Presence = .{},
    }) !*DiscordWs {
        const result = try args.allocator.create(DiscordWs);
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

    pub fn deinit(self: *DiscordWs) void {
        if (self.ssl_tunnel) |ssl_tunnel| {
            ssl_tunnel.deinit();
        }
        self.heartbeat.deinit();
        self.allocator.destroy(self);
    }

    fn connect(self: *DiscordWs) !ConnectInfo {
        std.debug.assert(self.ssl_tunnel == null);
        self.ssl_tunnel = try request.SslTunnel.init(.{
            .allocator = self.allocator,
            .host = "gateway.discord.gg",
        });
        errdefer self.disconnect();

        self.client = wz.base.client.create(
            &self.client_buffer,
            self.ssl_tunnel.?.client.reader(),
            self.ssl_tunnel.?.client.writer(),
        );

        // Handshake
        try self.client.handshakeStart("/?v=6&encoding=json");
        try self.client.handshakeAddHeaderValue("Host", "gateway.discord.gg");
        try self.client.handshakeFinish();

        if (try self.client.next()) |event| {
            std.debug.assert(event == .header);
        }

        var result = ConnectInfo{
            .heartbeat_interval_ms = 0,
            .seq = 0,
            .session_id = .{},
        };

        var flush_error: util.ErrorOf(self.client.flushReader)!void = {};
        {
            var stream = util.streamJson(self.client.reader());
            defer self.client.flushReader() catch |err| {
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

        if (try self.client.next()) |event| {
            if (event.header.opcode == .Close) {
                try self.processCloseEvent();
            }
        }

        {
            var stream = util.streamJson(self.client.reader());
            defer self.client.flushReader() catch |err| {
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

    fn disconnect(self: *DiscordWs) void {
        if (self.ssl_tunnel) |ssl_tunnel| {
            ssl_tunnel.deinit();
            self.ssl_tunnel = null;
        }
    }

    pub fn run(self: *DiscordWs, ctx: anytype, handler: anytype) !void {
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

    fn processCloseEvent(self: *DiscordWs) !void {
        const event = (try self.client.next()).?;

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

    pub fn listen(self: *DiscordWs, ctx: anytype, handler: anytype) !void {
        while (try self.client.next()) |event| {
            switch (event.header.opcode) {
                .Text => {
                    self.processChunks(self.client.reader(), ctx, handler) catch |err| {
                        std.debug.print("Process chunks failed: {s}\n", .{err});
                    };
                    try self.client.flushReader();
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

    pub fn processChunks(self: *DiscordWs, reader: anytype, ctx: anytype, handler: anytype) !void {
        var stream = util.streamJson(reader);
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

    pub fn sendCommand(self: *DiscordWs, opcode: Opcode, data: anytype) !void {
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

        try self.client.writeHeader(.{ .opcode = .Text, .length = msg.len });
        try self.client.writeChunk(msg);
    }
};

test "" {
    _ = request;
    _ = util;
}
