const std = @import("std");
const std_json = @import("std-json.zig");

const debug_buffer = std.builtin.mode == .Debug;

pub fn streamJson(reader: anytype) StreamJson(@TypeOf(reader)) {
    return .{
        .reader = reader,
        .parser = std_json.StreamingParser.init(),

        .element_number = 0,

        ._root = null,
        ._debug_buffer = if (debug_buffer)
            std.fifo.LinearFifo(u8, .{ .Static = 0x100 }).init()
        else {},
    };
}

pub fn StreamJson(comptime Reader: type) type {
    return struct {
        const Stream = @This();

        reader: Reader,
        parser: std_json.StreamingParser,

        element_number: usize,

        _root: ?Element,
        _debug_buffer: if (debug_buffer)
            std.fifo.LinearFifo(u8, .{ .Static = 0x100 })
        else
            void,

        const ElementType = union(enum) {
            Object: void,
            Array: void,
            String: void,
            Number: struct { first_char: u8 },
            Boolean: void,
            Null: void,
        };

        const Error = Reader.Error || std_json.StreamingParser.Error || error{
            WrongElementType,
            UnexpectedEndOfJson,
        };

        pub const Element = struct {
            ctx: *Stream,
            kind: ElementType,

            element_number: usize,
            stack_level: u8,

            fn init(ctx: *Stream) Error!?Element {
                ctx.assertState(.{ .ValueBegin, .ValueBeginNoClosing, .TopLevelBegin });

                const start_state = ctx.parser.state;
                const kind: ElementType = blk: {
                    while (true) {
                        const byte = try ctx.nextByte();

                        if (try ctx.feed(byte)) |token| {
                            switch (token) {
                                .ArrayBegin => break :blk .Array,
                                .ObjectBegin => break :blk .Object,
                                .ArrayEnd, .ObjectEnd => return null,
                                else => ctx.assertFailure("Element unrecognized: {}", .{token}),
                            }
                        }

                        if (ctx.parser.state != start_state) {
                            switch (ctx.parser.state) {
                                .String => break :blk .String,
                                .Number, .NumberMaybeDotOrExponent, .NumberMaybeDigitOrDotOrExponent => break :blk .{ .Number = .{ .first_char = byte } },
                                .TrueLiteral1, .FalseLiteral1 => break :blk .Boolean,
                                .NullLiteral1 => break :blk .Null,
                                else => ctx.assertFailure("Element unrecognized: {}", .{ctx.parser.state}),
                            }
                        }
                    }
                };
                ctx.element_number += 1;
                return Element{ .ctx = ctx, .kind = kind, .element_number = ctx.element_number, .stack_level = ctx.parser.stack_used };
            }

            pub fn boolean(self: Element) Error!bool {
                if (self.kind != .Boolean) {
                    return error.WrongElementType;
                }
                self.ctx.assertState(.{ .TrueLiteral1, .FalseLiteral1 });

                switch (try self.finalizeToken()) {
                    .True => return true,
                    .False => return false,
                    else => unreachable,
                }
            }

            pub fn optionalBoolean(self: Element) Error!?bool {
                if (try self.checkOptional()) {
                    return null;
                } else {
                    return try self.boolean();
                }
            }

            pub fn optionalNumber(self: Element, comptime T: type) !?T {
                if (try self.checkOptional()) {
                    return null;
                } else {
                    return try self.number(T);
                }
            }

            pub fn number(self: Element, comptime T: type) !T {
                if (self.kind != .Number) {
                    return error.WrongElementType;
                }

                switch (@typeInfo(T)) {
                    .Int => {
                        // +1 for converting floor -> ceil
                        // +1 for negative sign
                        // +1 for simplifying terminating character detection
                        const max_digits = std.math.log10(std.math.maxInt(T)) + 3;
                        var buffer: [max_digits]u8 = undefined;

                        return try std.fmt.parseInt(T, try self.numberBuffer(&buffer), 10);
                    },
                    .Float => {
                        const max_digits = 0x1000; // Yeah this is a total kludge, but floats are hard. :(
                        var buffer: [max_digits]u8 = undefined;

                        return try std.fmt.parseFloat(T, try self.numberBuffer(&buffer));
                    },
                    else => @compileError("Unsupported number type"),
                }
            }

            fn numberBuffer(self: Element, buffer: []u8) (Error || error{Overflow})![]u8 {
                // Handle first byte manually
                buffer[0] = self.kind.Number.first_char;

                for (buffer[1..]) |*c, i| {
                    const byte = try self.ctx.nextByte();

                    if (try self.ctx.feed(byte)) |token| {
                        const len = i + 1;
                        std.debug.assert(token == .Number);
                        std.debug.assert(token.Number.count == len);
                        return buffer[0..len];
                    } else {
                        c.* = byte;
                    }
                }

                return error.Overflow;
            }

            pub fn stringBuffer(self: Element, buffer: []u8) (Error || error{NoSpaceLeft})![]u8 {
                const reader = try self.stringReader();
                const size = try reader.readAll(buffer);
                return buffer[0..size];
            }

            const StringReader = std.io.Reader(
                Element,
                Error,
                (struct {
                    fn read(self: Element, buffer: []u8) Error!usize {
                        if (self.ctx.parser.state == .ValueEnd or self.ctx.parser.state == .TopLevelEnd) {
                            return 0;
                        }

                        for (buffer) |*c, i| {
                            const byte = try self.ctx.nextByte();

                            if (try self.ctx.feed(byte)) |token| {
                                std.debug.assert(token == .String);
                                return i;
                            } else {
                                c.* = byte;
                            }
                        }

                        return buffer.len;
                    }
                }).read,
            );

            pub fn stringReader(self: Element) Error!StringReader {
                if (self.kind != .String) {
                    return error.WrongElementType;
                }

                return StringReader{ .context = self };
            }

            pub fn optionalStringBuffer(self: Element, buffer: []u8) (Error || error{NoSpaceLeft})!?[]u8 {
                if (try self.checkOptional()) {
                    return null;
                } else {
                    return try self.stringBuffer(buffer);
                }
            }

            pub fn arrayNext(self: Element) Error!?Element {
                if (self.kind != .Array) {
                    return error.WrongElementType;
                }

                if (self.ctx.parser.state == .TopLevelEnd) {
                    return null;
                }

                // Scan for next element
                while (self.ctx.parser.state == .ValueEnd) {
                    if (try self.ctx.feed(try self.ctx.nextByte())) |token| {
                        std.debug.assert(token == .ArrayEnd);
                        return null;
                    }
                }

                return try Element.init(self.ctx);
            }

            const ObjectMatch = struct {
                key: []const u8,
                value: Element,
            };

            pub fn objectMatch(self: Element, key: []const u8) !?ObjectMatch {
                return self.objectMatchAny(&[_][]const u8{key});
            }

            pub fn objectMatchAny(self: Element, keys: []const []const u8) !?ObjectMatch {
                if (self.kind != .Object) {
                    return error.WrongElementType;
                }

                while (true) {
                    if (self.ctx.parser.state == .TopLevelEnd) {
                        return null;
                    }

                    // Scan for next element
                    while (self.ctx.parser.state == .ValueEnd) {
                        if (try self.ctx.feed(try self.ctx.nextByte())) |token| {
                            std.debug.assert(token == .ObjectEnd);
                            return null;
                        }
                    }

                    const key_element = (try Element.init(self.ctx)) orelse return null;
                    std.debug.assert(key_element.kind == .String);

                    const key_match = try key_element.stringFind(keys);

                    // Skip over the colon
                    while (self.ctx.parser.state == .ObjectSeparator) {
                        _ = try self.ctx.feed(try self.ctx.nextByte());
                    }

                    if (key_match) |key| {
                        // Match detected
                        return ObjectMatch{
                            .key = key,
                            .value = (try Element.init(self.ctx)).?,
                        };
                    } else {
                        // Skip over value
                        const value_element = (try Element.init(self.ctx)).?;
                        _ = try value_element.finalizeToken();
                    }
                }
            }

            fn stringFind(self: Element, checks: []const []const u8) !?[]const u8 {
                std.debug.assert(self.kind == .String);

                var last_byte: u8 = undefined;
                var prev_match: []const u8 = &[0]u8{};
                var tail: usize = 0;
                var string_complete = false;

                for (checks) |check| {
                    if (string_complete and std.mem.eql(u8, check, prev_match[0 .. tail - 1])) {
                        return check;
                    }

                    if (tail >= 2 and !std.mem.eql(u8, check[0 .. tail - 2], prev_match[0 .. tail - 2])) {
                        continue;
                    }
                    if (tail >= 1 and (tail - 1 >= check.len or check[tail - 1] != last_byte)) {
                        continue;
                    }

                    prev_match = check;
                    while (!string_complete and tail <= check.len and
                        (tail < 1 or check[tail - 1] == last_byte)) : (tail += 1)
                    {
                        last_byte = try self.ctx.nextByte();
                        if (try self.ctx.feed(last_byte)) |token| {
                            std.debug.assert(token == .String);
                            string_complete = true;
                            if (tail == check.len) {
                                return check;
                            }
                        }
                    }
                }

                if (!string_complete) {
                    const token = try self.finalizeToken();
                    std.debug.assert(token == .String);
                }
                return null;
            }

            fn checkOptional(self: Element) !bool {
                if (self.kind != .Null) return false;
                self.ctx.assertState(.{.NullLiteral1});

                _ = try self.finalizeToken();
                return true;
            }

            pub fn finalizeToken(self: Element) Error!std_json.Token {
                switch (self.kind) {
                    .Boolean, .Null, .Number, .String => {
                        std.debug.assert(self.element_number == self.ctx.element_number);
                    },
                    .Array, .Object => {
                        std.debug.assert(self.ctx.parser.stack_used >= self.stack_level);
                    },
                }

                while (true) {
                    const byte = try self.ctx.nextByte();
                    if (try self.ctx.feed(byte)) |token| {
                        switch (self.kind) {
                            .Boolean => std.debug.assert(token == .True or token == .False),
                            .Null => std.debug.assert(token == .Null),
                            .Number => std.debug.assert(token == .Number),
                            .String => std.debug.assert(token == .String),
                            .Array => {
                                if (self.ctx.parser.stack_used >= self.stack_level) {
                                    continue;
                                }
                                // Number followed by ArrayEnd generates two tokens at once
                                // causing raw token assertion to be unreliable.
                                std.debug.assert(byte == ']');
                                return .ArrayEnd;
                            },
                            .Object => {
                                if (self.ctx.parser.stack_used >= self.stack_level) {
                                    continue;
                                }
                                // Number followed by ObjectEnd generates two tokens at once
                                // causing raw token assertion to be unreliable.
                                std.debug.assert(byte == '}');
                                return .ObjectEnd;
                            },
                        }
                        return token;
                    }
                }
            }
        };

        pub fn root(self: *Stream) Error!Element {
            if (self._root == null) {
                self._root = (try Element.init(self)).?;
            }
            return self._root.?;
        }

        fn assertState(ctx: Stream, valids: anytype) void {
            inline for (valids) |valid| {
                if (ctx.parser.state == valid) {
                    return;
                }
            }
            ctx.assertFailure("Unexpected state: {}", .{ctx.parser.state});
        }

        fn assertFailure(ctx: Stream, comptime fmt: []const u8, args: anytype) void {
            if (debug_buffer) {
                ctx.debugDump(std.io.getStdErr().writer()) catch {};
            }
            if (std.debug.runtime_safety) {
                var buffer: [0x1000]u8 = undefined;
                @panic(std.fmt.bufPrint(&buffer, fmt, args) catch &buffer);
            }
        }

        pub fn debugDump(ctx: Stream, writer: anytype) !void {
            var tmp = ctx._debug_buffer;
            const reader = tmp.reader();

            var buf: [0x100]u8 = undefined;
            const size = try reader.read(&buf);
            try writer.writeAll(buf[0..size]);
            try writer.writeByte('\n');
        }

        fn nextByte(ctx: *Stream) Error!u8 {
            return ctx.reader.readByte() catch |err| switch (err) {
                error.EndOfStream => error.UnexpectedEndOfJson,
                else => |e| e,
            };
        }

        // A simpler feed() to enable one liners.
        // token2 can only be close object/array and we don't need it
        fn feed(ctx: *Stream, byte: u8) !?std_json.Token {
            if (debug_buffer) {
                if (ctx._debug_buffer.writableLength() == 0) {
                    ctx._debug_buffer.discard(1);
                    std.debug.assert(ctx._debug_buffer.writableLength() == 1);
                }
                ctx._debug_buffer.writeAssumeCapacity(&[_]u8{byte});
            }
            var token1: ?std_json.Token = undefined;
            var token2: ?std_json.Token = undefined;
            ctx.parser.feed(byte, &token1, &token2) catch |err| {
                if (debug_buffer) {
                    ctx.debugDump(std.io.getStdErr().writer()) catch {};
                }
                return err;
            };
            return token1;
        }
    };
}

