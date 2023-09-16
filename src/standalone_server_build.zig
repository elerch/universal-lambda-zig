const std = @import("std");
const builtin = @import("builtin");

/// adds a build step to the build
///
/// * standalone_server: This will run the handler as a standalone web server
///
pub fn configureBuild(b: *std.build.Builder, exe: *std.Build.Step.Compile) !void {
    _ = exe;
    // We don't actually need to do much here. Basically we need a dummy step,
    // but one which the user will select, which will allow our options mechanism
    // to kick in

    // Package step
    const standalone_step = b.step("standalone_server", "Run the function in its own web server");
    standalone_step.dependOn(b.getInstallStep());
}
