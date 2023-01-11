const std = @import("std");
const builtin = @import("builtin");

const wz = @import("wz");
const zasp = @import("zasp");

const Client = @import("Client.zig");
const Heartbeat = @import("Gateway/Heartbeat.zig");
const https = @import("https.zig");
const discord = @import("discord.zig");
const util = @import("util.zig");

const log = std.log.scoped(.zCord);
const default_agent = "zCord/0.0.1";

const Gateway = @This();

allocator: std.mem.Allocator,
client: Client,
intents: discord.Gateway.Intents,
presence: discord.Gateway.Presence,

ssl_tunnel: ?*https.Tunnel,
wz: WzClient,
event_stream: ?zasp.json.Stream(WzClient.PayloadReader),
wz_buffer: [0x1000]u8,
write_mutex: std.Thread.Mutex,

heartbeat_interval_ms: u64,
seq: u32,
session_id: ?std.BoundedArray(u8, 0x100),

heartbeat: Heartbeat,

const WzClient = wz.base.client.BaseClient(https.Tunnel.Client.Reader, https.Tunnel.Client.Writer);
pub const JsonElement = zasp.json.Stream(WzClient.PayloadReader).Element;

pub fn start(client: Client, args: struct {
    allocator: std.mem.Allocator,
    intents: discord.Gateway.Intents = .{},
    presence: discord.Gateway.Presence = .{},
    heartbeat: Heartbeat.Strategy = Heartbeat.Strategy.default,
}) !*Gateway {
    const result = try args.allocator.create(Gateway);
    result.allocator = args.allocator;
    result.client = client;
    result.intents = args.intents;
    result.presence = args.presence;

    result.ssl_tunnel = null;
    result.event_stream = null;
    result.write_mutex = .{};
    result.seq = 0;
    result.session_id = null;

    try result.reconnect();
    errdefer result.disconnect();

    result.heartbeat = try Heartbeat.init(result, args.heartbeat);
    errdefer result.heartbeat.deinit();

    return result;
}

pub fn destroy(self: *Gateway) void {
    if (self.ssl_tunnel) |ssl_tunnel| {
        ssl_tunnel.destroy();
    }
    self.heartbeat.deinit();
    self.allocator.destroy(self);
}

fn fetchGatewayHost(temp_allocator: std.mem.Allocator, client: Client, buffer: []u8) ![]const u8 {
    var req = try client.sendRequest(temp_allocator, .GET, "/api/v10/gateway/bot", null);
    defer req.deinit();

    switch (req.response_code.?) {
        .success_ok => {},
        .client_unauthorized => return error.AuthenticationFailed,
        else => {
            log.warn("Unknown response code: {}", .{req.response_code.?});
            return error.UnknownGatewayResponse;
        },
    }

    try req.completeHeaders();

    var stream = zasp.json.stream(req.client.reader());

    const root = try stream.root();
    const match = (try root.objectMatchOne("url")) orelse return error.UnknownGatewayResponse;
    const url = try match.value.stringBuffer(buffer);
    if (std.mem.startsWith(u8, url, "wss://")) {
        return url["wss://".len..];
    } else {
        log.warn("Unknown url: {s}", .{url});
        return error.UnknownGatewayResponse;
    }
}

fn connect(self: *Gateway) !void {
    std.debug.assert(self.ssl_tunnel == null);

    var buf: [0x100]u8 = undefined;
    const host = try fetchGatewayHost(self.allocator, self.client, &buf);

    self.ssl_tunnel = try https.Tunnel.create(.{
        .allocator = self.allocator,
        .host = host,
    });
    errdefer self.disconnect();

    const reader = self.ssl_tunnel.?.client.reader();
    const writer = self.ssl_tunnel.?.client.writer();

    // Handshake
    var handshake = WzClient.handshake(&self.wz_buffer, reader, writer, std.crypto.random);
    try handshake.writeStatusLine("/?v=10&encoding=json");
    try handshake.writeHeaderValue("Host", host);
    try handshake.finishHeaders();

    if (!try handshake.wait()) {
        return error.HandshakeError;
    }

    self.wz = handshake.socket();

    if (try self.wz.next()) |event| {
        std.debug.assert(event == .header);
    }

    var flush_error: WzClient.ReadNextError!void = {};
    {
        var stream = zasp.json.stream(self.wz.reader());
        defer self.wz.flushReader() catch |err| {
            flush_error = err;
        };
        errdefer |err| log.info("{}", .{stream.debugInfo()});

        const root = try stream.root();
        const paths = try root.pathMatch(struct {
            op: u8,
            @"d.heartbeat_interval": u32,
        });

        if (paths.op != @enumToInt(discord.Gateway.Opcode.hello)) {
            return error.MalformedHelloResponse;
        }

        self.heartbeat_interval_ms = paths.@"d.heartbeat_interval";
    }
    try flush_error;

    if (self.session_id) |session_id| {
        try self.sendCommand(.{ .@"resume" = .{
            .token = self.client.auth_token,
            .seq = self.seq,
            .session_id = session_id.constSlice(),
        } });
        return;
    }

    try self.sendCommand(.{ .identify = .{
        .compress = false,
        .intents = self.intents,
        .token = self.client.auth_token,
        .properties = .{
            .@"$os" = @tagName(builtin.target.os.tag),
            .@"$browser" = self.client.user_agent,
            .@"$device" = self.client.user_agent,
        },
        .presence = self.presence,
    } });

    if (try self.wz.next()) |event| {
        if (event.header.opcode == .close) {
            try self.processCloseEvent();
        }
    }

    {
        var stream = zasp.json.stream(self.wz.reader());
        defer self.wz.flushReader() catch |err| {
            flush_error = err;
        };
        errdefer |err| log.info("{}", .{stream.debugInfo()});

        const root = try stream.root();
        // TODO: possibly "rewind" this to allow data reconsumption
        const paths = try root.pathMatch(struct {
            t: std.BoundedArray(u8, 0x100),
            s: ?u32,
            op: u8,
            @"d.session_id": std.BoundedArray(u8, 0x100),
            @"d.user.username": std.BoundedArray(u8, 0x100),
            @"d.user.discriminator": std.BoundedArray(u8, 0x100),
        });

        if (!std.mem.eql(u8, paths.t.constSlice(), "READY")) {
            return error.MalformedIdentify;
        }
        if (paths.op != @enumToInt(discord.Gateway.Opcode.dispatch)) {
            return error.MalformedIdentify;
        }

        if (paths.s) |seq| {
            self.seq = seq;
        }

        self.session_id = paths.@"d.session_id";

        log.info("Connected -- {s}#{s}", .{
            paths.@"d.user.username".constSlice(),
            paths.@"d.user.discriminator".constSlice(),
        });
    }
    try flush_error;
}