fn expectEqual(actual: anytype, expected: ExpectedType(@TypeOf(actual))) void {
    std.testing.expectEqual(expected, actual);
}

fn ExpectedType(comptime ActualType: type) type {
    if (@typeInfo(ActualType) == .Union) {
        return @TagType(ActualType);
    } else {
        return ActualType;
    }
}

test "boolean" {
    var fbs = std.io.fixedBufferStream("[true]");
    var stream = streamJson(fbs.reader());

    const root = try stream.root();
    const element = (try root.arrayNext()).?;
    expectEqual(element.kind, .Boolean);
    expectEqual(try element.boolean(), true);
}

test "null" {
    var fbs = std.io.fixedBufferStream("[null]");
    var stream = streamJson(fbs.reader());

    const root = try stream.root();
    const element = (try root.arrayNext()).?;
    expectEqual(element.kind, .Null);
    expectEqual(try element.optionalBoolean(), null);
}

test "integer" {
    {
        var fbs = std.io.fixedBufferStream("[1]");
        var stream = streamJson(fbs.reader());

        const root = try stream.root();
        const element = (try root.arrayNext()).?;
        expectEqual(element.kind, .Number);
        expectEqual(try element.number(u8), 1);
    }
    {
        // Technically invalid, but we don't stream far enough to find out
        var fbs = std.io.fixedBufferStream("[123,]");
        var stream = streamJson(fbs.reader());

        const root = try stream.root();
        const element = (try root.arrayNext()).?;
        expectEqual(element.kind, .Number);
        expectEqual(try element.number(u8), 123);
    }
    {
        var fbs = std.io.fixedBufferStream("[-128]");
        var stream = streamJson(fbs.reader());

        const root = try stream.root();
        const element = (try root.arrayNext()).?;
        expectEqual(element.kind, .Number);
        expectEqual(try element.number(i8), -128);
    }
    {
        var fbs = std.io.fixedBufferStream("[456]");
        var stream = streamJson(fbs.reader());

        const root = try stream.root();
        const element = (try root.arrayNext()).?;
        expectEqual(element.kind, .Number);
        expectEqual(element.number(u8), error.Overflow);
    }
}

