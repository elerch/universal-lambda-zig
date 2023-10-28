const std = @import("std");
const builtin = @import("builtin");

/// flexilib will create a dynamic library for use with flexilib.
/// Flexilib will need to get the exe compiled as a library
pub fn configureBuild(b: *std.build.Builder, cs: *std.Build.Step.Compile, build_root_src: []const u8) !void {
    const package_step = b.step("flexilib", "Create a flexilib dynamic library");

    const lib = b.addSharedLibrary(.{
        .name = cs.name,
        .root_source_file = .{ .path = b.pathJoin(&[_][]const u8{ build_root_src, "flexilib.zig" }) },
        .target = cs.target,
        .optimize = cs.optimize,
    });

    // We will not free this, as the rest of the build system will use it.
    // This should be ok because our allocator is, I believe, an arena
    var module_dependencies = try b.allocator.alloc(std.Build.ModuleDependency, cs.modules.count());
    var iterator = cs.modules.iterator();

    var i: usize = 0;
    while (iterator.next()) |entry| : (i += 1) {
        module_dependencies[i] = .{
            .name = entry.key_ptr.*,
            .module = entry.value_ptr.*,
        };
        lib.addModule(entry.key_ptr.*, entry.value_ptr.*);
    }

    // Add the downstream root source file back into the build as a module
    // that our new root source file can import
    lib.addAnonymousModule("flexilib_handler", .{
        // Source file can be anywhere on disk, does not need to be a subdirectory
        .source_file = cs.root_src.?,
        .dependencies = module_dependencies,
    });
    package_step.dependOn(&b.addInstallArtifact(lib, .{}).step);
}
