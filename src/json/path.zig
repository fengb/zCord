const std = @import("std");
const json = @import("../json.zig");

const PathToken = union(enum) {
    index: u32,
    key: []const u8,

    fn tokenize(string: []const u8) Iterator {
        return .{ .string = string, .index = 0 };
    }

    const Iterator = struct {
        string: []const u8,
        index: usize,

        fn next(self: *Iterator) !?PathToken {
            if (self.index >= self.string.len) return null;

            var token_start = self.index;
            switch (self.string[self.index]) {
                '[' => {
                    self.index += 1;
                    switch (self.string[self.index]) {
                        '\'' => {
                            self.index += 1;
                            const start = self.index;
                            while (self.index < self.string.len) : (self.index += 1) {
                                switch (self.string[self.index]) {
                                    '\\' => return error.InvalidToken,
                                    '\'' => {
                                        defer self.index += 2;
                                        if (self.string[self.index + 1] != ']') {
                                            return error.InvalidToken;
                                        }
                                        return PathToken{ .key = self.string[start..self.index] };
                                    },
                                    else => {},
                                }
                            }
                            return error.InvalidToken;
                        },
                        '0'...'9' => {
                            const start = self.index;
                            while (self.index < self.string.len) : (self.index += 1) {
                                switch (self.string[self.index]) {
                                    '0'...'9' => {},
                                    ']' => {
                                        defer self.index += 1;
                                        return PathToken{ .index = std.fmt.parseInt(u32, self.string[start..self.index], 10) catch unreachable };
                                    },
                                    else => return error.InvalidToken,
                                }
                            }
                            return error.InvalidToken;
                        },
                        else => return error.InvalidToken,
                    }
                },
                'a'...'z', 'A'...'Z', '_', '$' => {
                    const start = self.index;
                    while (self.index < self.string.len) : (self.index += 1) {
                        switch (self.string[self.index]) {
                            'a'...'z', 'A'...'Z', '0'...'9', '_', '$' => {},
                            '.' => {
                                defer self.index += 1;
                                return PathToken{ .key = self.string[start..self.index] };
                            },
                            '[' => return PathToken{ .key = self.string[start..self.index] },
                            else => return error.InvalidToken,
                        }
                    }
                    return PathToken{ .key = self.string[start..self.index] };
                },
                else => return error.InvalidToken,
            }
        }
    };
};

test "PathToken" {
    var iter = PathToken.tokenize("foo.bar.baz");
    std.testing.expectEqualStrings("foo", (try iter.next()).?.key);
    std.testing.expectEqualStrings("bar", (try iter.next()).?.key);
    std.testing.expectEqualStrings("baz", (try iter.next()).?.key);
    std.testing.expectEqual(@as(?PathToken, null), try iter.next());

    iter = PathToken.tokenize("[1][2][3]");
    std.testing.expectEqual(@as(u32, 1), (try iter.next()).?.index);
    std.testing.expectEqual(@as(u32, 2), (try iter.next()).?.index);
    std.testing.expectEqual(@as(u32, 3), (try iter.next()).?.index);
    std.testing.expectEqual(@as(?PathToken, null), try iter.next());

    iter = PathToken.tokenize("['foo']['bar']['baz']");
    std.testing.expectEqualStrings("foo", (try iter.next()).?.key);
    std.testing.expectEqualStrings("bar", (try iter.next()).?.key);
    std.testing.expectEqualStrings("baz", (try iter.next()).?.key);
    std.testing.expectEqual(@as(?PathToken, null), try iter.next());
}

const AstNode = union(enum) {
    atom: struct {
        path: []const u8,
        type: type,
    },
    object: []const Object,
    array: []const Array,

    const Object = struct { key: []const u8, node: AstNode };
    const Array = struct { index: usize, node: AstNode };

    fn atom(comptime path: []const u8, comptime t: type) AstNode {
        return .{ .atom = .{ .path = path, .type = t } };
    }
    fn object(comptime children: []const Object) AstNode {
        return .{ .object = children };
    }
    fn array(comptime children: []const Array) AstNode {
        return .{ .array = children };
    }

    fn init(comptime T: type) AstNode {
        return AstNode.object(&[_]Object{
            .{ .key = "foo", .node = atom("foo", bool) },
            .{ .key = "bar", .node = atom("bar", u32) },
            .{ .key = "baz", .node = atom("baz", []const u8) },
        });
    }

    fn apply(comptime self: AstNode, allocator: ?*std.mem.Allocator, json_element: anytype, result: anytype) !void {
        switch (self) {
            .atom => |at| {
                @field(result, at.path) = switch (at.type) {
                    bool => try json_element.boolean(),
                    []const u8, []u8 => try (try json_element.stringReader()).readAllAlloc(allocator.?, std.math.maxInt(usize)),
                    else => try json_element.number(at.type),
                };
            },
            .object => |obj| {
                comptime var matches: [obj.len][]const u8 = undefined;
                comptime for (obj) |directive, i| {
                    matches[i] = directive.key;
                };
                while (try json_element.objectMatchAny(&matches)) |item| match: {
                    inline for (obj) |directive| {
                        if (std.mem.eql(u8, directive.key, item.key)) {
                            try directive.node.apply(allocator, item.value, result);
                            break :match;
                        }
                    }
                    unreachable;
                }
            },
            .array => |arr| {
                var i: usize = 0;
                while (try json_element.arrayNext()) |item| : (i += 1) {
                    inline for (arr) |child| {
                        if (child.index == i) {
                            try child.node.apply(json_element, result);
                        }
                    }
                }
            },
        }
    }
};

pub fn match(allocator: ?*std.mem.Allocator, json_element: anytype, comptime T: type) !T {
    var result: T = undefined;
    comptime const ast = AstNode.init(T);
    try ast.apply(allocator, json_element, &result);
    return result;
}

pub fn freeMatch(allocator: *std.mem.Allocator, value: anytype) void {
    inline for (std.meta.fields(@TypeOf(value))) |field| {
        if (field.field_type == []const u8) {
            allocator.free(@field(value, field.name));
        }
    }
}

test "simple match" {
    var fbs = std.io.fixedBufferStream(
        \\{"foo": true, "bar": 2, "baz": "nop"}
    );
    var str = json.stream(fbs.reader());

    const root = try str.root();
    expectEqual(root.kind, .Object);

    const m = try match(std.testing.allocator, root, struct {
        @"foo": bool,
        @"bar": u32,
        @"baz": []const u8,
    });
    defer freeMatch(std.testing.allocator, m);

    expectEqual(m.@"foo", true);
    expectEqual(m.@"bar", 2);
    std.testing.expectEqualStrings(m.@"baz", "nop");
}

fn expectEqual(actual: anytype, expected: @TypeOf(actual)) void {
    std.testing.expectEqual(expected, actual);
}
