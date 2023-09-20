const std = @import("std");
const builtin = @import("builtin");

/// flexilib will create a dynamic library for use with flexilib.
/// Flexilib will need to get the exe compiled as a library
/// For flexilib, we will need the main file to have a pub fn named
/// "handler". If it is not called that, a pub const handler = ... can be
/// used instead
pub fn configureBuild(b: *std.build.Builder, exe: *std.Build.Step.Compile, build_root_src: []const u8) !void {
    const package_step = b.step("flexilib", "Create a flexilib dynamic library");

    // const exe = b.addExecutable(.{
    //     .name = "universal-lambda-example",
    //     // In this case the main source file is merely a path, however, in more
    //     // complicated build scripts, this could be a generated file.
    //     .root_source_file = .{ .path = "src/main.zig" },
    //     .target = target,
    //     .optimize = optimize,
    // });
    //
    const lib = b.addSharedLibrary(.{
        .name = exe.name,
        .root_source_file = .{ .path = b.pathJoin(&[_][]const u8{ build_root_src, "flexilib.zig" }) },
        .target = exe.target,
        .optimize = exe.optimize,
    });

    // We will not free this, as the rest of the build system will use it.
    // This should be ok because our allocator is, I believe, an arena
    var module_dependencies = try b.allocator.alloc(std.Build.ModuleDependency, exe.modules.count());
    var iterator = exe.modules.iterator();

    var i: usize = 0;
    while (iterator.next()) |entry| : (i += 1) {
        module_dependencies[i] = .{
            .name = entry.key_ptr.*,
            .module = entry.value_ptr.*,
        };
        lib.addModule(entry.key_ptr.*, entry.value_ptr.*);
    }
    lib.addAnonymousModule("flexilib_handler", .{
        // Source file can be anywhere on disk, does not need to be a subdirectory
        .source_file = exe.root_src.?,
        .dependencies = module_dependencies,
    });
    package_step.dependOn(&b.addInstallArtifact(lib, .{}).step);
}
