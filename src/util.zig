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

pub const TimeoutStream = struct {
    underlying_stream: std.net.Stream,
    expiration: ?std.os.timespec = null,

    pub fn init(stream: std.net.Stream, duration_ms: u32) !TimeoutStream {
        if (duration_ms == 0) {
            return TimeoutStream{ .underlying_stream = stream };
        }

        var now: std.os.timespec = undefined;
        std.os.clock_gettime(std.os.CLOCK.REALTIME, &now) catch |err| switch (err) {
            error.UnsupportedClock => unreachable,
            else => |e| return e,
        };

        const raw_ns = now.tv_nsec + @as(i64, duration_ms % 1000) * 1_000_000;

        return TimeoutStream{
            .underlying_stream = stream,
            .expiration = std.os.timespec{
                .tv_sec = now.tv_sec + duration_ms / 1000 + @divFloor(raw_ns, 1_000_000_000),
                .tv_nsec = @mod(raw_ns, 1_000_000_000),
            },
        };
    }

    pub fn close(self: TimeoutStream) void {
        self.underlying_stream.close();
    }

    pub const ReadError = std.net.Stream.ReadError || error{Timeout};
    pub const WriteError = std.net.Stream.WriteError || error{Timeout};

    pub const Reader = std.io.Reader(TimeoutStream, ReadError, read);
    pub const Writer = std.io.Writer(TimeoutStream, WriteError, write);

    pub fn reader(self: TimeoutStream) Reader {
        return .{ .context = self };
    }

    pub fn writer(self: TimeoutStream) Writer {
        return .{ .context = self };
    }

    const PollFdEvents = std.meta.fieldInfo(std.os.pollfd, .events).field_type;
    fn pollWait(self: TimeoutStream, events: PollFdEvents) !void {
        if (self.expiration) |expiration| {
            var polling = [_]std.os.pollfd{.{
                .fd = self.underlying_stream.handle,
                .events = events,
                .revents = 0,
            }};

            var now: std.os.timespec = undefined;
            std.os.clock_gettime(std.os.CLOCK.REALTIME, &now) catch |err| switch (err) {
                error.UnsupportedClock => unreachable,
                else => |e| return e,
            };

            const timeout_ms = std.math.cast(u31, (expiration.tv_sec - now.tv_sec) * 1_000 + @divFloor(expiration.tv_nsec - now.tv_nsec, 1_000_000)) orelse return error.Timeout;
            const poll_result = std.os.poll(&polling, timeout_ms) catch |err| return switch (err) {
                error.NetworkSubsystemFailed => error.Timeout,
                else => |e| e,
            };
            if (poll_result == 0) {
                return error.Timeout;
            }
        }
    }

    pub fn read(self: TimeoutStream, buffer: []u8) ReadError!usize {
        try self.pollWait(std.os.POLL.IN);
        return self.underlying_stream.read(buffer);
    }

    pub fn write(self: TimeoutStream, buffer: []const u8) WriteError!usize {
        try self.pollWait(std.os.POLL.OUT);
        return self.underlying_stream.write(buffer);
    }
};
