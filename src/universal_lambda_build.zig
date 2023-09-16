const std = @import("std");

/// Determines the style of interface between what is in a main program
/// and the provider system. This should not be an exhaustive set of steps,
/// but a higher level "how do I get the handler registered". So only what
/// would describe a runtime difference
pub const BuildType = enum {
    awslambda,
    exe_run,
    standalone_run,
    cloudflare,
    flexilib,
};

pub fn configureBuild(b: *std.Build, exe: *std.Build.Step.Compile) !void {
    // Add steps
    try @import("lambdabuild.zig").configureBuild(b, exe);
    // Add options module so we can let our universal_lambda know what
    // type of interface is necessary

    // Add module
    exe.addAnonymousModule("universal_lambda_handler", .{
        .source_file = .{ .path = "upstream/src/universal_lambda.zig" },
        .dependencies = &[_]std.Build.ModuleDependency{.{
            .name = "build_options",
            .module = try createOptionsModule(b, exe),
        }},
    });
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
