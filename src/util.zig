const std = @import("std");
const std_json = @import("std-json.zig");

pub fn streamJson(reader: anytype) StreamJson(@TypeOf(reader)) {
    return .{
        .reader = reader,
        .parser = std_json.StreamingParser.init(),
        ._root = null,
    };
}

pub fn StreamJson(comptime Reader: type) type {
    return struct {
        const Stream = @This();

        reader: Reader,
        parser: std_json.StreamingParser,
        _root: ?Element,

        const ElementType = union(enum) {
            Object: void,
            Array: void,
            String: void,
            Number: struct { first_char: u8 },
            Boolean: void,
            Null: void,
        };

        const Element = struct {
            ctx: *Stream,
            kind: ElementType,

            pub fn init(ctx: *Stream) !Element {
                ctx.assertState(.{ .ValueBegin, .ValueBeginNoClosing, .TopLevelBegin });

                const start_state = ctx.parser.state;
                const kind: ElementType = blk: {
                    while (true) {
                        const byte = try ctx.reader.readByte();

                        if (try ctx.feed(byte)) |token| {
                            switch (token) {
                                .ArrayBegin => break :blk .Array,
                                .ObjectBegin => break :blk .Object,
                                else => std.debug.panic("Element unrecognized: {}", .{token}),
                            }
                        }

                        if (ctx.parser.state != start_state) {
                            switch (ctx.parser.state) {
                                .String => break :blk .String,
                                .Number, .NumberMaybeDigitOrDotOrExponent => break :blk .{ .Number = .{ .first_char = byte } },
                                .TrueLiteral1 => break :blk .Boolean,
                                .FalseLiteral1 => break :blk .Boolean,
                                .NullLiteral1 => break :blk .Null,
                                else => std.debug.panic("Element unrecognized: {}", .{ctx.parser.state}),
                            }
                        }
                    }
                };
                return Element{ .ctx = ctx, .kind = kind };
            }

            pub fn boolean(self: Element) !bool {
                if (self.kind != .Boolean) {
                    return error.WrongElementType;
                }
                self.ctx.assertState(.{ .TrueLiteral1, .FalseLiteral1 });

                switch (try self.finalizeToken()) {
                    .True => return true,
                    .False => return false,
                    else => |token| std.debug.panic("Token unrecognized: {}", .{token}),
                }
            }

            pub fn optionalBoolean(self: Element) !?bool {
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

                // +1 for converting floor -> ceil
                // +1 for negative sign
                // +1 for simplifying terminating character detection
                const max_digits = std.math.log10(std.math.maxInt(T)) + 3;
                var buffer: [max_digits]u8 = undefined;

                // Handle first byte manually
                buffer[0] = self.kind.Number.first_char;

                for (buffer[1..]) |*c, i| {
                    const byte = try self.ctx.reader.readByte();

                    if (try self.ctx.feed(byte)) |token| {
                        const len = i + 1;
                        std.debug.assert(token == .Number);
                        std.debug.assert(token.Number.count == len);
                        return try std.fmt.parseInt(T, buffer[0..len], 10);
                    } else {
                        c.* = byte;
                    }
                }

                return error.Overflow;
            }

            pub fn stringBuffer(self: Element, buffer: []u8) ![]u8 {
                if (self.kind != .String) {
                    return error.WrongElementType;
                }

                for (buffer) |*c, i| {
                    const byte = try self.ctx.reader.readByte();

                    if (try self.ctx.feed(byte)) |token| {
                        std.debug.assert(token == .String);
                        std.debug.assert(token.String.count == i);
                        return buffer[0..i];
                    } else {
                        c.* = byte;
                    }
                }

                return error.NoSpaceLeft;
            }

            pub fn arrayNext(self: Element) !?Element {
                if (self.kind != .Array) {
                    return error.WrongElementType;
                }

                if (self.ctx.parser.state == .TopLevelEnd) {
                    return null;
                }
                while (self.ctx.parser.state == .ValueEnd) {
                    if (try self.ctx.feed(try self.ctx.reader.readByte())) |token| {
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
                if (self.kind != .Object) {
                    return error.WrongElementType;
                }

                if (self.ctx.parser.state == .TopLevelEnd) {
                    return null;
                }
                while (self.ctx.parser.state == .ValueEnd) {
                    if (try self.ctx.feed(try self.ctx.reader.readByte())) |token| {
                        std.debug.assert(token == .ObjectEnd);
                        return null;
                    }
                }

                const key_element = try Element.init(self.ctx);
                std.debug.assert(key_element.kind == .String);

                for (key) |char| {
                    const byte = try self.ctx.reader.readByte();
                    _ = try self.ctx.feed(byte);
                    if (char != byte) {
                        break;
                    }
                } else {
                    if (try self.ctx.feed(try self.ctx.reader.readByte())) |token| {
                        std.debug.assert(token == .String);

                        // Skip over the colon
                        while (self.ctx.parser.state == .ObjectSeparator) {
                            _ = try self.ctx.feed(try self.ctx.reader.readByte());
                        }

                        // Match detected
                        return ObjectMatch{
                            .key = key,
                            .value = try Element.init(self.ctx),
                        };
                    }
                }

                const key_token = try key_element.finalizeToken();
                std.debug.assert(key_token == .String);

                // Skip over value as well

                return null;
            }

            fn checkOptional(self: Element) !bool {
                if (self.kind != .Null) return false;
                self.ctx.assertState(.{.NullLiteral1});

                const token = try self.finalizeToken();
                if (token != .Null) {
                    std.debug.panic("Token unrecognized: {}", .{token});
                }
                return true;
            }

            fn finalizeToken(self: Element) !std_json.Token {
                while (true) {
                    if (try self.ctx.feed(try self.ctx.reader.readByte())) |token| {
                        return token;
                    }
                }
            }
        };

        pub fn root(self: *Stream) !Element {
            if (self._root == null) {
                self._root = try Element.init(self);
            }
            return self._root.?;
        }

        fn assertState(ctx: Stream, valids: anytype) void {
            inline for (valids) |valid| {
                if (ctx.parser.state == valid) {
                    return;
                }
            }
            std.debug.panic("Unexpected state: {}", .{ctx.parser.state});
        }

        // A simpler feed() to enable one liners.
        // token2 can only be close object/array and we don't need it
        fn feed(ctx: *Stream, byte: u8) !?std_json.Token {
            var token1: ?std_json.Token = undefined;
            var token2: ?std_json.Token = undefined;
            try ctx.parser.feed(byte, &token1, &token2);
            return token1;
        }
    };
}

fn expectEqual(actual: anytype, expected: @TypeOf(actual)) void {
    std.testing.expectEqual(expected, actual);
}

test "boolean" {
    var fba = std.io.fixedBufferStream("[true]");
    var stream = streamJson(fba.reader());

    const root = try stream.root();
    const element = (try root.arrayNext()).?;
    expectEqual(element.kind, .Boolean);
    expectEqual(try element.boolean(), true);
}

test "null" {
    var fba = std.io.fixedBufferStream("[null]");
    var stream = streamJson(fba.reader());

    const root = try stream.root();
    const element = (try root.arrayNext()).?;
    expectEqual(element.kind, .Null);
    expectEqual(try element.optionalBoolean(), null);
}

test "number" {
    {
        var fba = std.io.fixedBufferStream("[1]");
        var stream = streamJson(fba.reader());

        const root = try stream.root();
        const element = (try root.arrayNext()).?;
        // expectEqual(element.kind, .Number);
        expectEqual(try element.number(u8), 1);
    }
    {
        // Technically invalid, but we don't stream far enough to find out
        var fba = std.io.fixedBufferStream("[123,]");
        var stream = streamJson(fba.reader());

        const root = try stream.root();
        const element = (try root.arrayNext()).?;
        // expectEqual(element.kind, .Number);
        expectEqual(try element.number(u8), 123);
    }
    {
        var fba = std.io.fixedBufferStream("[-128]");
        var stream = streamJson(fba.reader());

        const root = try stream.root();
        const element = (try root.arrayNext()).?;
        // expectEqual(element.kind, .Number);
        expectEqual(try element.number(i8), -128);
    }
    {
        var fba = std.io.fixedBufferStream("[456]");
        var stream = streamJson(fba.reader());

        const root = try stream.root();
        const element = (try root.arrayNext()).?;
        // expectEqual(element.kind, .Number);
        expectEqual(element.number(u8), error.Overflow);
    }
}

test "string" {
    {
        var fba = std.io.fixedBufferStream(
            \\"hello world"
        );
        var stream = streamJson(fba.reader());

        const element = try stream.root();
        expectEqual(element.kind, .String);
        var buffer: [100]u8 = undefined;
        std.testing.expectEqualSlices(u8, "hello world", try element.stringBuffer(&buffer));
    }
}

test "array of simple values" {
    var fba = std.io.fixedBufferStream("[false, true, null]");
    var stream = streamJson(fba.reader());

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
    var fba = std.io.fixedBufferStream("[1, 2, -3]");
    var stream = streamJson(fba.reader());

    const root = try stream.root();
    expectEqual(root.kind, .Array);

    if (try root.arrayNext()) |item| {
        // expectEqual(item.kind, .Number);
        expectEqual(try item.number(u8), 1);
    } else {
        std.debug.panic("Expected a value", .{});
    }

    if (try root.arrayNext()) |item| {
        // expectEqual(item.kind, .Number);
        expectEqual(try item.number(u8), 2);
    } else {
        std.debug.panic("Expected a value", .{});
    }

    if (try root.arrayNext()) |item| {
        // expectEqual(item.kind, .Number);
        expectEqual(try item.number(i8), -3);
    } else {
        std.debug.panic("Expected a value", .{});
    }

    expectEqual(try root.arrayNext(), null);
}

test "array of strings" {
    var fba = std.io.fixedBufferStream(
        \\["hello", "world"]);
    );
    var stream = streamJson(fba.reader());

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

test "object match" {
    var fba = std.io.fixedBufferStream(
        \\{"foo": true, "bar": false}
    );
    var stream = streamJson(fba.reader());

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
