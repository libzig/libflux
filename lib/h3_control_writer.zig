const std = @import("std");
const errors = @import("errors.zig");
const h3_core = @import("h3_core.zig");

pub const Setting = struct {
    id: u64,
    value: u64,
};

pub const Writer = struct {
    allocator: std.mem.Allocator,
    wrote_settings: bool,

    pub fn init(allocator: std.mem.Allocator) Writer {
        return .{
            .allocator = allocator,
            .wrote_settings = false,
        };
    }

    pub fn write_settings(self: *Writer, settings: []const Setting) errors.FluxError![]u8 {
        if (self.wrote_settings) {
            return errors.FluxError.settings_error;
        }

        var payload: std.ArrayList(u8) = .{};
        defer payload.deinit(self.allocator);

        for (settings) |setting| {
            try append_varint(self.allocator, &payload, setting.id);
            try append_varint(self.allocator, &payload, setting.value);
        }

        self.wrote_settings = true;
        return self.build_frame(@intFromEnum(h3_core.H3FrameType.settings), payload.items);
    }

    pub fn write_goaway(self: *Writer, id: u64) errors.FluxError![]u8 {
        return self.write_single_varint_frame(@intFromEnum(h3_core.H3FrameType.goaway), id);
    }

    pub fn write_cancel_push(self: *Writer, push_id: u64) errors.FluxError![]u8 {
        return self.write_single_varint_frame(@intFromEnum(h3_core.H3FrameType.cancel_push), push_id);
    }

    pub fn write_max_push_id(self: *Writer, push_id: u64) errors.FluxError![]u8 {
        return self.write_single_varint_frame(@intFromEnum(h3_core.H3FrameType.max_push_id), push_id);
    }

    pub fn write_priority_update(self: *Writer, is_push: bool, element_id: u64, priority_field_value: []const u8) errors.FluxError![]u8 {
        const frame_type: u64 = if (is_push)
            @intFromEnum(h3_core.H3FrameType.priority_update_push)
        else
            @intFromEnum(h3_core.H3FrameType.priority_update_request);

        var payload: std.ArrayList(u8) = .{};
        defer payload.deinit(self.allocator);

        try append_varint(self.allocator, &payload, element_id);
        payload.appendSlice(self.allocator, priority_field_value) catch {
            return errors.FluxError.internal_failure;
        };

        return self.build_frame(frame_type, payload.items);
    }

    fn write_single_varint_frame(self: *Writer, frame_type: u64, value: u64) errors.FluxError![]u8 {
        var payload: std.ArrayList(u8) = .{};
        defer payload.deinit(self.allocator);

        try append_varint(self.allocator, &payload, value);
        return self.build_frame(frame_type, payload.items);
    }

    fn build_frame(self: *Writer, frame_type: u64, payload: []const u8) errors.FluxError![]u8 {
        var frame: std.ArrayList(u8) = .{};
        defer frame.deinit(self.allocator);

        try append_varint(self.allocator, &frame, frame_type);
        try append_varint(self.allocator, &frame, payload.len);
        frame.appendSlice(self.allocator, payload) catch {
            return errors.FluxError.internal_failure;
        };

        return frame.toOwnedSlice(self.allocator) catch {
            return errors.FluxError.internal_failure;
        };
    }
};

fn append_varint(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u64) errors.FluxError!void {
    if (value <= 63) {
        out.append(allocator, @as(u8, @intCast(value))) catch {
            return errors.FluxError.internal_failure;
        };
        return;
    }

    if (value <= 16383) {
        const encoded: u16 = (@as(u16, @intCast(value)) | 0x4000);
        out.append(allocator, @as(u8, @intCast(encoded >> 8))) catch {
            return errors.FluxError.internal_failure;
        };
        out.append(allocator, @as(u8, @intCast(encoded & 0xff))) catch {
            return errors.FluxError.internal_failure;
        };
        return;
    }

    if (value <= 1073741823) {
        const encoded: u32 = (@as(u32, @intCast(value)) | 0x80000000);
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

fn read_varint(data: []const u8) ?struct { value: u64, consumed: usize } {
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

test "writer emits settings frame and enforces single settings emission" {
    var writer = Writer.init(std.testing.allocator);

    const frame = try writer.write_settings(&.{
        .{ .id = @intFromEnum(h3_core.H3SettingId.qpack_max_table_capacity), .value = 4096 },
        .{ .id = @intFromEnum(h3_core.H3SettingId.qpack_blocked_streams), .value = 16 },
    });
    defer std.testing.allocator.free(frame);

    const frame_type = read_varint(frame).?;
    try std.testing.expectEqual(@as(u64, @intFromEnum(h3_core.H3FrameType.settings)), frame_type.value);

    const frame_len = read_varint(frame[frame_type.consumed..]).?;
    try std.testing.expect(frame_len.value > 0);

    try std.testing.expectError(errors.FluxError.settings_error, writer.write_settings(&.{}));
}

test "writer emits goaway cancel_push and max_push_id frames" {
    var writer = Writer.init(std.testing.allocator);

    const goaway = try writer.write_goaway(17);
    defer std.testing.allocator.free(goaway);
    try std.testing.expectEqual(@as(u64, @intFromEnum(h3_core.H3FrameType.goaway)), read_varint(goaway).?.value);

    const cancel_push = try writer.write_cancel_push(3);
    defer std.testing.allocator.free(cancel_push);
    try std.testing.expectEqual(@as(u64, @intFromEnum(h3_core.H3FrameType.cancel_push)), read_varint(cancel_push).?.value);

    const max_push_id = try writer.write_max_push_id(99);
    defer std.testing.allocator.free(max_push_id);
    try std.testing.expectEqual(@as(u64, @intFromEnum(h3_core.H3FrameType.max_push_id)), read_varint(max_push_id).?.value);
}

test "writer emits priority update request and push frames" {
    var writer = Writer.init(std.testing.allocator);

    const req = try writer.write_priority_update(false, 23, "u=3");
    defer std.testing.allocator.free(req);
    try std.testing.expectEqual(@as(u64, @intFromEnum(h3_core.H3FrameType.priority_update_request)), read_varint(req).?.value);

    const push = try writer.write_priority_update(true, 44, "i");
    defer std.testing.allocator.free(push);
    try std.testing.expectEqual(@as(u64, @intFromEnum(h3_core.H3FrameType.priority_update_push)), read_varint(push).?.value);
}

test "writer varint framing supports multi-byte values" {
    var writer = Writer.init(std.testing.allocator);

    const goaway = try writer.write_goaway(70000);
    defer std.testing.allocator.free(goaway);

    const frame_type = read_varint(goaway).?;
    try std.testing.expectEqual(@as(u64, @intFromEnum(h3_core.H3FrameType.goaway)), frame_type.value);

    const frame_len = read_varint(goaway[frame_type.consumed..]).?;
    const payload = goaway[frame_type.consumed + frame_len.consumed ..];
    const id = read_varint(payload).?;
    try std.testing.expectEqual(@as(u64, 70000), id.value);
}
