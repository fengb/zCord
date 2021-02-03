const std = @import("std");
const hzzp = @import("hzzp");
const ssl = @import("zig-bearssl");

const bot_agent = "zigbot9001/0.0.1";

pub const SslTunnel = struct {
    allocator: *std.mem.Allocator,

    trust_anchor: ssl.TrustAnchorCollection,
    x509: ssl.x509.Minimal,
    client: ssl.Client,

    tcp_conn: std.net.Stream,
    tcp_reader: std.net.Stream.Reader,
    tcp_writer: std.net.Stream.Writer,

    conn: Stream,

    pub const Stream = ssl.Stream(*std.net.Stream.Reader, *std.net.Stream.Writer);

    pub fn init(args: struct {
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

        result.tcp_conn = try std.net.tcpConnectToHost(args.allocator, args.host, args.port);
        errdefer result.tcp_conn.close();

        result.tcp_reader = result.tcp_conn.reader();
        result.tcp_writer = result.tcp_conn.writer();

        result.conn = ssl.initStream(result.client.getEngine(), &result.tcp_reader, &result.tcp_writer);

        return result;
    }

    pub fn deinit(self: *SslTunnel) void {
        self.tcp_conn.close();
        self.trust_anchor.deinit();

        self.allocator.destroy(self);
    }
};

pub const Https = struct {
    allocator: *std.mem.Allocator,
    ssl_tunnel: *SslTunnel,
    buffer: []u8,
    client: HzzpClient,

    const HzzpClient = hzzp.base.client.BaseClient(SslTunnel.Stream.DstReader, SslTunnel.Stream.DstWriter);

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

        var client = hzzp.base.client.create(buffer, ssl_tunnel.conn.reader(), ssl_tunnel.conn.writer());

        try client.writeStatusLine(args.method, args.path);

        try client.writeHeaderValue("Host", args.host);
        try client.writeHeaderValue("User-Agent", bot_agent);

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
        try self.client.writeHeaderFormat("Content-Length", "{d}", .{std.fmt.count(fmt, args)});
        try self.client.finishHeaders();

        try self.client.writer.print(fmt, args);
        try self.ssl_tunnel.conn.flush();
    }

    pub fn expectSuccessStatus(self: *Https) !u16 {
        if (try self.client.next()) |event| {
            if (event != .status) {
                return error.MissingStatus;
            }
            switch (event.status.code) {
                200...299 => return event.status.code,

                100...199 => return error.MiscInformation,

                300...399 => return error.MiscRedirect,

                400 => return error.BadRequest,
                401 => return error.Unauthorized,
                402 => return error.PaymentRequired,
                403 => return error.Forbidden,
                404 => return error.NotFound,
                429 => return error.TooManyRequests,
                405...428, 430...499 => return error.MiscClientError,

                500 => return error.InternalServerError,
                501...599 => return error.MiscServerError,
                else => unreachable,
            }
        } else {
            return error.NoResponse;
        }
    }

    pub fn completeHeaders(self: *Https) !void {
        while (try self.client.next()) |event| {
            if (event == .head_done) {
                return;
            }
        }
    }
};
