const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "universal-lambda-zig",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "src/universal_lambda_build.zig" },
        .target = target,
        .optimize = optimize,
    });
    const universal_lambda = @import("src/universal_lambda_build.zig");
    universal_lambda.module_root = b.build_root.path;
    _ = try universal_lambda.addModules(b, lib);

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/test.zig" },
        .target = target,
        .optimize = optimize,
    });
    _ = try universal_lambda.addModules(b, main_tests);
    // _ = try ulb.createOptionsModule(b, main_tests);

    // main_tests.addModule("flexilib-interface", flexilib_module);
    var run_main_tests = b.addRunArtifact(main_tests);
    run_main_tests.skip_foreign_checks = true;

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build test`
    // This will evaluate the `test` step rather than the default, which is "install".
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
}

pub fn configureBuild(b: *std.Build, cs: *std.Build.Step.Compile) !void {
    try @import("src/universal_lambda_build.zig").configureBuild(b, cs);
}
pub fn addModules(b: *std.Build, cs: *std.Build.Step.Compile) ![]const u8 {
    try @import("src/universal_lambda_build.zig").addModules(b, cs);
}
