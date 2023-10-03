const std = @import("std");
const build_options = @import("build_options");
const flexilib = @import("flexilib-interface.zig"); // TODO: pull in flexilib directly
pub const HandlerFn = *const fn (std.mem.Allocator, []const u8, Context) anyerror![]const u8;

const log = std.log.scoped(.universal_lambda);

// TODO: Should this be union?
pub const Context = union(enum) {
    web_request: *std.http.Server.Response,
    flexilib: struct {
        request: flexilib.Request,
        response: flexilib.Response,
    },
    none: void,
};

const runFn = blk: {
    switch (build_options.build_type) {
        .awslambda => break :blk @import("lambda.zig").run,
        .standalone_server => break :blk runStandaloneServer,
        .exe_run => break :blk runExe,
        else => @compileError("Provider interface for " ++ @tagName(build_options.build_type) ++ " has not yet been implemented"),
    }
};

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
    try runFn(allocator, event_handler);
}

fn runExe(allocator: ?std.mem.Allocator, event_handler: HandlerFn) !void {
    var arena = std.heap.ArenaAllocator.init(allocator orelse std.heap.page_allocator);
    defer arena.deinit();

    const aa = arena.allocator();

    const data = try std.io.getStdIn().reader().readAllAlloc(aa, std.math.maxInt(usize));
    // We're setting up an arena allocator. While we could use a gpa and get
    // some additional safety, this is now "production" runtime, and those
    // things are better handled by unit tests
    const writer = std.io.getStdOut().writer();
    try writer.writeAll(try event_handler(aa, data, .{ .none = {} }));
    try writer.writeAll("\n");
}

/// Will create a web server and marshall all requests back to our event handler
/// To keep things simple, we'll have this on a single thread, at least for now
fn runStandaloneServer(allocator: ?std.mem.Allocator, event_handler: HandlerFn) !void {
    const alloc = allocator orelse std.heap.page_allocator;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var aa = arena.allocator();
    var server = std.http.Server.init(aa, .{ .reuse_address = true });
    defer server.deinit();
    const address = try std.net.Address.parseIp("127.0.0.1", 8080); // TODO: allow config
    try server.listen(address);
    const server_port = server.socket.listen_address.in.getPort();
    var uri: ["http://127.0.0.1:99999".len]u8 = undefined;
    _ = try std.fmt.bufPrint(&uri, "http://127.0.0.1:{d}", .{server_port});
    log.info("server listening at {s}", .{uri});

    // No threads, maybe later
    //log.info("starting server thread, tid {d}", .{std.Thread.getCurrentId()});
    while (true) {
        defer {
            if (!arena.reset(.{ .retain_with_limit = 1024 * 1024 })) {
                // reallocation failed, arena is degraded
                log.warn("Arena reset failed and is degraded. Resetting arena", .{});
                arena.deinit();
                arena = std.heap.ArenaAllocator.init(alloc);
                aa = arena.allocator();
            }
        }
        processRequest(aa, &server, event_handler) catch |e| {
            log.err("Unexpected error processing request: {any}", .{e});
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpStackTrace(trace.*);
            }
        };
    }
}

fn processRequest(aa: std.mem.Allocator, server: *std.http.Server, event_handler: HandlerFn) !void {
    var res = try server.accept(.{ .allocator = aa });
    defer {
        _ = res.reset();
        if (res.headers.owned and res.headers.list.items.len > 0) res.headers.deinit();
        res.deinit();
    }
    try res.wait(); // wait for client to send a complete request head

    const errstr = "Internal Server Error\n";
    var errbuf: [errstr.len]u8 = undefined;
    @memcpy(&errbuf, errstr);
    var response_bytes: []const u8 = errbuf[0..];

    var body =
        if (res.request.content_length) |l|
        try res.reader().readAllAlloc(aa, @as(usize, l))
    else
        try aa.dupe(u8, "");
    // no need to free - will be handled by arena

    response_bytes = event_handler(aa, body, .{ .web_request = &res }) catch |e| brk: {
        res.status = .internal_server_error;
        // TODO: more about this particular request
        log.err("Unexpected error from executor processing request: {any}", .{e});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        break :brk "Unexpected error generating request to lambda";
    };
    res.transfer_encoding = .{ .content_length = response_bytes.len };

    try res.do();
    _ = try res.writer().writeAll(response_bytes);
    try res.finish();
}

test {
    std.testing.refAllDecls(@This()); // standalone, standalone web server
    std.testing.refAllDecls(@import("lambda.zig")); // lambda
    // TODO: re-enable
    // std.testing.refAllDecls(@import("flexilib.zig")); // flexilib
}
