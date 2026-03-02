const std = @import("std");
const errors = @import("errors.zig");

pub const H3FrameType = enum(u64) {
    data = 0x00,
    headers = 0x01,
    cancel_push = 0x03,
    settings = 0x04,
    push_promise = 0x05,
    goaway = 0x07,
    max_push_id = 0x0d,
    priority_update_request = 0x0f0700,
    priority_update_push = 0x0f0701,
};

pub const H3SettingId = enum(u64) {
    qpack_max_table_capacity = 0x01,
    max_field_section_size = 0x06,
    qpack_blocked_streams = 0x07,
    enable_connect_protocol = 0x08,
    h3_datagram = 0x33,
    enable_webtransport = 0x2b603742,
    webtransport_max_sessions = 0x2b603743,
};

pub const H3UniStreamType = enum(u64) {
    control = 0x00,
    push = 0x01,
    qpack_encoder = 0x02,
    qpack_decoder = 0x03,
};

pub const H3UniStreamRole = enum {
    control,
    push,
    qpack_encoder,
    qpack_decoder,
    unknown,
};

pub const Core = struct {
    ready: bool,
    alpn_validated: bool,
    negotiated_alpn: ?[]const u8,
    control_stream_id: ?u64,
    qpack_encoder_stream_id: ?u64,
    qpack_decoder_stream_id: ?u64,
    push_stream_count: usize,

    pub fn init() Core {
        return .{
            .ready = false,
            .alpn_validated = false,
            .negotiated_alpn = null,
            .control_stream_id = null,
            .qpack_encoder_stream_id = null,
            .qpack_decoder_stream_id = null,
            .push_stream_count = 0,
        };
    }

    pub fn set_alpn_validated(self: *Core, ok: bool) void {
        self.alpn_validated = ok;
        if (!ok) self.ready = false;
    }

    pub fn validate_alpn(self: *Core, negotiated_alpn: []const u8) errors.FluxError!void {
        self.negotiated_alpn = negotiated_alpn;
        if (!std.mem.eql(u8, negotiated_alpn, "h3")) {
            self.set_alpn_validated(false);
            return errors.FluxError.invalid_state;
        }

        self.set_alpn_validated(true);
    }

    pub fn mark_ready(self: *Core) errors.FluxError!void {
        if (!self.alpn_validated) {
            return errors.FluxError.invalid_state;
        }

        self.ready = true;
    }

    pub fn parse_uni_stream_role(stream_type: u64) H3UniStreamRole {
        return switch (stream_type) {
            @intFromEnum(H3UniStreamType.control) => .control,
            @intFromEnum(H3UniStreamType.push) => .push,
            @intFromEnum(H3UniStreamType.qpack_encoder) => .qpack_encoder,
            @intFromEnum(H3UniStreamType.qpack_decoder) => .qpack_decoder,
            else => .unknown,
        };
    }

    pub fn register_uni_stream(self: *Core, stream_id: u64, stream_type: u64) errors.FluxError!H3UniStreamRole {
        const role = parse_uni_stream_role(stream_type);
        switch (role) {
            .control => {
                if (self.control_stream_id != null) {
                    return errors.FluxError.protocol_violation;
                }
                self.control_stream_id = stream_id;
            },
            .qpack_encoder => {
                if (self.qpack_encoder_stream_id != null) {
                    return errors.FluxError.protocol_violation;
                }
                self.qpack_encoder_stream_id = stream_id;
            },
            .qpack_decoder => {
                if (self.qpack_decoder_stream_id != null) {
                    return errors.FluxError.protocol_violation;
                }
                self.qpack_decoder_stream_id = stream_id;
            },
            .push => {
                self.push_stream_count += 1;
            },
            .unknown => {},
        }

        return role;
    }
};

test "h3 core cannot become ready without alpn validation" {
    var core = Core.init();
    try std.testing.expectError(errors.FluxError.invalid_state, core.mark_ready());

    core.set_alpn_validated(true);
    try core.mark_ready();
    try std.testing.expect(core.ready);
}

test "h3 core rejects non-h3 alpn" {
    var core = Core.init();
    try std.testing.expectError(errors.FluxError.invalid_state, core.validate_alpn("hq-29"));
    try std.testing.expect(!core.ready);
    try std.testing.expect(!core.alpn_validated);
}

test "h3 core accepts h3 alpn" {
    var core = Core.init();
    try core.validate_alpn("h3");
    try core.mark_ready();
    try std.testing.expect(core.ready);
    try std.testing.expect(core.alpn_validated);
    try std.testing.expect(std.mem.eql(u8, core.negotiated_alpn.?, "h3"));
}

test "uni stream role parser routes known types" {
    try std.testing.expectEqual(H3UniStreamRole.control, Core.parse_uni_stream_role(0x00));
    try std.testing.expectEqual(H3UniStreamRole.push, Core.parse_uni_stream_role(0x01));
    try std.testing.expectEqual(H3UniStreamRole.qpack_encoder, Core.parse_uni_stream_role(0x02));
    try std.testing.expectEqual(H3UniStreamRole.qpack_decoder, Core.parse_uni_stream_role(0x03));
}

test "uni stream role parser maps unknown types" {
    try std.testing.expectEqual(H3UniStreamRole.unknown, Core.parse_uni_stream_role(0x54));
}

test "uni stream registry rejects duplicate critical streams" {
    var core = Core.init();

    try std.testing.expectEqual(H3UniStreamRole.control, try core.register_uni_stream(2, 0x00));
    try std.testing.expectError(errors.FluxError.protocol_violation, core.register_uni_stream(6, 0x00));

    try std.testing.expectEqual(H3UniStreamRole.qpack_encoder, try core.register_uni_stream(10, 0x02));
    try std.testing.expectError(errors.FluxError.protocol_violation, core.register_uni_stream(14, 0x02));

    try std.testing.expectEqual(H3UniStreamRole.qpack_decoder, try core.register_uni_stream(18, 0x03));
    try std.testing.expectError(errors.FluxError.protocol_violation, core.register_uni_stream(22, 0x03));
}

test "uni stream registry allows multiple push and unknown streams" {
    var core = Core.init();

    try std.testing.expectEqual(H3UniStreamRole.push, try core.register_uni_stream(3, 0x01));
    try std.testing.expectEqual(H3UniStreamRole.push, try core.register_uni_stream(7, 0x01));
    try std.testing.expectEqual(@as(usize, 2), core.push_stream_count);

    try std.testing.expectEqual(H3UniStreamRole.unknown, try core.register_uni_stream(11, 0x21));
    try std.testing.expectEqual(H3UniStreamRole.unknown, try core.register_uni_stream(15, 0x54));
}
