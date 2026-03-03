const std = @import("std");
const errors = @import("errors.zig");
const h3_control_reader = @import("h3_control_reader.zig");
const h3_framing = @import("h3_framing.zig");
const qpack = @import("qpack.zig");
const wt_capsule = @import("wt_capsule.zig");
const wt_core = @import("wt_core.zig");

test "negative corpus h3 control reader malformed settings" {
    var reader = h3_control_reader.Reader.init(std.testing.allocator);
    defer reader.deinit();

    // settings frame with odd payload varint sequence
    const malformed = [_]u8{ 0x04, 0x02, 0x01, 0xff };
    try std.testing.expectError(errors.FluxError.settings_error, reader.feed(&malformed));
}

test "negative corpus h3 framing malformed varint does not emit frame" {
    var decoder = h3_framing.Decoder.init(std.testing.allocator);
    defer decoder.deinit();

    const malformed = [_]u8{0xff};
    try decoder.feed(&malformed);
    try std.testing.expect(decoder.next_frame() == null);
}

test "negative corpus qpack decode rejects unknown dynamic reference" {
    const engine = qpack.Engine.init();
    var table = qpack.DynamicTable.init(std.testing.allocator, 256);
    defer table.deinit();

    try std.testing.expectError(errors.FluxError.protocol_violation, engine.decode_with_dynamic(std.testing.allocator, &table, "d:999\n"));
}

test "negative corpus wt capsule stream coupling violation" {
    const wire = try wt_capsule.encode_capsule(std.testing.allocator, @intFromEnum(wt_capsule.CapsuleType.datagram), "x");
    defer std.testing.allocator.free(wire);

    var decoder = wt_capsule.Decoder.init(std.testing.allocator, 33);
    defer decoder.deinit();

    try std.testing.expectError(errors.FluxError.invalid_state, decoder.feed(35, wire));
}

test "fuzz smoke random bytes through parsers" {
    var prng = std.Random.DefaultPrng.init(@as(u64, 0xC0FFEE));
    const rand = prng.random();

    var control_reader = h3_control_reader.Reader.init(std.testing.allocator);
    defer control_reader.deinit();

    var frame_decoder = h3_framing.Decoder.init(std.testing.allocator);
    defer frame_decoder.deinit();

    var capsule_decoder = wt_capsule.Decoder.init(std.testing.allocator, 99);
    defer capsule_decoder.deinit();

    var i: usize = 0;
    while (i < 128) : (i += 1) {
        var buf: [32]u8 = undefined;
        rand.bytes(&buf);
        const len = rand.intRangeAtMost(usize, 0, buf.len);
        const sample = buf[0..len];

        _ = control_reader.feed(sample) catch {};
        _ = frame_decoder.feed(sample) catch {};
        _ = capsule_decoder.feed(99, sample) catch {};

        while (control_reader.next_event()) |event| {
            var e = event;
            control_reader.release_event(&e);
        }
        while (frame_decoder.next_frame()) |frame| {
            var f = frame;
            frame_decoder.release_frame(&f);
        }
        while (capsule_decoder.next_capsule()) |capsule| {
            var c = capsule;
            capsule_decoder.release_capsule(&c);
        }
    }
}

test "negative corpus wt connect rejects malformed response" {
    var core = wt_core.Core.init(std.testing.allocator);
    defer core.deinit();
    core.apply_negotiated_features(.{
        .connect_protocol_enabled = true,
        .h3_datagram_enabled = true,
        .webtransport_enabled = true,
        .webtransport_max_sessions = 1,
    });

    try std.testing.expectError(errors.FluxError.protocol_violation, core.validate_connect_response(":status=200\n"));
}
