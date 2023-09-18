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

pub fn configureBuild(b: *std.Build, exe: *std.Build.Step.Compile) !void {
    const file_location = try findFileLocation(b);
    // Add module
    exe.addAnonymousModule("universal_lambda_handler", .{
        // Source file can be anywhere on disk, does not need to be a subdirectory
        .source_file = .{ .path = b.pathJoin(&[_][]const u8{ file_location, "universal_lambda.zig" }) },
        .dependencies = &[_]std.Build.ModuleDependency{.{
            .name = "build_options",
            .module = try createOptionsModule(b, exe),
        }},
    });

    // Add steps
    try @import("lambdabuild.zig").configureBuild(b, exe);
    try @import("standalone_server_build.zig").configureBuild(b, exe);
    try @import("flexilib_build.zig").configureBuild(b, exe, file_location);

    // Add options module so we can let our universal_lambda know what
    // type of interface is necessary

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
    const build_root = b.option([]const u8, "universal_lambda_build_root", "Build root for universal lambda (development of universal lambda only)");
    if (build_root) |br| {
        return b.pathJoin(&[_][]const u8{ br, "src" });
    }
    const build_runner = @import("root");
    const deps = build_runner.dependencies;
    const build_roots = deps.build_root;
    if (!@hasField(build_roots, "universal_lambda_build"))
        @panic("Dependency in build.zig.zon must be named 'universal_lambda_build'");
    return b.pathJoin(&[_][]const u8{ @field(build_roots, "universal_lambda_build"), "src" });
}
/// Make our target platform visible to runtime through an import
/// called "build_options". This will also be available to the consuming
/// executable if needed
fn createOptionsModule(b: *std.Build, exe: *std.Build.Step.Compile) !*std.Build.Module {
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
    exe.addOptions("build_options", options);
    return exe.modules.get("build_options").?;
}

fn findBuildType(build_args: [][:0]u8) ?BuildType {
    var rc: ?BuildType = null;
    for (build_args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) break; // we're done as soon as we get to options
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
