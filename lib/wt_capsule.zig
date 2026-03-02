const std = @import("std");
const errors = @import("errors.zig");

pub const CapsuleType = enum(u64) {
    datagram = 0x00,
    close_webtransport_session = 0x2843,
    drain_webtransport_session = 0x78ae,
    register_datagram_context = 0xff37a0,
    close_datagram_context = 0xff37a1,
};

pub const Capsule = struct {
    capsule_type: u64,
    payload: []u8,
};

const VarInt = struct {
    value: u64,
    consumed: usize,
};

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    stream_id: u64,
    buffer: std.ArrayList(u8),
    capsules: std.ArrayList(Capsule),

    pub fn init(allocator: std.mem.Allocator, stream_id: u64) Decoder {
        return .{
            .allocator = allocator,
            .stream_id = stream_id,
            .buffer = .{},
            .capsules = .{},
        };
    }

    pub fn deinit(self: *Decoder) void {
        while (self.capsules.items.len > 0) {
            var capsule = self.capsules.orderedRemove(0);
            self.release_capsule(&capsule);
        }

        self.capsules.deinit(self.allocator);
        self.buffer.deinit(self.allocator);
    }

    pub fn feed(self: *Decoder, stream_id: u64, bytes: []const u8) errors.FluxError!void {
        if (stream_id != self.stream_id) {
            return errors.FluxError.invalid_state;
        }

        self.buffer.appendSlice(self.allocator, bytes) catch {
            return errors.FluxError.internal_failure;
        };

        try self.parse_available();
    }

    pub fn next_capsule(self: *Decoder) ?Capsule {
        if (self.capsules.items.len == 0) {
            return null;
        }

        return self.capsules.orderedRemove(0);
    }

    pub fn release_capsule(self: *Decoder, capsule: *Capsule) void {
        self.allocator.free(capsule.payload);
    }

    fn parse_available(self: *Decoder) errors.FluxError!void {
        var cursor: usize = 0;

        while (true) {
            const rem = self.buffer.items[cursor..];
            const typ = decode_varint(rem) orelse break;
            const len_vi = decode_varint(rem[typ.consumed..]) orelse break;

            const header_len = typ.consumed + len_vi.consumed;
            const payload_len = std.math.cast(usize, len_vi.value) orelse return errors.FluxError.protocol_violation;
            if (rem.len < header_len + payload_len) {
                break;
            }

            const payload = rem[header_len .. header_len + payload_len];
            const owned = self.allocator.dupe(u8, payload) catch return errors.FluxError.internal_failure;

            self.capsules.append(self.allocator, .{
                .capsule_type = typ.value,
                .payload = owned,
            }) catch {
                self.allocator.free(owned);
                return errors.FluxError.internal_failure;
            };

            cursor += header_len + payload_len;
        }

        if (cursor > 0) {
            const remaining = self.buffer.items.len - cursor;
            std.mem.copyForwards(u8, self.buffer.items[0..remaining], self.buffer.items[cursor..]);
            self.buffer.shrinkRetainingCapacity(remaining);
        }
    }
};

pub fn encode_capsule(allocator: std.mem.Allocator, capsule_type: u64, payload: []const u8) errors.FluxError![]u8 {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);

    try append_varint(allocator, &out, capsule_type);
    try append_varint(allocator, &out, payload.len);
    out.appendSlice(allocator, payload) catch return errors.FluxError.internal_failure;

    return out.toOwnedSlice(allocator) catch return errors.FluxError.internal_failure;
}

