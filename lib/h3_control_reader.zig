const std = @import("std");
const errors = @import("errors.zig");
const h3_core = @import("h3_core.zig");

pub const Setting = struct {
    id: u64,
    value: u64,
};

pub const PriorityUpdate = struct {
    is_push: bool,
    element_id: u64,
    value: []u8,
};

pub const ControlEvent = union(enum) {
    settings: []Setting,
    goaway: u64,
    cancel_push: u64,
    max_push_id: u64,
    priority_update: PriorityUpdate,
};

const VarInt = struct {
    value: u64,
    consumed: usize,
};

pub const Reader = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    events: std.ArrayList(ControlEvent),
    saw_first_frame: bool,
    settings_received: bool,

    pub fn init(allocator: std.mem.Allocator) Reader {
        return .{
            .allocator = allocator,
            .buffer = .{},
            .events = .{},
            .saw_first_frame = false,
            .settings_received = false,
        };
    }

    pub fn deinit(self: *Reader) void {
        while (self.events.items.len > 0) {
            var event = self.events.orderedRemove(0);
            self.release_event(&event);
        }
        self.events.deinit(self.allocator);
        self.buffer.deinit(self.allocator);
    }

    pub fn feed(self: *Reader, data: []const u8) errors.FluxError!void {
        self.buffer.appendSlice(self.allocator, data) catch {
            return errors.FluxError.internal_failure;
        };

        try self.process_available();
    }

    pub fn next_event(self: *Reader) ?ControlEvent {
        if (self.events.items.len == 0) {
            return null;
        }
        return self.events.orderedRemove(0);
    }

    pub fn release_event(self: *Reader, event: *ControlEvent) void {
        switch (event.*) {
            .settings => |settings| self.allocator.free(settings),
            .priority_update => |priority| self.allocator.free(priority.value),
            else => {},
        }
    }

    fn process_available(self: *Reader) errors.FluxError!void {
        var cursor: usize = 0;

        while (true) {
            const rem = self.buffer.items[cursor..];
            const frame_type = decode_varint(rem) orelse break;
            const frame_len_vi = decode_varint(rem[frame_type.consumed..]) orelse break;

            const frame_header_len = frame_type.consumed + frame_len_vi.consumed;
            const frame_len = std.math.cast(usize, frame_len_vi.value) orelse {
                return errors.FluxError.protocol_violation;
            };

            if (rem.len < frame_header_len + frame_len) {
                break;
            }

            const payload = rem[frame_header_len .. frame_header_len + frame_len];
            try self.handle_frame(frame_type.value, payload);
            cursor += frame_header_len + frame_len;
        }

        if (cursor > 0) {
            const remaining = self.buffer.items.len - cursor;
            std.mem.copyForwards(u8, self.buffer.items[0..remaining], self.buffer.items[cursor..]);
            self.buffer.shrinkRetainingCapacity(remaining);
        }
    }

    fn handle_frame(self: *Reader, frame_type: u64, payload: []const u8) errors.FluxError!void {
        if (!self.saw_first_frame) {
            self.saw_first_frame = true;
            if (frame_type != @intFromEnum(h3_core.H3FrameType.settings)) {
                return errors.FluxError.missing_settings;
            }
        }

        if (frame_type == @intFromEnum(h3_core.H3FrameType.settings) and self.settings_received) {
            return errors.FluxError.settings_error;
        }

        switch (frame_type) {
            @intFromEnum(h3_core.H3FrameType.settings) => {
                const parsed = try self.parse_settings(payload);
                self.settings_received = true;
                try self.push_event(.{ .settings = parsed });
            },
            @intFromEnum(h3_core.H3FrameType.goaway) => {
                const id = try parse_exact_varint(payload);
                try self.push_event(.{ .goaway = id });
            },
            @intFromEnum(h3_core.H3FrameType.cancel_push) => {
                const id = try parse_exact_varint(payload);
                try self.push_event(.{ .cancel_push = id });
            },
            @intFromEnum(h3_core.H3FrameType.max_push_id) => {
                const id = try parse_exact_varint(payload);
                try self.push_event(.{ .max_push_id = id });
            },
            @intFromEnum(h3_core.H3FrameType.priority_update_request), @intFromEnum(h3_core.H3FrameType.priority_update_push) => {
                const priority = try self.parse_priority_update(frame_type, payload);
                try self.push_event(.{ .priority_update = priority });
            },
            else => {},
        }
    }

    fn parse_settings(self: *Reader, payload: []const u8) errors.FluxError![]Setting {
        var values: std.ArrayList(Setting) = .{};
        defer values.deinit(self.allocator);

        var cursor: usize = 0;
        while (cursor < payload.len) {
            const id_vi = decode_varint(payload[cursor..]) orelse {
                return errors.FluxError.settings_error;
            };
            cursor += id_vi.consumed;

            const value_vi = decode_varint(payload[cursor..]) orelse {
                return errors.FluxError.settings_error;
            };
            cursor += value_vi.consumed;

            values.append(self.allocator, .{
                .id = id_vi.value,
                .value = value_vi.value,
            }) catch {
                return errors.FluxError.internal_failure;
            };
        }

        return values.toOwnedSlice(self.allocator) catch {
            return errors.FluxError.internal_failure;
        };
    }

    fn parse_priority_update(self: *Reader, frame_type: u64, payload: []const u8) errors.FluxError!PriorityUpdate {
        const element = decode_varint(payload) orelse {
            return errors.FluxError.protocol_violation;
        };

        const value = payload[element.consumed..];
        const owned_value = self.allocator.alloc(u8, value.len) catch {
            return errors.FluxError.internal_failure;
        };
        @memcpy(owned_value, value);

        return .{
            .is_push = frame_type == @intFromEnum(h3_core.H3FrameType.priority_update_push),
            .element_id = element.value,
            .value = owned_value,
        };
    }

    fn push_event(self: *Reader, event: ControlEvent) errors.FluxError!void {
        self.events.append(self.allocator, event) catch {
            return errors.FluxError.internal_failure;
        };
    }
};

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

