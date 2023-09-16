const std = @import("std");
pub const BuildType = enum {
    awslambda_package,
    awslambda_iam,
    awslambda_deploy,
    awslambda_run,
    exe_run,
    standalone_run,
    // cloudflare_* (TBD)
    // flexilib_* (TBD)
};
// awslambda_package
// awslambda_iam
// awslambda_deploy
// awslambda_run
// exe_run // TODO: Can we skip this?
// cloudflare_* (TBD)
// flexilib_* (TBD)
pub fn configureBuild(b: *std.Build, exe: *std.Build.Step.Compile) !void {
    // Make our target platform visible to runtime through an import
    // called "build_options"
    var options_module: *std.Build.Module = undefined;
    {
        // We need to go through the command line args, look for argument(s)
        // between "build" and anything prefixed with "-". First take, blow up
        // if there is more than one. That's the step we're rolling with
        // These frameworks I believe are inextricably tied to both build and
        // run behavior
        const options = b.addOptions();
        options.addOption(BuildType, "build_type", .exe_run);
        exe.addOptions("build_options", options);
        options_module = exe.modules.get("build_options").?;
    }
    // Add modules
    {
        exe.addAnonymousModule("universal_lambda_handler", .{
            .source_file = .{ .path = "upstream/src/universal_lambda.zig" },
            .dependencies = &[_]std.Build.ModuleDependency{.{
                .name = "build_options",
                .module = options_module,
            }},
        });
    }

    // Add steps
}
