const std = @import("std");
const json_std = @import("json/std.zig");

const debug_buffer = std.builtin.mode == .Debug;

pub fn stream(reader: anytype) Stream(@TypeOf(reader)) {
    return .{
        .reader = reader,
        .parser = json_std.StreamingParser.init(),

        .element_number = 0,
        .parse_failure = null,

        ._root = null,
        ._debug_cursor = null,
        ._debug_buffer = if (debug_buffer)
            std.fifo.LinearFifo(u8, .{ .Static = 0x100 }).init()
        else {},
    };
}

pub fn Stream(comptime Reader: type) type {
    return struct {
        const Self = @This();

        reader: Reader,
        parser: json_std.StreamingParser,

        element_number: usize,
        parse_failure: ?ParseFailure,

        _root: ?Element,
        _debug_cursor: ?usize,
        _debug_buffer: if (debug_buffer)
            std.fifo.LinearFifo(u8, .{ .Static = 0x100 })
        else
            void,

        const ParseFailure = union(enum) {
            wrong_element: struct { wanted: ElementType, actual: ElementType },
        };

        const ElementType = enum {
            Object, Array, String, Number, Boolean, Null
        };

        const Error = Reader.Error || json_std.StreamingParser.Error || error{
            WrongElementType,
            UnexpectedEndOfJson,
        };

        pub const Element = struct {
            ctx: *Self,
            kind: ElementType,

            first_char: u8,
            element_number: usize,
            stack_level: u8,

            fn init(ctx: *Self) Error!?Element {
                ctx.assertState(.{ .ValueBegin, .ValueBeginNoClosing, .TopLevelBegin });

                const start_state = ctx.parser.state;

                var byte: u8 = undefined;
                const kind: ElementType = blk: {
                    while (true) {
                        byte = try ctx.nextByte();

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
                                .Number, .NumberMaybeDotOrExponent, .NumberMaybeDigitOrDotOrExponent => break :blk .Number,
                                .TrueLiteral1, .FalseLiteral1 => break :blk .Boolean,
                                .NullLiteral1 => break :blk .Null,
                                else => ctx.assertFailure("Element unrecognized: {}", .{ctx.parser.state}),
                            }
                        }
                    }
                };
                ctx.element_number += 1;
                return Element{
                    .ctx = ctx,
                    .kind = kind,
                    .first_char = byte,
                    .element_number = ctx.element_number,
                    .stack_level = ctx.parser.stack_used,
                };
            }

            pub fn boolean(self: Element) Error!bool {
                try self.validateType(.Boolean);
                self.ctx.assertState(.{ .TrueLiteral1, .FalseLiteral1 });

                switch ((try self.finalizeToken()).?) {
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
                try self.validateType(.Number);

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
                buffer[0] = self.first_char;

                for (buffer[1..]) |*c, i| {
                    const byte = try self.ctx.nextByte();

                    if (try self.ctx.feed(byte)) |token| {
                        const len = i + 1;
                        self.ctx.assert(token == .Number);
                        self.ctx.assert(token.Number.count == len);
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

                        var i: usize = 0;
                        while (i < buffer.len) : (i += 1) {
                            const byte = try self.ctx.nextByte();

                            if (try self.ctx.feed(byte)) |token| {
                                self.ctx.assert(token == .String);
                                return i;
                            } else if (byte == '\\') {
                                const next = try self.ctx.nextByte();
                                self.ctx.assert((try self.ctx.feed(next)) == null);

                                buffer[i] = switch (next) {
                                    '"' => '"',
                                    '/' => '/',
                                    '\\' => '\\',
                                    'n' => '\n',
                                    'r' => '\r',
                                    't' => '\t',
                                    'b' => 0x08, // backspace
                                    'f' => 0x0C, // form feed
                                    'u' => {
                                        var hexes: [4]u8 = undefined;
                                        for (hexes) |*hex| {
                                            hex.* = try self.ctx.nextByte();
                                            self.ctx.assert((try self.ctx.feed(hex.*)) == null);
                                        }
                                        const MASK = 0b111111;
                                        const charpoint = std.fmt.parseInt(u16, &hexes, 16) catch unreachable;
                                        switch (charpoint) {
                                            0...0x7F => buffer[i] = @intCast(u8, charpoint),
                                            0x80...0x07FF => {
                                                buffer[i] = 0xC0 | @intCast(u8, charpoint >> 6);
                                                i += 1;
                                                buffer[i] = 0x80 | @intCast(u8, charpoint & MASK);
                                            },
                                            0x0800...0xFFFF => {
                                                buffer[i] = 0xE0 | @intCast(u8, charpoint >> 12);
                                                i += 1;
                                                buffer[i] = 0x80 | @intCast(u8, charpoint >> 6 & MASK);
                                                i += 1;
                                                buffer[i] = 0x80 | @intCast(u8, charpoint & MASK);
                                            },
                                        }
                                        continue;
                                    },
                                    // should have been handled by the internal parser
                                    else => unreachable,
                                };
                            } else {
                                buffer[i] = byte;
                            }
                        }

                        return buffer.len;
                    }
                }).read,
            );

            pub fn stringReader(self: Element) Error!StringReader {
                try self.validateType(.String);

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
                try self.validateType(.Array);

                // This array has been closed out.
                // TODO: evaluate to see if this is actually robust
                if (self.ctx.parser.stack_used < self.stack_level) {
                    return null;
                }

                // Scan for next element
                while (self.ctx.parser.state == .ValueEnd) {
                    if (try self.ctx.feed(try self.ctx.nextByte())) |token| {
                        self.ctx.assert(token == .ArrayEnd);
                        return null;
                    }
                }

                return try Element.init(self.ctx);
            }

            fn ObjectMatchUnion(comptime TagType: type) type {
                comptime var union_fields: []const std.builtin.TypeInfo.UnionField = &.{};
                inline for (std.meta.fields(TagType)) |field| {
                    union_fields = union_fields ++ [_]std.builtin.TypeInfo.UnionField{.{
                        .name = field.name,
                        .field_type = Element,
                        .alignment = @alignOf(Element),
                    }};
                }

                const Tagged = union(enum) { temp };
                var info = @typeInfo(Tagged);
                info.Union.tag_type = TagType;
                info.Union.fields = union_fields;
                return @Type(info);
            }

            pub fn objectMatchUnion(self: Element, comptime Enum: type) !?ObjectMatchUnion(Enum) {
                comptime var string_keys: []const []const u8 = &.{};
                inline for (std.meta.fields(Enum)) |field| {
                    string_keys = string_keys ++ [_][]const u8{field.name};
                }

                const raw_match = (try self.objectMatchAny(string_keys)) orelse return null;
                inline for (string_keys) |key| {
                    if (std.mem.eql(u8, key, raw_match.key)) {
                        return @unionInit(ObjectMatchUnion(Enum), key, raw_match.value);
                    }
                }
                unreachable;
            }

            const ObjectMatchString = struct {
                key: []const u8,
                value: Element,
            };

            pub fn objectMatch(self: Element, key: []const u8) Error!?ObjectMatchString {
                return self.objectMatchAny(&[_][]const u8{key});
            }

            pub fn objectMatchAny(self: Element, keys: []const []const u8) Error!?ObjectMatchString {
                try self.validateType(.Object);

                while (true) {
                    // This object has been closed out.
                    // TODO: evaluate to see if this is actually robust
                    if (self.ctx.parser.stack_used < self.stack_level) {
                        return null;
                    }

                    // Scan for next element
                    while (self.ctx.parser.state == .ValueEnd) {
                        if (try self.ctx.feed(try self.ctx.nextByte())) |token| {
                            self.ctx.assert(token == .ObjectEnd);
                            return null;
                        }
                    }

                    const key_element = (try Element.init(self.ctx)) orelse return null;
                    self.ctx.assert(key_element.kind == .String);

                    const key_match = try key_element.stringFind(keys);

                    // Skip over the colon
                    while (self.ctx.parser.state == .ObjectSeparator) {
                        _ = try self.ctx.feed(try self.ctx.nextByte());
                    }

                    if (key_match) |key| {
                        // Match detected
                        return ObjectMatchString{
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
                self.ctx.assert(self.kind == .String);

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
                            self.ctx.assert(token == .String);
                            string_complete = true;
                            if (tail == check.len) {
                                return check;
                            }
                        }
                    }
                }

                if (!string_complete) {
                    const token = try self.finalizeToken();
                    self.ctx.assert(token.? == .String);
                }
                return null;
            }

            fn checkOptional(self: Element) !bool {
                if (self.kind != .Null) return false;
                self.ctx.assertState(.{.NullLiteral1});

                _ = try self.finalizeToken();
                return true;
            }

            fn validateType(self: Element, wanted: ElementType) error{WrongElementType}!void {
                if (self.kind != wanted) {
                    self.ctx.parse_failure = ParseFailure{
                        .wrong_element = .{ .wanted = wanted, .actual = self.kind },
                    };
                    return error.WrongElementType;
                }
            }

            /// Dump the rest of this element into a writer.
            /// Warning: this consumes the stream contents.
            pub fn debugDump(self: Element, writer: anytype) !void {
                const Context = struct {
                    element: Element,
                    writer: @TypeOf(writer),

                    pub fn feed(s: @This(), byte: u8) !?json_std.Token {
                        try s.writer.writeByte(byte);
                        return try s.element.ctx.feed(byte);
                    }
                };
                _ = try self.finalizeTokenWithCustomFeeder(Context{ .element = self, .writer = writer });
            }

            pub fn finalizeToken(self: Element) Error!?json_std.Token {
                return self.finalizeTokenWithCustomFeeder(self.ctx);
            }

            fn finalizeTokenWithCustomFeeder(self: Element, feeder: anytype) !?json_std.Token {
                switch (self.kind) {
                    .Boolean, .Null, .Number, .String => {
                        self.ctx.assert(self.element_number == self.ctx.element_number);

                        switch (self.ctx.parser.state) {
                            .ValueEnd, .TopLevelEnd, .ValueBeginNoClosing => return null,
                            else => {},
                        }
                    },
                    .Array, .Object => {
                        if (self.ctx.parser.stack_used == self.stack_level - 1) {
                            // Assert the parser state
                            return null;
                        } else {
                            self.ctx.assert(self.ctx.parser.stack_used >= self.stack_level);
                        }
                    },
                }

                while (true) {
                    const byte = try self.ctx.nextByte();
                    if (try feeder.feed(byte)) |token| {
                        switch (self.kind) {
                            .Boolean => self.ctx.assert(token == .True or token == .False),
                            .Null => self.ctx.assert(token == .Null),
                            .Number => self.ctx.assert(token == .Number),
                            .String => self.ctx.assert(token == .String),
                            .Array => {
                                if (self.ctx.parser.stack_used >= self.stack_level) {
                                    continue;
                                }
                                // Number followed by ArrayEnd generates two tokens at once
                                // causing raw token assertion to be unreliable.
                                self.ctx.assert(byte == ']');
                                return .ArrayEnd;
                            },
                            .Object => {
                                if (self.ctx.parser.stack_used >= self.stack_level) {
                                    continue;
                                }
                                // Number followed by ObjectEnd generates two tokens at once
                                // causing raw token assertion to be unreliable.
                                self.ctx.assert(byte == '}');
                                return .ObjectEnd;
                            },
                        }
                        return token;
                    }
                }
            }
        };

        pub fn root(self: *Self) Error!Element {
            if (self._root == null) {
                self._root = (try Element.init(self)).?;
            }
            return self._root.?;
        }

        fn assertState(ctx: *Self, valids: anytype) void {
            inline for (valids) |valid| {
                if (ctx.parser.state == valid) {
                    return;
                }
            }
            ctx.assertFailure("Unexpected state: {s}", .{ctx.parser.state});
        }

        fn assert(ctx: *Self, cond: bool) void {
            if (!cond) {
                std.debug.print("{}", ctx.debugInfo());
                unreachable;
            }
        }

        fn assertFailure(ctx: *Self, comptime fmt: []const u8, args: anytype) void {
            std.debug.print("{}", .{ctx.debugInfo()});
            if (std.debug.runtime_safety) {
                var buffer: [0x1000]u8 = undefined;
                @panic(std.fmt.bufPrint(&buffer, fmt, args) catch &buffer);
            }
        }

        const DebugInfo = struct {
            ctx: *Self,

            pub fn format(self: DebugInfo, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
                if (debug_buffer) {
                    if (self.ctx._debug_cursor == null) {
                        self.ctx._debug_cursor = 0;

                        var i: usize = 0;
                        while (self.ctx.nextByte()) |byte| {
                            i += 1;
                            if (i > 30) break;
                            switch (byte) {
                                '"', ',', ' ', '\t', '\n' => {
                                    self.ctx._debug_buffer.count -= 1;
                                    break;
                                },
                                else => {},
                            }
                        } else |err| {}
                    }

                    var copy = self.ctx._debug_buffer;
                    const reader = copy.reader();

                    var buf: [0x100]u8 = undefined;
                    const size = try reader.read(&buf);
                    try writer.writeAll(buf[0..size]);
                    try writer.writeByte('\n');
                }
                if (self.ctx.parse_failure) |parse_failure| switch (parse_failure) {
                    .wrong_element => |wrong_element| {
                        try writer.print("WrongElementType - wanted: {s}", .{@tagName(wrong_element.wanted)});
                    },
                };
            }
        };

        pub fn debugInfo(ctx: *Self) DebugInfo {
            return .{ .ctx = ctx };
        }

        fn nextByte(ctx: *Self) Error!u8 {
            const byte = ctx.reader.readByte() catch |err| switch (err) {
                error.EndOfStream => return error.UnexpectedEndOfJson,
                else => |e| return e,
            };

            if (debug_buffer) {
                if (ctx._debug_buffer.writableLength() == 0) {
                    ctx._debug_buffer.discard(1);
                    std.debug.assert(ctx._debug_buffer.writableLength() == 1);
                }
                ctx._debug_buffer.writeAssumeCapacity(&[_]u8{byte});
            }

            return byte;
        }

        // A simpler feed() to enable one liners.
        // token2 can only be close object/array and we don't need it
        fn feed(ctx: *Self, byte: u8) !?json_std.Token {
            var token1: ?json_std.Token = undefined;
            var token2: ?json_std.Token = undefined;
            try ctx.parser.feed(byte, &token1, &token2);
            return token1;
        }
    };
}

