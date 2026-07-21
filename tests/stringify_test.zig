const std = @import("std");
const testing = std.testing;
const zyaml = @import("zyaml");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

test "stringify primitives" {
    const allocator = testing.allocator;

    const n = try zyaml.stringify(allocator, JSValue.fromNumber(42));
    defer allocator.free(n);
    try testing.expectEqualStrings("42\n", n);

    const b = try zyaml.stringify(allocator, JSValue.fromBool(true));
    defer allocator.free(b);
    try testing.expectEqualStrings("true\n", b);

    const nul = try zyaml.stringify(allocator, JSValue.NULL);
    defer allocator.free(nul);
    try testing.expectEqualStrings("null\n", nul);
}

test "stringify a string that needs quoting vs one that doesn't" {
    const allocator = testing.allocator;

    var plain = try JSValue.newString(allocator, "hello");
    defer plain.deinit();
    const plain_out = try zyaml.stringify(allocator, plain);
    defer allocator.free(plain_out);
    try testing.expectEqualStrings("hello\n", plain_out);

    // "42" as a STRING must be quoted, or it would re-parse as a number.
    var numeric_looking = try JSValue.newString(allocator, "42");
    defer numeric_looking.deinit();
    const numeric_out = try zyaml.stringify(allocator, numeric_looking);
    defer allocator.free(numeric_out);
    try testing.expectEqualStrings("\"42\"\n", numeric_out);

    // "true" as a STRING must be quoted too.
    var bool_looking = try JSValue.newString(allocator, "true");
    defer bool_looking.deinit();
    const bool_out = try zyaml.stringify(allocator, bool_looking);
    defer allocator.free(bool_out);
    try testing.expectEqualStrings("\"true\"\n", bool_out);
}

test "stringify a flat mapping" {
    const allocator = testing.allocator;
    var obj = try JSValue.newObject(allocator);
    defer obj.deinit();
    try obj.object.value.set("name", try JSValue.newString(allocator, "Ada"));
    try obj.object.value.set("age", JSValue.fromNumber(36));

    const out = try zyaml.stringify(allocator, obj);
    defer allocator.free(out);
    try testing.expectEqualStrings("name: Ada\nage: 36\n", out);
}

test "stringify a sequence of scalars" {
    const allocator = testing.allocator;
    var arr = try JSValue.newArray(allocator);
    defer arr.deinit();
    _ = try arr.array.value.push(JSValue.fromNumber(1));
    _ = try arr.array.value.push(JSValue.fromNumber(2));

    const out = try zyaml.stringify(allocator, arr);
    defer allocator.free(out);
    try testing.expectEqualStrings("- 1\n- 2\n", out);
}

test "stringify a nested mapping" {
    const allocator = testing.allocator;
    var inner = try JSValue.newObject(allocator);
    try inner.object.value.set("host", try JSValue.newString(allocator, "localhost"));
    var outer = try JSValue.newObject(allocator);
    defer outer.deinit();
    try outer.object.value.set("server", inner);

    const out = try zyaml.stringify(allocator, outer);
    defer allocator.free(out);
    try testing.expectEqualStrings("server:\n  host: localhost\n", out);
}

test "stringify empty mapping/array" {
    const allocator = testing.allocator;
    var obj = try JSValue.newObject(allocator);
    defer obj.deinit();
    const out = try zyaml.stringify(allocator, obj);
    defer allocator.free(out);
    try testing.expectEqualStrings("{}\n", out);

    var arr = try JSValue.newArray(allocator);
    defer arr.deinit();
    const out2 = try zyaml.stringify(allocator, arr);
    defer allocator.free(out2);
    try testing.expectEqualStrings("[]\n", out2);
}
