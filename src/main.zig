const std = @import("std");
const hzzp = @import("hzzp");
const ssl = @import("zig-bearssl");

const SslTunnel = struct {
    allocator: *std.mem.Allocator,

    trust_anchor: ssl.TrustAnchorCollection,
    x509: ssl.x509.Minimal,
    client: ssl.Client,

    raw_conn: std.fs.File,
    // TODO: why do these need to be overaligned?
    raw_reader: std.fs.File.Reader align(8),
    raw_writer: std.fs.File.Writer align(8),

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

pub fn main() !void {
    var ssl_tunnel = try SslTunnel.init(.{
        .allocator = std.heap.c_allocator,
        .pem = @embedFile("../discord-gg-chain.pem"),
        .host = "gateway.discord.gg",
    });
    errdefer ssl_tunnel.deinit();

    var buf: [0x1000]u8 = undefined;
    var client = hzzp.BaseClient.create(&buf, ssl_tunnel.conn.inStream(), ssl_tunnel.conn.outStream());
    try client.writeHead("GET", "/");
    try client.writeHeadComplete();
    try ssl_tunnel.conn.flush();

    while (try client.readEvent()) |event| {
        std.debug.print("{}\n\n", .{event});
    }
}