test "float" {
    {
        var fbs = std.io.fixedBufferStream("[1.125]");
        var stream = streamJson(fbs.reader());

        const root = try stream.root();
        const element = (try root.arrayNext()).?;
        expectEqual(element.kind, .Number);
        expectEqual(try element.number(f32), 1.125);
    }
    {
        // Technically invalid, but we don't stream far enough to find out
        var fbs = std.io.fixedBufferStream("[2.5,]");
        var stream = streamJson(fbs.reader());

        const root = try stream.root();
        const element = (try root.arrayNext()).?;
        expectEqual(element.kind, .Number);
        expectEqual(try element.number(f64), 2.5);
    }
    {
        var fbs = std.io.fixedBufferStream("[-1]");
        var stream = streamJson(fbs.reader());

        const root = try stream.root();
        const element = (try root.arrayNext()).?;
        expectEqual(element.kind, .Number);
        expectEqual(try element.number(f64), -1);
    }
    {
        var fbs = std.io.fixedBufferStream("[1e64]");
        var stream = streamJson(fbs.reader());

        const root = try stream.root();
        const element = (try root.arrayNext()).?;
        expectEqual(element.kind, .Number);
        expectEqual(element.number(f64), 1e64);
    }
}

test "string" {
    {
        var fbs = std.io.fixedBufferStream(
            \\"hello world"
        );
        var stream = streamJson(fbs.reader());

        const element = try stream.root();
        expectEqual(element.kind, .String);
        var buffer: [100]u8 = undefined;
        std.testing.expectEqualSlices(u8, "hello world", try element.stringBuffer(&buffer));
    }
}

