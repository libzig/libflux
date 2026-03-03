const std = @import("std");
const libflux = @import("libflux");

test "lsquic parity wt settings ids negotiate expected capabilities" {
    var n = libflux.wt_core.Negotiator.init();

    try n.apply_local_h3_settings(&.{
        .{ .id = 0x08, .value = 1 },
        .{ .id = 0x33, .value = 1 },
        .{ .id = 0x2b603742, .value = 1 },
        .{ .id = 0x2b603743, .value = 8 },
    });

    try n.apply_peer_h3_settings(&.{
        .{ .id = 0x08, .value = 1 },
        .{ .id = 0x33, .value = 0 },
        .{ .id = 0x2b603742, .value = 1 },
        .{ .id = 0x2b603743, .value = 3 },
    });

    const features = n.negotiate();
    try std.testing.expect(features.supports_webtransport());
    try std.testing.expect(!features.supports_webtransport_datagrams());
    try std.testing.expectEqual(@as(u64, 3), features.webtransport_max_sessions);
}

test "lsquic parity wt settings reject invalid values" {
    var n = libflux.wt_core.Negotiator.init();

    try std.testing.expectError(libflux.errors.FluxError.settings_error, n.apply_local_h3_settings(&.{
        .{ .id = 0x2b603742, .value = 2 },
        .{ .id = 0x2b603743, .value = 1 },
    }));

    try std.testing.expectError(libflux.errors.FluxError.settings_error, n.apply_peer_h3_settings(&.{
        .{ .id = 0x2b603742, .value = 1 },
    }));
}
