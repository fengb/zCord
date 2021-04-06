const std = @import("std");
const hzzp = @import("hzzp");
const wz = @import("wz");

const Heartbeat = @import("Client/Heartbeat.zig");
const https = @import("https.zig");
const discord = @import("discord.zig");
const json = @import("json.zig");
const util = @import("util.zig");

const log = std.log.scoped(.zCord);
const default_agent = "zCord/0.0.1";

const Client = @This();

allocator: *std.mem.Allocator,

context: ?*c_void,
auth_token: []const u8,
user_agent: []const u8,
intents: discord.Gateway.Intents,
presence: discord.Gateway.Presence,
connect_info: ?ConnectInfo,

ssl_tunnel: ?*https.Tunnel,
wz: WzClient,
wz_buffer: [0x1000]u8,
write_mutex: std.Thread.Mutex,

heartbeat: Heartbeat,

const WzClient = wz.base.client.BaseClient(https.Tunnel.Client.Reader, https.Tunnel.Client.Writer);
pub const JsonElement = json.Stream(WzClient.PayloadReader).Element;

pub const ConnectInfo = struct {
    heartbeat_interval_ms: u64,
    seq: u32,
    user_id: discord.Snowflake(.user),
    session_id: util.Fixbuf(0x100),
};

pub fn create(args: struct {
    allocator: *std.mem.Allocator,
    auth_token: []const u8,
    user_agent: []const u8 = default_agent,
    context: ?*c_void = null,
    intents: discord.Gateway.Intents = .{},
    presence: discord.Gateway.Presence = .{},
    heartbeat: Heartbeat.Strategy = Heartbeat.Strategy.default,
}) !*Client {
    const result = try args.allocator.create(Client);
    errdefer args.allocator.destroy(result);
    result.allocator = args.allocator;

    result.context = args.context;
    result.auth_token = args.auth_token;
    result.user_agent = args.user_agent;
    result.intents = args.intents;
    result.presence = args.presence;
    result.connect_info = null;

    result.ssl_tunnel = null;
    result.write_mutex = .{};

    result.heartbeat = try Heartbeat.init(result, args.heartbeat);
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

pub fn ctx(self: *Client, comptime T: type) *T {
    return @ptrCast(*T, @alignCast(@alignOf(T), self.context.?));
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

    var result: ConnectInfo = undefined;

    var flush_error: util.ErrorOf(self.wz.flushReader)!void = {};
    {
        var stream = json.stream(self.wz.reader());
        defer self.wz.flushReader() catch |err| {
            flush_error = err;
        };
        errdefer |err| log.info("{}", .{stream.debugInfo()});

        const root = try stream.root();
        const paths = try json.path.match(null, root, struct {
            @"op": u8,
            @"d.heartbeat_interval": u32,
        });

        if (paths.@"op" != @enumToInt(discord.Gateway.Opcode.hello)) {
            return error.MalformedHelloResponse;
        }

        result.heartbeat_interval_ms = paths.@"d.heartbeat_interval";
    }
    try flush_error;

    if (result.heartbeat_interval_ms == 0) {
        return error.MalformedHelloResponse;
    }

    if (self.connect_info) |old_info| {
        try self.sendCommand(.{ .@"resume" = .{
            .token = self.auth_token,
            .seq = old_info.seq,
            .session_id = old_info.session_id.slice(),
        } });
        result.seq = old_info.seq;
        result.user_id = old_info.user_id;
        result.session_id = old_info.session_id;
        return result;
    }

    try self.sendCommand(.{ .identify = .{
        .compress = false,
        .intents = self.intents,
        .token = self.auth_token,
        .properties = .{
            .@"$os" = @tagName(std.Target.current.os.tag),
            .@"$browser" = self.user_agent,
            .@"$device" = self.user_agent,
        },
        .presence = self.presence,
    } });

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
        errdefer |err| log.info("{}", .{stream.debugInfo()});

        const root = try stream.root();
        var buffer: [0x10000]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buffer);
        const paths = try json.path.match(&fba.allocator, root, struct {
            @"t": []const u8,
            @"s": ?u32,
            @"op": u8,
            @"d.session_id": []const u8,
            @"d.user.id": []const u8,
        });

        if (!std.mem.eql(u8, paths.@"t", "READY")) {
            return error.MalformedIdentify;
        }
        if (paths.@"op" != @enumToInt(discord.Gateway.Opcode.dispatch)) {
            return error.MalformedIdentify;
        }

        if (paths.@"s") |seq| {
            result.seq = seq;
        }

        result.user_id = try discord.Snowflake(.user).parse(paths.@"d.user.id");
        result.session_id.copyFrom(paths.@"d.session_id");
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

pub fn ws(self: *Client, handler: anytype) !void {
    var reconnect_wait: u64 = 1;
    while (true) {
        self.connect_info = self.connect() catch |err| switch (err) {
            error.AuthenticationFailed,
            error.DisallowedIntents,
            error.CertificateVerificationFailed,
            => |e| return e,
            else => {
                log.info("Connect error: {s}", .{@errorName(err)});
                std.time.sleep(reconnect_wait * std.time.ns_per_s);
                reconnect_wait = std.math.min(reconnect_wait * 2, 30);
                continue;
            },
        };
        defer self.disconnect();

        if (@hasDecl(handler, "handleConnect")) {
            handler.handleConnect(self, self.connect_info.?);
        }

        reconnect_wait = 1;

        self.heartbeat.send(.start);
        defer self.heartbeat.send(.stop);

        self.listen(handler) catch |err| switch (err) {
            error.ConnectionReset => continue,
            else => |e| {
                // TODO: convert this to inline switch once available
                if (!util.errSetContains(WzClient.ReadNextError, err)) {
                    return err;
                }
            },
        };
    }
}

fn processCloseEvent(self: *Client) !void {
    const event = (try self.wz.next()).?;

    const code_num = std.mem.readIntBig(u16, event.chunk.data[0..2]);
    const code = @intToEnum(discord.Gateway.CloseEventCode, code_num);
    switch (code) {
        _ => {
            log.info("Websocket close frame - {d}: unknown code. Reconnecting...", .{code_num});
            return error.ConnectionReset;
        },
        .NormalClosure,
        .GoingAway,
        .ProtocolError,
        .NoStatusReceived,
        .AbnormalClosure,
        .PolicyViolation,
        .InternalError,
        .ServiceRestart,
        .TryAgainLater,
        .BadGateway,
        .UnknownError,
        .SessionTimedOut,
        => {
            log.info("Websocket close frame - {d}: {s}. Reconnecting...", .{ @enumToInt(code), @tagName(code) });
            return error.ConnectionReset;
        },

        // Most likely user error
        .UnsupportedData => return error.UnsupportedData,
        .InvalidFramePayloadData => return error.InvalidFramePayloadData,
        .MessageTooBig => return error.MessageTooBig,
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
        .MissingExtension => unreachable,
        .TlsHandshake => unreachable,
        .NotAuthenticated => unreachable,
        .InvalidIntents => unreachable,
    }
}

fn listen(self: *Client, handler: anytype) !void {
    while (try self.wz.next()) |event| {
        switch (event.header.opcode) {
            .Text => {
                self.processChunks(self.wz.reader(), handler) catch |err| {
                    log.info("Process chunks failed: {s}", .{err});
                };
                try self.wz.flushReader();
            },
            .Ping, .Pong => {},
            .Close => try self.processCloseEvent(),
            .Binary => return error.WtfBinary,
            else => return error.WtfWtf,
        }
    }

    log.info("Websocket close frame - {{}}: no reason provided. Reconnecting...", .{});
    return error.ConnectionReset;
}

fn processChunks(self: *Client, reader: anytype, handler: anytype) !void {
    var stream = json.stream(reader);
    errdefer |err| log.info("{}", .{stream.debugInfo()});

    var name_buf: [32]u8 = undefined;
    var name: ?[]u8 = null;
    var op: ?discord.Gateway.Opcode = null;

    const root = try stream.root();

    while (try root.objectMatch(enum { t, s, op, d })) |match| switch (match) {
        .t => |el_type| {
            name = try el_type.optionalStringBuffer(&name_buf);
        },
        .s => |el_seq| {
            if (try el_seq.optionalNumber(u32)) |seq| {
                self.connect_info.?.seq = seq;
            }
        },
        .op => |el_op| {
            op = try std.meta.intToEnum(discord.Gateway.Opcode, try el_op.number(u8));
        },
        .d => |el_data| {
            switch (op orelse return error.DataBeforeOp) {
                .dispatch => {
                    log.info("<< {d} -- {s}", .{ self.connect_info.?.seq, name });
                    try handler.handleDispatch(
                        self,
                        name orelse return error.DispatchWithoutName,
                        el_data,
                    );
                },
                .heartbeat_ack => self.heartbeat.send(.ack),
                else => {},
            }
            _ = try el_data.finalizeToken();
        },
    };
}

pub fn sendCommand(self: *Client, command: discord.Gateway.Command) !void {
    const ssl_tunnel = self.ssl_tunnel orelse return error.NotConnected;

    var buf: [0x1000]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "{s}", .{json.format(command)});

    const held = self.write_mutex.acquire();
    defer held.release();

    try self.wz.writeHeader(.{ .opcode = .Text, .length = msg.len });
    try self.wz.writeChunk(msg);
}

pub fn sendRequest(self: *Client, allocator: *std.mem.Allocator, method: https.Request.Method, path: []const u8, body: anytype) !https.Request {
    var req = try https.Request.init(.{
        .allocator = self.allocator,
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
        .Null => try req.sendEmptyBody(),
        .Optional => {
            if (body == null) {
                try req.sendEmptyBody();
            } else {
                try req.printSend("{}", .{json.format(body)});
            }
        },
        else => try req.printSend("{}", .{json.format(body)}),
    }

    return req;
}

pub fn sendMessage(self: *Client, allocator: *std.mem.Allocator, channel_id: discord.Snowflake(.channel), msg: discord.Resource.Message) !https.Request {
    var buf: [0x100]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/api/v6/channels/{d}/messages", .{channel_id});
    return self.sendRequest(allocator, .POST, path, msg);
}

test {
    std.testing.refAllDecls(@This());
}
