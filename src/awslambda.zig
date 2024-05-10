const std = @import("std");
const interface = @import("universal_lambda_interface");
const lambda_zig = @import("aws_lambda_runtime");

const log = std.log.scoped(.awslambda);

threadlocal var universal_handler: interface.HandlerFn = undefined;

/// This is called by the aws lambda runtime (our import), and must
/// call the universal handler (our downstream client). The main job here
/// is to convert signatures, ore more specifically, build out the context
/// that the universal handler is expecting
fn lambdaHandler(arena: std.mem.Allocator, event_data: []const u8) ![]const u8 {
    const response_body: std.ArrayList(u8) = std.ArrayList(u8).init(arena);
    // Marshal lambda_zig data into a context
    // TODO: Maybe this should parse API Gateway data into a proper response
    // TODO: environment variables -> Headers?
    var response = interface.Response{
        .allocator = arena,
        .headers = &.{},
        .body = response_body,
        .request = .{
            .headers = &.{},
        },
    };

    // Call back to the handler that we were given
    const result = universal_handler(arena, event_data, &response);

    // TODO: If our universal handler writes to the response body, we should
    // handle that in a consistent way

    // Return result from our handler back to AWS lambda via the lambda module
    return result;
}

// AWS lambda zig handler: const HandlerFn = *const fn (std.mem.Allocator, []const u8) anyerror![]const u8;
// Our handler:        pub const HandlerFn = *const fn (std.mem.Allocator, []const u8, Context) anyerror![]const u8;
pub fn run(allocator: ?std.mem.Allocator, event_handler: interface.HandlerFn) !u8 {
    universal_handler = event_handler;

    // pub fn run(allocator: ?std.mem.Allocator, event_handler: HandlerFn) !void { // TODO: remove inferred error set?
    try lambda_zig.run(allocator, lambdaHandler);
    return 0;
}

fn handler(allocator: std.mem.Allocator, event_data: []const u8) ![]const u8 {
    _ = allocator;
    return event_data;
}

////////////////////////////////////////////////////////////////////////
// All code below this line is for testing
////////////////////////////////////////////////////////////////////////
test {
    std.testing.refAllDecls(lambda_zig);
}
test "basic request" {
    // std.testing.log_level = .debug;
    const allocator = std.testing.allocator;
    const request =
        \\{"foo": "bar", "baz": "qux"}
    ;

    // This is what's actually coming back. Is this right?
    const expected_response =
        \\nothing but net
    ;
    const TestHandler = struct {
        pub fn handler(alloc: std.mem.Allocator, event_data: []const u8, context: interface.Context) ![]const u8 {
            _ = alloc;
            _ = event_data;
            _ = context;
            log.debug("in handler", .{});
            return "nothing but net";
        }
    };
    universal_handler = TestHandler.handler;
    const lambda_response = try lambda_zig.test_lambda_request(allocator, request, 1, lambdaHandler);
    defer lambda_zig.deinit();
    defer allocator.free(lambda_response);
    try std.testing.expectEqualStrings(expected_response, lambda_response);
}
