const std = @import("std");

pub fn Json(comptime T: type) type {
    return struct {
        data: T,

        pub fn format(self: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            // TODO: convert stringify options
            return std.json.stringify(self.data, .{ .string = .{ .String = .{} } }, writer);
        }
    };
}

pub fn json(data: anytype) Json(@TypeOf(data)) {
    return .{ .data = data };
}

pub fn time(millis: i64) Time {
    return .{ .millis = millis };
}
const Time = struct {
    millis: i64,

    pub fn format(self: Time, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        const hours = @intCast(u16, @divFloor(self.millis, std.time.ms_per_hour));
        const mins = @intCast(u8, @mod(@divFloor(self.millis, std.time.ms_per_min), 60));
        const secs = @intCast(u8, @mod(@divFloor(self.millis, std.time.ms_per_s), 60));
        const mill = @intCast(u16, @mod(self.millis, 1000));
        return std.fmt.format(writer, "{: >4}:{:0>2}:{:0>2}.{:0>3}", .{ hours, mins, secs, mill });
    }
};

pub fn concat(segments: []const []const u8) Concat {
    return .{ .segments = segments };
}
const Concat = struct {
    segments: []const []const u8,

    pub fn format(self: Concat, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        for (self.segments) |segment| {
            try writer.writeAll(segment);
        }
    }

    pub fn jsonStringify(self: Concat, options: std.json.StringifyOptions, writer: anytype) !void {
        try writer.writeAll("\"");
        for (self.segments) |segment| {
            try writeJsonSegment(writer, segment);
        }
        try writer.writeAll("\"");
    }

    fn writeJsonSegment(writer: anytype, string: []const u8) !void {
        var prev: usize = 0;

        for (string) |char, i| {
            const escaped = switch (char) {
                '\\' => "\\\\",
                '\"' => "\\\"",
                0x8 => "\\b",
                0xC => "\\f",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                else => continue,
            };
            if (prev < i) {
                try writer.writeAll(string[prev..i]);
            }
            try writer.writeAll(escaped);
            prev = i + 1;
        }

        if (prev < string.len) {
            try writer.writeAll(string[prev..]);
        }
    }
};
