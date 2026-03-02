const std = @import("std");
const errors = @import("errors.zig");
const transport_adapter = @import("transport_adapter.zig");
const h3_core = @import("h3_core.zig");

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

pub const H3Setting = struct {
    id: u64,
    value: u64,
};

pub const WebTransportConnectRequest = struct {
    authority: []const u8,
    path: []const u8,
    origin: []const u8,
};

pub const WebTransportConnectResponse = struct {
    status: u16,
};

pub const SessionState = enum {
    active,
    closing,
    closed,
    errored,
};

pub const SessionInfo = struct {
    session_id: u64,
    stream_id: u64,
    state: SessionState,
};

pub const SessionEvent = union(enum) {
    opened: SessionInfo,
    closing: SessionInfo,
    closed: SessionInfo,
    errored: SessionInfo,
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

    pub fn apply_local_h3_settings(self: *Negotiator, settings: []const H3Setting) errors.FluxError!void {
        try apply_h3_settings_to_features(settings, &self.local);
    }

    pub fn apply_peer_h3_settings(self: *Negotiator, settings: []const H3Setting) errors.FluxError!void {
        try apply_h3_settings_to_features(settings, &self.peer);
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
    active_sessions: std.AutoHashMap(u64, SessionInfo),
    session_events: std.ArrayList(SessionEvent),

    pub fn init(allocator: std.mem.Allocator) Core {
        return .{
            .allocator = allocator,
            .sessions_open = 0,
            .negotiated = NegotiatedFeatures.init(),
            .next_session_id = 1,
            .active_sessions = std.AutoHashMap(u64, SessionInfo).init(allocator),
            .session_events = .{},
        };
    }

    pub fn deinit(self: *Core) void {
        self.active_sessions.deinit();
        self.session_events.deinit(self.allocator);
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

        const info = SessionInfo{
            .session_id = session_id,
            .stream_id = 0,
            .state = .active,
        };

        self.active_sessions.put(session_id, info) catch {
            return errors.FluxError.internal_failure;
        };
        self.sessions_open += 1;
        try self.push_session_event(.{ .opened = info });
        return session_id;
    }

    pub fn register_session_with_id(self: *Core, session_id: u64, stream_id: u64) errors.FluxError!void {
        if (!self.negotiated.supports_webtransport()) {
            return errors.FluxError.invalid_state;
        }

        if (self.active_sessions.contains(session_id)) {
            return errors.FluxError.protocol_violation;
        }

        if (self.sessions_open >= self.negotiated.webtransport_max_sessions) {
            return errors.FluxError.backpressure;
        }

        const info = SessionInfo{
            .session_id = session_id,
            .stream_id = stream_id,
            .state = .active,
        };

        self.active_sessions.put(session_id, info) catch {
            return errors.FluxError.internal_failure;
        };
        self.sessions_open += 1;
        try self.push_session_event(.{ .opened = info });
    }

    pub fn begin_close_session(self: *Core, session_id: u64) errors.FluxError!void {
        const info = self.active_sessions.getPtr(session_id) orelse return errors.FluxError.invalid_argument;
        switch (info.state) {
            .active => {
                info.state = .closing;
                try self.push_session_event(.{ .closing = info.* });
            },
            .closing, .closed => {},
            .errored => return errors.FluxError.invalid_state,
        }
    }

    pub fn mark_session_error(self: *Core, session_id: u64) errors.FluxError!void {
        const info = self.active_sessions.getPtr(session_id) orelse return errors.FluxError.invalid_argument;
        info.state = .errored;
        try self.push_session_event(.{ .errored = info.* });
    }

    pub fn complete_close_session(self: *Core, session_id: u64) errors.FluxError!void {
        const info = self.active_sessions.get(session_id) orelse return errors.FluxError.invalid_argument;
        if (info.state == .errored) {
            return errors.FluxError.invalid_state;
        }

        _ = self.active_sessions.remove(session_id);
        if (self.sessions_open > 0) {
            self.sessions_open -= 1;
        }

        var closed_info = info;
        closed_info.state = .closed;
        try self.push_session_event(.{ .closed = closed_info });
    }

    pub fn close_session(self: *Core) void {
        if (self.sessions_open == 0) return;
        var it = self.active_sessions.iterator();
        if (it.next()) |entry| {
            self.close_session_id(entry.key_ptr.*);
        }
    }

    pub fn close_session_id(self: *Core, session_id: u64) void {
        self.begin_close_session(session_id) catch return;
        self.complete_close_session(session_id) catch return;
    }

    pub fn next_session_event(self: *Core) ?SessionEvent {
        if (self.session_events.items.len == 0) {
            return null;
        }

        return self.session_events.orderedRemove(0);
    }

    pub fn send_session_datagram(self: *Core, adapter: *transport_adapter.Adapter, session_id: u64, context_id: u64, payload: []const u8) errors.FluxError!usize {
        if (!self.negotiated.supports_webtransport_datagrams()) {
            return errors.FluxError.invalid_state;
        }

        const info = self.active_sessions.get(session_id) orelse return errors.FluxError.invalid_argument;
        if (info.state != .active) {
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

        const info = self.active_sessions.get(sid_vi.value) orelse return errors.FluxError.invalid_argument;
        if (info.state != .active) {
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

    fn push_session_event(self: *Core, event: SessionEvent) errors.FluxError!void {
        self.session_events.append(self.allocator, event) catch {
            return errors.FluxError.internal_failure;
        };
    }

    pub fn encode_connect_request(self: *Core, request: WebTransportConnectRequest) errors.FluxError![]u8 {
        if (!self.negotiated.supports_webtransport()) {
            return errors.FluxError.invalid_state;
        }

        return std.fmt.allocPrint(
            self.allocator,
            ":method=CONNECT\n:protocol=webtransport\n:scheme=https\n:authority={s}\n:path={s}\norigin={s}\n",
            .{ request.authority, request.path, request.origin },
        ) catch {
            return errors.FluxError.internal_failure;
        };
    }

    pub fn validate_connect_request(self: *Core, encoded: []const u8) errors.FluxError!WebTransportConnectRequest {
        if (!self.negotiated.supports_webtransport()) {
            return errors.FluxError.invalid_state;
        }

        var method: ?[]const u8 = null;
        var protocol: ?[]const u8 = null;
        var scheme: ?[]const u8 = null;
        var authority: ?[]const u8 = null;
        var path: ?[]const u8 = null;
        var origin: ?[]const u8 = null;

        var lines = std.mem.splitScalar(u8, encoded, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, ":method=")) method = line[8..];
            if (std.mem.startsWith(u8, line, ":protocol=")) protocol = line[10..];
            if (std.mem.startsWith(u8, line, ":scheme=")) scheme = line[8..];
            if (std.mem.startsWith(u8, line, ":authority=")) authority = line[11..];
            if (std.mem.startsWith(u8, line, ":path=")) path = line[6..];
            if (std.mem.startsWith(u8, line, "origin=")) origin = line[7..];
        }

        if (method == null or protocol == null or scheme == null or authority == null or path == null or origin == null) {
            return errors.FluxError.protocol_violation;
        }

        if (!std.mem.eql(u8, method.?, "CONNECT")) return errors.FluxError.protocol_violation;
        if (!std.mem.eql(u8, protocol.?, "webtransport")) return errors.FluxError.protocol_violation;
        if (!std.mem.eql(u8, scheme.?, "https")) return errors.FluxError.protocol_violation;
        if (authority.?.len == 0 or path.?.len == 0 or origin.?.len == 0) return errors.FluxError.protocol_violation;

        const authority_owned = self.allocator.dupe(u8, authority.?) catch return errors.FluxError.internal_failure;
        errdefer self.allocator.free(authority_owned);
        const path_owned = self.allocator.dupe(u8, path.?) catch return errors.FluxError.internal_failure;
        errdefer self.allocator.free(path_owned);
        const origin_owned = self.allocator.dupe(u8, origin.?) catch return errors.FluxError.internal_failure;

        return .{
            .authority = authority_owned,
            .path = path_owned,
            .origin = origin_owned,
        };
    }

    pub fn free_connect_request(self: *Core, request: WebTransportConnectRequest) void {
        self.allocator.free(request.authority);
        self.allocator.free(request.path);
        self.allocator.free(request.origin);
    }

    pub fn encode_connect_response(self: *Core, response: WebTransportConnectResponse) errors.FluxError![]u8 {
        if (!self.negotiated.supports_webtransport()) {
            return errors.FluxError.invalid_state;
        }

        return std.fmt.allocPrint(self.allocator, ":status={d}\nsec-webtransport-http3-draft=draft02\n", .{response.status}) catch {
            return errors.FluxError.internal_failure;
        };
    }

    pub fn validate_connect_response(self: *Core, encoded: []const u8) errors.FluxError!WebTransportConnectResponse {
        if (!self.negotiated.supports_webtransport()) {
            return errors.FluxError.invalid_state;
        }

        var status: ?u16 = null;
        var draft: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, encoded, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, ":status=")) {
                status = std.fmt.parseInt(u16, line[8..], 10) catch return errors.FluxError.protocol_violation;
            }
            if (std.mem.startsWith(u8, line, "sec-webtransport-http3-draft=")) {
                draft = line[29..];
            }
        }

        if (status == null or draft == null) {
            return errors.FluxError.protocol_violation;
        }

        if (!std.mem.eql(u8, draft.?, "draft02")) {
            return errors.FluxError.protocol_violation;
        }

        if (status.? != 200) {
            return errors.FluxError.request_rejected;
        }

        return .{ .status = status.? };
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

fn apply_h3_settings_to_features(settings: []const H3Setting, out: *NegotiatedFeatures) errors.FluxError!void {
    for (settings, 0..) |setting, i| {
        var j: usize = 0;
        while (j < i) : (j += 1) {
            if (settings[j].id == setting.id) {
                return errors.FluxError.settings_error;
            }
        }

        switch (setting.id) {
            @intFromEnum(h3_core.H3SettingId.enable_connect_protocol) => {
                if (setting.value > 1) return errors.FluxError.settings_error;
                out.connect_protocol_enabled = setting.value == 1;
            },
            @intFromEnum(h3_core.H3SettingId.h3_datagram) => {
                if (setting.value > 1) return errors.FluxError.settings_error;
                out.h3_datagram_enabled = setting.value == 1;
            },
            @intFromEnum(h3_core.H3SettingId.enable_webtransport) => {
                if (setting.value > 1) return errors.FluxError.settings_error;
                out.webtransport_enabled = setting.value == 1;
            },
            @intFromEnum(h3_core.H3SettingId.webtransport_max_sessions) => {
                if (setting.value == 0) return errors.FluxError.settings_error;
                out.webtransport_max_sessions = setting.value;
            },
            else => {},
        }
    }

    if (out.webtransport_enabled and out.webtransport_max_sessions == 0) {
        return errors.FluxError.settings_error;
    }
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
    var core = Core.init(std.testing.allocator);
    defer core.deinit();
    core.apply_negotiated_features(features);
    try std.testing.expectEqual(TransportPreference.capsule_only, core.preferred_transport());

    n.set_peer_connect_protocol(true);
    features = n.negotiate();
    try std.testing.expect(features.supports_webtransport());
    try std.testing.expect(features.supports_webtransport_datagrams());
}

test "session registry rejects duplicate ids and emits lifecycle events" {
    var core = Core.init(std.testing.allocator);
    defer core.deinit();
    core.apply_negotiated_features(.{
        .connect_protocol_enabled = true,
        .h3_datagram_enabled = true,
        .webtransport_enabled = true,
        .webtransport_max_sessions = 4,
    });

    try core.register_session_with_id(42, 13);
    try std.testing.expectError(errors.FluxError.protocol_violation, core.register_session_with_id(42, 15));

    const opened = core.next_session_event().?;
    try std.testing.expect(opened == .opened);
    try std.testing.expectEqual(@as(u64, 42), opened.opened.session_id);

    try core.begin_close_session(42);
    const closing = core.next_session_event().?;
    try std.testing.expect(closing == .closing);
    try std.testing.expectEqual(SessionState.closing, closing.closing.state);

    try core.complete_close_session(42);
    const closed = core.next_session_event().?;
    try std.testing.expect(closed == .closed);
    try std.testing.expectEqual(SessionState.closed, closed.closed.state);
}

test "session close race is idempotent" {
    var core = Core.init(std.testing.allocator);
    defer core.deinit();
    core.apply_negotiated_features(.{
        .connect_protocol_enabled = true,
        .h3_datagram_enabled = false,
        .webtransport_enabled = true,
        .webtransport_max_sessions = 2,
    });

    try core.register_session_with_id(7, 21);
    _ = core.next_session_event();

    core.close_session_id(7);
    core.close_session_id(7);

    const e1 = core.next_session_event().?;
    const e2 = core.next_session_event().?;
    try std.testing.expect(e1 == .closing);
    try std.testing.expect(e2 == .closed);
    try std.testing.expect(core.next_session_event() == null);
    try std.testing.expectEqual(@as(usize, 0), core.sessions_open);
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

test "settings parser maps wt related ids into negotiator" {
    var n = Negotiator.init();

    try n.apply_local_h3_settings(&.{
        .{ .id = @intFromEnum(h3_core.H3SettingId.enable_connect_protocol), .value = 1 },
        .{ .id = @intFromEnum(h3_core.H3SettingId.h3_datagram), .value = 1 },
        .{ .id = @intFromEnum(h3_core.H3SettingId.enable_webtransport), .value = 1 },
        .{ .id = @intFromEnum(h3_core.H3SettingId.webtransport_max_sessions), .value = 8 },
    });

    try n.apply_peer_h3_settings(&.{
        .{ .id = @intFromEnum(h3_core.H3SettingId.enable_connect_protocol), .value = 1 },
        .{ .id = @intFromEnum(h3_core.H3SettingId.enable_webtransport), .value = 1 },
        .{ .id = @intFromEnum(h3_core.H3SettingId.webtransport_max_sessions), .value = 3 },
    });

    const features = n.negotiate();
    try std.testing.expect(features.supports_webtransport());
    try std.testing.expect(!features.supports_webtransport_datagrams());
    try std.testing.expectEqual(@as(u64, 3), features.webtransport_max_sessions);
}

test "settings parser rejects duplicate and invalid boolean values" {
    var n = Negotiator.init();

    try std.testing.expectError(errors.FluxError.settings_error, n.apply_local_h3_settings(&.{
        .{ .id = @intFromEnum(h3_core.H3SettingId.enable_connect_protocol), .value = 1 },
        .{ .id = @intFromEnum(h3_core.H3SettingId.enable_connect_protocol), .value = 1 },
    }));

    try std.testing.expectError(errors.FluxError.settings_error, n.apply_peer_h3_settings(&.{
        .{ .id = @intFromEnum(h3_core.H3SettingId.enable_webtransport), .value = 2 },
        .{ .id = @intFromEnum(h3_core.H3SettingId.webtransport_max_sessions), .value = 4 },
    }));
}

test "settings parser requires nonzero max sessions for enabled wt" {
    var n = Negotiator.init();

    try std.testing.expectError(errors.FluxError.settings_error, n.apply_local_h3_settings(&.{
        .{ .id = @intFromEnum(h3_core.H3SettingId.enable_webtransport), .value = 1 },
        .{ .id = @intFromEnum(h3_core.H3SettingId.webtransport_max_sessions), .value = 0 },
    }));

    try std.testing.expectError(errors.FluxError.settings_error, n.apply_peer_h3_settings(&.{
        .{ .id = @intFromEnum(h3_core.H3SettingId.enable_webtransport), .value = 1 },
    }));
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

test "webtransport connect handshake round trip succeeds" {
    var core = Core.init(std.testing.allocator);
    defer core.deinit();
    core.apply_negotiated_features(.{
        .connect_protocol_enabled = true,
        .h3_datagram_enabled = true,
        .webtransport_enabled = true,
        .webtransport_max_sessions = 4,
    });

    const req_encoded = try core.encode_connect_request(.{
        .authority = "example.test",
        .path = "/wt",
        .origin = "https://example.test",
    });
    defer std.testing.allocator.free(req_encoded);

    const parsed_req = try core.validate_connect_request(req_encoded);
    defer core.free_connect_request(parsed_req);
    try std.testing.expectEqualStrings("example.test", parsed_req.authority);
    try std.testing.expectEqualStrings("/wt", parsed_req.path);

    const rsp_encoded = try core.encode_connect_response(.{ .status = 200 });
    defer std.testing.allocator.free(rsp_encoded);
    const parsed_rsp = try core.validate_connect_response(rsp_encoded);
    try std.testing.expectEqual(@as(u16, 200), parsed_rsp.status);
}

test "webtransport connect request rejects missing pseudo headers" {
    var core = Core.init(std.testing.allocator);
    defer core.deinit();
    core.apply_negotiated_features(.{
        .connect_protocol_enabled = true,
        .h3_datagram_enabled = false,
        .webtransport_enabled = true,
        .webtransport_max_sessions = 2,
    });

    const missing_protocol = ":method=CONNECT\n:scheme=https\n:authority=example.test\n:path=/wt\norigin=https://example.test\n";
    try std.testing.expectError(errors.FluxError.protocol_violation, core.validate_connect_request(missing_protocol));

    const invalid_method = ":method=GET\n:protocol=webtransport\n:scheme=https\n:authority=example.test\n:path=/wt\norigin=https://example.test\n";
    try std.testing.expectError(errors.FluxError.protocol_violation, core.validate_connect_request(invalid_method));
}

test "webtransport connect response handles rejection and bad draft" {
    var core = Core.init(std.testing.allocator);
    defer core.deinit();
    core.apply_negotiated_features(.{
        .connect_protocol_enabled = true,
        .h3_datagram_enabled = true,
        .webtransport_enabled = true,
        .webtransport_max_sessions = 2,
    });

    const rejected = ":status=403\nsec-webtransport-http3-draft=draft02\n";
    try std.testing.expectError(errors.FluxError.request_rejected, core.validate_connect_response(rejected));

    const bad_draft = ":status=200\nsec-webtransport-http3-draft=draft01\n";
    try std.testing.expectError(errors.FluxError.protocol_violation, core.validate_connect_response(bad_draft));
}

test "webtransport connect handshake requires negotiated settings" {
    var core = Core.init(std.testing.allocator);
    defer core.deinit();

    try std.testing.expectError(errors.FluxError.invalid_state, core.encode_connect_request(.{
        .authority = "example.test",
        .path = "/wt",
        .origin = "https://example.test",
    }));

    try std.testing.expectError(errors.FluxError.invalid_state, core.validate_connect_request(
        ":method=CONNECT\n:protocol=webtransport\n:scheme=https\n:authority=example.test\n:path=/wt\norigin=https://example.test\n",
    ));
}
