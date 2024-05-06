const std = @import("std");
const interface = @import("flexilib-interface");
const universal_lambda_interface = @import("universal_lambda_interface");
const testing = std.testing;

const log = std.log.scoped(.@"main-lib");

const Application = if (@import("builtin").is_test) @This() else @import("flexilib_handler");

// The main program will look for exports during the request lifecycle:
// zigInit (optional): called at the beginning of a request, includes pointer to an allocator
// handle_request: called with request data, expects response data
// request_deinit (optional): called at the end of a request to allow resource cleanup
//
// Setup for these is aided by the interface library as shown below

// zigInit is an optional export called at the beginning of a request. It will
// be passed an allocator (which...shh...is an arena allocator). Since the
// interface library provides a request handler that requires a built-in allocator,
// if you are using the interface's handleRequest function as shown above,
// you will need to also include this export. To customize, just do something
// like this:
//
// export fn zigInit(parent_allocator: *anyopaque) callconv(.C) void {
//   // your code here, just include the next line
//   interface.zigInit(parent_allocator);
// }
//
comptime {
    @export(interface.zigInit, .{ .name = "zigInit", .linkage = .strong });
}

/// handle_request will be called on a single request, but due to the preservation
/// of restrictions imposed by the calling interface, it should generally be more
/// useful to call into the interface library to let it do the conversion work
/// on your behalf
export fn handle_request(request: *interface.Request) callconv(.C) ?*interface.Response {
    // The interface library provides a handleRequest function that will handle
    // marshalling data back and forth from the C format used for the interface
    // to a more Zig friendly format. It also allows usage of zig errors. To
    // use, pass in the request and the zig function used to handle the request
    // (here called "handleRequest"). The function signature must be:
    //
    // fn (std.mem.Allocator, interface.ZigRequest, interface.ZigResponse) !void
    //
    return interface.handleRequest(request, handleRequest);
}

// request_deinit is an optional export and will be called a the end of the
// request. Useful for deallocating memory. Since this is zig code and the
// allocator used is an arena allocator, all allocated memory will be automatically
// cleaned up by the main program at the end of a request
//
// export fn request_deinit() void {
// }

// ************************************************************************
// Boilerplate ^^, Custom code vv
// ************************************************************************
//
// handleRequest function here is the last line of boilerplate and the
// entry to a request
fn handleRequest(allocator: std.mem.Allocator, response: *interface.ZigResponse) !void {
    // setup
    var response_writer = response.body.writer();
    // dispatch to our actual handler
    if (handler == null) _ = try Application.main();
    std.debug.assert(handler != null);
    // setup response
    var ul_response = universal_lambda_interface.Response.init(allocator);
    defer ul_response.deinit();
    ul_response.request.target = response.request.target;
    ul_response.request.headers = response.request.headers;
    ul_response.request.method = std.meta.stringToEnum(std.http.Method, response.request.method) orelse std.http.Method.GET;
    const builtin = @import("builtin");
    const supports_getrusage = builtin.os.tag != .windows and @hasDecl(std.posix.system, "rusage"); // Is Windows it?
    var rss: if (supports_getrusage) std.posix.rusage else void = undefined;
    if (supports_getrusage and builtin.mode == .Debug)
        rss = std.posix.getrusage(std.posix.rusage.SELF);
    const response_content = try handler.?(
        allocator,
        response.request.content,
        &ul_response,
    );
    if (supports_getrusage and builtin.mode == .Debug) { // and  debug mode) {
        const rusage = std.posix.getrusage(std.posix.rusage.SELF);
        log.debug(
            "Request complete, max RSS of process: {d}M. Incremental: {d}K, User: {d}μs, System: {d}μs",
            .{
                @divTrunc(rusage.maxrss, 1024),
                rusage.maxrss - rss.maxrss,
                (rusage.utime.tv_sec - rss.utime.tv_sec) * std.time.us_per_s +
                    rusage.utime.tv_usec - rss.utime.tv_usec,
                (rusage.stime.tv_sec - rss.stime.tv_sec) * std.time.us_per_s +
                    rusage.stime.tv_usec - rss.stime.tv_usec,
            },
        );
    }
    response.headers = ul_response.headers;
    // Anything manually written goes first
    try response_writer.writeAll(ul_response.body.items);
    // Now we right the official body (response from handler)
    try response_writer.writeAll(response_content);
}

pub fn run(allocator: ?std.mem.Allocator, event_handler: universal_lambda_interface.HandlerFn) !u8 {
    _ = allocator;
    register(event_handler);
    return 0;
}

var handler: ?universal_lambda_interface.HandlerFn = null;
/// Registers a handler function with flexilib
pub fn register(h: universal_lambda_interface.HandlerFn) void {
    handler = h;
}
pub fn main() !u8 {
    // should only be called under test!
    // Flexilib runs under a DLL. So the plan is:
    // 1. dll calls handle_request
    // 2. handle_request discovers, through build, where it came from
    // 3. handle_request calls main
    // 4. main, in the application, calls run, thinking it's a console app
    // 5. run, calls back to universal lambda, which then calls back here to register
    // 6. register, registers the handler. It will need to be up to main() to recognize
    //    build_options and look for flexilib if they're doing something fancy
    register(testHandler);
    return 0;
}
fn testHandler(allocator: std.mem.Allocator, event_data: []const u8, context: @import("universal_lambda_interface").Context) ![]const u8 {
    context.headers = &.{.{ .name = "X-custom-foo", .value = "bar" }};
    try context.writeAll(event_data);
    return std.fmt.allocPrint(allocator, "{d}", .{context.request.headers.len});
}
// Need to figure out how tests would work
test "handle_request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var aa = arena.allocator();
    interface.zigInit(&aa);
    const headers: []interface.Header = @constCast(&[_]interface.Header{.{
        .name_ptr = @ptrCast(@constCast("GET".ptr)),
        .name_len = 3,
        .value_ptr = @ptrCast(@constCast("GET".ptr)),
        .value_len = 3,
    }});
    var req = interface.Request{
        .method = @ptrCast(@constCast("GET".ptr)),
        .method_len = 3,
        .content = @ptrCast(@constCast(" ".ptr)),
        .content_len = 1,
        .headers = headers.ptr,
        .headers_len = 1,
        .target = @ptrCast(@constCast("/".ptr)),
        .target_len = 1,
    };
    const response = handle_request(&req).?;
    try testing.expectEqualStrings(" 1", response.ptr[0..response.len]);
    try testing.expectEqual(@as(usize, 1), response.headers_len);
    try testing.expectEqualStrings("X-custom-foo", response.headers[0].name_ptr[0..response.headers[0].name_len]);
    try testing.expectEqualStrings("bar", response.headers[0].value_ptr[0..response.headers[0].value_len]);
}