test "empty array" {
    var fbs = std.io.fixedBufferStream("[]");
    var stream = streamJson(fbs.reader());

    const root = try stream.root();
    expectEqual(root.kind, .Array);

    expectEqual(try root.arrayNext(), null);
}

test "array of simple values" {
    var fbs = std.io.fixedBufferStream("[false, true, null]");
    var stream = streamJson(fbs.reader());

    const root = try stream.root();
    expectEqual(root.kind, .Array);
    if (try root.arrayNext()) |item| {
        expectEqual(item.kind, .Boolean);
        expectEqual(try item.boolean(), false);
    } else {
        std.debug.panic("Expected a value", .{});
    }

    if (try root.arrayNext()) |item| {
        expectEqual(item.kind, .Boolean);
        expectEqual(try item.boolean(), true);
    } else {
        std.debug.panic("Expected a value", .{});
    }

    if (try root.arrayNext()) |item| {
        expectEqual(item.kind, .Null);
        expectEqual(try item.optionalBoolean(), null);
    } else {
        std.debug.panic("Expected a value", .{});
    }

    expectEqual(try root.arrayNext(), null);
}

test "array of numbers" {
    var fbs = std.io.fixedBufferStream("[1, 2, -3]");
    var stream = streamJson(fbs.reader());

    const root = try stream.root();
    expectEqual(root.kind, .Array);

    if (try root.arrayNext()) |item| {
        expectEqual(item.kind, .Number);
        expectEqual(try item.number(u8), 1);
    } else {
        std.debug.panic("Expected a value", .{});
    }

    if (try root.arrayNext()) |item| {
        expectEqual(item.kind, .Number);
        expectEqual(try item.number(u8), 2);
    } else {
        std.debug.panic("Expected a value", .{});
    }

    if (try root.arrayNext()) |item| {
        expectEqual(item.kind, .Number);
        expectEqual(try item.number(i8), -3);
    } else {
        std.debug.panic("Expected a value", .{});
    }

    expectEqual(try root.arrayNext(), null);
}

