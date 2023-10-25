//! This consists of helper functions to provide simple access using standard
//! patterns.
const std = @import("std");
const interface = @import("universal_lambda_interface");

const Option = struct {
    short: []const u8,
    long: []const u8,
};

const target_option: Option = .{ .short = "t", .long = "target" };
const url_option: Option = .{ .short = "u", .long = "url" };
const header_option: Option = .{ .short = "h", .long = "header" };
const method_option: Option = .{ .short = "m", .long = "method" };

pub fn run(allocator: ?std.mem.Allocator, event_handler: interface.HandlerFn) !u8 {
    var arena = std.heap.ArenaAllocator.init(allocator orelse std.heap.page_allocator);
    defer arena.deinit();

    const aa = arena.allocator();

    const is_test = @import("builtin").is_test;
    const data = if (is_test)
        test_content
    else
        try std.io.getStdIn().reader().readAllAlloc(aa, std.math.maxInt(usize));
    // We're setting up an arena allocator. While we could use a gpa and get
    // some additional safety, this is now "production" runtime, and those
    // things are better handled by unit tests
    var response = interface.Response.init(aa);
    defer response.deinit();
    var headers = try findHeaders(aa);
    defer headers.deinit();
    response.request.headers = headers.http_headers.*;
    response.request.headers_owned = false;
    response.request.target = try findTarget(aa);
    response.request.method = try findMethod(aa);
    // Note here we are throwing out the status and reason. This is to make
    // the console experience less "webby" and more "consoly", at the potential
    // cost of data loss for not outputting the http status/reason
    const output = event_handler(aa, data, &response) catch |err| {
        const err_writer = if (is_test)
            test_output.writer()
        else
            std.io.getStdErr();

        // Flush anything already written by the handler
        try err_writer.writeAll(response.body.items);
        return err;
    };

    const writer = if (is_test)
        test_output.writer()
    else if (response.status.class() == .success) std.io.getStdOut() else std.io.getStdErr();

    // First flush anything written by the handler
    try writer.writeAll(response.body.items);

    // Now flush the result
    try writer.writeAll(output);
    try writer.writeAll("\n");
    // We might have gotten an error message managed directly by the event handler
    // If that's the case, we will need to report back an error code
    return if (response.status.class() == .success) 0 else 1;
}

fn findMethod(allocator: std.mem.Allocator) !std.http.Method {
    // without context, we have environment variables (but for this, I think not),
    // possibly event data (API Gateway does this if so configured),
    // or the command line. For now we'll just look at the command line
    var argIterator = try std.process.argsWithAllocator(allocator);
    _ = argIterator.next();
    var is_target_option = false;
    while (argIterator.next()) |arg| {
        if (is_target_option) {
            if (std.mem.startsWith(u8, arg, "-") or
                std.mem.startsWith(u8, arg, "--"))
                return error.CommandLineError;
            return std.meta.stringToEnum(std.http.Method, arg) orelse return error.BadMethod;
        }
        if (std.mem.startsWith(u8, arg, "-" ++ method_option.short) or
            std.mem.startsWith(u8, arg, "--" ++ method_option.long))
        {
            // We'll search for --target=blah style first
            var split = std.mem.splitSequence(u8, arg, "=");
            _ = split.next();
            const rest = split.rest();
            if (split.next()) |_|
                return std.meta.stringToEnum(std.http.Method, rest) orelse return error.BadMethod;
            is_target_option = true;
        }
    }
    return .GET;
}
fn findTarget(allocator: std.mem.Allocator) ![]const u8 {
    // without context, we have environment variables (but for this, I think not),
    // possibly event data (API Gateway does this if so configured),
    // or the command line. For now we'll just look at the command line
    var argIterator = try std.process.argsWithAllocator(allocator);
    _ = argIterator.next();
    var is_target_option = false;
    var is_url_option = false;
    while (argIterator.next()) |arg| {
        if (is_target_option or is_url_option) {
            if (std.mem.startsWith(u8, arg, "-") or
                std.mem.startsWith(u8, arg, "--"))
                return error.CommandLineError;
            if (is_target_option)
                return arg;
            return (try std.Uri.parse(arg)).path;
        }
        if (std.mem.startsWith(u8, arg, "-" ++ target_option.short) or
            std.mem.startsWith(u8, arg, "--" ++ target_option.long))
        {
            // We'll search for --target=blah style first
            var split = std.mem.splitSequence(u8, arg, "=");
            _ = split.next();
            const rest = split.rest();
            if (split.next()) |_| return rest; // found it
            is_target_option = true;
        }
        if (std.mem.startsWith(u8, arg, "-" ++ url_option.short) or
            std.mem.startsWith(u8, arg, "--" ++ url_option.long))
        {
            // We'll search for --target=blah style first
            var split = std.mem.splitSequence(u8, arg, "=");
            _ = split.next();
            const rest = split.rest();
            if (split.next()) |_| return (try std.Uri.parse(rest)).path; // found it
            is_url_option = true;
        }
    }
    return "/";
}

