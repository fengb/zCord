const std = @import("std");
const hzzp = @import("hzzp");
const ssl = @import("zig-bearssl");

const allocator = std.heap.c_allocator;

const pem = @embedFile("../ssl503375-cloudflaressl-com-chain.pem");

pub fn main() !void {
    var trust_anchor = ssl.TrustAnchorCollection.init(allocator);
    defer trust_anchor.deinit();
    try trust_anchor.appendFromPEM(pem);
    var x509 = ssl.x509.Minimal.init(trust_anchor);
    var ssl_client = ssl.Client.init(x509.getEngine());
    ssl_client.relocate();
    try ssl_client.reset("gateway.discord.gg", false);

    var file = try std.net.tcpConnectToHost(allocator, "gateway.discord.gg", 443);
    var in = file.reader();
    var out = file.writer();

    var ssl_conn = ssl.initStream(ssl_client.getEngine(), &in, &out);
    var in_ = ssl_conn.inStream();
    var out_ = ssl_conn.outStream();

    var buf: [0x1000]u8 = undefined;
    var client = hzzp.BaseClient.create(&buf, &in_, &out_);
    try client.writeHead("GET", "/");
    try client.writeHeadComplete();
    try ssl_conn.flush();

    while (try client.readEvent()) |event| {
        std.debug.print("{}\n\n", .{event});
    }
}
