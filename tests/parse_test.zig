const std = @import("std");
const testing = std.testing;
const zyaml = @import("zyaml");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

test "parse scalars: null/bool/number/string typing" {
    const allocator = testing.allocator;

    var n = try zyaml.parse(allocator, "~");
    defer n.deinit();
    try testing.expect(n.isNull());

    var n2 = try zyaml.parse(allocator, "null");
    defer n2.deinit();
    try testing.expect(n2.isNull());

    var t = try zyaml.parse(allocator, "true");
    defer t.deinit();
    try testing.expect(t.asBool() == true);

    var f = try zyaml.parse(allocator, "False");
    defer f.deinit();
    try testing.expect(f.asBool() == false);

    var i = try zyaml.parse(allocator, "42");
    defer i.deinit();
    try testing.expectEqual(@as(f64, 42), i.asNumber());

    var neg = try zyaml.parse(allocator, "-3.14");
    defer neg.deinit();
    try testing.expectEqual(@as(f64, -3.14), neg.asNumber());

    var s = try zyaml.parse(allocator, "hello world");
    defer s.deinit();
    try testing.expectEqualStrings("hello world", s.asString().value.data);
}

test "parse quoted scalars are always strings, never re-typed" {
    const allocator = testing.allocator;
    var v = try zyaml.parse(allocator, "\"42\"");
    defer v.deinit();
    try testing.expect(v.isString());
    try testing.expectEqualStrings("42", v.asString().value.data);

    var v2 = try zyaml.parse(allocator, "'true'");
    defer v2.deinit();
    try testing.expect(v2.isString());
    try testing.expectEqualStrings("true", v2.asString().value.data);
}

test "parse double-quoted escapes" {
    const allocator = testing.allocator;
    var v = try zyaml.parse(allocator, "\"a\\nb\\t\\\"c\\\"\"");
    defer v.deinit();
    try testing.expectEqualStrings("a\nb\t\"c\"", v.asString().value.data);
}

test "parse single-quoted doubled-quote escape" {
    const allocator = testing.allocator;
    var v = try zyaml.parse(allocator, "'it''s'");
    defer v.deinit();
    try testing.expectEqualStrings("it's", v.asString().value.data);
}

test "parse a simple block mapping" {
    const allocator = testing.allocator;
    var v = try zyaml.parse(allocator,
        \\name: Ada
        \\age: 36
        \\active: true
    );
    defer v.deinit();
    try testing.expect(v.isObject());
    try testing.expectEqualStrings("Ada", v.asObject().value.get("name").?.asString().value.data);
    try testing.expectEqual(@as(f64, 36), v.asObject().value.get("age").?.asNumber());
    try testing.expect(v.asObject().value.get("active").?.asBool() == true);
}

test "parse a nested block mapping" {
    const allocator = testing.allocator;
    var v = try zyaml.parse(allocator,
        \\server:
        \\  host: localhost
        \\  port: 8080
        \\name: app
    );
    defer v.deinit();
    const server = v.asObject().value.get("server").?;
    try testing.expect(server.isObject());
    try testing.expectEqualStrings("localhost", server.asObject().value.get("host").?.asString().value.data);
    try testing.expectEqual(@as(f64, 8080), server.asObject().value.get("port").?.asNumber());
    try testing.expectEqualStrings("app", v.asObject().value.get("name").?.asString().value.data);
}

test "parse a block sequence of scalars" {
    const allocator = testing.allocator;
    var v = try zyaml.parse(allocator,
        \\- one
        \\- two
        \\- 3
    );
    defer v.deinit();
    try testing.expect(v.isArray());
    try testing.expectEqual(@as(usize, 3), v.asArray().value.length());
    try testing.expectEqualStrings("one", v.asArray().value.get(0).asString().value.data);
    try testing.expectEqual(@as(f64, 3), v.asArray().value.get(2).asNumber());
}

test "parse a sequence nested under a mapping key" {
    const allocator = testing.allocator;
    var v = try zyaml.parse(allocator,
        \\fruits:
        \\  - apple
        \\  - banana
    );
    defer v.deinit();
    const fruits = v.asObject().value.get("fruits").?;
    try testing.expect(fruits.isArray());
    try testing.expectEqual(@as(usize, 2), fruits.asArray().value.length());
    try testing.expectEqualStrings("apple", fruits.asArray().value.get(0).asString().value.data);
}

test "parse a sequence of mappings (the common real-world shape)" {
    const allocator = testing.allocator;
    var v = try zyaml.parse(allocator,
        \\- name: foo
        \\  age: 3
        \\- name: bar
        \\  age: 5
    );
    defer v.deinit();
    try testing.expect(v.isArray());
    try testing.expectEqual(@as(usize, 2), v.asArray().value.length());
    const first = v.asArray().value.get(0);
    try testing.expectEqualStrings("foo", first.asObject().value.get("name").?.asString().value.data);
    try testing.expectEqual(@as(f64, 3), first.asObject().value.get("age").?.asNumber());
    const second = v.asArray().value.get(1);
    try testing.expectEqualStrings("bar", second.asObject().value.get("name").?.asString().value.data);
}

