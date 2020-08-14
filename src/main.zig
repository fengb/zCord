const std = @import("std");
const hzzp = @import("hzzp");
const wz = @import("wz");
const ssl = @import("zig-bearssl");

const request = @import("request.zig");
const util = @import("util.zig");

const agent = "zigbot9001/0.0.1";

fn Buffer(comptime max_len: usize) type {
    return struct {
        data: [max_len]u8 = undefined,
        len: usize = 0,

        fn slice(self: @This()) []const u8 {
            return self.data[0..self.len];
        }
    };
}

const Context = struct {
    allocator: *std.mem.Allocator,
    auth_token: []const u8,

    pub fn sendDiscordMessage(self: Context, channel_id: u64, issue: GithubIssue) !void {
        var path: [0x100]u8 = undefined;
        var req = try request.Https.init(.{
            .allocator = self.allocator,
            .pem = @embedFile("../discord-com-chain.pem"),
            .host = "discord.com",
            .method = "POST",
            .path = try std.fmt.bufPrint(&path, "/api/v6/channels/{}/messages", .{channel_id}),
        });
        defer req.deinit();

        try req.client.writeHeader("Accept", "application/json");
        try req.client.writeHeader("Content-Type", "application/json");
        try req.client.writeHeader("Authorization", self.auth_token);

        const label = if (std.mem.indexOf(u8, issue.url.slice(), "/pull/")) |_|
            "Pull"
        else
            "Issue";

        try req.printSend(
            \\{{
            \\  "content": "",
            \\  "tts": false,
            \\  "embed": {{
            \\    "title": "{0} #{1} — {2}",
            \\    "description": "{3}"
            \\  }}
            \\}}
        ,
            .{
                label,
                issue.number,
                issue.title.slice(),
                issue.url.slice(),
            },
        );

        _ = try req.expectSuccessStatus();

        if (true) {
            // Quit immediately because bearssl cleanup fails
            std.debug.print("cid {} <- %%{}\n", .{ channel_id, issue });
            std.os.exit(0);
        }

        while (try client.readEvent()) |_| {}
    }

    const GithubIssue = struct { number: u32, title: Buffer(0x100), url: Buffer(0x100) };
    pub fn requestGithubIssue(self: Context, issue: u32) !GithubIssue {
        var path: [0x100]u8 = undefined;
        var req = try request.Https.init(.{
            .allocator = self.allocator,
            .pem = @embedFile("../github-com-chain.pem"),
            .host = "api.github.com",
            .method = "GET",
            .path = try std.fmt.bufPrint(&path, "/repos/ziglang/zig/issues/{}", .{issue}),
        });
        // TODO: fix resource deinit
        // defer req.deinit();

        try req.client.writeHeader("Accept", "application/json");
        try req.client.writeHeadComplete();
        try req.ssl_tunnel.conn.flush();

        _ = try req.expectSuccessStatus();
        try req.completeHeaders();
        var body = req.body();
        var stream = util.streamJson(body.reader());
        const root = try stream.root();

        var result = GithubIssue{ .number = issue, .title = .{}, .url = .{} };
        while (try root.objectMatchAny(&[_][]const u8{ "title", "html_url" })) |match| {
            const swh = util.Swhash(16);
            switch (swh.match(match.key)) {
                swh.case("html_url") => {
                    const slice = try match.value.stringBuffer(&result.url.data);
                    result.url.len = slice.len;
                },
                swh.case("title") => {
                    const slice = try match.value.stringBuffer(&result.title.data);
                    result.title.len = slice.len;
                },
                else => unreachable,
            }

            if (result.title.len > 0 and result.url.len > 0) {
                return result;
            }
        }

        return error.FieldNotFound;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var auth_buf: [0x100]u8 = undefined;
    const context = Context{
        .allocator = &gpa.allocator,
        .auth_token = try std.fmt.bufPrint(&auth_buf, "Bot {}", .{std.os.getenv("AUTH") orelse return error.AuthNotFound}),
    };

    var discord_ws = try DiscordWs.init(
        context.allocator,
        context.auth_token,
    );

    try discord_ws.run(context, struct {
        fn handleDispatch(ctx: Context, name: []const u8, data: anytype) !void {
            std.debug.print(">> {}\n", .{name});
            if (!std.mem.eql(u8, name, "MESSAGE_CREATE")) return;

            var ask: Buffer(0x100) = .{};
            var channel_id: ?u64 = null;

            while (try data.objectMatchAny(&[_][]const u8{ "content", "channel_id" })) |match| {
                const swh = util.Swhash(16);
                switch (swh.match(match.key)) {
                    swh.case("content") => {
                        var buf: [0x10000]u8 = undefined;
                        ask = findAsk(try match.value.stringBuffer(&buf));
                    },
                    swh.case("channel_id") => {
                        var buf: [0x100]u8 = undefined;
                        const channel_string = try match.value.stringBuffer(&buf);
                        channel_id = try std.fmt.parseInt(u64, channel_string, 10);
                    },
                    else => unreachable,
                }
            }

            if (ask.len > 0 and channel_id != null) {
                const child_pid = try std.os.fork();
                if (child_pid == 0) {
                    if (std.fmt.parseInt(u32, ask.slice(), 10)) |issue| {
                        const gh_issue = try ctx.requestGithubIssue(issue);
                        try ctx.sendDiscordMessage(channel_id.?, gh_issue);
                    } else |err| {
                        std.debug.print("{}\n", .{ask.slice()});
                    }
                } else {
                    // Not a child. Go back to listening.
                }
            }
        }

        fn findAsk(string: []const u8) Buffer(0x100) {
            const State = enum {
                no_match,
                percent,
                ready,
            };
            var state = State.no_match;
            var buffer: Buffer(0x100) = .{};

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
                        switch (c) {
                            ' ', ',', '\n', '\t' => return buffer,
                            else => {
                                buffer.data[buffer.len] = c;
                                buffer.len += 1;
                            },
                        }
                    },
                }
            }

            return buffer;
        }
    });
    std.debug.print("Terminus\n\n", .{});
}

const DiscordWs = struct {
    allocator: *std.mem.Allocator,

    ssl_tunnel: *request.SslTunnel,

    client: wz.BaseClient.BaseClient(request.SslTunnel.Stream.DstInStream, request.SslTunnel.Stream.DstOutStream),
    client_buffer: []u8,
    write_mutex: std.Mutex,

    heartbeat_interval: usize,
    heartbeat_seq: ?usize,
    heartbeat_thread: *std.Thread,

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

        result.ssl_tunnel = try request.SslTunnel.init(.{
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
            \\     "token": "{0}",
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
