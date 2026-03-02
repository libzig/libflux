const std = @import("std");
const errors = @import("errors.zig");

pub const Core = struct {
    ready: bool,
    alpn_validated: bool,

    pub fn init() Core {
        return .{
            .ready = false,
            .alpn_validated = false,
        };
    }

    pub fn set_alpn_validated(self: *Core, ok: bool) void {
        self.alpn_validated = ok;
        if (!ok) self.ready = false;
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
