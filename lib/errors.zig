const std = @import("std");

pub const FluxError = error{
    invalid_argument,
    invalid_state,
    settings_error,
    missing_settings,
    protocol_violation,
    frame_unexpected,
    stream_closed,
    backpressure,
    internal_failure,
};

pub const H3CloseCode = enum(u64) {
    no_error = 0x0100,
    general_protocol_error = 0x0101,
    internal_error = 0x0102,
    stream_creation_error = 0x0103,
    closed_critical_stream = 0x0104,
    frame_unexpected = 0x0105,
    frame_error = 0x0106,
    excessive_load = 0x0107,
    id_error = 0x0108,
    settings_error = 0x0109,
    missing_settings = 0x010A,
    request_rejected = 0x010B,
    request_cancelled = 0x010C,
    request_incomplete = 0x010D,
    message_error = 0x010E,
    connect_error = 0x010F,
    version_fallback = 0x0110,
};

pub fn map_error_to_h3_close_code(err: anyerror) H3CloseCode {
    return switch (err) {
        FluxError.invalid_argument => .frame_error,
        FluxError.invalid_state => .general_protocol_error,
        FluxError.settings_error => .settings_error,
        FluxError.missing_settings => .missing_settings,
        FluxError.protocol_violation => .general_protocol_error,
        FluxError.frame_unexpected => .frame_unexpected,
        FluxError.stream_closed => .closed_critical_stream,
        FluxError.backpressure => .excessive_load,
        FluxError.internal_failure => .internal_error,
        else => .internal_error,
    };
}

test "close code mapping covers core errors" {
    try std.testing.expectEqual(H3CloseCode.frame_error, map_error_to_h3_close_code(FluxError.invalid_argument));
    try std.testing.expectEqual(H3CloseCode.general_protocol_error, map_error_to_h3_close_code(FluxError.protocol_violation));
    try std.testing.expectEqual(H3CloseCode.frame_unexpected, map_error_to_h3_close_code(FluxError.frame_unexpected));
}
