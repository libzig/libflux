const std = @import("std");
const errors = @import("errors.zig");
const h3_core = @import("h3_core.zig");

pub const Frame = union(enum) {
    headers: []u8,
    data: []u8,
    unknown: UnknownFrame,
};

pub const UnknownFrame = struct {
    frame_type: u64,
    payload: []u8,
};

const VarInt = struct {
    value: u64,
    consumed: usize,
};

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    events: std.ArrayList(Frame),

    pub fn init(allocator: std.mem.Allocator) Decoder {
        return .{
            .allocator = allocator,
            .buffer = .{},
            .events = .{},
        };
    }

    pub fn deinit(self: *Decoder) void {
        while (self.events.items.len > 0) {
            var frame = self.events.orderedRemove(0);
            self.release_frame(&frame);
        }

        self.events.deinit(self.allocator);
        self.buffer.deinit(self.allocator);
    }

    pub fn feed(self: *Decoder, bytes: []const u8) errors.FluxError!void {
        self.buffer.appendSlice(self.allocator, bytes) catch {
            return errors.FluxError.internal_failure;
        };

        try self.parse_available();
    }

    pub fn next_frame(self: *Decoder) ?Frame {
        if (self.events.items.len == 0) {
            return null;
        }

        return self.events.orderedRemove(0);
    }

    pub fn release_frame(self: *Decoder, frame: *Frame) void {
        switch (frame.*) {
            .headers => |payload| self.allocator.free(payload),
            .data => |payload| self.allocator.free(payload),
            .unknown => |entry| self.allocator.free(entry.payload),
        }
    }

    fn parse_available(self: *Decoder) errors.FluxError!void {
        var cursor: usize = 0;

        while (true) {
            const remaining = self.buffer.items[cursor..];
            const frame_type = decode_varint(remaining) orelse break;
            const frame_len_vi = decode_varint(remaining[frame_type.consumed..]) orelse break;

            const frame_header_len = frame_type.consumed + frame_len_vi.consumed;
            const frame_len = std.math.cast(usize, frame_len_vi.value) orelse {
                return errors.FluxError.protocol_violation;
            };

            if (remaining.len < frame_header_len + frame_len) {
                break;
            }

            const payload = remaining[frame_header_len .. frame_header_len + frame_len];
            try self.push_frame(frame_type.value, payload);

            cursor += frame_header_len + frame_len;
        }

        if (cursor > 0) {
            const leftover = self.buffer.items.len - cursor;
            std.mem.copyForwards(u8, self.buffer.items[0..leftover], self.buffer.items[cursor..]);
            self.buffer.shrinkRetainingCapacity(leftover);
        }
    }

    fn push_frame(self: *Decoder, frame_type: u64, payload: []const u8) errors.FluxError!void {
        const owned = self.allocator.alloc(u8, payload.len) catch {
            return errors.FluxError.internal_failure;
        };
        @memcpy(owned, payload);

        const frame: Frame = switch (frame_type) {
            @intFromEnum(h3_core.H3FrameType.headers) => .{ .headers = owned },
            @intFromEnum(h3_core.H3FrameType.data) => .{ .data = owned },
            else => .{ .unknown = .{ .frame_type = frame_type, .payload = owned } },
        };

        self.events.append(self.allocator, frame) catch {
            self.allocator.free(owned);
            return errors.FluxError.internal_failure;
        };
    }
};

pub fn encode_headers(allocator: std.mem.Allocator, payload: []const u8) errors.FluxError![]u8 {
    return encode_frame(allocator, @intFromEnum(h3_core.H3FrameType.headers), payload);
}

pub fn encode_data(allocator: std.mem.Allocator, payload: []const u8) errors.FluxError![]u8 {
    return encode_frame(allocator, @intFromEnum(h3_core.H3FrameType.data), payload);
}

fn encode_frame(allocator: std.mem.Allocator, frame_type: u64, payload: []const u8) errors.FluxError![]u8 {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);

    try append_varint(allocator, &out, frame_type);
    try append_varint(allocator, &out, payload.len);
    out.appendSlice(allocator, payload) catch {
        return errors.FluxError.internal_failure;
    };

    return out.toOwnedSlice(allocator) catch {
        return errors.FluxError.internal_failure;
    };
}

fn decode_varint(data: []const u8) ?VarInt {
    if (data.len == 0) return null;

    const prefix = data[0] >> 6;
    const length: usize = switch (prefix) {
        0 => 1,
        1 => 2,
        2 => 4,
        else => 8,
    };
    if (data.len < length) return null;

    var value: u64 = data[0] & 0x3f;
    var i: usize = 1;
    while (i < length) : (i += 1) {
        value = (value << 8) | data[i];
    }

    return .{ .value = value, .consumed = length };
}