test "parse flow mapping and sequence" {
    const allocator = testing.allocator;
    var v = try zyaml.parse(allocator, "{a: 1, b: [2, 3], c: \"x\"}");
    defer v.deinit();
    try testing.expect(v.isObject());
    try testing.expectEqual(@as(f64, 1), v.asObject().value.get("a").?.asNumber());
    const b = v.asObject().value.get("b").?;
    try testing.expectEqual(@as(usize, 2), b.asArray().value.length());
    try testing.expectEqualStrings("x", v.asObject().value.get("c").?.asString().value.data);
}

test "parse flow value as a block mapping's value" {
    const allocator = testing.allocator;
    var v = try zyaml.parse(allocator, "ports: [80, 443]");
    defer v.deinit();
    const ports = v.asObject().value.get("ports").?;
    try testing.expectEqual(@as(usize, 2), ports.asArray().value.length());
    try testing.expectEqual(@as(f64, 80), ports.asArray().value.get(0).asNumber());
}

test "parse comments and blank lines are ignored" {
    const allocator = testing.allocator;
    var v = try zyaml.parse(allocator,
        \\# top comment
        \\name: Ada # trailing comment
        \\
        \\age: 36
    );
    defer v.deinit();
    try testing.expectEqualStrings("Ada", v.asObject().value.get("name").?.asString().value.data);
    try testing.expectEqual(@as(f64, 36), v.asObject().value.get("age").?.asNumber());
}

test "a '#' inside a quoted string is not a comment" {
    const allocator = testing.allocator;
    var v = try zyaml.parse(allocator, "url: \"http://x#y\"");
    defer v.deinit();
    try testing.expectEqualStrings("http://x#y", v.asObject().value.get("url").?.asString().value.data);
}

test "parse an empty value (key: with nothing) is null" {
    const allocator = testing.allocator;
    var v = try zyaml.parse(allocator, "a: ");
    defer v.deinit();
    try testing.expect(v.asObject().value.get("a").?.isNull());
}

test "parse skips a leading '---' document marker" {
    const allocator = testing.allocator;
    var v = try zyaml.parse(allocator,
        \\---
        \\a: 1
    );
    defer v.deinit();
    try testing.expectEqual(@as(f64, 1), v.asObject().value.get("a").?.asNumber());
}

test "parse rejects tab indentation" {
    const allocator = testing.allocator;
    try testing.expectError(zyaml.YamlError.TabIndentation, zyaml.parse(allocator, "a:\n\tb: 1"));
}

test "parse rejects a mismatched indentation level" {
    const allocator = testing.allocator;
    // "b: 1" is indented less than the mapping's established level (2), but
    // more than the top level (0) -- doesn't line up with anything.
    try testing.expectError(zyaml.YamlError.BadIndentation, zyaml.parse(allocator,
        \\a:
        \\  x: 1
        \\ b: 2
    ));
}

test "parse incomplete flow array releases transferred string once" {
    try testing.expectError(error.UnexpectedEnd, zyaml.parse(testing.allocator, "[\"x\""));
}

test "parse incomplete flow object releases transferred string once" {
    try testing.expectError(error.UnexpectedEnd, zyaml.parse(testing.allocator, "{a: \"x\""));
}

test "parse incomplete nested flow releases completed children" {
    try testing.expectError(error.UnexpectedEnd, zyaml.parse(testing.allocator, "[[\"a\"], {\"b\""));
}

test "parse block collections release prior children on later error" {
    const inputs = [_][]const u8{
        "- hello\n- \"\\q\"",
        "-\n  - hello\n- \"\\q\"",
        "- name: hello\n- name: \"\\q\"",
        "a: hello\nb: \"\\q\"",
    };
    for (inputs) |input| {
        try testing.expectError(error.InvalidEscape, zyaml.parse(testing.allocator, input));
    }
}

fn exerciseFlowOwnership(allocator: std.mem.Allocator, input: []const u8) !void {
    const doc = try zyaml.parse(allocator, input);
    defer doc.deinit();
}

test "parse flow insertion failures release untransferred containers" {
    try testing.checkAllAllocationFailures(testing.allocator, exerciseFlowOwnership, .{"[[1], {b: [2]}]"});
}

test "parse duplicate block key releases replaced string" {
    const doc = try zyaml.parse(testing.allocator, "a: first\na: second");
    defer doc.deinit();
    try testing.expectEqualStrings("second", doc.asObject().value.get("a").?.asString().value.data);
}

test "parse duplicate flow key releases replaced string" {
    const doc = try zyaml.parse(testing.allocator, "{a: first, a: second}");
    defer doc.deinit();
    try testing.expectEqualStrings("second", doc.asObject().value.get("a").?.asString().value.data);
}

test "parse duplicate keys recursively release replaced subtrees" {
    const inputs = [_][]const u8{
        "a:\n  items: [first, {nested: value}]\na: second",
        "{a: {items: [first, {nested: value}]}, a: second}",
    };
    for (inputs) |input| {
        const doc = try zyaml.parse(testing.allocator, input);
        defer doc.deinit();
        try testing.expectEqualStrings("second", doc.asObject().value.get("a").?.asString().value.data);
    }
}

test "parse duplicate key replacement is safe under allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, exerciseFlowOwnership, .{"{a: [1], a: [2]}"});
}

test "parse strings and replaced subtrees survive every allocation failure" {
    const inputs = [_][]const u8{
        "a: hello\na: {b: [world]}",
        "{a: hello, a: {b: [world]}}",
    };
    for (inputs) |input| {
        try testing.checkAllAllocationFailures(testing.allocator, exerciseFlowOwnership, .{input});
    }
}
