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

        value: ?T = null,
        mutex: std.Thread.Mutex = .{},
        reset_event: std.Thread.ResetEvent = .{},

        pub fn get(self: *Self) T {
            self.reset_event.wait();

            self.mutex.lock();
            defer self.mutex.unlock();

            self.reset_event.reset();
            defer self.value = null;
            return self.value.?;
        }

        pub fn getWithTimeout(self: *Self, timeout_ns: u64) ?T {
            self.reset_event.timedWait(timeout_ns) catch |err| switch (err) {
                error.Timeout => {},
            };

            self.mutex.lock();
            defer self.mutex.unlock();

            self.reset_event.reset();
            defer self.value = null;
            return self.value;
        }

        pub fn putOverwrite(self: *Self, value: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.value = value;
            self.reset_event.set();
        }
    };
}
