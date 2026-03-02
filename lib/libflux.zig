const std = @import("std");

pub const LIBFLUX_VERSION = "0.0.1";

pub fn version() []const u8 {
    return LIBFLUX_VERSION;
}

test "library version is defined" {
    try std.testing.expect(version().len != 0);
}
