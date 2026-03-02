const std = @import("std");
const errors = @import("errors.zig");
const transport_adapter = @import("transport_adapter.zig");

pub const MAX_WT_DATAGRAM_PAYLOAD = 1150;

pub const TransportPreference = enum {
    datagram,
    capsule_only,
};

pub const SessionDatagram = struct {
    session_id: u64,
    context_id: u64,
    payload: []u8,
};

pub const NegotiatedFeatures = struct {
    connect_protocol_enabled: bool,
    h3_datagram_enabled: bool,
    webtransport_enabled: bool,
    webtransport_max_sessions: u64,

    pub fn init() NegotiatedFeatures {
        return .{
            .connect_protocol_enabled = false,
            .h3_datagram_enabled = false,
            .webtransport_enabled = false,
            .webtransport_max_sessions = 0,
        };
    }

    pub fn supports_webtransport(self: NegotiatedFeatures) bool {
        return self.connect_protocol_enabled and self.webtransport_enabled;
    }

    pub fn supports_webtransport_datagrams(self: NegotiatedFeatures) bool {
        return self.supports_webtransport() and self.h3_datagram_enabled;
    }
};

pub const Negotiator = struct {
    local: NegotiatedFeatures,
    peer: NegotiatedFeatures,

    pub fn init() Negotiator {
        return .{
            .local = NegotiatedFeatures.init(),
            .peer = NegotiatedFeatures.init(),
        };
    }

    pub fn set_local_connect_protocol(self: *Negotiator, enabled: bool) void {
        self.local.connect_protocol_enabled = enabled;
    }

    pub fn set_local_h3_datagram(self: *Negotiator, enabled: bool) void {
        self.local.h3_datagram_enabled = enabled;
    }

    pub fn set_local_webtransport(self: *Negotiator, enabled: bool, max_sessions: u64) void {
        self.local.webtransport_enabled = enabled;
        self.local.webtransport_max_sessions = max_sessions;
    }

    pub fn set_peer_connect_protocol(self: *Negotiator, enabled: bool) void {
        self.peer.connect_protocol_enabled = enabled;
    }

    pub fn set_peer_h3_datagram(self: *Negotiator, enabled: bool) void {
        self.peer.h3_datagram_enabled = enabled;
    }

    pub fn set_peer_webtransport(self: *Negotiator, enabled: bool, max_sessions: u64) void {
        self.peer.webtransport_enabled = enabled;
        self.peer.webtransport_max_sessions = max_sessions;
    }

    pub fn negotiate(self: *Negotiator) NegotiatedFeatures {
        return .{
            .connect_protocol_enabled = self.local.connect_protocol_enabled and self.peer.connect_protocol_enabled,
            .h3_datagram_enabled = self.local.h3_datagram_enabled and self.peer.h3_datagram_enabled,
            .webtransport_enabled = self.local.webtransport_enabled and self.peer.webtransport_enabled,
            .webtransport_max_sessions = @min(self.local.webtransport_max_sessions, self.peer.webtransport_max_sessions),
        };
    }
};

