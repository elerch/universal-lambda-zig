const std = @import("std");

const test_targets = [_]std.zig.CrossTarget{
    .{}, // native
    .{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
    },
    .{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
    },
    .{
        .cpu_arch = .arm,
        .os_tag = .linux,
    },
    // Windows needs to avoid std.os.getenv - we'll wait until this is needed
    // .{
    //     .cpu_arch = .x86_64,
    //     .os_tag = .windows,
    // },
    // I don't have a good way to test these
    // .{
    //     .cpu_arch = .aarch64,
    //     .os_tag = .macos,
    // },
    // .{
    //     .cpu_arch = .x86_64,
    //     .os_tag = .macos,
    // },
    .{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    },
};
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

    // re-expose modules downstream
    const flexilib_dep = b.dependency("flexilib", .{
        .target = target,
        .optimize = optimize,
    });
    const flexilib_module = flexilib_dep.module("flexilib-interface");
    _ = b.addModule("flexilib-interface", .{
        .root_source_file = flexilib_module.root_source_file,
        .target = target,
        .optimize = optimize,
    });

    _ = b.addModule("universal_lambda_interface", .{
        .root_source_file = b.path("src/interface.zig"),
        .target = target,
        .optimize = optimize,
    });

    _ = b.addModule("universal_lambda_handler", .{
        .root_source_file = b.path("src/universal_lambda.zig"),
        .target = target,
        .optimize = optimize,
    });
    @import("src/universal_lambda_build.zig").addImports(b, lib, null);

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    const test_step = b.step("test", "Run library tests");

    for (test_targets) |t| {
        // Creates steps for unit testing. This only builds the test executable
        // but does not run it.
        const exe_tests = b.addTest(.{
            .root_source_file = .{ .path = "src/test.zig" },
            .target = b.resolveTargetQuery(t),
            .optimize = optimize,
        });
        _ = try universal_lambda.addModules(b, exe_tests);

        var run_exe_tests = b.addRunArtifact(exe_tests);
        run_exe_tests.skip_foreign_checks = true;
        test_step.dependOn(&run_exe_tests.step);

        // Universal lambda can end up as an exe or a lib. When it is a library,
        // we end up changing the root source file away from downstream so we can
        // control exports and such. This is just flexilib for now, but we could
        // end up in a situation where we need to create an array of libraries
        // with various roots that all meet the rest of the build DAG at test_step
        // in the future. Scaleway, for instance, is another system that works
        // via shared library
        const lib_tests = b.addTest(.{
            .root_source_file = .{ .path = "src/flexilib.zig" },
            .target = b.resolveTargetQuery(t),
            .optimize = optimize,
        });
        _ = try universal_lambda.addModules(b, lib_tests);

        var run_lib_tests = b.addRunArtifact(lib_tests);
        run_lib_tests.skip_foreign_checks = true;
        // This creates a build step. It will be visible in the `zig build --help` menu,
        // and can be selected like this: `zig build test`
        // This will evaluate the `test` step rather than the default, which is "install".
        test_step.dependOn(&run_lib_tests.step);
    }
}

pub fn configureBuild(b: *std.Build, cs: *std.Build.Step.Compile) !void {
    try @import("src/universal_lambda_build.zig").configureBuild(b, cs);
}
pub fn addImports(b: *std.Build, cs: *std.Build.Step.Compile, universal_lambda_zig_dep: *std.Build.Dependency) void {
    // The underlying call has an optional dependency here, but we do not.
    // Downstream must provide the dependency, which will ensure that the
    // modules we have exposed above do, in fact, get exposed
    return @import("src/universal_lambda_build.zig").addImports(b, cs, universal_lambda_zig_dep);
}