fn append_varint(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u64) errors.FluxError!void {
    if (value <= 63) {
        out.append(allocator, @as(u8, @intCast(value))) catch {
            return errors.FluxError.internal_failure;
        };
        return;
    }

    if (value <= 16383) {
        const encoded: u16 = @as(u16, @intCast(value)) | 0x4000;
        out.append(allocator, @as(u8, @intCast(encoded >> 8))) catch {
            return errors.FluxError.internal_failure;
        };
        out.append(allocator, @as(u8, @intCast(encoded & 0xff))) catch {
            return errors.FluxError.internal_failure;
        };
        return;
    }

    if (value <= 1073741823) {
        const encoded: u32 = @as(u32, @intCast(value)) | 0x80000000;
        out.append(allocator, @as(u8, @intCast(encoded >> 24))) catch {
            return errors.FluxError.internal_failure;
        };
        out.append(allocator, @as(u8, @intCast((encoded >> 16) & 0xff))) catch {
            return errors.FluxError.internal_failure;
        };
        out.append(allocator, @as(u8, @intCast((encoded >> 8) & 0xff))) catch {
            return errors.FluxError.internal_failure;
        };
        out.append(allocator, @as(u8, @intCast(encoded & 0xff))) catch {
            return errors.FluxError.internal_failure;
        };
        return;
    }

    const encoded: u64 = value | 0xc000000000000000;
    out.append(allocator, @as(u8, @intCast(encoded >> 56))) catch {
        return errors.FluxError.internal_failure;
    };
    out.append(allocator, @as(u8, @intCast((encoded >> 48) & 0xff))) catch {
        return errors.FluxError.internal_failure;
    };
    out.append(allocator, @as(u8, @intCast((encoded >> 40) & 0xff))) catch {
        return errors.FluxError.internal_failure;
    };
    out.append(allocator, @as(u8, @intCast((encoded >> 32) & 0xff))) catch {
        return errors.FluxError.internal_failure;
    };
    out.append(allocator, @as(u8, @intCast((encoded >> 24) & 0xff))) catch {
        return errors.FluxError.internal_failure;
    };
    out.append(allocator, @as(u8, @intCast((encoded >> 16) & 0xff))) catch {
        return errors.FluxError.internal_failure;
    };
    out.append(allocator, @as(u8, @intCast((encoded >> 8) & 0xff))) catch {
        return errors.FluxError.internal_failure;
    };
    out.append(allocator, @as(u8, @intCast(encoded & 0xff))) catch {
        return errors.FluxError.internal_failure;
    };
}

test "headers frame round-trip" {
    const wire = try encode_headers(std.testing.allocator, "hdr");
    defer std.testing.allocator.free(wire);

    var decoder = Decoder.init(std.testing.allocator);
    defer decoder.deinit();

    try decoder.feed(wire);

    var frame = decoder.next_frame().?;
    defer decoder.release_frame(&frame);
    try std.testing.expect(frame == .headers);
    try std.testing.expectEqualStrings("hdr", frame.headers);
}

test "data frame supports zero-length payload" {
    const wire = try encode_data(std.testing.allocator, "");
    defer std.testing.allocator.free(wire);

    var decoder = Decoder.init(std.testing.allocator);
    defer decoder.deinit();

    try decoder.feed(wire);

    var frame = decoder.next_frame().?;
    defer decoder.release_frame(&frame);
    try std.testing.expect(frame == .data);
    try std.testing.expectEqual(@as(usize, 0), frame.data.len);
}

test "decoder handles split frame header and payload" {
    const wire = try encode_headers(std.testing.allocator, "split-check");
    defer std.testing.allocator.free(wire);

    var decoder = Decoder.init(std.testing.allocator);
    defer decoder.deinit();

    try decoder.feed(wire[0..1]);
    try std.testing.expect(decoder.next_frame() == null);

    try decoder.feed(wire[1..3]);
    try std.testing.expect(decoder.next_frame() == null);

    try decoder.feed(wire[3..]);
    var frame = decoder.next_frame().?;
    defer decoder.release_frame(&frame);
    try std.testing.expect(frame == .headers);
    try std.testing.expectEqualStrings("split-check", frame.headers);
}

test "decoder parses multiple frames with chunked input" {
    const headers_wire = try encode_headers(std.testing.allocator, "h");
    defer std.testing.allocator.free(headers_wire);
    const data_wire = try encode_data(std.testing.allocator, "body");
    defer std.testing.allocator.free(data_wire);

    var combined: std.ArrayList(u8) = .{};
    defer combined.deinit(std.testing.allocator);
    try combined.appendSlice(std.testing.allocator, headers_wire);
    try combined.appendSlice(std.testing.allocator, data_wire);

    var decoder = Decoder.init(std.testing.allocator);
    defer decoder.deinit();

    try decoder.feed(combined.items[0..2]);
    try decoder.feed(combined.items[2..5]);
    try decoder.feed(combined.items[5..]);

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
        try std.testing.expectEqualStrings("body", frame.data);
    }
}
