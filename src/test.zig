const std = @import("std");

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(@import("universal_lambda.zig"));
}
