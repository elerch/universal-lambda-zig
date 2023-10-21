const std = @import("std");
const builtin = @import("builtin");
const CloudflareDeployStep = @import("CloudflareDeployStep");

const script = @embedFile("index.js");

pub fn configureBuild(b: *std.build.Builder, cs: *std.Build.Step.Compile, build_root_src: []const u8) !void {
    _ = build_root_src;
    const deploy_cmd = CloudflareDeployStep.create(
        b,
        "zigwasi",
        .{ .path = "index.js" },
        .{
            .primary_file_data = script,
            .wasm_name = .{
                .search = "zigout.wasm",
                .replace = cs.name,
            },
            .wasm_dir = b.getInstallDir(.bin, "."),
        },
    );
    deploy_cmd.step.dependOn(b.getInstallStep());

    const deploy_step = b.step("cloudflare", "Deploy as Cloudflare worker (must be compiled with -Dtarget=wasm32-wasi)");
    deploy_step.dependOn(&deploy_cmd.step);
}
