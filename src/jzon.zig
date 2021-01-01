const std = @import("std");

pub fn dump(writer: anytype, jzon: anytype) !void {
    const T = @TypeOf(jzon);

    if (comptime std.meta.trait.hasFn("format")(T)) {
        // TODO: create an auto-escaping writer
        return writer.print(
            \\"{}"
        , .{jzon});
    }

    switch (@typeInfo(T)) {
        .Int, .Float, .ComptimeInt, .ComptimeFloat, .Bool, .Null => try writer.print("{}", .{jzon}),
        .Struct => |s_info| {
            try writer.writeByte('{');
            inline for (s_info.fields) |field, i| {
                if (i != 0) {
                    try writer.writeByte(',');
                }
                try writer.writeByte('"');
                try writer.writeAll(field.name);
                try writer.writeByte('"');
                try writer.writeByte(':');

                try dump(writer, @field(jzon, field.name));
            }
            try writer.writeByte('}');
        },
        .Pointer => |ptr_info| {
            const text = std.mem.span(jzon);
            try writer.writeByte('"');

            // Fancy text escape logic. This scans the text for reserved chars. Unescaped chars are written simultaneously.
            const Reserved = enum(u8) {
                Quote = '"',
                Newline = '\n',
                Backslash = '\\',
            };

            var start: usize = 0;
            for (text) |letter, i| {
                const reserved = std.meta.intToEnum(Reserved, letter) catch continue;
                if (start < i) {
                    try writer.writeAll(text[start..i]);
                }
                switch (reserved) {
                    .Quote => try writer.writeAll("\\\""),
                    .Newline => try writer.writeAll("\\n"),
                    .Backslash => try writer.writeAll("\\\\"),
                }
                start = i + 1;
            }
            if (start < text.len) {
                try writer.writeAll(text[start..]);
            }

            try writer.writeByte('"');
        },
        else => @compileError("Type not supported yet"),
    }
}

pub fn Format(comptime T: type) type {
    return struct {
        const Self = @This();

        data: T,

        pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            return dump(writer, self.data);
        }
    };
}

pub fn format(arg: anytype) Format(@TypeOf(arg)) {
    return .{ .data = arg };
}

test "basic" {
    var buf: [1 << 10]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try dump(fbs.writer(), .{});
    std.testing.expectEqualStrings("{}", fbs.getWritten());

    fbs.reset();
    try dump(fbs.writer(), .{ .foo = 1, .bar = false, .baz = null });
    std.testing.expectEqualStrings(
        \\{"foo":1,"bar":false,"baz":null}
    , fbs.getWritten());
}

test "strings" {
    var buf: [1 << 10]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try dump(fbs.writer(), .{ .foo = "bar" });
    std.testing.expectEqualStrings(
        \\{"foo":"bar"}
    , fbs.getWritten());

    fbs.reset();
    try dump(fbs.writer(), .{ .foo = "bar\n" });
    std.testing.expectEqualStrings(
        \\{"foo":"bar\n"}
    , fbs.getWritten());
}