pub const Core = struct {
    allocator: std.mem.Allocator,
    sessions_open: usize,
    negotiated: NegotiatedFeatures,
    next_session_id: u64,
    active_sessions: std.AutoHashMap(u64, void),

    pub fn init(allocator: std.mem.Allocator) Core {
        return .{
            .allocator = allocator,
            .sessions_open = 0,
            .negotiated = NegotiatedFeatures.init(),
            .next_session_id = 1,
            .active_sessions = std.AutoHashMap(u64, void).init(allocator),
        };
    }

    pub fn deinit(self: *Core) void {
        self.active_sessions.deinit();
    }

    pub fn apply_negotiated_features(self: *Core, features: NegotiatedFeatures) void {
        self.negotiated = features;
    }

    pub fn preferred_transport(self: *const Core) TransportPreference {
        if (self.negotiated.supports_webtransport_datagrams()) {
            return .datagram;
        }

        return .capsule_only;
    }

    pub fn open_session(self: *Core) errors.FluxError!void {
        _ = try self.open_session_id();
    }

    pub fn open_session_id(self: *Core) errors.FluxError!u64 {
        if (!self.negotiated.supports_webtransport()) {
            return errors.FluxError.invalid_state;
        }

        if (self.sessions_open >= self.negotiated.webtransport_max_sessions) {
            return errors.FluxError.backpressure;
        }

        const session_id = self.next_session_id;
        self.next_session_id += 1;

        self.active_sessions.put(session_id, {}) catch {
            return errors.FluxError.internal_failure;
        };
        self.sessions_open += 1;
        return session_id;
    }

    pub fn close_session(self: *Core) void {
        if (self.sessions_open == 0) return;
        var it = self.active_sessions.iterator();
        if (it.next()) |entry| {
            _ = self.active_sessions.remove(entry.key_ptr.*);
        }
        self.sessions_open -= 1;
    }

    pub fn close_session_id(self: *Core, session_id: u64) void {
        if (self.active_sessions.remove(session_id)) {
            self.sessions_open -= 1;
        }
    }

    pub fn send_session_datagram(self: *Core, adapter: *transport_adapter.Adapter, session_id: u64, context_id: u64, payload: []const u8) errors.FluxError!usize {
        if (!self.negotiated.supports_webtransport_datagrams()) {
            return errors.FluxError.invalid_state;
        }

        if (!self.active_sessions.contains(session_id)) {
            return errors.FluxError.invalid_argument;
        }

        if (payload.len == 0 or payload.len > MAX_WT_DATAGRAM_PAYLOAD) {
            return errors.FluxError.invalid_argument;
        }

        var wire: std.ArrayList(u8) = .{};
        defer wire.deinit(self.allocator);

        try append_varint(self.allocator, &wire, session_id);
        try append_varint(self.allocator, &wire, context_id);
        wire.appendSlice(self.allocator, payload) catch {
            return errors.FluxError.internal_failure;
        };

        return adapter.send_datagram(wire.items);
    }

    pub fn recv_session_datagram(self: *Core, adapter: *transport_adapter.Adapter) errors.FluxError!SessionDatagram {
        if (!self.negotiated.supports_webtransport_datagrams()) {
            return errors.FluxError.invalid_state;
        }

        var event = adapter.next_event() orelse return errors.FluxError.invalid_state;
        defer adapter.release_event(&event);

        if (event.kind != .datagram_received) {
            return errors.FluxError.invalid_state;
        }

        const payload = event.payload orelse return errors.FluxError.protocol_violation;
        const sid_vi = decode_varint(payload) orelse return errors.FluxError.protocol_violation;
        const ctx_vi = decode_varint(payload[sid_vi.consumed..]) orelse return errors.FluxError.protocol_violation;

        const body_offset = sid_vi.consumed + ctx_vi.consumed;
        if (body_offset >= payload.len) {
            return errors.FluxError.protocol_violation;
        }

        if (!self.active_sessions.contains(sid_vi.value)) {
            return errors.FluxError.invalid_argument;
        }

        const body = payload[body_offset..];
        if (body.len > MAX_WT_DATAGRAM_PAYLOAD) {
            return errors.FluxError.backpressure;
        }

        const owned = self.allocator.dupe(u8, body) catch {
            return errors.FluxError.internal_failure;
        };

        return .{
            .session_id = sid_vi.value,
            .context_id = ctx_vi.value,
            .payload = owned,
        };
    }

    pub fn free_session_datagram(self: *Core, datagram: SessionDatagram) void {
        self.allocator.free(datagram.payload);
    }
};

const VarInt = struct {
    value: u64,
    consumed: usize,
};

