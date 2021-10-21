const std = @import("std");
const builtin = @import("builtin");

/// Discord utilizes Twitter's snowflake format for uniquely identifiable
/// descriptors (IDs). These IDs are guaranteed to be unique across all of
/// Discord, except in some unique scenarios in which child objects share their
/// parent's ID. Because Snowflake IDs are up to 64 bits in size (e.g. a uint64),
/// they are always returned as strings in the HTTP API to prevent integer
/// overflows in some languages. See Gateway ETF/JSON for more information
/// regarding Gateway encoding.
pub fn Snowflake(comptime scope: @Type(.EnumLiteral)) type {
    _ = scope;

    return enum(u64) {
        _,

        const Self = @This();

        pub fn init(num: u64) Self {
            return @intToEnum(Self, num);
        }

        pub fn parse(str: []const u8) !Self {
            return init(
                std.fmt.parseInt(u64, str, 10) catch return error.SnowflakeTooSpecial,
            );
        }

        pub fn consumeJsonElement(elem: anytype) !Self {
            var buf: [64]u8 = undefined;
            const str = elem.stringBuffer(&buf) catch |err| switch (err) {
                error.StreamTooLong => return error.SnowflakeTooSpecial,
                else => |e| return e,
            };
            return try parse(str);
        }

        /// Milliseconds since Discord Epoch, the first second of 2015 or 1420070400000.
        pub fn getTimestamp(self: Self) u64 {
            return (@enumToInt(self) >> 22) + 1420070400000;
        }

        pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = fmt;
            _ = options;
            try writer.print("{}", .{@enumToInt(self)});
        }

        pub fn jsonStringify(self: Self, options: std.json.StringifyOptions, writer: anytype) !void {
            _ = options;
            try writer.print("\"{}\"", .{@enumToInt(self)});
        }
    };
}

pub const Gateway = struct {
    pub const Opcode = enum(u4) {
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

    pub const CloseEventCode = enum(u16) {
        NormalClosure = 1000,
        GoingAway = 1001,
        ProtocolError = 1002,
        UnsupportedData = 1003,
        NoStatusReceived = 1005,
        AbnormalClosure = 1006,
        InvalidFramePayloadData = 1007,
        PolicyViolation = 1008,
        MessageTooBig = 1009,
        MissingExtension = 1010,
        InternalError = 1011,
        ServiceRestart = 1012,
        TryAgainLater = 1013,
        BadGateway = 1014,
        TlsHandshake = 1015,

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
    };

    pub const Command = union(Opcode) {
        dispatch: void,
        reconnect: void,
        invalid_session: void,
        hello: void,
        heartbeat_ack: void,

        identify: struct {
            token: []const u8,
            properties: struct {
                @"$os": []const u8 = @tagName(builtin.target.os.tag),
                @"$browser": []const u8,
                @"$device": []const u8,
            },
            compress: bool = false,
            presence: ?Presence = null,
            intents: Intents,
        },
        @"resume": struct {
            token: []const u8,
            session_id: []const u8,
            seq: u32,
        },
        heartbeat: u32,
        request_guild_members: struct {
            guild_id: Snowflake(.guild),
            query: []const u8 = "",
            limit: u32,
            presences: bool = false,
            user_ids: ?[]Snowflake(.user) = null,
        },
        voice_state_update: struct {
            guild_id: Snowflake(.guild),
            channel_id: ?Snowflake(.channel) = null,
            self_mute: bool,
            self_deaf: bool,
        },
        presence_update: struct {
            since: ?u32 = null,
            activities: ?[]Activity = null,
            status: Status,
            afk: bool,
        },

        pub fn jsonStringify(self: Command, options: std.json.StringifyOptions, writer: anytype) @TypeOf(writer).Error!void {
            inline for (std.meta.fields(Opcode)) |field| {
                const tag = @field(Opcode, field.name);
                if (std.meta.activeTag(self) == tag) {
                    return std.json.stringify(.{
                        .op = @enumToInt(tag),
                        .d = @field(self, @tagName(tag)),
                    }, options, writer);
                }
            }
            unreachable;
        }
    };

    pub const Intents = packed struct {
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
        _pad: u1 = 0,

        pub fn toRaw(self: Intents) u16 {
            return @bitCast(u16, self);
        }

        pub fn fromRaw(raw: u16) Intents {
            return @bitCast(Intents, raw);
        }

        pub fn jsonStringify(self: Intents, options: std.json.StringifyOptions, writer: anytype) !void {
            _ = options;
            try writer.print("{}", .{self.toRaw()});
        }
    };

    pub const Status = enum {
        online,
        dnd,
        idle,
        invisible,
        offline,

        pub fn jsonStringify(self: @This(), options: std.json.StringifyOptions, writer: anytype) !void {
            _ = options;
            try writer.writeAll("\"");
            try writer.writeAll(@tagName(self));
            try writer.writeAll("\"");
        }
    };

    pub const Presence = struct {
        status: Status = .online,
        activities: []const Activity = &.{},
        since: ?u32 = null,
        afk: bool = false,
    };

    pub const Activity = struct {
        type: enum(u3) {
            Game = 0,
            Streaming = 1,
            Listening = 2,
            Watching = 3,
            Custom = 4,
            Competing = 5,

            pub fn jsonStringify(self: @This(), options: std.json.StringifyOptions, writer: anytype) !void {
                _ = options;
                try writer.print("{d}", .{@enumToInt(self)});
            }
        },
        name: []const u8,
    };
};

pub const Resource = struct {
    pub const Message = struct {
        content: []const u8 = "",
        embed: ?Embed = null,

        pub const Embed = struct {
            title: ?[]const u8 = null,
            description: ?[]const u8 = null,
            url: ?[]const u8 = null,
            timestamp: ?[]const u8 = null,
            color: ?u32 = null,
        };
    };
};

test {
    _ = std.testing.refAllDecls(Gateway);
    _ = std.testing.refAllDecls(Resource);
}