test "array of strings" {
    var fbs = std.io.fixedBufferStream(
        \\["hello", "world"]);
    );
    var stream = streamJson(fbs.reader());

    const root = try stream.root();
    expectEqual(root.kind, .Array);

    if (try root.arrayNext()) |item| {
        var buffer: [100]u8 = undefined;
        expectEqual(item.kind, .String);
        std.testing.expectEqualSlices(u8, "hello", try item.stringBuffer(&buffer));
    } else {
        std.debug.panic("Expected a value", .{});
    }

    if (try root.arrayNext()) |item| {
        var buffer: [100]u8 = undefined;
        expectEqual(item.kind, .String);
        std.testing.expectEqualSlices(u8, "world", try item.stringBuffer(&buffer));
    } else {
        std.debug.panic("Expected a value", .{});
    }

    expectEqual(try root.arrayNext(), null);
}

test "empty object" {
    var fbs = std.io.fixedBufferStream("{}");
    var stream = streamJson(fbs.reader());

    const root = try stream.root();
    expectEqual(root.kind, .Object);

    expectEqual(try root.objectMatch(""), null);
}

test "object match" {
    var fbs = std.io.fixedBufferStream(
        \\{"foo": true, "bar": false}
    );
    var stream = streamJson(fbs.reader());

    const root = try stream.root();
    expectEqual(root.kind, .Object);

    if (try root.objectMatch("foo")) |match| {
        std.testing.expectEqualSlices(u8, "foo", match.key);
        var buffer: [100]u8 = undefined;
        expectEqual(match.value.kind, .Boolean);
        expectEqual(try match.value.boolean(), true);
    } else {
        std.debug.panic("Expected a value", .{});
    }

    if (try root.objectMatch("bar")) |match| {
        std.testing.expectEqualSlices(u8, "bar", match.key);
        var buffer: [100]u8 = undefined;
        expectEqual(match.value.kind, .Boolean);
        expectEqual(try match.value.boolean(), false);
    } else {
        std.debug.panic("Expected a value", .{});
    }
}

