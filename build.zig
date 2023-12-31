const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("atlas-allocator", .{
        .source_file = .{ .path = "src/main.zig" },
    });

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_main_tests = b.addRunArtifact(main_tests);

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build test`
    // This will evaluate the `test` step rather than the default, which is "install".
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);

    const gen_docs = b.addObject(.{
        .name = "zig-atlas-allocator",
        .target = target,
        .optimize = optimize,
        .root_source_file = .{ .path = "src/main.zig" },
    });

    gen_docs.emit_bin = .no_emit;
    gen_docs.emit_docs = .{ .emit_to = "./docs" };

    const doc_step = b.step("docs", "Build the documentation");
    doc_step.dependOn(&gen_docs.step);

    const test_exe = b.addExecutable(.{
        .name = "shelf-allocator-test",
        .root_source_file = .{ .path = "src/test.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_test_exe = b.addRunArtifact(test_exe);
    const run_test_step = b.step("shelf-allocator-test", "Run the allocator tests");
    run_test_step.dependOn(&run_test_exe.step);

    b.installArtifact(test_exe);
}
