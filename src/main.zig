const std = @import("std");
const hzzp = @import("hzzp");

const HttpClient = hzzp.BaseClient.BaseClient(*std.fs.File.Reader, *std.fs.File.Writer);

pub fn main() !void {
    var file = try std.net.tcpConnectToHost(std.heap.page_allocator, "example.com", 80);

    var buf: [0x1000]u8 = undefined;
    var client = HttpClient.init(&buf, &file.reader(), &file.writer());
    try client.writeHead("GET", "/");
    try client.writeHeadComplete();

    while (try client.readEvent()) |event| {
        std.debug.print("{}\n\n", .{event});
    }
}
