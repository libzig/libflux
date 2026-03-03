const std = @import("std");
const libflux = @import("libflux");

test "lsquic parity wt streams associate with session preface" {
    var core = libflux.wt_core.Core.init(std.testing.allocator);
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

    const accepted = try core.accept_session_stream(501, .bidi, preface);
    try std.testing.expectEqual(session_id, accepted);
    try std.testing.expectEqual(session_id, core.get_stream_session_id(501).?);
}

test "lsquic parity wt stream close race is safe" {
    var core = libflux.wt_core.Core.init(std.testing.allocator);
    defer core.deinit();

    core.apply_negotiated_features(.{
        .connect_protocol_enabled = true,
        .h3_datagram_enabled = false,
        .webtransport_enabled = true,
        .webtransport_max_sessions = 1,
    });

    const session_id = try core.open_session_id();
    _ = core.next_session_event();

    const stream_id = try core.open_session_stream(session_id, .uni);
    try core.close_session_stream(stream_id);
    try core.close_session_stream(stream_id);

    core.close_session_id(session_id);
    _ = core.next_session_event();
    _ = core.next_session_event();
    _ = core.next_session_event();

    try std.testing.expectEqual(@as(?u64, null), core.get_stream_session_id(stream_id));
}
