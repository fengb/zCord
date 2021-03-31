const std = @import("std");
const json = @import("../json.zig");

const PathToken = union(enum) {
    index: u32,
    key: []const u8,

    fn tokenize(string: []const u8) Tokenizer {
        return .{ .string = string, .index = 0 };
    }

    const Tokenizer = struct {
        string: []const u8,
        index: usize,

        fn next(self: *Tokenizer) !?PathToken {
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

const AstNode = struct {
    initial_path: []const u8,
    data: union(enum) {
        empty: void,
        atom: type,
        object: []const Object,
        array: []const Array,
    } = .empty,

    const Object = struct { key: []const u8, node: AstNode };
    const Array = struct { index: usize, node: AstNode };

    fn init(comptime T: type) !AstNode {
        var result = AstNode{ .initial_path = "" };
        for (std.meta.fields(T)) |field| {
            var tokenizer = PathToken.tokenize(field.name);
            try result.insert(field.field_type, &tokenizer);
        }
        return result;
    }

    fn insert(comptime self: *AstNode, comptime T: type, tokenizer: *PathToken.Tokenizer) error{Collision}!void {
        const token = (try tokenizer.next()) orelse {
            if (self.data != .empty) return error.Collision;

            self.data = .{ .atom = T };
            return;
        };

        switch (token) {
            .index => |index| {
                switch (self.data) {
                    .array => {},
                    .empty => {
                        self.data = .{ .array = &.{} };
                    },
                    else => return error.Collision,
                }
                for (self.data.array) |elem| {
                    if (elem.index == index) {
                        // TODO: replace this awful copy with comptime allocators
                        var copy = self.data.array[0..self.data.array.len].*;
                        try copy[i].node.insert(T, tokenizer);
                        self.data.array = &copy;
                        break;
                    }
                } else {
                    var new_node = AstNode{ .initial_path = tokenizer.string };
                    try new_node.insert(T, tokenizer);
                    self.data.object = self.data.object ++ [_]Object{
                        .{ .key = key, .node = new_node },
                    };
                }
            },
            .key => |key| {
                switch (self.data) {
                    .object => {},
                    .empty => {
                        self.data = .{ .object = &.{} };
                    },
                    else => return error.Collision,
                }
                for (self.data.object) |elem, i| {
                    if (std.mem.eql(u8, elem.key, key)) {
                        // TODO: replace this awful copy with comptime allocators
                        var copy = self.data.object[0..self.data.object.len].*;
                        try copy[i].node.insert(T, tokenizer);
                        self.data.object = &copy;
                        break;
                    }
                } else {
                    var new_node = AstNode{ .initial_path = tokenizer.string };
                    try new_node.insert(T, tokenizer);
                    self.data.object = self.data.object ++ [_]Object{
                        .{ .key = key, .node = new_node },
                    };
                }
            },
        }
    }

    fn apply(comptime self: AstNode, allocator: ?*std.mem.Allocator, json_element: anytype, matches: anytype, result: anytype) !void {
        switch (self.data) {
            .empty => unreachable,
            .atom => |AtomType| {
                @field(result, self.initial_path) = switch (AtomType) {
                    bool => try json_element.boolean(),
                    ?bool => try json_element.optionalBoolean(),
                    []const u8, []u8 => try (try json_element.stringReader()).readAllAlloc(allocator.?, std.math.maxInt(usize)),
                    ?[]const u8, ?[]u8 => blk: {
                        const reader = (try json_element.optionalStringReader()) orelse break :blk null;
                        break :blk try reader.readAllAlloc(allocator.?, std.math.maxInt(usize));
                    },
                    else => switch (@typeInfo(AtomType)) {
                        .Float, .Int => try json_element.number(AtomType),
                        .Optional => |o_info| switch (@typeInfo(o_info.child)) {
                            .Float, .Int => try json_element.optionalNumber(o_info.child),
                            else => @compileError("Type not supported " ++ @typeName(AtomType)),
                        },
                        else => @compileError("Type not supported " ++ @typeName(AtomType)),
                    },
                };

                if (@hasField(std.meta.Child(@TypeOf(matches)), self.initial_path)) {
                    @field(matches, self.initial_path) = true;
                }
            },
            .object => |object| {
                comptime var keys: [object.len][]const u8 = undefined;
                comptime for (object) |directive, i| {
                    keys[i] = directive.key;
                };
                while (try json_element.objectMatchAny(&keys)) |item| match: {
                    inline for (object) |directive| {
                        if (std.mem.eql(u8, directive.key, item.key)) {
                            try directive.node.apply(allocator, item.value, matches, result);
                            break :match;
                        }
                    }
                    unreachable;
                }
            },
            .array => |array| {
                var i: usize = 0;
                while (try json_element.arrayNext()) |item| : (i += 1) match: {
                    inline for (array) |child| {
                        if (child.index == i) {
                            try child.node.apply(json_element, matches, result);
                            break :match;
                        }
                    }
                }
            },
        }
    }
};

fn RequiredMatches(comptime T: type) type {
    var required_fields: []const std.builtin.TypeInfo.StructField = &.{};
    for (std.meta.fields(T)) |field| {
        if (@typeInfo(field.field_type) != .Optional) {
            required_fields = required_fields ++ [_]std.builtin.TypeInfo.StructField{
                .{ .name = field.name, .field_type = bool, .default_value = false, .is_comptime = false, .alignment = 1 },
            };
        }
    }
    return @Type(.{
        .Struct = .{
            .layout = .Auto,
            .fields = required_fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

pub fn match(allocator: ?*std.mem.Allocator, json_element: anytype, comptime T: type) !T {
    comptime const ast = try AstNode.init(T);

    var result: T = undefined;
    inline for (std.meta.fields(T)) |field| {
        if (@typeInfo(field.field_type) == .Optional) {
            @field(result, field.name) = null;
        }
    }

    var matches: RequiredMatches(T) = .{};

    errdefer {
        inline for (std.meta.fields(@TypeOf(result))) |field| {
            switch (field.field_type) {
                ?[]const u8, ?[]u8 => {
                    if (@field(result, field.name)) |str| {
                        allocator.?.free(str);
                    }
                },
                []const u8, []u8 => {
                    if (@field(matches, field.name)) {
                        allocator.?.free(@field(result, field.name));
                    }
                },
                else => {},
            }
        }
    }

    try ast.apply(allocator, json_element, &matches, &result);

    inline for (std.meta.fields(@TypeOf(matches))) |field| {
        if (!@field(matches, field.name)) {
            return error.Required;
        }
    }
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

test "nested" {
    var fbs = std.io.fixedBufferStream(
        \\{"nest": { "foo": 1, "bar": false } }
    );
    var str = json.stream(fbs.reader());

    const root = try str.root();
    expectEqual(root.kind, .Object);

    const m = try match(std.testing.allocator, root, struct {
        @"nest.foo": u32,
        @"nest.bar": bool,
    });

    expectEqual(m.@"nest.foo", 1);
    expectEqual(m.@"nest.bar", false);
}

fn expectEqual(actual: anytype, expected: @TypeOf(actual)) void {
    std.testing.expectEqual(expected, actual);
}

test "optionals" {
    var fbs = std.io.fixedBufferStream("{}");
    var str = json.stream(fbs.reader());

    const root = try str.root();
    expectEqual(root.kind, .Object);

    const m = try match(std.testing.allocator, root, struct {
        @"foo": ?bool,
        @"bar": ?u32,
        @"baz": ?[]const u8,
    });
    defer freeMatch(std.testing.allocator, m);

    expectEqual(m.@"foo", null);
    expectEqual(m.@"bar", null);
    expectEqual(m.@"baz", null);
}

test "requireds" {
    var fbs = std.io.fixedBufferStream("{}");
    var str = json.stream(fbs.reader());

    const root = try str.root();
    expectEqual(root.kind, .Object);

    std.testing.expectError(error.Required, match(std.testing.allocator, root, struct {
        @"foo": bool,
        @"bar": u32,
        @"baz": []const u8,
    }));
}
