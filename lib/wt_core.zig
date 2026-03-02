const std = @import("std");
const errors = @import("errors.zig");

pub const TransportPreference = enum {
    datagram,
    capsule_only,
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
    sessions_open: usize,
    negotiated: NegotiatedFeatures,

    pub fn init() Core {
        return .{
            .sessions_open = 0,
            .negotiated = NegotiatedFeatures.init(),
        };
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
        if (!self.negotiated.supports_webtransport()) {
            return errors.FluxError.invalid_state;
        }

        if (self.sessions_open >= self.negotiated.webtransport_max_sessions) {
            return errors.FluxError.backpressure;
        }

        self.sessions_open += 1;
    }

    pub fn close_session(self: *Core) void {
        if (self.sessions_open == 0) return;
        self.sessions_open -= 1;
    }
};

test "wt core tracks session count under negotiated limits" {
    var core = Core.init();
    core.apply_negotiated_features(.{
        .connect_protocol_enabled = true,
        .h3_datagram_enabled = true,
        .webtransport_enabled = true,
        .webtransport_max_sessions = 2,
    });

    try core.open_session();
    try core.open_session();
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
    try std.testing.expectEqual(TransportPreference.capsule_only, (Core{ .sessions_open = 0, .negotiated = features }).preferred_transport());

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
    var core = Core.init();
    core.apply_negotiated_features(features);

    try std.testing.expect(core.negotiated.supports_webtransport());
    try std.testing.expect(!core.negotiated.supports_webtransport_datagrams());
    try std.testing.expectEqual(TransportPreference.capsule_only, core.preferred_transport());
}

test "opening session without negotiated webtransport fails" {
    var core = Core.init();
    try std.testing.expectError(errors.FluxError.invalid_state, core.open_session());
}
