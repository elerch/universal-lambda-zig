const build_options = @import("universal_lambda_build_options");
const std = @import("std");
const interface = @import("universal_lambda_interface");

const log = std.log.scoped(.universal_lambda);

const runFn = blk: {
    switch (build_options.build_type) {
        .awslambda => break :blk @import("awslambda.zig").run,
        .standalone_server => break :blk @import("standalone_server.zig").runStandaloneServerParent,
        // In the case of flexilib, our root module is actually flexilib.zig
        // so we need to import that, otherwise we risk the dreaded "file exists
        // in multiple modules" problem
        .flexilib => break :blk @import("root").run,
        .exe_run, .cloudflare => break :blk @import("console.zig").run,
    }
};

/// Starts the universal lambda framework. Handler will be called when an event is processing.
/// Depending on the serverless system used, from a practical sense, this may not return.
///
/// If an allocator is not provided, an approrpriate allocator will be selected and used
/// This function is intended to loop infinitely. If not used in this manner,
/// make sure to call the deinit() function
pub fn run(allocator: ?std.mem.Allocator, event_handler: interface.HandlerFn) !u8 { // TODO: remove inferred error set?
    return try runFn(allocator, event_handler);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(@import("console.zig"));
    std.testing.refAllDecls(@import("standalone_server.zig"));
    std.testing.refAllDecls(@import("awslambda.zig"));
    // By importing flexilib.zig, this breaks downstream any time someone
    // tries to build flexilib, because flexilib.zig becomes the root module,
    // then gets imported here again. It shouldn't be done unless doing
    // zig build test, but it is. So we need to figure that out at some point...
    // const root = @import("root");
    // if (@hasDecl(root, "run") and @hasDecl(root, "register"))
    //     std.testing.refAllDecls(root)
    // else
    //     std.testing.refAllDecls(@import("flexilib.zig"));
    //
    // What we need to do here is update our own build.zig to add a specific
    // test with flexilib as root. That will match the behavior of downstream

    // The following do not currently have tests

    // TODO: Do we want build files here too?
}