fn expectEqual(actual: anytype, expected: ExpectedType(@TypeOf(actual))) void {
    std.testing.expectEqual(expected, actual);
}

fn ExpectedType(comptime ActualType: type) type {
    if (@typeInfo(ActualType) == .Union) {
        return std.meta.Tag(ActualType);
    } else {
        return ActualType;
    }
}

test "boolean" {
    var fbs = std.io.fixedBufferStream("[true]");
    var str = stream(fbs.reader());

    const root = try str.root();
    const element = (try root.arrayNext()).?;
    expectEqual(element.kind, .Boolean);
    expectEqual(try element.boolean(), true);
}

test "null" {
    var fbs = std.io.fixedBufferStream("[null]");
    var str = stream(fbs.reader());

    const root = try str.root();
    const element = (try root.arrayNext()).?;
    expectEqual(element.kind, .Null);
    expectEqual(try element.optionalBoolean(), null);
}

test "integer" {
    {
        var fbs = std.io.fixedBufferStream("[1]");
        var str = stream(fbs.reader());

        const root = try str.root();
        const element = (try root.arrayNext()).?;
        expectEqual(element.kind, .Number);
        expectEqual(try element.number(u8), 1);
    }
    {
        // Technically invalid, but we don't str far enough to find out
        var fbs = std.io.fixedBufferStream("[123,]");
        var str = stream(fbs.reader());

        const root = try str.root();
        const element = (try root.arrayNext()).?;
        expectEqual(element.kind, .Number);
        expectEqual(try element.number(u8), 123);
    }
    {
        var fbs = std.io.fixedBufferStream("[-128]");
        var str = stream(fbs.reader());

        const root = try str.root();
        const element = (try root.arrayNext()).?;
        expectEqual(element.kind, .Number);
        expectEqual(try element.number(i8), -128);
    }
    {
        var fbs = std.io.fixedBufferStream("[456]");
        var str = stream(fbs.reader());

        const root = try str.root();
        const element = (try root.arrayNext()).?;
        expectEqual(element.kind, .Number);
        expectEqual(element.number(u8), error.Overflow);
    }
}

