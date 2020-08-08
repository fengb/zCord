const std = @import("std");
const hzzp = @import("hzzp");
const wz = @import("wz");
const ssl = @import("zig-bearssl");

const util = @import("util.zig");

const agent = "zigbot9001/0.0.1";

const SslTunnel = struct {
    allocator: *std.mem.Allocator,

    trust_anchor: ssl.TrustAnchorCollection,
    x509: ssl.x509.Minimal,
    client: ssl.Client,

    raw_conn: std.fs.File,
    raw_reader: std.fs.File.Reader,
    raw_writer: std.fs.File.Writer,

    conn: ssl.Stream(*std.fs.File.Reader, *std.fs.File.Writer),

    fn init(args: struct {
        allocator: *std.mem.Allocator,
        pem: []const u8,
        host: [:0]const u8,
        port: u16 = 443,
    }) !*SslTunnel {
        const result = try args.allocator.create(SslTunnel);
        errdefer args.allocator.destroy(result);

        result.allocator = args.allocator;

        result.trust_anchor = ssl.TrustAnchorCollection.init(args.allocator);
        errdefer result.trust_anchor.deinit();
        try result.trust_anchor.appendFromPEM(args.pem);

        result.x509 = ssl.x509.Minimal.init(result.trust_anchor);
        result.client = ssl.Client.init(result.x509.getEngine());
        result.client.relocate();
        try result.client.reset(args.host, false);

        result.raw_conn = try std.net.tcpConnectToHost(args.allocator, args.host, args.port);
        errdefer result.raw_conn.close();

        result.raw_reader = result.raw_conn.reader();
        result.raw_writer = result.raw_conn.writer();

        result.conn = ssl.initStream(result.client.getEngine(), &result.raw_reader, &result.raw_writer);

        return result;
    }

    fn deinit(self: *SslTunnel) void {
        self.conn.close() catch {};
        self.raw_conn.close();
        self.trust_anchor.deinit();

        self.* = undefined;
        errdefer self.allocator.destroy(self);
    }
};

pub fn requestGithubIssue(issue: u32) !void {
    var ssl_tunnel = try SslTunnel.init(.{
        .allocator = std.heap.c_allocator,
        .pem = @embedFile("../github-com-chain.pem"),
        .host = "api.github.com",
    });
    errdefer ssl_tunnel.deinit();

    var buf: [0x1000]u8 = undefined;
    var client = hzzp.BaseClient.create(&buf, ssl_tunnel.conn.inStream(), ssl_tunnel.conn.outStream());

    var path: [0x100]u8 = undefined;
    try client.writeHead("GET", try std.fmt.bufPrint(&path, "/repos/ziglang/zig/issues/{}", .{issue}));

    try client.writeHeader("Host", "api.github.com");
    try client.writeHeader("User-Agent", agent);
    try client.writeHeader("Accept", "application/json");
    try client.writeHeadComplete();
    try ssl_tunnel.conn.flush();

    if (try client.readEvent()) |event| {
        if (event != .status) {
            return error.MissingStatus;
        }
        switch (event.status.code) {
            200 => {}, // success!
            404 => return error.NotFound,
            else => @panic("Response not expected"),
        }
    } else {
        return error.NoResponse;
    }

    // Skip headers
    while (try client.readEvent()) |event| {
        if (event == .head_complete) {
            break;
        }
    }

    var reader = hzzpChunkReader(client);
    var tmp: [0x1000]u8 = undefined;
    while (try reader.reader().readUntilDelimiterOrEof(&tmp, ',')) |line| {
        std.debug.print("{}\n", .{line});
    }
}

fn hzzpChunkReader(client: anytype) HzzpChunkReader(@TypeOf(client)) {
    return .{ .client = client };
}