fn disconnect(self: *Gateway) void {
    if (self.ssl_tunnel) |ssl_tunnel| {
        ssl_tunnel.destroy();
        self.ssl_tunnel = null;
    }
}

pub fn reconnect(self: *Gateway) !void {
    var reconnect_wait: u64 = 1;
    while (true) {
        return self.connect() catch |err| switch (err) {
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
    }
}

fn processCloseEvent(self: *Gateway) !void {
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

pub const Event = struct {
    gateway: *Gateway,
    name: discord.Gateway.EventName,
    data: JsonElement,

    pub fn deinit(event: Event) void {
        event.gateway.event_stream = null;
    }
};

pub fn recvEvent(self: *Gateway) !Event {
    std.debug.assert(self.event_stream == null); // Can only recv one event at a time
    errdefer self.event_stream = null;

    while (true) {
        if (self.ssl_tunnel == null) {
            try self.reconnect();
            self.heartbeat.send(.start);
        }

        return self.recvEventNoReconnect() catch |err| switch (err) {
            error.ConnectionReset => {
                self.disconnect();
                continue;
            },
            error.InvalidSession => {
                self.disconnect();
                self.seq = 0;
                self.session_id = null;
                continue;
            },
            else => {
                log.warn("Unexpected error: {}", .{err});
                self.disconnect();
                continue;
            },
        };
    }
}

fn recvEventNoReconnect(self: *Gateway) !Event {
    while (true) {
        try self.wz.flushReader();
        const event = self.wz.next() catch |err| switch (err) {
            error.EndOfStream => return error.ConnectionReset,
            else => |e| return e,
        };

        switch (event.?.header.opcode) {
            .text => {
                const gateway_event = self.processEvent(self.wz.reader()) catch |err| switch (err) {
                    error.ConnectionReset, error.InvalidSession => |e| return e,
                    else => {
                        log.warn("Process chunks failed: {s}", .{err});
                        continue;
                    },
                };
                return gateway_event orelse continue;
            },
            .ping, .pong => {},
            .close => try self.processCloseEvent(),
            .binary => return error.WtfBinary,
            else => return error.WtfWtf,
        }
    }
}

fn processEvent(self: *Gateway, reader: anytype) !?Event {
    self.event_stream = zasp.json.stream(reader);
    errdefer |err| {
        if (util.errSetContains(@TypeOf(self.event_stream.?).ParseError, err)) {
            log.warn("{}", .{self.event_stream.?.debugInfo()});
        }
    }

    var name: ?discord.Gateway.EventName = null;
    var op: ?discord.Gateway.Opcode = null;

    const root = try self.event_stream.?.root();

    while (try root.objectMatch(enum { t, s, op, d })) |match| switch (match.key) {
        .t => {
            var buf: [32]u8 = undefined;
            if (try match.value.optionalStringBuffer(&buf)) |raw| {
                name = discord.Gateway.EventName.parse(raw);
            }
        },
        .s => {
            if (try match.value.optionalNumber(u32)) |seq| {
                self.seq = seq;
            }
        },
        .op => {
            op = try std.meta.intToEnum(discord.Gateway.Opcode, try match.value.number(u8));
        },
        .d => {
            switch (op orelse return error.DataBeforeOp) {
                .dispatch => {
                    return Event{
                        .gateway = self,
                        .name = name orelse return error.DispatchWithoutName,
                        .data = match.value,
                    };
                },
                .heartbeat_ack => {
                    self.heartbeat.send(.ack);
                    _ = try match.value.finalizeToken();
                },
                .reconnect => {
                    log.info("Discord reconnect. Reconnecting...", .{});
                    return error.ConnectionReset;
                },
                .invalid_session => {
                    log.info("Discord invalid session. Reconnecting...", .{});
                    const resumable = match.value.boolean() catch false;
                    if (resumable) {
                        return error.ConnectionReset;
                    } else {
                        return error.InvalidSession;
                    }
                },
                else => {
                    log.info("Unhandled {} -- {s}", .{ op, name });
                    match.value.debugDump(std.io.getStdErr().writer()) catch {};
                },
            }
        },
    };

    return null;
}

pub fn sendCommand(self: *Gateway, command: discord.Gateway.Command) !void {
    if (self.ssl_tunnel == null) return error.NotConnected;

    var buf: [0x1000]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "{s}", .{zasp.json.format(command)});

    self.write_mutex.lock();
    defer self.write_mutex.unlock();

    try self.wz.writeHeader(.{ .opcode = .text, .length = msg.len });
    try self.wz.writeChunk(msg);
}

test {
    std.testing.refAllDecls(@This());
}