test "object match any" {
    var fbs = std.io.fixedBufferStream(
        \\{"foo": true, "foobar": false, "bar": null}
    );
    var stream = streamJson(fbs.reader());

    const root = try stream.root();
    expectEqual(root.kind, .Object);

    if (try root.objectMatchAny(&[_][]const u8{ "foobar", "foo" })) |match| {
        std.testing.expectEqualSlices(u8, "foo", match.key);
        var buffer: [100]u8 = undefined;
        expectEqual(match.value.kind, .Boolean);
        expectEqual(try match.value.boolean(), true);
    } else {
        std.debug.panic("Expected a value", .{});
    }

    if (try root.objectMatchAny(&[_][]const u8{ "foo", "foobar" })) |match| {
        std.testing.expectEqualSlices(u8, "foobar", match.key);
        var buffer: [100]u8 = undefined;
        expectEqual(match.value.kind, .Boolean);
        expectEqual(try match.value.boolean(), false);
    } else {
        std.debug.panic("Expected a value", .{});
    }
}

test "object match not found" {
    var fbs = std.io.fixedBufferStream(
        \\{"foo": [[]], "bar": false, "baz": {}}
    );
    var stream = streamJson(fbs.reader());

    const root = try stream.root();
    expectEqual(root.kind, .Object);

    expectEqual(try root.objectMatch("???"), null);
}

fn expectElement(e: anytype) StreamJson(std.io.FixedBufferStream([]const u8).Reader).Error!void {
    switch (e.kind) {
        // TODO: test objects better
        .Object => _ = try e.finalizeToken(),
        .Array => {
            while (try e.arrayNext()) |child| {
                try expectElement(child);
            }
        },
        .String => _ = try e.finalizeToken(),
        // TODO: fix inferred errors
        // .Number => _ = try e.number(u64),
        .Number => _ = try e.finalizeToken(),
        .Boolean => _ = try e.boolean(),
        .Null => _ = try e.optionalBoolean(),
    }
}

fn expectValidParseOutput(input: []const u8) !void {
    var fbs = std.io.fixedBufferStream(input);
    var stream = streamJson(fbs.reader());

    const root = try stream.root();
    try expectElement(root);
}

test "smoke" {
    try expectValidParseOutput(
        \\[[], [], [[]], [[""], [], [[], 0], null], false]
    );
}
/// Super simple "perfect hash" algorithm
/// Only really useful for switching on strings
// TODO: can we auto detect and promote the underlying type?
pub fn Swhash(comptime max_bytes: comptime_int) type {
    const T = std.meta.IntType(false, max_bytes * 8);

    return struct {
        pub fn match(string: []const u8) T {
            return hash(string) orelse std.math.maxInt(T);
        }

        pub fn case(comptime string: []const u8) T {
            return hash(string) orelse @compileError("Cannot hash '" ++ string ++ "'");
        }

        fn hash(string: []const u8) ?T {
            if (string.len > max_bytes) return null;
            var tmp = [_]u8{0} ** max_bytes;
            std.mem.copy(u8, &tmp, string);
            return std.mem.readIntNative(T, &tmp);
        }
    };
}