fn append_varint(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u64) errors.FluxError!void {
    if (value <= 63) {
        out.append(allocator, @as(u8, @intCast(value))) catch return errors.FluxError.internal_failure;
        return;
    }

    if (value <= 16383) {
        const encoded: u16 = @as(u16, @intCast(value)) | 0x4000;
        out.append(allocator, @as(u8, @intCast(encoded >> 8))) catch return errors.FluxError.internal_failure;
        out.append(allocator, @as(u8, @intCast(encoded & 0xff))) catch return errors.FluxError.internal_failure;
        return;
    }

    if (value <= 1073741823) {
        const encoded: u32 = @as(u32, @intCast(value)) | 0x80000000;
        out.append(allocator, @as(u8, @intCast(encoded >> 24))) catch return errors.FluxError.internal_failure;
        out.append(allocator, @as(u8, @intCast((encoded >> 16) & 0xff))) catch return errors.FluxError.internal_failure;
        out.append(allocator, @as(u8, @intCast((encoded >> 8) & 0xff))) catch return errors.FluxError.internal_failure;
        out.append(allocator, @as(u8, @intCast(encoded & 0xff))) catch return errors.FluxError.internal_failure;
        return;
    }

    const encoded: u64 = value | 0xc000000000000000;
    out.append(allocator, @as(u8, @intCast(encoded >> 56))) catch return errors.FluxError.internal_failure;
    out.append(allocator, @as(u8, @intCast((encoded >> 48) & 0xff))) catch return errors.FluxError.internal_failure;
    out.append(allocator, @as(u8, @intCast((encoded >> 40) & 0xff))) catch return errors.FluxError.internal_failure;
    out.append(allocator, @as(u8, @intCast((encoded >> 32) & 0xff))) catch return errors.FluxError.internal_failure;
    out.append(allocator, @as(u8, @intCast((encoded >> 24) & 0xff))) catch return errors.FluxError.internal_failure;
    out.append(allocator, @as(u8, @intCast((encoded >> 16) & 0xff))) catch return errors.FluxError.internal_failure;
    out.append(allocator, @as(u8, @intCast((encoded >> 8) & 0xff))) catch return errors.FluxError.internal_failure;
    out.append(allocator, @as(u8, @intCast(encoded & 0xff))) catch return errors.FluxError.internal_failure;
}

fn decode_varint(data: []const u8) ?VarInt {
    if (data.len == 0) return null;

    const prefix = data[0] >> 6;
    const len: usize = switch (prefix) {
        0 => 1,
        1 => 2,
        2 => 4,
        else => 8,
    };
    if (data.len < len) return null;

    var value: u64 = data[0] & 0x3f;
    var i: usize = 1;
    while (i < len) : (i += 1) {
        value = (value << 8) | data[i];
    }

    return .{ .value = value, .consumed = len };
}

test "capsule encode decode round trip" {
    const wire = try encode_capsule(std.testing.allocator, @intFromEnum(CapsuleType.datagram), "abc");
    defer std.testing.allocator.free(wire);

    var decoder = Decoder.init(std.testing.allocator, 9);
    defer decoder.deinit();

    try decoder.feed(9, wire);
    var capsule = decoder.next_capsule().?;
    defer decoder.release_capsule(&capsule);

    try std.testing.expectEqual(@as(u64, @intFromEnum(CapsuleType.datagram)), capsule.capsule_type);
    try std.testing.expectEqualStrings("abc", capsule.payload);
}

test "capsule decoder handles fragmented input" {
    const wire = try encode_capsule(std.testing.allocator, @intFromEnum(CapsuleType.close_datagram_context), "ctx");
    defer std.testing.allocator.free(wire);

    var decoder = Decoder.init(std.testing.allocator, 11);
    defer decoder.deinit();

    try decoder.feed(11, wire[0..2]);
    try std.testing.expect(decoder.next_capsule() == null);
    try decoder.feed(11, wire[2..]);

    var capsule = decoder.next_capsule().?;
    defer decoder.release_capsule(&capsule);
    try std.testing.expectEqual(@as(u64, @intFromEnum(CapsuleType.close_datagram_context)), capsule.capsule_type);
    try std.testing.expectEqualStrings("ctx", capsule.payload);
}

test "capsule decoder enforces stream coupling" {
    const wire = try encode_capsule(std.testing.allocator, @intFromEnum(CapsuleType.register_datagram_context), "r");
    defer std.testing.allocator.free(wire);

    var decoder = Decoder.init(std.testing.allocator, 15);
    defer decoder.deinit();

    try std.testing.expectError(errors.FluxError.invalid_state, decoder.feed(17, wire));
}

test "capsule decoder waits for complete payload before emitting" {
    var decoder = Decoder.init(std.testing.allocator, 21);
    defer decoder.deinit();

    const partial = [_]u8{
        0x00, // capsule type 0
        0x05, // payload length 5
        'a',
        'b',
        'c',
    };
    try decoder.feed(21, &partial);
    try std.testing.expect(decoder.next_capsule() == null);

    const tail = [_]u8{ 'd', 'e' };
    try decoder.feed(21, &tail);

    var capsule = decoder.next_capsule().?;
    defer decoder.release_capsule(&capsule);
    try std.testing.expectEqual(@as(u64, @intFromEnum(CapsuleType.datagram)), capsule.capsule_type);
    try std.testing.expectEqualStrings("abcde", capsule.payload);
}
