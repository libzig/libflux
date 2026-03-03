const std = @import("std");
const libflux = @import("libflux");
const h3_framing = libflux.h3_framing;

test "lsquic parity: split HEADERS frame decode" {
    const wire = try h3_framing.encode_headers(std.testing.allocator, "xyz");
    defer std.testing.allocator.free(wire);

    var decoder = h3_framing.Decoder.init(std.testing.allocator);
    defer decoder.deinit();

    try decoder.feed(wire[0..1]);
    try std.testing.expect(decoder.next_frame() == null);
    try decoder.feed(wire[1..]);

    var frame = decoder.next_frame().?;
    defer decoder.release_frame(&frame);
    try std.testing.expect(frame == .headers);
    try std.testing.expectEqualStrings("xyz", frame.headers);
}

test "lsquic parity: zero-size DATA frame is accepted" {
    const wire = try h3_framing.encode_data(std.testing.allocator, "");
    defer std.testing.allocator.free(wire);

    var decoder = h3_framing.Decoder.init(std.testing.allocator);
    defer decoder.deinit();
    try decoder.feed(wire);

    var frame = decoder.next_frame().?;
    defer decoder.release_frame(&frame);
    try std.testing.expect(frame == .data);
    try std.testing.expectEqual(@as(usize, 0), frame.data.len);
}

test "lsquic parity: coalesced HEADERS then DATA frames" {
    const headers = try h3_framing.encode_headers(std.testing.allocator, "h");
    defer std.testing.allocator.free(headers);
    const data = try h3_framing.encode_data(std.testing.allocator, "payload");
    defer std.testing.allocator.free(data);

    var combined: std.ArrayList(u8) = .{};
    defer combined.deinit(std.testing.allocator);
    try combined.appendSlice(std.testing.allocator, headers);
    try combined.appendSlice(std.testing.allocator, data);

    var decoder = h3_framing.Decoder.init(std.testing.allocator);
    defer decoder.deinit();
    try decoder.feed(combined.items);

    {
        var frame = decoder.next_frame().?;
        defer decoder.release_frame(&frame);
        try std.testing.expect(frame == .headers);
        try std.testing.expectEqualStrings("h", frame.headers);
    }
    {
        var frame = decoder.next_frame().?;
        defer decoder.release_frame(&frame);
        try std.testing.expect(frame == .data);
        try std.testing.expectEqualStrings("payload", frame.data);
    }
}