test "float" {
    {
        var fbs = std.io.fixedBufferStream("[1.125]");
        var str = stream(fbs.reader());

        const root = try str.root();
        const element = (try root.arrayNext()).?;
        expectEqual(element.kind, .Number);
        expectEqual(try element.number(f32), 1.125);
    }
    {
        // Technically invalid, but we don't str far enough to find out
        var fbs = std.io.fixedBufferStream("[2.5,]");
        var str = stream(fbs.reader());

        const root = try str.root();
        const element = (try root.arrayNext()).?;
        expectEqual(element.kind, .Number);
        expectEqual(try element.number(f64), 2.5);
    }
    {
        var fbs = std.io.fixedBufferStream("[-1]");
        var str = stream(fbs.reader());

        const root = try str.root();
        const element = (try root.arrayNext()).?;
        expectEqual(element.kind, .Number);
        expectEqual(try element.number(f64), -1);
    }
    {
        var fbs = std.io.fixedBufferStream("[1e64]");
        var str = stream(fbs.reader());

        const root = try str.root();
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
        var str = stream(fbs.reader());

        const element = try str.root();
        expectEqual(element.kind, .String);
        var buffer: [100]u8 = undefined;
        std.testing.expectEqualStrings("hello world", try element.stringBuffer(&buffer));
    }
}

