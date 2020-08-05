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

        const ElementType = enum {
            Object, Array, String, Number, Boolean, Null
        };

        const Element = struct {
            ctx: *Stream,
            kind: ElementType,

            pub fn init(ctx: *Stream) !Element {
                ctx.assertState(.{ .ValueBegin, .ValueBeginNoClosing, .TopLevelBegin });

                const kind: ElementType = blk: {
                    while (true) {
                        var token1: ?std_json.Token = undefined;
                        var token2: ?std_json.Token = undefined;

                        const old_state = ctx.parser.state;
                        try ctx.parser.feed(try ctx.reader.readByte(), &token1, &token2);

                        if (token1) |tok| {
                            switch (tok) {
                                .ArrayBegin => break :blk .Array,
                                .ObjectBegin => break :blk .Object,
                                else => std.debug.panic("Element unrecognized: {}", .{tok}),
                            }
                        }

                        if (ctx.parser.state != old_state) {
                            switch (ctx.parser.state) {
                                .String => break :blk .String,
                                .Number => break :blk .Number,
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

                var token1: ?std_json.Token = null;
                var token2: ?std_json.Token = undefined;

                while (token1 == null) {
                    try self.ctx.parser.feed(try self.ctx.reader.readByte(), &token1, &token2);
                }

                switch (token1.?) {
                    .True => return true,
                    .False => return false,
                    else => std.debug.panic("Token unrecognized: {}", .{token1}),
                }
            }

            pub fn optionalBoolean(self: Element) !?bool {
                if (self.kind != .Boolean and self.kind != .Null) {
                    return error.WrongElementType;
                }
                self.ctx.assertState(.{ .TrueLiteral1, .FalseLiteral1, .NullLiteral1 });

                var token1: ?std_json.Token = null;
                var token2: ?std_json.Token = undefined;

                while (token1 == null) {
                    try self.ctx.parser.feed(try self.ctx.reader.readByte(), &token1, &token2);
                }

                switch (token1.?) {
                    .True => return true,
                    .False => return false,
                    .Null => return null,
                    else => std.debug.panic("Token unrecognized: {}", .{token1}),
                }
            }

            pub fn arrayNext(self: Element) !?Element {
                if (self.kind != .Array) {
                    return error.WrongElementType;
                }

                switch (self.ctx.parser.state) {
                    .ValueBegin => {},
                    .ValueEnd => {
                        while (true) {
                            var token1: ?std_json.Token = undefined;
                            var token2: ?std_json.Token = undefined;

                            try self.ctx.parser.feed(try self.ctx.reader.readByte(), &token1, &token2);

                            if (token1) |tok| {
                                switch (tok) {
                                    .ArrayEnd => return null,
                                    else => std.debug.panic("Token unrecognized: {}", .{token1}),
                                }
                            }

                            if (self.ctx.parser.state == .ValueBeginNoClosing) {
                                return try Element.init(self.ctx);
                            }
                        }
                    },
                    else => std.debug.panic("State unrecognized: {}", .{self.ctx.parser.state}),
                }

                return try Element.init(self.ctx);
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
    };
}

fn expectEqual(actual: anytype, expected: @TypeOf(actual)) void {
    std.testing.expectEqual(expected, actual);
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
