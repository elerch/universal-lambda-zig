const std = @import("std");

pub const HandlerFn = *const fn (std.mem.Allocator, []const u8, Context) anyerror![]const u8;

pub const Response = struct {
    allocator: std.mem.Allocator,
    headers: []const std.http.Header,
    headers_owned: bool = true,
    status: std.http.Status = .ok,
    reason: ?[]const u8 = null,
    /// client request. Note that in AWS lambda, all these are left at default.
    /// It is currently up to you to work through a) if API Gateway is set up,
    /// and b) how that gets parsed into event data. API Gateway has the ability
    /// to severely muck with inbound data and we are unprepared to deal with
    /// that here
    request: struct {
        target: []const u8 = "/",
        headers: []const std.http.Header,
        headers_owned: bool = true,
        method: std.http.Method = .GET,
    },
    body: std.ArrayList(u8),

    // The problem we face is this:
    //
    // exe_run, cloudflare (wasi) are basically console apps
    // flexilib is a web server (wierd one)
    // standalone web server is a web server
    // aws lambda is a web client
    //
    // void will work for exe_run/cloudflare
    // ZigResponse works out of the box for flexilib - the lifecycle problem is
    // handled in the interface
    //
    // aws lambda - need to investigate
    // standalone web server...needs to spool
    pub fn init(allocator: std.mem.Allocator) Response {
        return .{
            .allocator = allocator,
            .headers = &.{},
            .request = .{
                .headers = &.{},
            },
            .body = std.ArrayList(u8).init(allocator),
        };
    }
    pub fn write(res: *Response, bytes: []const u8) !usize {
        return res.body.writer().write(bytes);
    }

    pub fn writeAll(res: *Response, bytes: []const u8) !void {
        return res.body.writer().writeAll(bytes);
    }

    pub fn writer(res: *Response) std.io.Writer(*Response, error{OutOfMemory}, writeFn) {
        return .{ .context = res };
    }

    fn writeFn(context: *Response, data: []const u8) error{OutOfMemory}!usize {
        return try context.write(data);
    }
    pub fn deinit(res: *Response) void {
        res.body.deinit();
        if (res.headers_owned) res.allocator.free(res.headers);
        if (res.request.headers_owned) res.allocator.free(res.request.headers);
    }
};

pub const Context = *Response;
