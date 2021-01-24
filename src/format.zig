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
