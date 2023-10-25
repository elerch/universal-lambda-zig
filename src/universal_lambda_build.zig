const std = @import("std");

/// Determines the style of interface between what is in a main program
/// and the provider system. This should not be an exhaustive set of steps,
/// but a higher level "how do I get the handler registered". So only what
/// would describe a runtime difference
pub const BuildType = enum {
    awslambda,
    exe_run,
    standalone_server,
    cloudflare,
    flexilib,
};

pub var module_root: ?[]const u8 = null;

pub fn configureBuild(b: *std.Build, cs: *std.Build.Step.Compile) !void {
    const function_name = b.option([]const u8, "function-name", "Function name for Lambda [zig-fn]") orelse "zig-fn";

    const file_location = addModules(b, cs);

    // Add steps
    try @import("lambda_build.zig").configureBuild(b, cs, function_name);
    try @import("cloudflare_build.zig").configureBuild(b, cs, function_name);
    try @import("flexilib_build.zig").configureBuild(b, cs, file_location);
    try @import("standalone_server_build.zig").configureBuild(b, cs);
}

/// Add modules
///
/// We will create the following modules for downstream consumption:
///
/// * build_options
/// * flexilib-interface
/// * universal_lambda_handler
pub fn addModules(b: *std.Build, cs: *std.Build.Step.Compile) ![]const u8 {
    const file_location = try findFileLocation(b);
    const options_module = try createOptionsModule(b, cs);

    // We need to add the interface module here as well, so universal_lambda.zig
    // can reference it. Unfortunately, this creates an issue that the consuming
    // build.zig.zon must have flexilib included, even if they're not building
    // flexilib. TODO: Accept for now, but we need to think through this situation
    // This might be fixed in 0.12.0 (see https://github.com/ziglang/zig/issues/16172).
    // We can also possibly use the findFileLocation hack above in concert with
    // addAnonymousModule
    const flexilib_dep = b.dependency("flexilib", .{
        .target = cs.target,
        .optimize = cs.optimize,
    });
    const flexilib_module = flexilib_dep.module("flexilib-interface");
    // Make the interface available for consumption
    cs.addModule("flexilib-interface", flexilib_module);
    cs.addAnonymousModule("universal_lambda_interface", .{
        .source_file = .{ .path = b.pathJoin(&[_][]const u8{ file_location, "interface.zig" }) },
        // We alsso need the interface module available here
        .dependencies = &[_]std.Build.ModuleDependency{},
    });
    // Add module
    cs.addAnonymousModule("universal_lambda_handler", .{
        // Source file can be anywhere on disk, does not need to be a subdirectory
        .source_file = .{ .path = b.pathJoin(&[_][]const u8{ file_location, "universal_lambda.zig" }) },
        // We alsso need the interface module available here
        .dependencies = &[_]std.Build.ModuleDependency{
            // Add options module so we can let our universal_lambda know what
            // type of interface is necessary
            .{
                .name = "build_options",
                .module = options_module,
            },
            .{
                .name = "flexilib-interface",
                .module = flexilib_module,
            },
            .{
                .name = "universal_lambda_interface",
                .module = cs.modules.get("universal_lambda_interface").?,
            },
        },
    });
    return file_location;
}

/// This function relies on internal implementation of the build runner
/// When a developer launches "zig build", a program is compiled, with the
/// main entrypoint existing in build_runner.zig (this can be overridden by
/// by command line).
///
/// The code we see in build.zig is compiled into that program. The program
/// is named 'build' and stuck in the zig cache, then it is run. There are
/// two phases to the build.
///
/// Build phase, where a graph is established of the steps that need to be run,
/// then the "make phase", where the steps are actually executed. Steps have
/// a make function that is called.
///
/// This function is reaching into the struct that is the build_runner.zig, and
/// finding the location of the dependency for ourselves to determine the
/// location of our own file. This is, of course, brittle, but there does not
/// seem to be a better way at the moment, and we need this to be able to import
/// modules appropriately.
///
/// For development of this process directly, we'll allow a build option to
/// override this process completely, because during development it's easier
/// for the example build.zig to simply import the file directly than it is
/// to pull from a download location and update hashes every time we change
fn findFileLocation(b: *std.Build) ![]const u8 {
    if (module_root) |r| return b.pathJoin(&[_][]const u8{ r, "src" });
    const build_root = b.option(
        []const u8,
        "universal_lambda_build_root",
        "Build root for universal lambda (development of universal lambda only)",
    );
    if (build_root) |br| {
        return b.pathJoin(&[_][]const u8{ br, "src" });
    }
    // This is introduced post 0.11. Once it is available, we can skip the
    // access check, and instead check the end of the path matches the dependency
    // hash
    // for (b.available_deps) |dep| {
    //     std.debug.print("{}", .{dep});
    //     // if (std.
    // }
    const ulb_root = outer_blk: {
        // trigger initlialization if it hasn't been initialized already
        _ = b.dependency("universal_lambda_build", .{}); //b.args);
        var str_iterator = b.initialized_deps.iterator();
        while (str_iterator.next()) |entry| {
            const br = entry.key_ptr.*;
            const marker_found = blk: {
                // Check for a file that should only exist in our package
                std.fs.accessAbsolute(b.pathJoin(&[_][]const u8{ br, "src", "flexilib.zig" }), .{}) catch break :blk false;
                break :blk true;
            };
            if (marker_found) break :outer_blk br;
        }
        return error.CannotFindUniversalLambdaBuildRoot;
    };
    return b.pathJoin(&[_][]const u8{ ulb_root, "src" });
}
/// Make our target platform visible to runtime through an import
/// called "build_options". This will also be available to the consuming
/// executable if needed
pub fn createOptionsModule(b: *std.Build, cs: *std.Build.Step.Compile) !*std.Build.Module {
    // We need to go through the command line args, look for argument(s)
    // between "build" and anything prefixed with "-". First take, blow up
    // if there is more than one. That's the step we're rolling with
    // These frameworks I believe are inextricably tied to both build and
    // run behavior.
    //
    var args = try std.process.argsAlloc(b.allocator);
    defer b.allocator.free(args);
    const options = b.addOptions();
    options.addOption(BuildType, "build_type", findBuildType(args) orelse .exe_run);
    cs.addOptions("build_options", options);
    return cs.modules.get("build_options").?;
}

fn findBuildType(build_args: [][:0]u8) ?BuildType {
    var rc: ?BuildType = null;
    for (build_args[1..]) |arg| {
        inline for (std.meta.fields(BuildType)) |field| {
            if (std.mem.startsWith(u8, arg, field.name)) {
                if (rc != null)
                    @panic("Sorry, we are not smart enough to build a single handler for multiple simultaneous providers");
                rc = @field(BuildType, field.name);
            }
        }
    }
    return rc;
}
