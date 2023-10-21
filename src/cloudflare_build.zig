const std = @import("std");
const builtin = @import("builtin");
const CloudflareDeployStep = @import("CloudflareDeployStep.zig");

const script = @embedFile("index.js");

pub fn configureBuild(b: *std.build.Builder, cs: *std.Build.Step.Compile, function_name: []const u8) !void {
    const wasm_name = try std.fmt.allocPrint(b.allocator, "{s}.wasm", .{cs.name});
    const deploy_cmd = CloudflareDeployStep.create(
        b,
        function_name,
        .{ .path = "index.js" },
        .{
            .primary_file_data = script,
            .wasm_name = .{
                .search = "custom.wasm",
                .replace = wasm_name,
            },
            .wasm_dir = b.getInstallPath(.bin, "."),
        },
    );
    deploy_cmd.step.dependOn(b.getInstallStep());

    const deploy_step = b.step("cloudflare", "Deploy as Cloudflare worker (must be compiled with -Dtarget=wasm32-wasi)");
    deploy_step.dependOn(&deploy_cmd.step);
}
