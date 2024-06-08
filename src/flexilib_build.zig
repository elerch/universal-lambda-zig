const std = @import("std");
const builtin = @import("builtin");

/// flexilib will create a dynamic library for use with flexilib.
/// Flexilib will need to get the exe compiled as a library
pub fn configureBuild(b: *std.Build, cs: *std.Build.Step.Compile, universal_lambda_zig_dep: *std.Build.Dependency) !void {
    const package_step = b.step("flexilib", "Create a flexilib dynamic library");

    const lib = b.addSharedLibrary(.{
        .name = cs.name,
        .root_source_file = b.path(b.pathJoin(&[_][]const u8{
            // root path comes from our dependency, which should be us,
            // and if it's not, we'll just blow up here but it's not our fault ;-)
            universal_lambda_zig_dep.builder.build_root.path.?,
            "src",
            "flexilib.zig",
        })),
        .target = cs.root_module.resolved_target.?,
        .optimize = cs.root_module.optimize.?,
    });

    // Add the downstream root source file back into the build as a module
    // that our new root source file can import
    const flexilib_handler = b.createModule(.{
        // Source file can be anywhere on disk, does not need to be a subdirectory
        .root_source_file = cs.root_module.root_source_file,
    });

    lib.root_module.addImport("flexilib_handler", flexilib_handler);

    // Now we need to get our imports added. Rather than reinvent the wheel, we'll
    // utilize our addImports function, but tell it to work on our library
    @import("universal_lambda_build.zig").addImports(b, lib, universal_lambda_zig_dep);

    // flexilib_handler module needs imports to work...we are not in control
    // of this file, so it could expect anything that's already imported. So
    // we'll walk through the import table and simply add all the imports back in
    var iterator = lib.root_module.import_table.iterator();
    while (iterator.next()) |entry|
        flexilib_handler.addImport(entry.key_ptr.*, entry.value_ptr.*);

    package_step.dependOn(&b.addInstallArtifact(lib, .{}).step);
}
