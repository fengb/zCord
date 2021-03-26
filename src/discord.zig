const std = @import("std");

/// Discord utilizes Twitter's snowflake format for uniquely identifiable
/// descriptors (IDs). These IDs are guaranteed to be unique across all of
/// Discord, except in some unique scenarios in which child objects share their
/// parent's ID. Because Snowflake IDs are up to 64 bits in size (e.g. a uint64),
/// they are always returned as strings in the HTTP API to prevent integer
/// overflows in some languages. See Gateway ETF/JSON for more information
/// regarding Gateway encoding.
pub const Snowflake = struct {
    raw: u64,

    pub fn init(num: 64) Snowflake {
        return .{ .raw = num };
    }

    pub fn parse(str: []const u8) !Snowflake {
        return Snowflake{
            .raw = try std.fmt.parseInt(u64, str, 10),
        };
    }

    /// Milliseconds since Discord Epoch, the first second of 2015 or 1420070400000.
    pub fn getTimestamp(self: Snowflake) u64 {
        return (self >> 22) + 1420070400000;
    }

    pub fn format(self: Snowflake, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{}", .{self.raw});
    }

    pub fn jsonStringify(self: Snowflake, options: std.json.StringifyOptions, writer: anytype) !void {
        try writer.print("\"{}\"", .{self.raw});
    }
};

pub const Gateway = struct {
    pub const Opcode = enum {
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
            return @bitCast(Intents, self);
        }
    };

    pub const Presence = struct {
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
