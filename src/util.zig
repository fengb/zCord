const std = @import("std");

pub fn Fixbuf(comptime max_len: usize) type {
    return struct {
        data: [max_len]u8 = undefined,
        len: usize = 0,

        pub fn copyFrom(self: *@This(), data: []const u8) void {
            std.mem.copy(u8, &self.data, data);
            self.len = data.len;
        }

        pub fn slice(self: @This()) []const u8 {
            return self.data[0..self.len];
        }

        pub fn append(self: *@This(), char: u8) !void {
            if (self.len >= max_len) {
                return error.NoSpaceLeft;
            }
            self.data[self.len] = char;
            self.len += 1;
        }

        pub fn last(self: @This()) ?u8 {
            if (self.len > 0) {
                return self.data[self.len - 1];
            } else {
                return null;
            }
        }

        pub fn pop(self: *@This()) !u8 {
            return self.last() orelse error.Empty;
        }
    };
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
        cond: std.Thread.Condition = .{},
        mutex: std.Thread.Mutex = .{},

        pub fn get(self: *Self) T {
            const held = self.mutex.acquire();
            defer held.release();

            if (self.value) |value| {
                self.value = null;
                return value;
            } else {
                self.cond.wait(&self.mutex);

                defer self.value = null;
                return self.value.?;
            }
        }

        pub fn getWithTimeout(self: *Self, timeout_ns: u64) ?T {
            const held = self.mutex.acquire();
            defer held.release();

            if (self.value) |value| {
                self.value = null;
                return value;
            } else {
                const future_ns = std.time.nanoTimestamp() + timeout_ns;
                var future: std.os.timespec = undefined;
                future.tv_sec = @intCast(@TypeOf(future.tv_sec), @divFloor(future_ns, std.time.ns_per_s));
                future.tv_nsec = @intCast(@TypeOf(future.tv_nsec), @mod(future_ns, std.time.ns_per_s));

                const rc = std.os.system.pthread_cond_timedwait(&self.cond.impl.cond, &self.mutex.impl.pthread_mutex, &future);
                std.debug.assert(rc == 0 or rc == std.os.system.ETIMEDOUT);
                defer self.value = null;
                return self.value;
            }
        }

        pub fn putOverwrite(self: *Self, value: T) void {
            self.value = value;
            self.cond.impl.signal();
        }
    };
}