fn HzzpChunkReader(comptime Client: type) type {
    return struct {
        const Self = @This();
        const Reader = std.io.Reader(*Self, Client.ReadError, readFn);

        client: Client,
        complete: bool = false,
        chunk: ?hzzp.BaseClient.Chunk = null,
        loc: usize = undefined,

        fn readFn(self: *Self, buffer: []u8) Client.ReadError!usize {
            if (self.complete) return 0;

            if (self.chunk) |chunk| {
                const remaining = chunk.data[self.loc..];
                if (buffer.len < remaining.len) {
                    std.mem.copy(u8, buffer, remaining[0..buffer.len]);
                    self.loc += buffer.len;
                    return buffer.len;
                } else {
                    std.mem.copy(u8, buffer, remaining);
                    if (chunk.final) {
                        self.complete = true;
                    }
                    self.chunk = null;
                    return remaining.len;
                }
            } else {
                const event = (try self.client.readEvent()) orelse {
                    self.complete = true;
                    return 0;
                };

                if (event != .chunk) {
                    self.complete = true;
                    return 0;
                }

                if (buffer.len < event.chunk.data.len) {
                    std.mem.copy(u8, buffer, event.chunk.data[0..buffer.len]);
                    self.chunk = event.chunk;
                    self.loc = buffer.len;
                    return buffer.len;
                } else {
                    std.mem.copy(u8, buffer, event.chunk.data);
                    if (event.chunk.final) {
                        self.complete = true;
                    }
                    return event.chunk.data.len;
                }
            }
        }

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }
    };
}

pub fn main() !void {
    // try requestGithubIssue(5076);
    var discord_ws = try DiscordWs.init(
        std.heap.c_allocator,
        std.os.getenv("AUTH") orelse return error.AuthNotFound,
    );

    try discord_ws.run({}, struct {
        fn handleDispatch(ctx: void, name: []const u8, data: anytype) !void {
            std.debug.print(">> {}\n", .{name});
            if (!std.mem.eql(u8, name, "MESSAGE_CREATED")) return;

            var channel_id = [_]u8{0} ** 32;
            var issue_buffer = [_]u8{0} ** 10;
            while (try data.objectMatchAny(&[_][]const u8{ "content", "channel_id" })) |match| {
                const swh = util.Swhash(16);
                switch (swh.match(match.key)) {
                    swh.case("content") => {
                        _ = try match.value.finalizeToken();
                    },
                    swh.case("channel_id") => {
                        _ = try match.value.stringBuffer(&channel_id);
                    },
                    else => unreachable,
                }
            }
        }
    });
    std.debug.print("Terminus\n\n", .{});
}

