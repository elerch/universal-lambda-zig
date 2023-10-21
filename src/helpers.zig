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

pub fn getFirstHeaderValue(allocator: std.mem.Allocator, context: universal_lambda.Context, header_name: []const u8) !?[]const u8 {
    switch (context) {
        .web_request => |res| return res.request.headers.getFirstValue(header_name),
        .flexilib => |ctx| {
            for (ctx.request.headers) |hdr| {
                if (std.ascii.eqlIgnoreCase(hdr.name_ptr[0..hdr.name_len], header_name)) {
                    return hdr.value_ptr[0..hdr.value_len];
                }
            }
            return null;
        },
        .none => return findHeaderWithoutContext(allocator, header_name),
    }
}

fn findHeaderWithoutContext(allocator: std.mem.Allocator, header_name: []const u8) !?[]const u8 {
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
            var split = std.mem.splitSequence(u8, arg, "=");
            const name = split.next().?;
            if (!std.ascii.eqlIgnoreCase(name, header_name)) continue;
            if (split.next()) |s| return s; // found it
            continue; // bad format, but we're not returning errors. We can cope with this one though
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
        // TODO: This is the only place where allocation is necessary. This
        // will work, because in reality there is always an area allocator passed
        // to us. But if there's not....
        if (std.ascii.eqlIgnoreCase(kvp.key_ptr.*, header_name))
            return try allocator.dupe(u8, kvp.value_ptr.*);
    }
    return null; // nowhere to be found
}
