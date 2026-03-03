const std = @import("std");
const libflux = @import("libflux");
const qpack = libflux.qpack;
const errors = libflux.errors;

test "lsquic parity: qpack partial drains preserve all bytes" {
    var sync = qpack.ControlSync.init(std.testing.allocator);
    defer sync.deinit();

    _ = try sync.queue_insert_instruction("x-h1", "one");
    _ = try sync.queue_insert_instruction("x-h2", "two");

    const a = try sync.drain_encoder_chunk(3);
    defer std.testing.allocator.free(a);
    const b = try sync.drain_encoder_chunk(4);
    defer std.testing.allocator.free(b);
    const c = try sync.drain_encoder_chunk(1024);
    defer std.testing.allocator.free(c);

    var all: std.ArrayList(u8) = .{};
    defer all.deinit(std.testing.allocator);
    try all.appendSlice(std.testing.allocator, a);
    try all.appendSlice(std.testing.allocator, b);
    try all.appendSlice(std.testing.allocator, c);

    try sync.recv_encoder_bytes(all.items);
    try std.testing.expectEqual(@as(u64, 2), sync.known_insert_count);
}

test "lsquic parity: blocked stream unblocks after ack" {
    var sync = qpack.ControlSync.init(std.testing.allocator);
    defer sync.deinit();

    _ = try sync.queue_insert_instruction("x-a", "1");
    _ = try sync.queue_insert_instruction("x-b", "2");
    try sync.mark_stream_blocked(100, 2);
    try std.testing.expect(sync.is_stream_blocked(100));

    try sync.recv_decoder_bytes("ack:100:2\n");
    try std.testing.expect(!sync.is_stream_blocked(100));
}

test "lsquic parity: malformed ack line is rejected" {
    var sync = qpack.ControlSync.init(std.testing.allocator);
    defer sync.deinit();

    try std.testing.expectError(errors.FluxError.protocol_violation, sync.recv_decoder_bytes("ack:abc:2\n"));
}