const DiscordWs = struct {
    allocator: *std.mem.Allocator,

    ssl_tunnel: *SslTunnel,

    client: wz.BaseClient.BaseClient(SslStream.DstInStream, SslStream.DstOutStream),
    client_buffer: []u8,
    write_mutex: std.Mutex,

    heartbeat_interval: usize,
    heartbeat_seq: ?usize,
    heartbeat_thread: *std.Thread,

    const SslStream = std.meta.fieldInfo(SslTunnel, "conn").field_type;

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

    pub fn init(allocator: *std.mem.Allocator, auth_token: []const u8) !*DiscordWs {
        const result = try allocator.create(DiscordWs);
        errdefer allocator.destroy(result);
        result.allocator = allocator;

        result.write_mutex = std.Mutex.init();
        errdefer result.write_mutex.deinit();

        result.ssl_tunnel = try SslTunnel.init(.{
            .allocator = allocator,
            .pem = @embedFile("../discord-gg-chain.pem"),
            .host = "gateway.discord.gg",
        });
        errdefer result.ssl_tunnel.deinit();

        result.client_buffer = try allocator.alloc(u8, 0x1000);
        errdefer allocator.free(result.client_buffer);

        result.client = wz.BaseClient.create(
            result.client_buffer,
            result.ssl_tunnel.conn.inStream(),
            result.ssl_tunnel.conn.outStream(),
        );

        // Handshake
        var handshake_headers = std.http.Headers.init(allocator);
        defer handshake_headers.deinit();
        try handshake_headers.append("Host", "gateway.discord.gg", null);
        try result.client.sendHandshake(&handshake_headers, "/?v=6&encoding=json");
        try result.ssl_tunnel.conn.flush();
        try result.client.waitForHandshake();

        if (try result.client.readEvent()) |event| {
            std.debug.assert(event == .header);
        }

        result.heartbeat_interval = 0;
        if (try result.client.readEvent()) |event| {
            std.debug.assert(event == .chunk);

            var fba = std.io.fixedBufferStream(event.chunk.data);
            var stream = util.streamJson(fba.reader());

            const root = try stream.root();
            while (try root.objectMatchAny(&[_][]const u8{ "op", "d" })) |match| {
                const swh = util.Swhash(2);
                switch (swh.match(match.key)) {
                    swh.case("op") => {
                        const op = try std.meta.intToEnum(Opcode, try match.value.number(u8));
                        if (op != .hello) {
                            return error.MalformedHelloResponse;
                        }
                    },
                    swh.case("d") => {
                        while (try match.value.objectMatch("heartbeat_interval")) |hbi| {
                            result.heartbeat_interval = try hbi.value.number(u32);
                        }
                    },
                    else => unreachable,
                }
            }
        }

        if (result.heartbeat_interval == 0) {
            return error.MalformedHelloResponse;
        }

        // Identify
        try result.printMessage(
            \\ {{
            \\   "op": 2,
            \\   "d": {{
            \\     "compress": "false",
            \\     "token": "Bot {0}",
            \\     "properties": {{
            \\       "$os": "{1}",
            \\       "$browser": "{2}",
            \\       "$device": "{2}"
            \\     }}
            \\   }}
            \\ }}
        ,
            .{
                auth_token,
                @tagName(std.Target.current.os.tag),
                agent,
            },
        );

        result.heartbeat_seq = null;
        result.heartbeat_thread = try std.Thread.spawn(result, heartbeatHandler);

        return result;
    }

    pub fn deinit(self: *DiscordWs) void {
        self.ssl_tunnel.deinit();
        self.client.close();
        self.* = undefined;
        self.allocator.destroy(self);
    }

    pub fn run(self: *DiscordWs, ctx: anytype, handler: anytype) !void {
        while (try self.client.readEvent()) |event| {
            if (event != .chunk) continue;

            var name_buf: [32]u8 = undefined;
            var name: ?[]u8 = null;
            var op: ?Opcode = null;

            var fba = std.io.fixedBufferStream(event.chunk.data);
            var stream = util.streamJson(fba.reader());
            const root = try stream.root();

            while (try root.objectMatchAny(&[_][]const u8{ "t", "s", "op", "d" })) |match| {
                const swh = util.Swhash(2);
                switch (swh.match(match.key)) {
                    swh.case("t") => {
                        name = try match.value.optionalStringBuffer(&name_buf);
                    },
                    swh.case("s") => {
                        if (try match.value.optionalNumber(u32)) |seq| {
                            self.heartbeat_seq = seq;
                            std.debug.print("seq = {}\n", .{self.heartbeat_seq});
                        }
                    },
                    swh.case("op") => {
                        op = try std.meta.intToEnum(Opcode, try match.value.number(u8));
                    },
                    swh.case("d") => {
                        switch (op orelse return error.DataBeforeOp) {
                            .dispatch => {
                                try handler.handleDispatch(
                                    ctx,
                                    name orelse return error.DispatchWithoutName,
                                    match.value,
                                );
                            },
                            else => {
                                _ = try match.value.finalizeToken();
                            },
                        }
                    },
                    else => unreachable,
                }
            }
        }
    }

    pub fn printMessage(self: *DiscordWs, comptime fmt: []const u8, args: anytype) !void {
        var buf: [0x1000]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, fmt, args);

        const held = self.write_mutex.acquire();
        defer held.release();

        try self.client.writeMessageHeader(.{ .length = msg.len, .opcode = 1 });

        var masked = std.mem.zeroes([0x1000]u8);
        self.client.maskPayload(msg, &masked);
        try self.client.writeMessagePayload(masked[0..msg.len]);

        try self.ssl_tunnel.conn.flush();
    }

    fn heartbeatHandler(self: *DiscordWs) !void {
        while (true) {
            std.time.sleep(self.heartbeat_interval * 1_000_000);

            try self.printMessage(
                \\ {{
                \\   "op": 1,
                \\   "d": {}
                \\ }}
            , .{self.heartbeat_seq});
        }
    }
};