fn parse_exact_varint(payload: []const u8) errors.FluxError!u64 {
    const decoded = decode_varint(payload) orelse {
        return errors.FluxError.protocol_violation;
    };
    if (decoded.consumed != payload.len) {
        return errors.FluxError.protocol_violation;
    }
    return decoded.value;
}

fn append_varint(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u64) !void {
    if (value <= 63) {
        try out.append(allocator, @as(u8, @intCast(value)));
        return;
    }

    if (value <= 16383) {
        const encoded: u16 = (@as(u16, @intCast(value)) | 0x4000);
        try out.append(allocator, @as(u8, @intCast(encoded >> 8)));
        try out.append(allocator, @as(u8, @intCast(encoded & 0xff)));
        return;
    }

    if (value <= 1073741823) {
        const encoded: u32 = (@as(u32, @intCast(value)) | 0x80000000);
        try out.append(allocator, @as(u8, @intCast(encoded >> 24)));
        try out.append(allocator, @as(u8, @intCast((encoded >> 16) & 0xff)));
        try out.append(allocator, @as(u8, @intCast((encoded >> 8) & 0xff)));
        try out.append(allocator, @as(u8, @intCast(encoded & 0xff)));
        return;
    }

    const encoded: u64 = value | 0xc000000000000000;
    try out.append(allocator, @as(u8, @intCast(encoded >> 56)));
    try out.append(allocator, @as(u8, @intCast((encoded >> 48) & 0xff)));
    try out.append(allocator, @as(u8, @intCast((encoded >> 40) & 0xff)));
    try out.append(allocator, @as(u8, @intCast((encoded >> 32) & 0xff)));
    try out.append(allocator, @as(u8, @intCast((encoded >> 24) & 0xff)));
    try out.append(allocator, @as(u8, @intCast((encoded >> 16) & 0xff)));
    try out.append(allocator, @as(u8, @intCast((encoded >> 8) & 0xff)));
    try out.append(allocator, @as(u8, @intCast(encoded & 0xff)));
}

fn append_frame(allocator: std.mem.Allocator, out: *std.ArrayList(u8), frame_type: u64, payload: []const u8) !void {
    try append_varint(allocator, out, frame_type);
    try append_varint(allocator, out, payload.len);
    try out.appendSlice(allocator, payload);
}