pub const Headers = struct {
    http_headers: *std.http.Headers,
    owned: bool,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, headers: *std.http.Headers, owned: bool) Self {
        return .{
            .http_headers = headers,
            .owned = owned,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.owned) {
            self.http_headers.deinit();
            self.allocator.destroy(self.http_headers);
            self.http_headers = undefined;
        }
    }
};

// Get headers from request. Headers will be gathered from the command line
// and include all environment variables
pub fn findHeaders(allocator: std.mem.Allocator) !Headers {
    var headers = try allocator.create(std.http.Headers);
    errdefer allocator.destroy(headers);
    headers.allocator = allocator;
    headers.list = .{};
    headers.index = .{};
    headers.owned = true;
    errdefer headers.deinit();

    // without context, we have environment variables
    // possibly event data (API Gateway does this if so configured),
    // or the command line. For headers, we'll prioritize command line options
    // with a fallback to environment variables
    const is_test = @import("builtin").is_test;
    var argIterator = if (is_test) test_args.iterator(0) else try std.process.argsWithAllocator(allocator);
    _ = argIterator.next();
    var is_header_option = false;
    while (argIterator.next()) |a| {
        const arg = if (is_test) a.* else a;
        if (is_header_option) {
            if (std.mem.startsWith(u8, arg, "-") or
                std.mem.startsWith(u8, arg, "--"))
                return error.CommandLineError;
            is_header_option = false;
            var split = std.mem.splitSequence(u8, arg, "=");
            const name = split.next().?;
            try headers.append(name, split.rest());
        }
        if (std.mem.startsWith(u8, arg, "-" ++ header_option.short) or
            std.mem.startsWith(u8, arg, "--" ++ header_option.long))
        {
            // header option forms on command line:
            // -h name=value
            // --header name=value
            is_header_option = true;
        }
    }
    if (is_test) return Headers.init(allocator, headers, true);

    // not found on command line. Let's check environment
    var map = try std.process.getEnvMap(allocator);
    defer map.deinit();
    var it = map.iterator();
    while (it.next()) |kvp| {
        // Do not allow environment variables to interfere with command line
        if (headers.getFirstValue(kvp.key_ptr.*) == null)
            try headers.append(
                kvp.key_ptr.*,
                kvp.value_ptr.*,
            );
    }
    return Headers.init(allocator, headers, true);
}

test {
    std.testing.refAllDecls(@This());
}

test "can get headers" {
    // const ll = std.testing.log_level;
    // std.testing.log_level = .debug;
    // defer std.testing.log_level = ll;
    // This test complains about a leak in WASI, but in WASI, we're not running
    // long processes (just command line stuff), so we don't really care about
    // leaks. There doesn't seem to be a way to ignore leak detection
    if (@import("builtin").os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    test_args = .{};
    defer test_args.deinit(allocator);
    try test_args.append(allocator, "mainexe");
    try test_args.append(allocator, "-h");
    try test_args.append(allocator, "X-Foo=Bar");
    var headers = try findHeaders(allocator);
    defer headers.deinit();
    try std.testing.expectEqual(@as(usize, 1), headers.http_headers.list.items.len);
}

fn testHandler(allocator: std.mem.Allocator, event_data: []const u8, context: interface.Context) ![]const u8 {
    try context.headers.append("X-custom-foo", "bar");
    try context.writeAll(event_data);
    return std.fmt.allocPrint(allocator, "{d}", .{context.request.headers.list.items.len});
}

var test_args: std.SegmentedList([]const u8, 8) = undefined;
var test_content: []const u8 = undefined;
var test_output: std.ArrayList(u8) = undefined;
// Need to figure out how tests would work
test "handle_request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var aa = arena.allocator();
    test_args = .{};
    defer test_args.deinit(aa);
    try test_args.append(aa, "mainexe");
    try test_args.append(aa, "-t");
    try test_args.append(aa, "/hello");

    try test_args.append(aa, "-m");
    try test_args.append(aa, "PUT");

    try test_args.append(aa, "-h");
    try test_args.append(aa, "X-Foo=Bar");

    test_content = " ";
    test_output = std.ArrayList(u8).init(aa);
    defer test_output.deinit();
    const response = try run(aa, testHandler);
    try std.testing.expectEqualStrings(" 1\n", test_output.items);
    try std.testing.expectEqual(@as(u8, 0), response);
    // Response headers won't be visible in a console app
    // try testing.expectEqual(@as(usize, 1), response.headers_len);
    // try testing.expectEqualStrings("X-custom-foo", response.headers[0].name_ptr[0..response.headers[0].name_len]);
    // try testing.expectEqualStrings("bar", response.headers[0].value_ptr[0..response.headers[0].value_len]);
}
