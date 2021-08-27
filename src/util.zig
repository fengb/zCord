const std = @import("std");

pub const Fixbuf = @compileError("Please use std.BoundedArray instead");

pub fn errSetContains(comptime ErrorSet: type, err: anyerror) bool {
    inline for (comptime std.meta.fields(ErrorSet)) |e| {
        if (err == @field(ErrorSet, e.name)) {
            return true;
        }
    }
    return false;
}

pub fn ReturnOf(comptime func: anytype) type {
    return switch (@typeInfo(@TypeOf(func))) {
        .Fn, .BoundFn => |fn_info| fn_info.return_type.?,
        else => unreachable,
    };
}

pub fn ErrorOf(comptime func: anytype) type {
    const return_type = ReturnOf(func);
    return switch (@typeInfo(return_type)) {
        .ErrorUnion => |eu_info| eu_info.error_set,
        else => unreachable,
    };
}

pub fn Mailbox(comptime T: type) type {
    return struct {
        const Self = @This();

        value: ?T,
        mutex: std.Thread.Mutex,
        reset_event: std.Thread.ResetEvent,

        pub fn init(self: *Self) !void {
            try self.reset_event.init();
            errdefer self.reset_event.deinit();

            self.value = null;
            self.mutex = .{};
        }

        pub fn deinit(self: *Self) void {
            self.reset_event.deinit();
        }

        pub fn get(self: *Self) T {
            self.reset_event.wait();

            const held = self.mutex.acquire();
            defer held.release();

            self.reset_event.reset();
            defer self.value = null;
            return self.value.?;
        }

        pub fn getWithTimeout(self: *Self, timeout_ns: u64) ?T {
            _ = self.reset_event.timedWait(timeout_ns);

            const held = self.mutex.acquire();
            defer held.release();

            self.reset_event.reset();
            defer self.value = null;
            return self.value;
        }

        pub fn putOverwrite(self: *Self, value: T) void {
            const held = self.mutex.acquire();
            defer held.release();

            self.value = value;
            self.reset_event.set();
        }
    };
}