test "control reader enforces first frame settings" {
    var reader = Reader.init(std.testing.allocator);
    defer reader.deinit();

    var wire: std.ArrayList(u8) = .{};
    defer wire.deinit(std.testing.allocator);

    var payload: std.ArrayList(u8) = .{};
    defer payload.deinit(std.testing.allocator);
    try append_varint(std.testing.allocator, &payload, 17);
    try append_frame(std.testing.allocator, &wire, @intFromEnum(h3_core.H3FrameType.goaway), payload.items);

    try std.testing.expectError(errors.FluxError.missing_settings, reader.feed(wire.items));
}

test "control reader parses settings and allows fragmented input" {
    var reader = Reader.init(std.testing.allocator);
    defer reader.deinit();

    var payload: std.ArrayList(u8) = .{};
    defer payload.deinit(std.testing.allocator);
    try append_varint(std.testing.allocator, &payload, @intFromEnum(h3_core.H3SettingId.qpack_max_table_capacity));
    try append_varint(std.testing.allocator, &payload, 4096);
    try append_varint(std.testing.allocator, &payload, @intFromEnum(h3_core.H3SettingId.qpack_blocked_streams));
    try append_varint(std.testing.allocator, &payload, 16);

    var frame: std.ArrayList(u8) = .{};
    defer frame.deinit(std.testing.allocator);
    try append_frame(std.testing.allocator, &frame, @intFromEnum(h3_core.H3FrameType.settings), payload.items);

    const split = frame.items.len / 2;
    try reader.feed(frame.items[0..split]);
    try std.testing.expect(reader.next_event() == null);

    try reader.feed(frame.items[split..]);
    var event = reader.next_event().?;
    defer reader.release_event(&event);

    try std.testing.expect(event == .settings);
    try std.testing.expectEqual(@as(usize, 2), event.settings.len);
    try std.testing.expectEqual(@as(u64, @intFromEnum(h3_core.H3SettingId.qpack_max_table_capacity)), event.settings[0].id);
    try std.testing.expectEqual(@as(u64, 4096), event.settings[0].value);
}

test "control reader rejects duplicate settings" {
    var reader = Reader.init(std.testing.allocator);
    defer reader.deinit();

    var settings_payload: std.ArrayList(u8) = .{};
    defer settings_payload.deinit(std.testing.allocator);
    try append_varint(std.testing.allocator, &settings_payload, @intFromEnum(h3_core.H3SettingId.qpack_blocked_streams));
    try append_varint(std.testing.allocator, &settings_payload, 32);

    var frame: std.ArrayList(u8) = .{};
    defer frame.deinit(std.testing.allocator);
    try append_frame(std.testing.allocator, &frame, @intFromEnum(h3_core.H3FrameType.settings), settings_payload.items);
    try append_frame(std.testing.allocator, &frame, @intFromEnum(h3_core.H3FrameType.settings), settings_payload.items);

    try std.testing.expectError(errors.FluxError.settings_error, reader.feed(frame.items));
}

test "control reader parses goaway cancel push and max push id" {
    var reader = Reader.init(std.testing.allocator);
    defer reader.deinit();

    var wire: std.ArrayList(u8) = .{};
    defer wire.deinit(std.testing.allocator);

    var settings_payload: std.ArrayList(u8) = .{};
    defer settings_payload.deinit(std.testing.allocator);
    try append_varint(std.testing.allocator, &settings_payload, @intFromEnum(h3_core.H3SettingId.max_field_section_size));
    try append_varint(std.testing.allocator, &settings_payload, 8192);
    try append_frame(std.testing.allocator, &wire, @intFromEnum(h3_core.H3FrameType.settings), settings_payload.items);

    var var_payload: std.ArrayList(u8) = .{};
    defer var_payload.deinit(std.testing.allocator);
    try append_varint(std.testing.allocator, &var_payload, 9);
    try append_frame(std.testing.allocator, &wire, @intFromEnum(h3_core.H3FrameType.goaway), var_payload.items);

    var_payload.clearRetainingCapacity();
    try append_varint(std.testing.allocator, &var_payload, 4);
    try append_frame(std.testing.allocator, &wire, @intFromEnum(h3_core.H3FrameType.cancel_push), var_payload.items);

    var_payload.clearRetainingCapacity();
    try append_varint(std.testing.allocator, &var_payload, 12);
    try append_frame(std.testing.allocator, &wire, @intFromEnum(h3_core.H3FrameType.max_push_id), var_payload.items);

    try reader.feed(wire.items);

    {
        var event = reader.next_event().?;
        defer reader.release_event(&event);
        try std.testing.expect(event == .settings);
    }
    {
        var event = reader.next_event().?;
        defer reader.release_event(&event);
        try std.testing.expect(event == .goaway);
        try std.testing.expectEqual(@as(u64, 9), event.goaway);
    }
    {
        var event = reader.next_event().?;
        defer reader.release_event(&event);
        try std.testing.expect(event == .cancel_push);
        try std.testing.expectEqual(@as(u64, 4), event.cancel_push);
    }
    {
        var event = reader.next_event().?;
        defer reader.release_event(&event);
        try std.testing.expect(event == .max_push_id);
        try std.testing.expectEqual(@as(u64, 12), event.max_push_id);
    }
}

