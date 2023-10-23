//! This consists of helper functions to provide simple access using standard
//! patterns.
const std = @import("std");
const universal_lambda = @import("universal_lambda_handler");

const Option = struct {
    short: []const u8,
    long: []const u8,
};

const target_option: Option = .{ .short = "t", .long = "target" };
const header_option: Option = .{ .short = "h", .long = "header" };

/// Finds the "target" for this request. In a web request, this is the path
/// used for the request (e.g. "/" vs "/admin"). In a non-web environment,
/// this is determined by a command line option -t or --target. Note that
/// AWS API Gateway is not supported here...this is a configured thing in
/// API Gateway, and so is pretty situational. It also would be presented in
/// event data rather than context
pub fn findTarget(allocator: std.mem.Allocator, context: universal_lambda.Context) ![]const u8 {
    switch (context) {
        .web_request => |res| return res.request.target,
        .flexilib => |ctx| return ctx.request.target,
        .none => return findTargetWithoutContext(allocator),
    }
}

fn findTargetWithoutContext(allocator: std.mem.Allocator) ![]const u8 {
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
            {
                // bad user input, but we're not returning errors here
                return "/";
            }
            return arg;
        }
        if (std.mem.startsWith(u8, arg, "-" ++ target_option.short) or
            std.mem.startsWith(u8, arg, "--" ++ target_option.long))
        {
            // We'll search for --target=blah style first
            var split = std.mem.splitSequence(u8, arg, "=");
            _ = split.next();
            if (split.next()) |s| return s; // found it
            is_target_option = true;
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

/// Get headers from request. If Lambda is not in a web context, headers
/// will be gathered from the command line and include all environment variables
pub fn allHeaders(allocator: std.mem.Allocator, context: universal_lambda.Context) !Headers {
    switch (context) {
        .web_request => |res| return Headers.init(allocator, &res.request.headers, false),
        .flexilib => |ctx| return Headers.init(allocator, &ctx.request.headers, false),
        .none => return headersWithoutContext(allocator),
    }
}

fn headersWithoutContext(allocator: std.mem.Allocator) !Headers {
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
    var argIterator = try std.process.argsWithAllocator(allocator);
    _ = argIterator.next();
    var is_header_option = false;
    while (argIterator.next()) |arg| {
        if (is_header_option) {
            if (std.mem.startsWith(u8, arg, "-") or
                std.mem.startsWith(u8, arg, "--"))
            {
                return error.CommandLineError;
            }
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
    return Headers.init(allocator, headers, true); // nowhere to be found
}

test {
    std.testing.refAllDecls(@This());
}

test "can get headers" {
    // This test complains about a leak in WASI, but in WASI, we're not running
    // long processes (just command line stuff), so we don't really care about
    // leaks. There doesn't seem to be a way to ignore leak detection
    if (@import("builtin").os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var response = universal_lambda.Response.init(allocator);
    const context = universal_lambda.Context{
        .none = &response,
    };
    var headers = try allHeaders(allocator, context);
    defer headers.deinit();
    try std.testing.expect(headers.http_headers.list.items.len > 0);
}