fn append_varint(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u64) errors.FluxError!void {
    if (value <= 63) {
        out.append(allocator, @as(u8, @intCast(value))) catch return errors.FluxError.internal_failure;
        return;
    }

    if (value <= 16383) {
        const encoded: u16 = (@as(u16, @intCast(value)) | 0x4000);
        out.append(allocator, @as(u8, @intCast(encoded >> 8))) catch return errors.FluxError.internal_failure;
        out.append(allocator, @as(u8, @intCast(encoded & 0xff))) catch return errors.FluxError.internal_failure;
        return;
    }

    const encoded: u32 = (@as(u32, @intCast(value)) | 0x80000000);
    out.append(allocator, @as(u8, @intCast(encoded >> 24))) catch return errors.FluxError.internal_failure;
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

test "wt core tracks session count under negotiated limits" {
    var core = Core.init(std.testing.allocator);
    defer core.deinit();
    core.apply_negotiated_features(.{
        .connect_protocol_enabled = true,
        .h3_datagram_enabled = true,
        .webtransport_enabled = true,
        .webtransport_max_sessions = 2,
    });

    _ = try core.open_session_id();
    _ = try core.open_session_id();
    try std.testing.expectEqual(@as(usize, 2), core.sessions_open);
    try std.testing.expectError(errors.FluxError.backpressure, core.open_session());

    core.close_session();
    try std.testing.expectEqual(@as(usize, 1), core.sessions_open);
}

test "negotiation matrix requires connect protocol and webtransport" {
    var n = Negotiator.init();

    n.set_local_connect_protocol(true);
    n.set_local_h3_datagram(true);
    n.set_local_webtransport(true, 8);

    n.set_peer_connect_protocol(false);
    n.set_peer_h3_datagram(true);
    n.set_peer_webtransport(true, 4);

    var features = n.negotiate();
    try std.testing.expect(!features.supports_webtransport());
    try std.testing.expectEqual(TransportPreference.capsule_only, (Core{
        .allocator = std.testing.allocator,
        .sessions_open = 0,
        .negotiated = features,
        .next_session_id = 1,
        .active_sessions = std.AutoHashMap(u64, void).init(std.testing.allocator),
    }).preferred_transport());

    n.set_peer_connect_protocol(true);
    features = n.negotiate();
    try std.testing.expect(features.supports_webtransport());
    try std.testing.expect(features.supports_webtransport_datagrams());
}

test "negotiation fallback chooses capsule-only when datagram disabled" {
    var n = Negotiator.init();

    n.set_local_connect_protocol(true);
    n.set_local_h3_datagram(true);
    n.set_local_webtransport(true, 16);

    n.set_peer_connect_protocol(true);
    n.set_peer_h3_datagram(false);
    n.set_peer_webtransport(true, 3);

    const features = n.negotiate();
    var core = Core.init(std.testing.allocator);
    defer core.deinit();
    core.apply_negotiated_features(features);

    try std.testing.expect(core.negotiated.supports_webtransport());
    try std.testing.expect(!core.negotiated.supports_webtransport_datagrams());
    try std.testing.expectEqual(TransportPreference.capsule_only, core.preferred_transport());
}

test "opening session without negotiated webtransport fails" {
    var core = Core.init(std.testing.allocator);
    defer core.deinit();
    try std.testing.expectError(errors.FluxError.invalid_state, core.open_session());
}

test "session datagram routing validates context and payload bounds" {
    var adapter = transport_adapter.Adapter.init(std.testing.allocator);
    defer adapter.deinit();
    adapter.set_datagram_enabled(true);

    var core = Core.init(std.testing.allocator);
    defer core.deinit();
    core.apply_negotiated_features(.{
        .connect_protocol_enabled = true,
        .h3_datagram_enabled = true,
        .webtransport_enabled = true,
        .webtransport_max_sessions = 1,
    });

    const session_id = try core.open_session_id();
    _ = try core.send_session_datagram(&adapter, session_id, 7, "ping");

    var event = adapter.next_event().?;
    defer adapter.release_event(&event);
    try std.testing.expectEqual(transport_adapter.EventKind.datagram_sent, event.kind);

    try std.testing.expectError(errors.FluxError.invalid_argument, core.send_session_datagram(&adapter, session_id, 7, ""));

    const too_big = try std.testing.allocator.alloc(u8, MAX_WT_DATAGRAM_PAYLOAD + 1);
    defer std.testing.allocator.free(too_big);
    @memset(too_big, 'x');
    try std.testing.expectError(errors.FluxError.invalid_argument, core.send_session_datagram(&adapter, session_id, 7, too_big));
}

test "session datagram receive routes by session id" {
    var adapter = transport_adapter.Adapter.init(std.testing.allocator);
    defer adapter.deinit();
    adapter.set_datagram_enabled(true);

    var core = Core.init(std.testing.allocator);
    defer core.deinit();
    core.apply_negotiated_features(.{
        .connect_protocol_enabled = true,
        .h3_datagram_enabled = true,
        .webtransport_enabled = true,
        .webtransport_max_sessions = 2,
    });

    const session_id = try core.open_session_id();

    var wire: std.ArrayList(u8) = .{};
    defer wire.deinit(std.testing.allocator);
    try append_varint(std.testing.allocator, &wire, session_id);
    try append_varint(std.testing.allocator, &wire, 99);
    try wire.appendSlice(std.testing.allocator, "hello");

    try adapter.inject_datagram_received(wire.items);
    const datagram = try core.recv_session_datagram(&adapter);
    defer core.free_session_datagram(datagram);

    try std.testing.expectEqual(session_id, datagram.session_id);
    try std.testing.expectEqual(@as(u64, 99), datagram.context_id);
    try std.testing.expectEqualStrings("hello", datagram.payload);
}

test "session datagram receive rejects unknown session" {
    var adapter = transport_adapter.Adapter.init(std.testing.allocator);
    defer adapter.deinit();
    adapter.set_datagram_enabled(true);

    var core = Core.init(std.testing.allocator);
    defer core.deinit();
    core.apply_negotiated_features(.{
        .connect_protocol_enabled = true,
        .h3_datagram_enabled = true,
        .webtransport_enabled = true,
        .webtransport_max_sessions = 1,
    });

    var wire: std.ArrayList(u8) = .{};
    defer wire.deinit(std.testing.allocator);
    try append_varint(std.testing.allocator, &wire, 999);
    try append_varint(std.testing.allocator, &wire, 1);
    try wire.appendSlice(std.testing.allocator, "x");

    try adapter.inject_datagram_received(wire.items);
    try std.testing.expectError(errors.FluxError.invalid_argument, core.recv_session_datagram(&adapter));
}
