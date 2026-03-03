const std = @import("std");
const errors = @import("errors.zig");
const h3_control_reader = @import("h3_control_reader.zig");
const h3_framing = @import("h3_framing.zig");
const qpack = @import("qpack.zig");
const wt_core = @import("wt_core.zig");

pub const ParityStatus = enum {
    implemented,
    partial,
    pending,
};

pub const ParityCase = struct {
    source: []const u8,
    target: []const u8,
    status: ParityStatus,
};

pub const PARITY_CASES = [_]ParityCase{
    .{ .source = "xtra/lsquic/tests/test_hcsi_reader.c", .target = "h3_control_reader", .status = .implemented },
    .{ .source = "xtra/lsquic/tests/test_h3_framing.c", .target = "h3_framing", .status = .implemented },
    .{ .source = "xtra/lsquic/tests/test_send_headers.c", .target = "qpack_control_sync", .status = .implemented },
    .{ .source = "xtra/lsquic/src/liblsquic/lsquic_stream.c (WT paths)", .target = "wt_streams", .status = .implemented },
    .{ .source = "xtra/lsquic/src/liblsquic/lsquic_hcso_writer.c (WT settings)", .target = "wt_settings", .status = .implemented },
};

pub fn all_parity_cases_implemented() bool {
    for (PARITY_CASES) |entry| {
        if (entry.status != .implemented) {
            return false;
        }
    }

    return true;
}

test "parity matrix has required entries and no pending status" {
    try std.testing.expect(PARITY_CASES.len >= 5);
    try std.testing.expect(all_parity_cases_implemented());
}

test "parity hcsi reader case maps to control reader settings rules" {
    var reader = h3_control_reader.Reader.init(std.testing.allocator);
    defer reader.deinit();

    const invalid_first = [_]u8{ 0x07, 0x01, 0x00 };
    try std.testing.expectError(errors.FluxError.missing_settings, reader.feed(&invalid_first));
}

test "parity h3 framing case handles split and zero data" {
    const zero_data = try h3_framing.encode_data(std.testing.allocator, "");
    defer std.testing.allocator.free(zero_data);

    var decoder = h3_framing.Decoder.init(std.testing.allocator);
    defer decoder.deinit();

    try decoder.feed(zero_data[0..1]);
    try std.testing.expect(decoder.next_frame() == null);
    try decoder.feed(zero_data[1..]);

    var frame = decoder.next_frame().?;
    defer decoder.release_frame(&frame);
    try std.testing.expect(frame == .data);
    try std.testing.expectEqual(@as(usize, 0), frame.data.len);
}

test "parity send_headers case covers partial control stream drains" {
    var sync = qpack.ControlSync.init(std.testing.allocator);
    defer sync.deinit();

    _ = try sync.queue_insert_instruction("x-one", "a");
    _ = try sync.queue_insert_instruction("x-two", "b");

    const p1 = try sync.drain_encoder_chunk(5);
    defer std.testing.allocator.free(p1);
    const p2 = try sync.drain_encoder_chunk(5);
    defer std.testing.allocator.free(p2);
    const p3 = try sync.drain_encoder_chunk(1024);
    defer std.testing.allocator.free(p3);

    try std.testing.expect(p1.len > 0 and p2.len > 0 and p3.len > 0);
}

test "parity wt settings case enforces ids and limits" {
    var negotiator = wt_core.Negotiator.init();

    try negotiator.apply_local_h3_settings(&.{
        .{ .id = 0x08, .value = 1 },
        .{ .id = 0x33, .value = 1 },
        .{ .id = 0x2b603742, .value = 1 },
        .{ .id = 0x2b603743, .value = 4 },
    });

    try negotiator.apply_peer_h3_settings(&.{
        .{ .id = 0x08, .value = 1 },
        .{ .id = 0x2b603742, .value = 1 },
        .{ .id = 0x2b603743, .value = 2 },
    });

    const features = negotiator.negotiate();
    try std.testing.expect(features.supports_webtransport());
    try std.testing.expectEqual(@as(u64, 2), features.webtransport_max_sessions);
}

test "parity wt streams case validates stream session association" {
    var core = wt_core.Core.init(std.testing.allocator);
    defer core.deinit();

    core.apply_negotiated_features(.{
        .connect_protocol_enabled = true,
        .h3_datagram_enabled = true,
        .webtransport_enabled = true,
        .webtransport_max_sessions = 2,
    });

    const session_id = try core.open_session_id();
    _ = core.next_session_event();
    const preface = try core.encode_stream_preface(session_id);
    defer std.testing.allocator.free(preface);

    const accepted = try core.accept_session_stream(77, .bidi, preface);
    try std.testing.expectEqual(session_id, accepted);
}
