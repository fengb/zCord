const std = @import("std");
const hzzp = @import("hzzp");
const wz = @import("wz");
const ssl = @import("zig-bearssl");
const analBuddy = @import("analysis-buddy");

const format = @import("format.zig");
const request = @import("request.zig");
const util = @import("util.zig");

const agent = "zigbot9001/0.0.1";

const auto_restart = true;
//const auto_restart = std.builtin.mode == .Debug;

pub usingnamespace if (auto_restart) RestartHandler else struct {};

const RestartHandler = struct {
    pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace) noreturn {
        std.debug.print("PANIC -- {s}\n", .{msg});

        if (error_return_trace) |t| {
            std.debug.dumpStackTrace(t.*);
        }

        std.debug.dumpCurrentStackTrace(@returnAddress());

        const err = std.os.execveZ(
            std.os.argv[0],
            @ptrCast([*:null]?[*:0]u8, std.os.argv.ptr),
            @ptrCast([*:null]?[*:0]u8, std.os.environ.ptr),
        );

        std.debug.print("{s}\n", .{@errorName(err)});
        std.os.exit(42);
    }
};

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

const Context = struct {
    allocator: *std.mem.Allocator,
    auth_token: []const u8,
    github_auth_token: ?[]const u8,
    prng: std.rand.DefaultPrng,
    prepared_anal: analBuddy.PrepareResult,

    timer: std.time.Timer,

    ask_mailbox: util.Mailbox(AskData),
    ask_thread: *std.Thread,

    // TODO move this to instance variable somehow?
    var awaiting_enema = false;

    const AskData = struct { ask: Buffer(0x1000), channel_id: u64 };

    pub fn init(allocator: *std.mem.Allocator, auth_token: []const u8, ziglib: []const u8, github_auth_token: ?[]const u8) !*Context {
        const result = try allocator.create(Context);
        errdefer allocator.destroy(result);

        result.allocator = allocator;
        result.auth_token = auth_token;
        result.github_auth_token = github_auth_token;
        result.prng = std.rand.DefaultPrng.init(@bitCast(u64, std.time.timestamp()));
        result.prepared_anal = try analBuddy.prepare(allocator, ziglib);
        errdefer analBuddy.dispose(&result.prepared_anal);

        result.timer = try std.time.Timer.start();

        result.ask_mailbox = util.Mailbox(AskData).init();
        result.ask_thread = try std.Thread.spawn(result, askHandler);

        std.os.sigaction(
            std.os.SIGWINCH,
            &std.os.Sigaction{
                .handler = .{
                    .handler = winchHandler,
                },
                .mask = std.os.empty_sigset,
                .flags = 0,
            },
            null,
        );

        return result;
    }

    fn winchHandler(signum: c_int) callconv(.C) void {
        awaiting_enema = true;
    }

    pub fn askHandler(self: *Context) void {
        while (true) {
            const mailbox = self.ask_mailbox.get();
            self.askOne(mailbox.channel_id, mailbox.ask.slice()) catch |err| {
                std.debug.print("{s}\n", .{err});
            };
        }
    }

    pub fn askOne(self: *Context, channel_id: u64, ask: []const u8) !void {
        const swh = util.Swhash(16);
        switch (swh.match(ask)) {
            swh.case("ping") => {
                _ = try self.sendDiscordMessage(.{
                    .channel_id = channel_id,
                    .title = "pong",
                    .description = &.{
                        \\```
                        \\          ,;;;!!!!!;;.
                        \\        :!!!!!!!!!!!!!!;
                        \\      :!!!!!!!!!!!!!!!!!;
                        \\     ;!!!!!!!!!!!!!!!!!!!;
                        \\    ;!!!!!!!!!!!!!!!!!!!!!
                        \\    ;!!!!!!!!!!!!!!!!!!!!'
                        \\    ;!!!!!!!!!!!!!!!!!!!'
                        \\     :!!!!!!!!!!!!!!!!'
                        \\      ,!!!!!!!!!!!!!''
                        \\   ,;!!!''''''''''
                        \\ .!!!!'
                        \\!!!!`
                        \\```
                    },
                });
                return;
            },
            swh.case("status") => {
                const rusage = std.os.getrusage(std.os.RUSAGE_SELF);
                const cpu_sec = (rusage.utime.tv_sec + rusage.stime.tv_sec) * 1000;
                const cpu_us = @divFloor(rusage.utime.tv_usec + rusage.stime.tv_usec, 1000);

                var buf: [0x1000]u8 = undefined;
                _ = try self.sendDiscordMessage(.{
                    .channel_id = channel_id,
                    .title = "",
                    .description = &.{
                        std.fmt.bufPrint(
                            &buf,
                            \\```
                            \\Uptime:    {s}
                            \\CPU time:  {s}
                            \\Max RSS:      {Bi:.3}
                            \\```
                        ,
                            .{
                                format.time(@intCast(i64, self.timer.read() / std.time.ns_per_ms)),
                                format.time(cpu_sec + cpu_us),
                                @intCast(u64, rusage.maxrss),
                            },
                        ) catch unreachable,
                    },
                });
                return;
            },
            swh.case("zen") => {
                _ = try self.sendDiscordMessage(.{
                    .channel_id = channel_id,
                    .title = "For Great Justice",
                    .description = &.{
                        \\```
                        \\* Communicate intent precisely.
                        \\* Edge cases matter.
                        \\* Favor reading code over writing code.
                        \\* Only one obvious way to do things.
                        \\* Runtime crashes are better than bugs.
                        \\* Compile errors are better than runtime crashes.
                        \\* Incremental improvements.
                        \\* Avoid local maximums.
                        \\* Reduce the amount one must remember.
                        \\* Focus on code rather than style.
                        \\* Resource allocation may fail; resource deallocation must succeed.
                        \\* Memory is a resource.
                        \\* Together we serve the users.
                        \\```
                    },
                });
                return;
            },
            swh.case("zenlang"),
            swh.case("v"),
            swh.case("vlang"),
            => {
                _ = try self.sendDiscordMessage(.{
                    .channel_id = channel_id,
                    .title = "bruh",
                });
                return;
            },
            swh.case("u0") => {
                _ = try self.sendDiscordMessage(.{
                    .channel_id = channel_id,
                    .title = "Zig's billion dollar mistake™",
                    .description = &.{"https://github.com/ziglang/zig/issues/1530#issuecomment-422113755"},
                });
                return;
            },
            swh.case("tater") => {
                _ = try self.sendDiscordMessage(.{
                    .channel_id = channel_id,
                    .title = "",
                    .image = "https://memegenerator.net/img/instances/41913604.jpg",
                });
                return;
            },
            swh.case("5076"), swh.case("ziglang/zig#5076") => {
                _ = try self.sendDiscordMessage(.{
                    .channel_id = channel_id,
                    .color = .green,
                    .title = "ziglang/zig — issue #5076",
                    .description = &.{
                        \\~~[syntax: drop the `const` keyword in global scopes](https://github.com/ziglang/zig/issues/5076)~~
                        \\https://www.youtube.com/watch?v=880uR25pP5U
                    },
                });
                return;
            },
            swh.case("submodule"), swh.case("submodules") => {
                _ = try self.sendDiscordMessage(.{
                    .channel_id = channel_id,
                    .title = "git submodules are the devil — _andrewrk_",
                    .description = &.{"https://github.com/ziglang/zig-bootstrap/issues/17#issuecomment-609980730"},
                });
                return;
            },
            swh.case("2.718"), swh.case("2.71828") => {
                _ = try self.sendDiscordMessage(.{
                    .channel_id = channel_id,
                    .title = "",
                    .image = "https://camo.githubusercontent.com/7f0d955df2205a170bf1582105c319ec6b00ec5c/68747470733a2f2f692e696d67666c69702e636f6d2f34646d7978702e6a7067",
                });
                return;
            },
            swh.case("bruh") => {
                _ = try self.sendDiscordMessage(.{
                    .channel_id = channel_id,
                    .title = "",
                    .image = "https://user-images.githubusercontent.com/106511/86198112-6718ba00-bb46-11ea-92fd-d006b462c5b1.jpg",
                });
                return;
            },
            swh.case("dab") => {
                _ = try self.sendDiscordMessage(.{
                    .channel_id = channel_id,
                    .title = "I promised I would dab and say “bruh” — _andrewrk_",
                    .description = &.{"https://vimeo.com/492676992"},
                    .image = "https://i.vimeocdn.com/video/1018725604.jpg?mw=700&mh=1243&q=70",
                });
                return;
            },
            else => {},
        }

        if (std.mem.startsWith(u8, ask, "run")) {
            const msg_id = try self.sendDiscordMessage(.{
                .channel_id = channel_id,
                .title = "*Run pending...*",
                .description = &.{},
            });

            var buffer: [0x4000]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&buffer);
            const ran = try self.requestRun(
                &fba.allocator,
                try self.parseRun(ask),
            );

            const description_lines = &[_][]const u8{
                "**stdout**:\n```\n",
                ran.stderr,
                "```",
                "\n\n",
                "**stderr**:\n```\n",
                ran.stderr,
                "```",
            };

            const description = if (ran.stdout.len == 0)
                description_lines[4..7]
            else if (ran.stderr.len == 0)
                description_lines[0..3]
            else
                description_lines[0..];

            _ = try self.sendDiscordMessage(.{
                .channel_id = channel_id,
                .edit_msg_id = msg_id,
                .title = "Run Results",
                .description = description,
            });
            return;
        }

        if (try self.maybeGithubIssue(ask)) |issue| {
            const is_pull_request = std.mem.indexOf(u8, issue.url.slice(), "/pull/") != null;
            const label = if (is_pull_request) "pull" else "issue";

            var title_buf: [0x1000]u8 = undefined;
            const title = try std.fmt.bufPrint(&title_buf, "{s} — {s} #{d}", .{
                issue.repo.slice(),
                label,
                issue.number,
            });
            _ = try self.sendDiscordMessage(.{
                .channel_id = channel_id,
                .title = title,
                .description = &.{
                    "[",
                    issue.title.slice(),
                    "](",
                    issue.url.slice(),
                    ")",
                },
                .color = if (is_pull_request) HexColor.blue else HexColor.green,
            });
        } else {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            if (awaiting_enema) {
                try analBuddy.reloadCached(&arena, self.prepared_anal.store.allocator, &self.prepared_anal);
                awaiting_enema = false;
            }
            if (try analBuddy.analyse(&arena, &self.prepared_anal, ask)) |match| {
                _ = try self.sendDiscordMessage(.{
                    .channel_id = channel_id,
                    .title = ask,
                    .description = &.{std.mem.trim(u8, match, " \t\r\n")},
                    .color = .red,
                });
            } else {}
        }
    }

    fn parseRun(self: Context, ask: []const u8) ![]const u8 {
        // we impliment a rudimentary tokenizer
        var b_num: u8 = 0;
        var start_idx: usize = 0;
        var end_idx: usize = 0;
        var state: enum { start, text } = .start;
        for (ask) |c, i| {
            // skip run
            if (i < 4) continue;
            switch (state) {
                .start => switch (c) {
                    '`' => {
                        b_num += 1;
                        if (b_num == 2) {
                            b_num = 0;
                            state = .text;
                            start_idx = i + 2;
                        }
                    },
                    ' ', '\t' => continue,
                    else => return error.InvalidInput,
                },
                .text => switch (c) {
                    '`' => {
                        b_num += 1;
                        if (b_num == 2) {
                            end_idx = i;
                            break;
                        }
                    },
                    else => continue,
                },
            }
        }
        if (start_idx == 0) return error.InvalidInput;
        if (end_idx == 0) return error.InvalidInput;
        return ask[start_idx..end_idx];
    }

    fn maybeGithubIssue(self: Context, ask: []const u8) !?GithubIssue {
        if (std.fmt.parseInt(u32, ask, 10)) |issue| {
            return try self.requestGithubIssue("ziglang/zig", ask);
        } else |_| {}

        const slash = std.mem.indexOfScalar(u8, ask, '/') orelse return null;
        const pound = std.mem.indexOfScalar(u8, ask, '#') orelse return null;

        if (slash > pound) return null;

        return try self.requestGithubIssue(ask[0..pound], ask[pound + 1 ..]);
    }

    pub fn sendDiscordMessage(self: Context, args: struct {
        channel_id: u64,
        edit_msg_id: u64 = 0,
        title: []const u8,
        color: HexColor = HexColor.black,
        description: []const []const u8 = &.{},
        image: ?[]const u8 = null,
    }) !u64 {
        var path_buf: [0x100]u8 = undefined;

        const method = if (args.edit_msg_id == 0) "POST" else "PATCH";
        const path = if (args.edit_msg_id == 0)
            try std.fmt.bufPrint(&path_buf, "/api/v6/channels/{d}/messages", .{args.channel_id})
        else
            try std.fmt.bufPrint(&path_buf, "/api/v6/channels/{d}/messages/{d}", .{ args.channel_id, args.edit_msg_id });

        var req = try request.Https.init(.{
            .allocator = self.allocator,
            .pem = @embedFile("../discord-com-chain.pem"),
            .host = "discord.com",
            .method = method,
            .path = path,
        });
        defer req.deinit();

        try req.client.writeHeaderValue("Accept", "application/json");
        try req.client.writeHeaderValue("Content-Type", "application/json");
        try req.client.writeHeaderValue("Authorization", self.auth_token);

        // Zig has difficulty resolving these peer types
        const image: ?struct { url: []const u8 } = if (args.image) |url|
            .{ .url = url }
        else
            null;

        const embed = .{
            .title = args.title,
            .color = @enumToInt(args.color),
            .description = format.concat(args.description),
            .image = image,
        };
        try req.printSend("{}", .{
            format.json(.{
                .content = "",
                .tts = false,
                .embed = embed,
            }),
        });

        if (req.expectSuccessStatus()) |_| {
            try req.completeHeaders();

            var body = req.body();
            var stream = util.streamJson(body.reader());

            const root = try stream.root();
            if (try root.objectMatchAny(&.{"id"})) |match| {
                var buf: [0x100]u8 = undefined;
                const id_string = try match.value.stringBuffer(&buf);
                return try std.fmt.parseInt(u64, id_string, 10);
            }
            return error.IdNotFound;
        } else |err| switch (err) {
            error.TooManyRequests => {
                try req.completeHeaders();

                var body = req.body();
                var stream = util.streamJson(body.reader());
                const root = try stream.root();

                if (try root.objectMatch("retry_after")) |match| {
                    const sec = try match.value.number(f64);
                    // Don't bother trying for awhile
                    std.time.sleep(@floatToInt(u64, sec * std.time.ns_per_s));
                }
                return error.TooManyRequests;
            },
            else => return err,
        }
    }

    pub fn requestRun(self: Context, allocator: *std.mem.Allocator, src: []const u8) !RunResult {
        var req = try request.Https.init(.{
            .allocator = self.allocator,
            .pem = @embedFile("../emkc-org-chain.pem"),
            .host = "emkc.org",
            .method = "POST",
            .path = "/api/v1/piston/execute",
        });
        defer req.deinit();

        try req.client.writeHeaderValue("Content-Type", "application/json");

        try req.printSend("{}", .{
            format.json(.{
                .language = "zig",
                .source = src,
                .stdin = "",
                .args = [0][]const u8{},
            }),
        });

        _ = try req.expectSuccessStatus();
        try req.completeHeaders();

        var body = req.body();

        var stream = util.streamJson(body.reader());
        const root = try stream.root();

        var result = RunResult{
            .stdout = &.{},
            .stderr = &.{},
        };
        errdefer {
            if (result.stdout.len > 0) {
                allocator.free(result.stdout);
            }
            if (result.stderr.len > 0) {
                allocator.free(result.stderr);
            }
        }

        while (try root.objectMatchAny(&[_][]const u8{
            "stdout",
            "stderr",
        })) |match| {
            const swh = util.Swhash(16);
            switch (swh.match(match.key)) {
                swh.case("stdout") => {
                    const reader = try match.value.stringReader();
                    result.stdout = try reader.readAllAlloc(allocator, std.math.maxInt(usize));
                },
                swh.case("stderr") => {
                    const reader = try match.value.stringReader();
                    result.stderr = try reader.readAllAlloc(allocator, std.math.maxInt(usize));
                },
                else => unreachable,
            }
        }
        return result;
    }

    const GithubIssue = struct { repo: Buffer(0x100), number: u32, title: Buffer(0x100), url: Buffer(0x100) };
    const RunResult = struct {
        stdout: []const u8,
        stderr: []const u8,
    };
    // from https://gist.github.com/thomasbnt/b6f455e2c7d743b796917fa3c205f812
    const HexColor = enum(u24) {
        black = 0,
        aqua = 0x1ABC9C,
        green = 0x2ECC71,
        blue = 0x3498DB,
        red = 0xE74C3C,
        gold = 0xF1C40F,
        _,

        pub fn init(raw: u32) HexColor {
            return @intToEnum(HexColor, raw);
        }
    };
    pub fn requestGithubIssue(self: Context, repo: []const u8, issue: []const u8) !GithubIssue {
        var path: [0x100]u8 = undefined;
        var req = try request.Https.init(.{
            .allocator = self.allocator,
            .pem = @embedFile("../github-com-chain.pem"),
            .host = "api.github.com",
            .method = "GET",
            .path = try std.fmt.bufPrint(&path, "/repos/{s}/issues/{s}", .{ repo, issue }),
        });
        defer req.deinit();

        try req.client.writeHeaderValue("Accept", "application/json");
        if (self.github_auth_token) |github_auth_token| {
            var auth_buf: [0x100]u8 = undefined;
            const token = try std.fmt.bufPrint(&auth_buf, "token {s}", .{github_auth_token});
            try req.client.writeHeaderValue("Authorization", token);
        }
        try req.client.writeHeadComplete();
        try req.ssl_tunnel.conn.flush();

        _ = try req.expectSuccessStatus();
        try req.completeHeaders();
        var body = req.body();
        var stream = util.streamJson(body.reader());
        const root = try stream.root();

        var result = GithubIssue{ .repo = Buffer(0x100).initFrom(repo), .number = 0, .title = .{}, .url = .{} };
        while (try root.objectMatchAny(&[_][]const u8{ "number", "title", "html_url" })) |match| {
            const swh = util.Swhash(16);
            switch (swh.match(match.key)) {
                swh.case("number") => {
                    result.number = try match.value.number(u32);
                },
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

            if (result.number > 0 and result.title.len > 0 and result.url.len > 0) {
                return result;
            }
        }

        return error.FieldNotFound;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var auth_buf: [0x100]u8 = undefined;
    const context = try Context.init(
        &gpa.allocator,
        try std.fmt.bufPrint(&auth_buf, "Bot {s}", .{std.os.getenv("DISCORD_AUTH") orelse return error.AuthNotFound}),
        std.os.getenv("ZIGLIB") orelse return error.ZiglibNotFound,
        std.os.getenv("GITHUB_AUTH"),
    );

    var reconnect_wait: u64 = 1;
    while (true) {
        var discord_ws = DiscordWs.init(
            context.allocator,
            context.auth_token,
            DiscordWs.Intents{ .guild_messages = true },
        ) catch |err| {
            std.debug.print("Connect error: {s}\n", .{@errorName(err)});
            std.time.sleep(reconnect_wait * std.time.ns_per_s);
            reconnect_wait = std.math.min(reconnect_wait * 2, 30);
            continue;
        };
        reconnect_wait = 1;

        defer discord_ws.deinit();

        discord_ws.run(context, struct {
            fn handleDispatch(ctx: *Context, name: []const u8, data: anytype) !void {
                if (!std.mem.eql(u8, name, "MESSAGE_CREATE")) return;

                var ask: Buffer(0x1000) = .{};
                var channel_id: ?u64 = null;

                while (try data.objectMatchAny(&[_][]const u8{ "content", "channel_id" })) |match| {
                    const swh = util.Swhash(16);
                    switch (swh.match(match.key)) {
                        swh.case("content") => {
                            ask = try findAsk(try match.value.stringReader());
                            _ = try match.value.finalizeToken();
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
                    std.debug.print(">> %%{s}\n", .{ask.slice()});
                    ctx.ask_mailbox.putOverwrite(.{ .channel_id = channel_id.?, .ask = ask });
                }
            }

            fn findAsk(reader: anytype) !Buffer(0x1000) {
                const State = enum {
                    no_match,
                    percent,
                    ready,
                    endless,
                };
                var state = State.no_match;
                var buffer: Buffer(0x1000) = .{};

                while (reader.readByte()) |c| {
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
                                ' ', ',', '\n', '\t', '(', ')', '!', '?', '[', ']', '{', '}' => {
                                    if (std.mem.eql(u8, buffer.slice(), "run")) {
                                        state = .endless;
                                        try buffer.append(c);
                                    } else {
                                        break;
                                    }
                                },
                                else => try buffer.append(c),
                            }
                        },
                        .endless => try buffer.append(c),
                    }
                } else |err| switch (err) {
                    error.EndOfStream => {},
                    else => |e| return e,
                }

                // Strip trailing period
                if (buffer.last() == @as(u8, '.')) {
                    _ = buffer.pop() catch unreachable;
                }
                return buffer;
            }
        }) catch |err| switch (err) {
            // TODO: investigate if IO localized enough. And possibly convert to ConnectionReset
            error.ConnectionReset, error.IO => continue,
            error.AuthenticationFailed => |e| return e,
            else => @panic(@errorName(err)),
        };

        std.debug.print("Exited: {}\n", .{discord_ws.client});
    }
}

const DiscordWs = struct {
    allocator: *std.mem.Allocator,

    is_dying: bool,
    ssl_tunnel: *request.SslTunnel,

    client: wz.base.Client.Client(request.SslTunnel.Stream.DstReader, request.SslTunnel.Stream.DstWriter),
    client_buffer: []u8,
    write_mutex: std.Thread.Mutex,

    heartbeat_interval: usize,
    heartbeat_seq: ?usize,
    heartbeat_ack: bool,
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

    pub fn init(allocator: *std.mem.Allocator, auth_token: []const u8, intents: Intents) !*DiscordWs {
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

        result.client = wz.base.Client.create(
            result.client_buffer,
            result.ssl_tunnel.conn.reader(),
            result.ssl_tunnel.conn.writer(),
        );

        // Handshake
        try result.client.sendHandshakeHead("/?v=6&encoding=json");
        try result.client.sendHandshakeHeaderValue("Host", "gateway.discord.gg");
        try result.client.sendHandshakeHeadComplete();
        try result.ssl_tunnel.conn.flush();
        try result.client.waitForHandshake();

        if (try result.client.readEvent()) |event| {
            std.debug.assert(event == .header);
        }

        result.is_dying = false;
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

        const Activity = struct {
            @"type": u8,
            name: []const u8,
        };

        try result.sendCommand(.identify, .{
            .compress = false,
            .intents = intents.toRaw(),
            .token = auth_token,
            .properties = .{
                .@"$os" = @tagName(std.Target.current.os.tag),
                .@"$browser" = agent,
                .@"$device" = agent,
            },
            .presence = .{
                .status = "online",
                .activities = &[_]Activity{
                    .{
                        .@"type" = 0,
                        .name = "examples: %%666 or %%std.ArrayList",
                    },
                },
            },
        });

        result.heartbeat_seq = null;
        result.heartbeat_ack = true;
        result.heartbeat_thread = try std.Thread.spawn(result, heartbeatHandler);

        return result;
    }

    pub fn deinit(self: *DiscordWs) void {
        self.ssl_tunnel.deinit();

        self.is_dying = true;
        self.heartbeat_thread.wait();

        self.allocator.destroy(self);
    }

    pub fn run(self: *DiscordWs, ctx: anytype, handler: anytype) !void {
        while (try self.client.readEvent()) |event| {
            // Skip over any remaining chunks. The processor didn't take care of it.
            if (event != .header) continue;

            switch (event.header.opcode) {
                .Text => {
                    self.processChunks(ctx, handler) catch |err| {
                        std.debug.print("Process chunks failed: {s}\n", .{err});
                    };
                },
                .Ping, .Pong => {},
                .Close => {
                    const body = (try self.client.readEvent()) orelse {
                        std.debug.print("Websocket close frame - {{}}: no reason provided. Reconnecting...\n", .{});
                        return error.ConnectionReset;
                    };

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

                        pub fn format(code: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
                            try writer.print("{d}: {s}", .{ @enumToInt(code), @tagName(code) });
                        }
                    };

                    const code_num = std.mem.readIntBig(u16, body.chunk.data[0..2]);
                    const code = std.meta.intToEnum(CloseEventCode, std.mem.readIntBig(u16, body.chunk.data[0..2])) catch |err| switch (err) {
                        error.InvalidEnumTag => {
                            std.debug.print("Websocket close frame - {d}: unknown code. Reconnecting...\n", .{code_num});
                            return error.ConnectionReset;
                        },
                    };

                    switch (code) {
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
                },
                .Binary => return error.WtfBinary,
                else => return error.WtfWtf,
            }
        }
    }

    pub fn processChunks(self: *DiscordWs, ctx: anytype, handler: anytype) !void {
        const event = (try self.client.readEvent()) orelse return error.NoBody;
        std.debug.assert(event == .chunk);

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
                    }
                },
                swh.case("op") => {
                    op = try std.meta.intToEnum(Opcode, try match.value.number(u8));
                },
                swh.case("d") => {
                    switch (op orelse return error.DataBeforeOp) {
                        .dispatch => {
                            std.debug.print("<< {d} -- {s}\n", .{ self.heartbeat_seq, name });
                            try handler.handleDispatch(
                                ctx,
                                name orelse return error.DispatchWithoutName,
                                match.value,
                            );
                        },
                        .heartbeat_ack => {
                            std.debug.print("<< ♥\n", .{});
                            self.heartbeat_ack = true;
                        },
                        else => {},
                    }
                    _ = try match.value.finalizeToken();
                },
                else => unreachable,
            }
        }
    }

    pub fn sendCommand(self: *DiscordWs, opcode: Opcode, data: anytype) !void {
        var buf: [0x1000]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{s}", .{
            format.json(.{
                .op = @enumToInt(opcode),
                .d = data,
            }),
        });

        const held = self.write_mutex.acquire();
        defer held.release();

        try self.client.writeMessageHeader(.{ .length = msg.len, .opcode = .Text });
        try self.client.writeMessagePayload(msg);

        try self.ssl_tunnel.conn.flush();
    }

    pub extern "c" fn shutdown(sockfd: std.os.fd_t, how: c_int) c_int;

    fn heartbeatHandler(self: *DiscordWs) void {
        while (true) {
            const start = std.time.milliTimestamp();
            // Buffer to fire early than late
            while (std.time.milliTimestamp() - start < self.heartbeat_interval - 1000) {
                std.time.sleep(std.time.ns_per_s);
                if (self.is_dying) {
                    return;
                }
            }

            if (!self.heartbeat_ack) {
                std.debug.print("Missed heartbeat. Reconnecting...\n", .{});
                const SHUT_RDWR = 2;
                const rc = shutdown(self.ssl_tunnel.tcp_conn.handle, SHUT_RDWR);
                if (rc != 0) {
                    std.debug.print("Shutdown failed: {d}\n", .{std.c.getErrno(rc)});
                }
                return;
            }

            self.heartbeat_ack = false;

            var retries: u6 = 0;
            while (self.sendCommand(.heartbeat, self.heartbeat_seq)) |_| {
                std.debug.print(">> ♡\n", .{});
                break;
            } else |err| {
                if (retries < 3) {
                    std.os.nanosleep(@as(u64, 1) << retries, 0);
                    retries += 1;
                } else {
                    const SHUT_RDWR = 2;
                    const rc = shutdown(self.ssl_tunnel.tcp_conn.handle, SHUT_RDWR);
                    if (rc != 0) {
                        std.debug.print("Shutdown failed: {d}\n", .{std.c.getErrno(rc)});
                    }
                    return;
                }
            }
        }
    }
};

test "" {
    _ = request;
    _ = util;
}
