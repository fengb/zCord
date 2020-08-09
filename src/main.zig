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
        self.allocator.destroy(self);
    }
};

pub fn sendDiscordMessage(channel_id: u64, issue: u32, message: []const u8) !void {
    var ssl_tunnel = try SslTunnel.init(.{
        .allocator = std.heap.c_allocator,
        .pem = @embedFile("../discord-com-chain.pem"),
        .host = "discord.com",
    });
    defer ssl_tunnel.deinit();

    var buf: [0x1000]u8 = undefined;
    var client = hzzp.BaseClient.create(&buf, ssl_tunnel.conn.inStream(), ssl_tunnel.conn.outStream());

    var path: [0x100]u8 = undefined;
    try client.writeHead("POST", try std.fmt.bufPrint(&path, "/api/v6/channels/{}/messages", .{channel_id}));

    try client.writeHeader("Host", "discord.com");
    try client.writeHeader("User-Agent", agent);
    try client.writeHeader("Accept", "application/json");
    try client.writeHeader("Content-Type", "application/json");

    var auth_buf: [0x100]u8 = undefined;
    try client.writeHeader(
        "Authorization",
        try std.fmt.bufPrint(&auth_buf, "Bot {}", .{std.os.getenv("AUTH") orelse @panic("How did we get here?")}),
    );

    var data_buf: [0x10000]u8 = undefined;
    const data = try std.fmt.bufPrint(
        &data_buf,
        \\{{
        \\  "content": "",
        \\  "tts": false,
        \\  "embed": {{
        \\    "title": "Issue {0} -- {1}",
        \\    "description": "https://github.com/ziglang/zig/issues/{0}"
        \\  }}
        \\}}
    ,
        .{ issue, message },
    );
    try client.writeHeader("Content-Length", try std.fmt.bufPrint(&auth_buf, "{}", .{data.len}));
    try client.writeHeadComplete();

    try client.writeChunk(data);
    try ssl_tunnel.conn.flush();

    if (try client.readEvent()) |event| {
        if (event != .status) {
            return error.MissingStatus;
        }
        switch (event.status.code) {
            200 => {}, // success!
            404 => return error.NotFound,
            else => std.debug.panic("Response not expected: {}", .{event.status.code}),
        }
    } else {
        return error.NoResponse;
    }

    if (true) {
        // Quit immediately because bearssl cleanup fails
        std.debug.print("cid {} <- %%{}\n", .{ channel_id, issue });
        std.os.exit(0);
    }

    while (try client.readEvent()) |_| {}
}

pub fn requestGithubIssue(channel_id: u64, issue: u32) !void {
    var ssl_tunnel = try SslTunnel.init(.{
        .allocator = std.heap.c_allocator,
        .pem = @embedFile("../github-com-chain.pem"),
        .host = "api.github.com",
    });
    defer ssl_tunnel.deinit();

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
    var stream = util.streamJson(reader.reader());
    const root = try stream.root();

    while (try root.objectMatch("title")) |match| {
        var buffer: [0x1000]u8 = undefined;
        const title = try match.value.stringBuffer(&buffer);
        try sendDiscordMessage(channel_id, issue, title);
        return;
    }

    return error.TitleNotFound;
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
            if (!std.mem.eql(u8, name, "MESSAGE_CREATE")) return;

            var issue: ?u32 = null;
            var channel_id: ?u64 = null;

            while (try data.objectMatchAny(&[_][]const u8{ "content", "channel_id" })) |match| {
                const swh = util.Swhash(16);
                switch (swh.match(match.key)) {
                    swh.case("content") => {
                        var buf: [0x10000]u8 = undefined;
                        issue = findIssue(try match.value.stringBuffer(&buf));
                    },
                    swh.case("channel_id") => {
                        var buf: [0x100]u8 = undefined;
                        const channel_string = try match.value.stringBuffer(&buf);
                        channel_id = try std.fmt.parseInt(u64, channel_string, 10);
                    },
                    else => unreachable,
                }
            }

            if (issue != null and channel_id != null) {
                const child_pid = try std.os.fork();
                if (child_pid == 0) {
                    try requestGithubIssue(channel_id.?, issue.?);
                } else {
                    // Not a child. Go back to listening.
                }
            }
        }

        fn findIssue(string: []const u8) ?u32 {
            const State = enum {
                no_match,
                percent,
                ready,
            };
            var state = State.no_match;
            var buffer: [0x100]u8 = undefined;
            var tail: usize = 0;

            for (string) |c| {
                switch (state) {
                    .no_match => {
                        if (c == '%') {
                            state = .percent;
                        }
                    },
                    .percent => {
                        state = if (c == '%') .ready else .no_match;
                    },
                    .ready => {
                        if (c >= '0' and c <= '9') {
                            buffer[tail] = c;
                            tail += 1;
                            continue;
                        }

                        if (std.mem.indexOfScalar(u8, " ,\n\t", c) != null) {
                            if (std.fmt.parseInt(u32, buffer[0..tail], 10)) |val| {
                                return val;
                            } else |err| {}
                        }

                        state = .no_match;
                        tail = 0;
                    },
                }
            }

            return std.fmt.parseInt(u32, buffer[0..tail], 10) catch null;
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

        result.write_mutex = .{};

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
            // Skip over any remaining chunks. The processor didn't take care of it.
            if (event != .header) continue;

            self.processChunks(ctx, handler) catch |err| {
                std.debug.print("{}\n", .{err});
            };
        }
    }
    pub fn processChunks(self: *DiscordWs, ctx: anytype, handler: anytype) !void {
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