test "control reader parses priority update request and push" {
    var reader = Reader.init(std.testing.allocator);
    defer reader.deinit();

    var wire: std.ArrayList(u8) = .{};
    defer wire.deinit(std.testing.allocator);

    var settings_payload: std.ArrayList(u8) = .{};
    defer settings_payload.deinit(std.testing.allocator);
    try append_varint(std.testing.allocator, &settings_payload, @intFromEnum(h3_core.H3SettingId.qpack_max_table_capacity));
    try append_varint(std.testing.allocator, &settings_payload, 1);
    try append_frame(std.testing.allocator, &wire, @intFromEnum(h3_core.H3FrameType.settings), settings_payload.items);

    var priority_payload: std.ArrayList(u8) = .{};
    defer priority_payload.deinit(std.testing.allocator);
    try append_varint(std.testing.allocator, &priority_payload, 23);
    try priority_payload.appendSlice(std.testing.allocator, "u=3");
    try append_frame(std.testing.allocator, &wire, @intFromEnum(h3_core.H3FrameType.priority_update_request), priority_payload.items);

    priority_payload.clearRetainingCapacity();
    try append_varint(std.testing.allocator, &priority_payload, 44);
    try priority_payload.appendSlice(std.testing.allocator, "i");
    try append_frame(std.testing.allocator, &wire, @intFromEnum(h3_core.H3FrameType.priority_update_push), priority_payload.items);

    try reader.feed(wire.items);

    {
        var event = reader.next_event().?;
        defer reader.release_event(&event);
        try std.testing.expect(event == .settings);
    }
    {
        var event = reader.next_event().?;
        defer reader.release_event(&event);
        try std.testing.expect(event == .priority_update);
        try std.testing.expect(!event.priority_update.is_push);
        try std.testing.expectEqual(@as(u64, 23), event.priority_update.element_id);
        try std.testing.expectEqualStrings("u=3", event.priority_update.value);
    }
    {
        var event = reader.next_event().?;
        defer reader.release_event(&event);
        try std.testing.expect(event == .priority_update);
        try std.testing.expect(event.priority_update.is_push);
        try std.testing.expectEqual(@as(u64, 44), event.priority_update.element_id);
        try std.testing.expectEqualStrings("i", event.priority_update.value);
    }
}

test "control reader ignores unknown frames" {
    var reader = Reader.init(std.testing.allocator);
    defer reader.deinit();

    var wire: std.ArrayList(u8) = .{};
    defer wire.deinit(std.testing.allocator);

    var settings_payload: std.ArrayList(u8) = .{};
    defer settings_payload.deinit(std.testing.allocator);
    try append_varint(std.testing.allocator, &settings_payload, @intFromEnum(h3_core.H3SettingId.qpack_blocked_streams));
    try append_varint(std.testing.allocator, &settings_payload, 2);
    try append_frame(std.testing.allocator, &wire, @intFromEnum(h3_core.H3FrameType.settings), settings_payload.items);

    try append_frame(std.testing.allocator, &wire, 0x42, "unknown");

    try reader.feed(wire.items);

    var event = reader.next_event().?;
    defer reader.release_event(&event);
    try std.testing.expect(event == .settings);
    try std.testing.expect(reader.next_event() == null);
}
