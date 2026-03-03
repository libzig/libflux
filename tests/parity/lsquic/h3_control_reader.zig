const std = @import("std");
const libflux = @import("libflux");
const h3_control_reader = libflux.h3_control_reader;
const h3_core = libflux.h3_core;
const errors = libflux.errors;

fn append_varint(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u64) !void {
    if (value <= 63) {
        try out.append(allocator, @as(u8, @intCast(value)));
        return;
    }
    if (value <= 16383) {
        const v: u16 = @as(u16, @intCast(value)) | 0x4000;
        try out.append(allocator, @as(u8, @intCast(v >> 8)));
        try out.append(allocator, @as(u8, @intCast(v & 0xff)));
        return;
    }

    const v: u32 = @as(u32, @intCast(value)) | 0x80000000;
    try out.append(allocator, @as(u8, @intCast(v >> 24)));
    try out.append(allocator, @as(u8, @intCast((v >> 16) & 0xff)));
    try out.append(allocator, @as(u8, @intCast((v >> 8) & 0xff)));
    try out.append(allocator, @as(u8, @intCast(v & 0xff)));
}

fn append_frame(allocator: std.mem.Allocator, out: *std.ArrayList(u8), frame_type: u64, payload: []const u8) !void {
    try append_varint(allocator, out, frame_type);
    try append_varint(allocator, out, payload.len);
    try out.appendSlice(allocator, payload);
}

test "lsquic parity: cancel_push and max_push_id vectors" {
    var reader = h3_control_reader.Reader.init(std.testing.allocator);
    defer reader.deinit();

    var wire: std.ArrayList(u8) = .{};
    defer wire.deinit(std.testing.allocator);

    try append_frame(std.testing.allocator, &wire, @intFromEnum(h3_core.H3FrameType.settings), "");

    var payload: std.ArrayList(u8) = .{};
    defer payload.deinit(std.testing.allocator);
    try append_varint(std.testing.allocator, &payload, 0x123445);
    try append_frame(std.testing.allocator, &wire, @intFromEnum(h3_core.H3FrameType.cancel_push), payload.items);

    payload.clearRetainingCapacity();
    try append_varint(std.testing.allocator, &payload, 291);
    try append_frame(std.testing.allocator, &wire, @intFromEnum(h3_core.H3FrameType.max_push_id), payload.items);

    try reader.feed(wire.items);

    {
        var e = reader.next_event().?;
        defer reader.release_event(&e);
        try std.testing.expect(e == .settings);
    }
    {
        var e = reader.next_event().?;
        defer reader.release_event(&e);
        try std.testing.expect(e == .cancel_push);
        try std.testing.expectEqual(@as(u64, 0x123445), e.cancel_push);
    }
    {
        var e = reader.next_event().?;
        defer reader.release_event(&e);
        try std.testing.expect(e == .max_push_id);
        try std.testing.expectEqual(@as(u64, 291), e.max_push_id);
    }
}

test "lsquic parity: malformed scalar payload fails" {
    var reader = h3_control_reader.Reader.init(std.testing.allocator);
    defer reader.deinit();

    // settings first, then GOAWAY with payload length 2 and non-canonical scalar payload.
    const bad = [_]u8{ @intFromEnum(h3_core.H3FrameType.settings), 0x00, @intFromEnum(h3_core.H3FrameType.goaway), 0x02, 0x01, 0x00 };
    try std.testing.expectError(errors.FluxError.protocol_violation, reader.feed(&bad));
}

test "lsquic parity: priority_update request and push" {
    var reader = h3_control_reader.Reader.init(std.testing.allocator);
    defer reader.deinit();

    var wire: std.ArrayList(u8) = .{};
    defer wire.deinit(std.testing.allocator);
    try append_frame(std.testing.allocator, &wire, @intFromEnum(h3_core.H3FrameType.settings), "");

    var req: std.ArrayList(u8) = .{};
    defer req.deinit(std.testing.allocator);
    try append_varint(std.testing.allocator, &req, 0x1234);
    try req.appendSlice(std.testing.allocator, "ABCDE");
    try append_frame(std.testing.allocator, &wire, @intFromEnum(h3_core.H3FrameType.priority_update_request), req.items);

    var push: std.ArrayList(u8) = .{};
    defer push.deinit(std.testing.allocator);
    try append_varint(std.testing.allocator, &push, 0x08);
    try push.appendSlice(std.testing.allocator, "PQRST");
    try append_frame(std.testing.allocator, &wire, @intFromEnum(h3_core.H3FrameType.priority_update_push), push.items);

    try reader.feed(wire.items);
    {
        var e = reader.next_event().?;
        defer reader.release_event(&e);
        try std.testing.expect(e == .settings);
    }
    {
        var e = reader.next_event().?;
        defer reader.release_event(&e);
        try std.testing.expect(e == .priority_update);
        try std.testing.expect(!e.priority_update.is_push);
        try std.testing.expectEqual(@as(u64, 0x1234), e.priority_update.element_id);
        try std.testing.expectEqualStrings("ABCDE", e.priority_update.value);
    }
    {
        var e = reader.next_event().?;
        defer reader.release_event(&e);
        try std.testing.expect(e == .priority_update);
        try std.testing.expect(e.priority_update.is_push);
        try std.testing.expectEqual(@as(u64, 0x08), e.priority_update.element_id);
        try std.testing.expectEqualStrings("PQRST", e.priority_update.value);
    }
}