test "string escapes" {
    {
        var fbs = std.io.fixedBufferStream(
            \\"hello\nworld\t"
        );
        var str = stream(fbs.reader());

        const element = try str.root();
        expectEqual(element.kind, .String);
        var buffer: [100]u8 = undefined;
        std.testing.expectEqualStrings("hello\nworld\t", try element.stringBuffer(&buffer));
    }
}

test "string unicode escape" {
    {
        var fbs = std.io.fixedBufferStream(
            \\"\u0024"
        );
        var str = stream(fbs.reader());

        const element = try str.root();
        expectEqual(element.kind, .String);
        var buffer: [100]u8 = undefined;
        std.testing.expectEqualStrings("$", try element.stringBuffer(&buffer));
    }
    {
        var fbs = std.io.fixedBufferStream(
            \\"\u00A2"
        );
        var str = stream(fbs.reader());

        const element = try str.root();
        expectEqual(element.kind, .String);
        var buffer: [100]u8 = undefined;
        std.testing.expectEqualStrings("¢", try element.stringBuffer(&buffer));
    }
    {
        var fbs = std.io.fixedBufferStream(
            \\"\u0939"
        );
        var str = stream(fbs.reader());

        const element = try str.root();
        expectEqual(element.kind, .String);
        var buffer: [100]u8 = undefined;
        std.testing.expectEqualStrings("ह", try element.stringBuffer(&buffer));
    }
    {
        var fbs = std.io.fixedBufferStream(
            \\"\u20AC"
        );
        var str = stream(fbs.reader());

        const element = try str.root();
        expectEqual(element.kind, .String);
        var buffer: [100]u8 = undefined;
        std.testing.expectEqualStrings("€", try element.stringBuffer(&buffer));
    }
    {
        var fbs = std.io.fixedBufferStream(
            \\"\uD55C"
        );
        var str = stream(fbs.reader());

        const element = try str.root();
        expectEqual(element.kind, .String);
        var buffer: [100]u8 = undefined;
        std.testing.expectEqualStrings("한", try element.stringBuffer(&buffer));
    }
}

