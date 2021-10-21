const std = @import("std");
const hzzp = @import("hzzp");
const iguanaTLS = @import("iguanaTLS");

pub const root_ca = struct {
    const pem = @embedFile("../cacert.pem");
    var cert_chain: ?iguanaTLS.x509.CertificateChain = null;

    /// Initializes the bundled root certificates
    /// This is a shared chain that's used whenever an PEM is not passed in
    pub fn preload(allocator: *std.mem.Allocator) !void {
        std.debug.assert(cert_chain == null);
        var fbs = std.io.fixedBufferStream(pem);
        cert_chain = try iguanaTLS.x509.CertificateChain.from_pem(allocator, fbs.reader());
    }

    pub fn deinit() void {
        cert_chain.?.deinit();
        cert_chain = null;
    }
};

pub const Tunnel = struct {
    allocator: *std.mem.Allocator,

    client: Client,
    tcp_conn: std.net.Stream,
    state: enum { connected, shutdown },

    pub const Client = iguanaTLS.Client(std.net.Stream.Reader, std.net.Stream.Writer, iguanaTLS.ciphersuites.all, false);

    pub fn create(args: struct {
        allocator: *std.mem.Allocator,
        host: []const u8,
        port: u16 = 443,
        pem: ?[]const u8 = null,
    }) !*Tunnel {
        const result = try args.allocator.create(Tunnel);
        errdefer args.allocator.destroy(result);

        result.allocator = args.allocator;

        const trusted_chain = if (args.pem) |pem| blk: {
            var fbs = std.io.fixedBufferStream(pem);
            break :blk try iguanaTLS.x509.CertificateChain.from_pem(args.allocator, fbs.reader());
        } else root_ca.cert_chain.?;
        defer if (args.pem) |_| trusted_chain.deinit();

        result.tcp_conn = try std.net.tcpConnectToHost(args.allocator, args.host, args.port);
        errdefer result.tcp_conn.close();

        result.client = try iguanaTLS.client_connect(.{
            .reader = result.tcp_conn.reader(),
            .writer = result.tcp_conn.writer(),
            .cert_verifier = .default,
            .trusted_certificates = trusted_chain.data.items,
            .temp_allocator = args.allocator,
        }, args.host);
        errdefer result.client.close_notify() catch {};

        return result;
    }

    pub fn shutdown(self: *Tunnel) !void {
        std.debug.assert(self.state == .connected);

        const close_err = self.client.close_notify();
        try std.os.shutdown(self.tcp_conn.handle, .both);
        self.state = .shutdown;
        try close_err;
    }

    pub fn destroy(self: *Tunnel) void {
        if (self.state == .connected) {
            self.client.close_notify() catch {};
        }
        self.tcp_conn.close();
        self.allocator.destroy(self);
    }
};

pub const Request = struct {
    allocator: *std.mem.Allocator,
    tunnel: *Tunnel,
    buffer: []u8,
    client: hzzp.base.client.BaseClient(Tunnel.Client.Reader, Tunnel.Client.Writer),
    response_code: ?hzzp.StatusCode,

    pub const Method = enum { GET, POST, PUT, DELETE, PATCH };

    pub fn init(args: struct {
        allocator: *std.mem.Allocator,
        host: []const u8,
        port: u16 = 443,
        method: Method,
        path: []const u8,
        user_agent: []const u8 = "zCord/0.0.1",
        pem: ?[]const u8 = null,
    }) !Request {
        var tunnel = try Tunnel.create(.{
            .allocator = args.allocator,
            .host = args.host,
            .port = args.port,
            .pem = args.pem,
        });
        errdefer tunnel.destroy();

        const buffer = try args.allocator.alloc(u8, 0x1000);
        errdefer args.allocator.free(buffer);

        var client = hzzp.base.client.create(buffer, tunnel.client.reader(), tunnel.client.writer());
        try client.writeStatusLine(@tagName(args.method), args.path);
        try client.writeHeaderValue("Host", args.host);
        try client.writeHeaderValue("User-Agent", args.user_agent);

        return Request{
            .allocator = args.allocator,
            .tunnel = tunnel,
            .buffer = buffer,
            .client = client,
            .response_code = null,
        };
    }

    pub fn deinit(self: *Request) void {
        self.tunnel.destroy();
        self.allocator.free(self.buffer);
        self.* = undefined;
    }

    pub const printSend = @compileError("Deprecated: please switch to `sendPrint(fmt, args)`");
    pub const expectSuccessStatus = @compileError("Deprecated: please switch to `req.response_code.group() == .success`");

    // TODO: fix this name
    pub fn sendPrint(self: *Request, comptime fmt: []const u8, args: anytype) !hzzp.StatusCode {
        try self.client.writeHeaderFormat("Content-Length", "{d}", .{std.fmt.count(fmt, args)});
        try self.client.finishHeaders();
        try self.client.writer.print(fmt, args);
        return try self.initResponseCode();
    }

    // TODO: fix this name
    pub fn sendEmptyBody(self: *Request) !hzzp.StatusCode {
        try self.client.finishHeaders();
        try self.client.writePayload(null);
        return try self.initResponseCode();
    }

    fn initResponseCode(self: *Request) !hzzp.StatusCode {
        if (self.response_code) |code| return code;

        const event = (try self.client.next()).?;
        if (event != .status) {
            return error.MissingStatus;
        }
        const raw_code = std.math.cast(u10, event.status.code) catch 666;
        self.response_code = @intToEnum(hzzp.StatusCode, raw_code);
        return self.response_code.?;
    }

    pub fn completeHeaders(self: *Request) !void {
        _ = try self.initResponseCode();
        while (try self.client.next()) |event| {
            if (event == .head_done) {
                return;
            }
        }
    }

    pub fn debugDumpResponse(self: *Request, writer: anytype) !void {
        try self.initResponseCode();
        try self.debugDumpHeaders(writer);
        try self.debugDumpBody(writer);
    }

    pub fn debugDumpHeaders(self: *Request, writer: anytype) !void {
        while (try self.client.next()) |event| {
            switch (event) {
                .header => |header| try writer.print("{s}: {s}\n", .{ header.name, header.value }),
                .head_done => return,
                else => unreachable,
            }
        }
    }

    pub fn debugDumpBody(self: *Request, writer: anytype) !void {
        const reader = self.client.reader();

        var buf: [0x1000]u8 = undefined;
        while (true) {
            const len = try reader.read(&buf);
            if (len == 0) break;
            try writer.writeAll(buf[0..len]);
        }
        try writer.writeAll("\n");
    }
};
