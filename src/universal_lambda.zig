const std = @import("std");
const build_options = @import("build_options");
const flexilib = @import("flexilib-interface");
const interface = @import("universal_lambda_interface");

const log = std.log.scoped(.universal_lambda);

const runFn = blk: {
    switch (build_options.build_type) {
        .awslambda => break :blk @import("lambda.zig").run,
        .standalone_server => break :blk runStandaloneServer,
        .flexilib => break :blk @import("flexilib.zig").run,
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

/// Will create a web server and marshall all requests back to our event handler
/// To keep things simple, we'll have this on a single thread, at least for now
fn runStandaloneServer(allocator: ?std.mem.Allocator, event_handler: interface.HandlerFn) !u8 {
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
    return 0;
}

fn processRequest(aa: std.mem.Allocator, server: *std.http.Server, event_handler: interface.HandlerFn) !void {
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
        if (res.status.class() == .success) res.status = .internal_server_error;
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
    std.testing.refAllDecls(@This());
    // if (builtin.os.tag == .wasi) return error.SkipZigTest;
    if (@import("builtin").os.tag != .wasi) {
        // these use http
        std.testing.refAllDecls(@import("lambda.zig"));
        std.testing.refAllDecls(@import("cloudflaredeploy.zig"));
        std.testing.refAllDecls(@import("CloudflareDeployStep.zig"));
    }
    std.testing.refAllDecls(@import("console.zig"));
    std.testing.refAllDecls(@import("flexilib.zig"));

    // The following do not currently have tests

    // TODO: Do we want build files here too?
}

fn testRequest(request_bytes: []const u8, event_handler: interface.HandlerFn) !void {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var server = std.http.Server.init(allocator, .{ .reuse_address = true });
    defer server.deinit();

    const address = try std.net.Address.parseIp("127.0.0.1", 0);
    try server.listen(address);
    const server_port = server.socket.listen_address.in.getPort();

    var al = std.ArrayList(u8).init(allocator);
    defer al.deinit();
    var writer = al.writer();
    _ = writer;
    var aa = arena.allocator();
    var bytes_allocated: usize = 0;
    // pre-warm
    const server_thread = try std.Thread.spawn(
        .{},
        processRequest,
        .{ aa, &server, event_handler },
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
