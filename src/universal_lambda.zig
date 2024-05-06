const std = @import("std");
const build_options = @import("universal_lambda_build_options");
const flexilib = @import("flexilib-interface");
const interface = @import("universal_lambda_interface");

const log = std.log.scoped(.universal_lambda);

const runFn = blk: {
    switch (build_options.build_type) {
        .awslambda => break :blk @import("awslambda.zig").run,
        .standalone_server => break :blk runStandaloneServerParent,
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

/// We need to create a child process to be able to deal with panics appropriately
fn runStandaloneServerParent(allocator: ?std.mem.Allocator, event_handler: interface.HandlerFn) !u8 {
    const alloc = allocator orelse std.heap.page_allocator;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const aa = arena.allocator();
    var al = std.ArrayList([]const u8).init(aa);
    defer al.deinit();
    var argi = std.process.args();
    // We do this first so it shows more prominently when looking at processes
    // Also it will be slightly faster for whatever that is worth
    const child_arg = "--child_of_standalone_server";
    if (argi.next()) |a| try al.append(a);
    try al.append(child_arg);
    while (argi.next()) |a| {
        if (std.mem.eql(u8, child_arg, a)) {
            // This should never actually return
            return try runStandaloneServer(allocator, event_handler);
        }
        try al.append(a);
    }
    // Parent
    const stdin = std.io.getStdIn();
    const stdout = std.io.getStdOut();
    const stderr = std.io.getStdErr();
    while (true) {
        var cp = std.ChildProcess.init(al.items, alloc);
        cp.stdin = stdin;
        cp.stdout = stdout;
        cp.stderr = stderr;
        _ = try cp.spawnAndWait();
        try stderr.writeAll("Caught abnormal process termination, relaunching server");
    }
}

/// Will create a web server and marshall all requests back to our event handler
/// To keep things simple, we'll have this on a single thread, at least for now
fn runStandaloneServer(allocator: ?std.mem.Allocator, event_handler: interface.HandlerFn) !u8 {
    // TODO: Get this under test. It doesn't work in zig 0.12.0
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
        const builtin = @import("builtin");
        const supports_getrusage = builtin.os.tag != .windows and @hasDecl(std.os.system, "rusage"); // Is Windows it?
        var rss: if (supports_getrusage) std.os.rusage else void = undefined;
        if (supports_getrusage and builtin.mode == .Debug)
            rss = std.os.getrusage(std.os.rusage.SELF);
        processRequest(aa, &server, event_handler) catch |e| {
            log.err("Unexpected error processing request: {any}", .{e});
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpStackTrace(trace.*);
            }
        };
        if (supports_getrusage and builtin.mode == .Debug) { // and  debug mode) {
            const rusage = std.os.getrusage(std.os.rusage.SELF);
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
    }
    return 0;
}

fn processRequest(aa: std.mem.Allocator, server: *std.net.Server, event_handler: interface.HandlerFn) !void {
    var connection = try server.accept();
    defer connection.stream.close();

    var read_buffer: [1024 * 16]u8 = undefined; // TODO: Fix this
    var server_connection = std.http.Server.init(connection, &read_buffer);
    var req = try server_connection.receiveHead();

    const request_body = try (try req.reader()).readAllAlloc(aa, @as(usize, std.math.maxInt(usize)));
    var request_headers = std.ArrayList(std.http.Header).init(aa);
    defer request_headers.deinit();
    var hi = req.iterateHeaders();
    while (hi.next()) |h| try request_headers.append(h);

    var response = interface.Response.init(aa);
    defer response.deinit();
    response.request.headers = request_headers.items;
    response.request.headers_owned = false;
    response.request.target = req.head.target;
    response.request.method = req.head.method;
    response.headers = &.{};
    response.headers_owned = false;

    var respond_options = std.http.Server.Request.RespondOptions{};
    const response_bytes = event_handler(aa, request_body, &response) catch |e| brk: {
        respond_options.status = response.status;
        respond_options.reason = response.reason;
        if (respond_options.status.class() == .success) {
            respond_options.status = .internal_server_error;
            respond_options.reason = null;
            response.body.items = "";
        }
        // TODO: stream body to client? or keep internal?
        // TODO: more about this particular request
        log.err("Unexpected error from executor processing request: {any}", .{e});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        break :brk "Unexpected error generating request to lambda";
    };

    const final_response = try std.mem.concat(aa, u8, &[_][]const u8{ response.body.items, response_bytes });
    try req.respond(final_response, respond_options);
}
test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(@import("console.zig"));
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

fn testRequest(request_bytes: []const u8, event_handler: interface.HandlerFn) !void {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const address = try std.net.Address.parseIp("127.0.0.1", 0);
    var http_server = try address.listen(.{ .reuse_address = true });
    const server_port = http_server.listen_address.in.getPort();

    var al = std.ArrayList(u8).init(allocator);
    defer al.deinit();
    const writer = al.writer();
    _ = writer;
    const aa = arena.allocator();
    const bytes_allocated: usize = 0;
    // pre-warm
    const server_thread = try std.Thread.spawn(
        .{},
        processRequest,
        .{ aa, &http_server, event_handler },
    );

    const stream = try std.net.tcpConnectToHost(allocator, "127.0.0.1", server_port);
    defer stream.close();
    _ = try stream.writeAll(request_bytes[0..]);

    server_thread.join();
    log.debug("Bytes allocated during request: {d}", .{arena.queryCapacity() - bytes_allocated});
    log.debug("Stdout: {s}", .{al.items});
}

fn testGet(comptime path: []const u8, event_handler: interface.HandlerFn) !void {
    try testRequest("GET " ++ path ++ " HTTP/1.1\r\n" ++
        "Accept: */*\r\n" ++
        "\r\n", event_handler);
}
test "can make a request" {
    if (@import("builtin").os.tag == .wasi) return error.SkipZigTest;
    const HandlerClosure = struct {
        var data_received: []const u8 = undefined;
        var context_received: interface.Context = undefined;
        const Self = @This();
        pub fn handler(allocator: std.mem.Allocator, event_data: []const u8, context: interface.Context) ![]const u8 {
            _ = allocator;
            data_received = event_data;
            context_received = context;
            return "success";
        }
    };
    try testGet("/", HandlerClosure.handler);
}
