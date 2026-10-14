const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zvalue_dep = b.dependency("zvalue", .{ .target = target, .optimize = optimize });
    const znumber_dep = b.dependency("znumber", .{ .target = target, .optimize = optimize });
    const zvalue_module = zvalue_dep.module("zvalue");
    const znumber_module = znumber_dep.module("znumber");

    const zyaml_module = b.addModule("zyaml", .{
        .root_source_file = b.path("src/zyaml.zig"),
        .target = target,
        .optimize = optimize,
    });
    zyaml_module.addImport("zvalue", zvalue_module);
    zyaml_module.addImport("znumber", znumber_module);

    const docs_library = b.addLibrary(.{
        .name = "zyaml",
        .root_module = zyaml_module,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_library.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate Zig API documentation");
    docs_step.dependOn(&install_docs.step);

    const test_step = b.step("test", "Run all tests");

    const test_files = [_][]const u8{
        "tests/parse_test.zig",
        "tests/stringify_test.zig",
        "tests/roundtrip_test.zig",
    };

    inline for (test_files) |test_file| {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_file),
                .target = target,
                .optimize = optimize,
            }),
        });

        unit_tests.root_module.addImport("zyaml", zyaml_module);
        unit_tests.root_module.addImport("zvalue", zvalue_module);

        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }

    // Also run the tests inlined in src/zyaml.zig itself (currently none,
    // kept for parity with the other z-* repos' pattern).
    const src_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zyaml.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    src_tests.root_module.addImport("zvalue", zvalue_module);
    src_tests.root_module.addImport("znumber", znumber_module);
    const run_src_tests = b.addRunArtifact(src_tests);
    test_step.dependOn(&run_src_tests.step);

    b.default_step = test_step;
}
