const std = @import("std");

pub fn jsonString(text: []const u8) JsonString {
    return .{ .text = text };
}

pub const JsonString = struct {
    text: []const u8,

    const Reserved = enum(u8) {
        Quote = '"',
        Newline = '\n',
        Backslash = '\\',
    };

    pub fn format(self: JsonString, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        var start: usize = 0;
        for (self.text) |letter, i| {
            const reserved = std.meta.intToEnum(Reserved, letter) catch continue;
            if (start < i) {
                try writer.writeAll(self.text[start..i]);
            }
            switch (reserved) {
                .Quote => try writer.writeAll("\\\""),
                .Newline => try writer.writeAll("\\n"),
                .Backslash => try writer.writeAll("\\\\"),
            }
            start = i + 1;
        }
        if (start < self.text.len) {
            try writer.writeAll(self.text[start..]);
        }
    }
};

pub fn time(millis: u64) Time {
    return .{ .millis = millis };
}
const Time = struct {
    millis: u64,

    pub fn format(self: Time, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        const hours = self.millis / std.time.ms_per_hour;
        const mins = (self.millis / std.time.ms_per_min) % 60;
        const secs = (self.millis / std.time.ms_per_s) % 60;
        const mill = self.millis % 1000;
        return std.fmt.format(writer, "{: <4}:{:0<2}:{:0<2}.{:0<3}", .{ hours, mins, secs, mill });
    }
};
