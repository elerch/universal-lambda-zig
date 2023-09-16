const std = @import("std");
const build_options = @import("build_options");

const HandlerFn = *const fn (std.mem.Allocator, []const u8, Context) anyerror![]const u8;

const log = std.log.scoped(.universal_lambda);

// TODO: Should this be union?
pub const Context = struct {};

fn deinit() void {
    // if (client) |*c| c.deinit();
    // client = null;
}
/// Starts the universal lambda framework. Handler will be called when an event is processing.
/// Depending on the serverless system used, from a practical sense, this may not return.
///
/// If an allocator is not provided, an approrpriate allocator will be selected and used
/// This function is intended to loop infinitely. If not used in this manner,
/// make sure to call the deinit() function
pub fn run(allocator: ?std.mem.Allocator, event_handler: HandlerFn) !void { // TODO: remove inferred error set?
    switch (build_options.build_type) {
        .exe_run => try runExe(allocator, event_handler),
        else => return error.NotImplemented,
    }
}

fn runExe(allocator: ?std.mem.Allocator, event_handler: HandlerFn) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const gpa_alloc = allocator orelse gpa.allocator();

    // TODO: set up an arena for this? Are we doing an arena for every type?
    const writer = std.io.getStdOut().writer();
    try writer.writeAll(try event_handler(gpa_alloc, "", .{}));
    try writer.writeAll("\n");
}