test "empty array" {
    var fbs = std.io.fixedBufferStream("[]");
    var str = stream(fbs.reader());

    const root = try str.root();
    expectEqual(root.kind, .Array);

    expectEqual(try root.arrayNext(), null);
}

test "array of simple values" {
    var fbs = std.io.fixedBufferStream("[false, true, null]");
    var str = stream(fbs.reader());

    const root = try str.root();
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
    var str = stream(fbs.reader());

    const root = try str.root();
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
    var str = stream(fbs.reader());

    const root = try str.root();
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

test "array early finalize" {
    var fbs = std.io.fixedBufferStream(
        \\[1, 2, 3]
    );
    var str = stream(fbs.reader());

    const root = try str.root();
    while (try root.arrayNext()) |_| {
        _ = try root.finalizeToken();
    }
}

test "objects ending in number" {
    var fbs = std.io.fixedBufferStream(
        \\[{"id":0},{"id": 1}, {"id": 2}]
    );
    var str = stream(fbs.reader());

    const root = try str.root();
    while (try root.arrayNext()) |obj| {
        if (try obj.objectMatch("banana")) |_| {
            std.debug.panic("How did this match?", .{});
        }
    }
}

test "empty object" {
    var fbs = std.io.fixedBufferStream("{}");
    var str = stream(fbs.reader());

    const root = try str.root();
    expectEqual(root.kind, .Object);

    expectEqual(try root.objectMatch(""), null);
}

test "object match" {
    var fbs = std.io.fixedBufferStream(
        \\{"foo": true, "bar": false}
    );
    var str = stream(fbs.reader());

    const root = try str.root();
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
    var str = stream(fbs.reader());

    const root = try str.root();
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

test "object match union" {
    var fbs = std.io.fixedBufferStream(
        \\{"foo": true, "foobar": false, "bar": null}
    );
    var str = stream(fbs.reader());

    const root = try str.root();
    expectEqual(root.kind, .Object);

    if (try root.objectMatchUnion(enum { foobar, foo })) |match| {
        expectEqual(match.foo.kind, .Boolean);
        expectEqual(try match.foo.boolean(), true);
    } else {
        std.debug.panic("Expected a value", .{});
    }

    if (try root.objectMatchUnion(enum { foo, foobar })) |match| {
        expectEqual(match.foobar.kind, .Boolean);
        expectEqual(try match.foobar.boolean(), false);
    } else {
        std.debug.panic("Expected a value", .{});
    }
}

test "object match not found" {
    var fbs = std.io.fixedBufferStream(
        \\{"foo": [[]], "bar": false, "baz": {}}
    );
    var str = stream(fbs.reader());

    const root = try str.root();
    expectEqual(root.kind, .Object);

    expectEqual(try root.objectMatch("???"), null);
}

fn expectElement(e: anytype) Stream(std.io.FixedBufferStream([]const u8).Reader).Error!void {
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
    var str = stream(fbs.reader());

    const root = try str.root();
    try expectElement(root);
}

test "smoke" {
    try expectValidParseOutput(
        \\[[], [], [[]], [[""], [], [[], 0], null], false]
    );
}

test "finalizeToken on object" {
    var fbs = std.io.fixedBufferStream("{}");
    var str = stream(fbs.reader());

    const root = try str.root();
    expectEqual(root.kind, .Object);

    expectEqual(try root.finalizeToken(), .ObjectEnd);
    expectEqual(try root.finalizeToken(), null);
    expectEqual(try root.finalizeToken(), null);
    expectEqual(try root.finalizeToken(), null);
    expectEqual(try root.finalizeToken(), null);
    expectEqual(try root.finalizeToken(), null);
}

test "finalizeToken on string" {
    var fbs = std.io.fixedBufferStream(
        \\"foo"
    );
    var str = stream(fbs.reader());

    const root = try str.root();
    expectEqual(root.kind, .String);

    std.testing.expect((try root.finalizeToken()).? == .String);
    expectEqual(try root.finalizeToken(), null);
    expectEqual(try root.finalizeToken(), null);
    expectEqual(try root.finalizeToken(), null);
    expectEqual(try root.finalizeToken(), null);
    expectEqual(try root.finalizeToken(), null);
}

test "finalizeToken on number" {
    var fbs = std.io.fixedBufferStream("[[1234,5678]]");
    var str = stream(fbs.reader());

    const root = try str.root();
    expectEqual(root.kind, .Array);

    const inner = (try root.arrayNext()).?;
    expectEqual(inner.kind, .Array);

    const first = (try inner.arrayNext()).?;
    expectEqual(first.kind, .Number);
    std.testing.expect((try first.finalizeToken()).? == .Number);
    expectEqual(try first.finalizeToken(), null);
    expectEqual(try first.finalizeToken(), null);
    expectEqual(try first.finalizeToken(), null);
    expectEqual(try first.finalizeToken(), null);

    const second = (try inner.arrayNext()).?;
    expectEqual(second.kind, .Number);
    std.testing.expect((try second.finalizeToken()).? == .Number);
    expectEqual(try second.finalizeToken(), null);
    expectEqual(try second.finalizeToken(), null);
    expectEqual(try second.finalizeToken(), null);
}
