const std = @import("std");
const hzzp = @import("hzzp");
const ssl = @import("zig-bearssl");

const bot_agent = "zigbot9001/0.0.1";

const SslTunnel = struct {
    allocator: *std.mem.Allocator,

    trust_anchor: ssl.TrustAnchorCollection,
    x509: ssl.x509.Minimal,
    client: ssl.Client,

    raw_conn: std.fs.File,
    raw_reader: std.fs.File.Reader,
    raw_writer: std.fs.File.Writer,

    conn: Stream,

    const Stream = ssl.Stream(*std.fs.File.Reader, *std.fs.File.Writer);

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

pub const Https = struct {
    allocator: *std.mem.Allocator,
    ssl_tunnel: *SslTunnel,
    buffer: []u8,
    client: HzzpClient,

    const HzzpClient = hzzp.BaseClient.BaseClient(SslTunnel.Stream.DstInStream, SslTunnel.Stream.DstOutStream);

    pub fn init(args: struct {
        allocator: *std.mem.Allocator,
        pem: []const u8,
        host: [:0]const u8,
        port: u16 = 443,
        method: []const u8,
        path: []const u8,
    }) !Https {
        var ssl_tunnel = try SslTunnel.init(.{
            .allocator = args.allocator,
            .pem = args.pem,
            .host = args.host,
            .port = args.port,
        });
        errdefer ssl_tunnel.deinit();

        const buffer = try args.allocator.alloc(u8, 0x1000);
        errdefer args.allocator.free(buffer);

        var client = hzzp.BaseClient.create(buffer, ssl_tunnel.conn.inStream(), ssl_tunnel.conn.outStream());

        try client.writeHead(args.method, args.path);

        try client.writeHeader("Host", args.host);
        try client.writeHeader("User-Agent", bot_agent);

        return Https{
            .allocator = args.allocator,
            .ssl_tunnel = ssl_tunnel,
            .buffer = buffer,
            .client = client,
        };
    }

    pub fn deinit(self: *Https) void {
        self.ssl_tunnel.deinit();
        self.allocator.free(self.buffer);
        self.* = undefined;
    }

    // TODO: fix this name
    pub fn printSend(self: *Https, comptime fmt: []const u8, args: anytype) !void {
        var buf: [0x10]u8 = undefined;
        try self.client.writeHeader(
            "Content-Length",
            try std.fmt.bufPrint(&buf, "{}", .{std.fmt.count(fmt, args)}),
        );
        try self.client.writeHeadComplete();

        try self.client.writer.print(fmt, args);
        try self.ssl_tunnel.conn.flush();
    }

    pub fn expectSuccessStatus(self: *Https) !u16 {
        if (try self.client.readEvent()) |event| {
            if (event != .status) {
                return error.MissingStatus;
            }
            switch (event.status.code) {
                200...299 => return event.status.code,
                100...199 => return error.Internal,
                300...399 => return error.Redirect,
                400 => return error.InvalidRequest,
                401 => return error.Unauthorized,
                402 => return error.PaymentRequired,
                403 => return error.Forbidden,
                404 => return error.NotFound,
                405...499 => return error.ClientError,
                500...599 => return error.ServerError,
                else => unreachable,
            }
        } else {
            return error.NoResponse;
        }
    }

    pub fn body(self: *Https) !Body {
        // TODO: maybe move into readFn
        // Skip headers
        while (try self.client.readEvent()) |event| {
            if (event == .head_complete) {
                break;
            }
        }

        return Body{ .client = self.client };
    }

    const Body = struct {
        const Reader = std.io.Reader(*Body, HzzpClient.ReadError, readFn);

        client: HzzpClient,
        complete: bool = false,
        chunk: ?hzzp.BaseClient.Chunk = null,
        loc: usize = undefined,

        fn readFn(self: *Body, buffer: []u8) HzzpClient.ReadError!usize {
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

        pub fn reader(self: *Body) Reader {
            return .{ .context = self };
        }
    };
};
