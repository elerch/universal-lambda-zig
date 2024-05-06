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

    // const file_location = try addModules(b, cs);

    // Add steps
    try @import("lambda-zig").configureBuild(b, cs, function_name);
    try @import("cloudflare-worker-deploy").configureBuild(b, cs, function_name);
    // try @import("flexilib_build.zig").configureBuild(b, cs, file_location);
    try @import("standalone_server_build.zig").configureBuild(b, cs);
}

/// Add modules
///
/// We will create the following modules for downstream consumption:
///
/// * universal_lambda_build_options
/// * flexilib-interface
/// * universal_lambda_handler
pub fn addImports(b: *std.Build, cs: *std.Build.Step.Compile, universal_lambda_zig_dep: ?*std.Build.Dependency) void {
    const Modules = struct {
        flexilib_interface: *std.Build.Module,
        universal_lambda_interface: *std.Build.Module,
        universal_lambda_handler: *std.Build.Module,
        universal_lambda_build_options: *std.Build.Module,
    };
    const modules =
        if (universal_lambda_zig_dep) |d|
        Modules{
            .flexilib_interface = d.module("flexilib-interface"),
            .universal_lambda_interface = d.module("universal_lambda_interface"),
            .universal_lambda_handler = d.module("universal_lambda_handler"),
            .universal_lambda_build_options = createOptionsModule(d.builder, cs),
        }
    else
        Modules{
            .flexilib_interface = b.modules.get("flexilib-interface").?,
            .universal_lambda_interface = b.modules.get("universal_lambda_interface").?,
            .universal_lambda_handler = b.modules.get("universal_lambda_handler").?,
            .universal_lambda_build_options = createOptionsModule(b, cs),
        };

    cs.root_module.addImport("universal_lambda_build_options", modules.universal_lambda_build_options);
    cs.root_module.addImport("flexilib-interface", modules.flexilib_interface);
    cs.root_module.addImport("universal_lambda_interface", modules.universal_lambda_interface);
    cs.root_module.addImport("universal_lambda_handler", modules.universal_lambda_handler);

    // universal lambda handler also needs these imports
    modules.universal_lambda_handler.addImport("universal_lambda_interface", modules.universal_lambda_interface);
    modules.universal_lambda_handler.addImport("flexilib-interface", modules.flexilib_interface);
    modules.universal_lambda_handler.addImport("universal_lambda_build_options", modules.universal_lambda_build_options);

    return;
}

/// Make our target platform visible to runtime through an import
/// called "universal_lambda_build_options". This will also be available to the consuming
/// executable if needed
pub fn createOptionsModule(b: *std.Build, cs: *std.Build.Step.Compile) *std.Build.Module {
    if (b.modules.get("universal_lambda_build_options")) |m| return m;

    // We need to go through the command line args, look for argument(s)
    // between "build" and anything prefixed with "-". First take, blow up
    // if there is more than one. That's the step we're rolling with
    // These frameworks I believe are inextricably tied to both build and
    // run behavior.
    //
    const args = std.process.argsAlloc(b.allocator) catch @panic("OOM");
    defer b.allocator.free(args);
    const options = b.addOptions();
    options.addOption(BuildType, "build_type", findBuildType(args) orelse .exe_run);
    // The normal way to do this is with module.addOptions, but that actually just does
    // an import, even though the parameter there is "module_name". addImport takes
    // a module, but in zig 0.12.0, that's using options.createModule(), which creates
    // a private module. This is a good default for them, but doesn't work for us
    const module = b.addModule("universal_lambda_build_options", .{
        .root_source_file = options.getOutput(),
    });
    cs.root_module.addImport("universal_lambda_build_options", module);
    return module;
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
