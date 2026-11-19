//! stringify(parse(x)) reproduces the same tree, for a representative mix
//! of shapes -- the practical guarantee this subset makes (formatting and
//! comments are NOT preserved, only the data).
const std = @import("std");
const testing = std.testing;
const zyaml = @import("zyaml");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

fn expectRoundtrip(allocator: std.mem.Allocator, src: []const u8) !void {
    var v1 = try zyaml.parse(allocator, src);
    defer v1.deinit();
    const dumped = try zyaml.stringify(allocator, v1);
    defer allocator.free(dumped);
    var v2 = try zyaml.parse(allocator, dumped);
    defer v2.deinit();

    // The comparison scaffold (a std.json.Value mirror of each JSValue tree,
    // just to diff them structurally) is arena-scoped: it isn't the code
    // under test, so a deep recursive deinit for it would be pure noise.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const j1 = try std.json.Stringify.valueAlloc(arena, try toJsonValue(arena, v1), .{});
    const j2 = try std.json.Stringify.valueAlloc(arena, try toJsonValue(arena, v2), .{});
    try testing.expectEqualStrings(j1, j2);
}

/// Minimal JSValue -> std.json.Value bridge, just for comparing two trees
/// structurally in these tests (this repo doesn't otherwise depend on
/// std.json; z-json is the real JSON<->JSValue bridge).
fn toJsonValue(allocator: std.mem.Allocator, v: JSValue) !std.json.Value {
    return switch (v.unpack()) {
        .null => .null,
        .boolean => |b| .{ .bool = b },
        .number => |n| .{ .float = n },
        .string => |box| .{ .string = box.value.data },
        .array => |box| blk: {
            var arr: std.json.Array = .init(allocator);
            for (box.value.toSlice()) |item| try arr.append(try toJsonValue(allocator, item));
            break :blk .{ .array = arr };
        },
        .object => |box| blk: {
            var obj: std.json.ObjectMap = .empty;
            const keys = try box.value.keys(allocator);
            defer allocator.free(keys);
            for (keys) |k| try obj.put(allocator, k, try toJsonValue(allocator, box.value.get(k).?));
            break :blk .{ .object = obj };
        },
        else => .null,
    };
}

test "roundtrip: flat mapping" {
    try expectRoundtrip(testing.allocator, "name: Ada\nage: 36\nactive: true\nnote: ~\n");
}

test "roundtrip: nested mapping + sequence" {
    try expectRoundtrip(testing.allocator,
        \\server:
        \\  host: localhost
        \\  port: 8080
        \\fruits:
        \\  - apple
        \\  - banana
        \\  - "42"
    );
}

test "roundtrip: sequence of mappings" {
    try expectRoundtrip(testing.allocator,
        \\- name: foo
        \\  age: 3
        \\- name: bar
        \\  age: 5
    );
}

test "roundtrip: flow collections" {
    try expectRoundtrip(testing.allocator, "a: {b: 1, c: [2, 3]}");
}

test "roundtrip: strings needing quotes stay strings" {
    try expectRoundtrip(testing.allocator, "a: \"42\"\nb: \"true\"\nc: \"null\"\n");
}
