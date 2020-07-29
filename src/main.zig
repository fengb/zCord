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

    conn: Connection,
    reader: Connection.DstInStream,
    writer: Connection.DstOutStream,

    const Connection = ssl.Stream(*std.fs.File.Reader, *std.fs.File.Writer);

    fn init(allocator: *std.mem.Allocator, pem: []const u8, host: [:0]const u8, port: u16) !*SslTunnel {
        const result = try allocator.create(SslTunnel);
        errdefer allocator.destroy(result);

        result.allocator = allocator;

        result.trust_anchor = ssl.TrustAnchorCollection.init(allocator);
        errdefer result.trust_anchor.deinit();
        try result.trust_anchor.appendFromPEM(pem);

        result.x509 = ssl.x509.Minimal.init(result.trust_anchor);
        result.client = ssl.Client.init(result.x509.getEngine());
        result.client.relocate();
        try result.client.reset(host, false);

        result.raw_conn = try std.net.tcpConnectToHost(allocator, host, port);
        errdefer result.raw_conn.close();

        result.raw_reader = result.raw_conn.reader();
        result.raw_writer = result.raw_conn.writer();

        result.conn = ssl.initStream(result.client.getEngine(), &result.raw_reader, &result.raw_writer);
        result.reader = result.conn.inStream();
        result.writer = result.conn.outStream();

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
    var ssl_tunnel = try SslTunnel.init(std.heap.c_allocator, @embedFile("../ssl503375-cloudflaressl-com-chain.pem"), "gateway.discord.gg", 443);
    errdefer ssl_tunnel.deinit();

    var buf: [0x1000]u8 = undefined;
    var client = hzzp.BaseClient.create(&buf, &ssl_tunnel.reader, &ssl_tunnel.writer);
    try client.writeHead("GET", "/");
    try client.writeHeadComplete();
    try ssl_tunnel.conn.flush();

    while (try client.readEvent()) |event| {
        std.debug.print("{}\n\n", .{event});
    }
}
