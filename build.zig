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
    const flexilib_dep = b.dependency("flexilib", .{
        .target = target,
        .optimize = optimize,
    });
    const flexilib_module = flexilib_dep.module("flexilib-interface");
    lib.addModule("flexilib-interface", flexilib_module);
    // Because we are...well, ourselves, we'll manually override the module
    // root (we are not a module here).
    const ulb = @import("src/universal_lambda_build.zig");
    ulb.module_root = "";
    _ = try ulb.createOptionsModule(b, lib);

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/universal_lambda.zig" },
        .target = target,
        .optimize = optimize,
    });
    _ = try ulb.createOptionsModule(b, main_tests);

    main_tests.addModule("flexilib-interface", flexilib_module);
    var run_main_tests = b.addRunArtifact(main_tests);
    run_main_tests.skip_foreign_checks = true;

    const helper_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/helpers.zig" },
        .target = target,
        .optimize = optimize,
    });
    _ = try ulb.createOptionsModule(b, helper_tests);
    // Add module
    helper_tests.addAnonymousModule("universal_lambda_handler", .{
        // Source file can be anywhere on disk, does not need to be a subdirectory
        .source_file = .{ .path = "src/universal_lambda.zig" },
        // We alsso need the interface module available here
        .dependencies = &[_]std.Build.ModuleDependency{
            // Add options module so we can let our universal_lambda know what
            // type of interface is necessary
            .{
                .name = "build_options",
                .module = main_tests.modules.get("build_options").?,
            },
            .{
                .name = "flexilib-interface",
                .module = flexilib_module,
            },
        },
    });
    var run_helper_tests = b.addRunArtifact(helper_tests);
    run_helper_tests.skip_foreign_checks = true;

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build test`
    // This will evaluate the `test` step rather than the default, which is "install".
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
    test_step.dependOn(&run_helper_tests.step);

    _ = b.addModule("universal_lambda_helpers", .{
        .source_file = .{ .path = "src/helpers.zig" },
    });
}

pub fn configureBuild(b: *std.Build, cs: *std.Build.Step.Compile) !void {
    try @import("src/universal_lambda_build.zig").configureBuild(b, cs);
}
