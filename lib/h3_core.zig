const std = @import("std");
const errors = @import("errors.zig");

pub const Core = struct {
    ready: bool,
    alpn_validated: bool,
    negotiated_alpn: ?[]const u8,

    pub fn init() Core {
        return .{
            .ready = false,
            .alpn_validated = false,
            .negotiated_alpn = null,
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
