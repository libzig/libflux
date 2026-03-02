const std = @import("std");
const errors = @import("errors.zig");

pub const Surface = struct {
    started: bool,

    pub fn init() Surface {
        return .{ .started = false };
    }

    pub fn start(self: *Surface, h3_ready: bool) errors.FluxError!void {
        if (self.started) {
            return errors.FluxError.invalid_state;
        }

        if (!h3_ready) {
            return errors.FluxError.invalid_state;
        }

        self.started = true;
    }
};

test "public api requires ready h3" {
    var surface = Surface.init();
    try std.testing.expectError(errors.FluxError.invalid_state, surface.start(false));

    try surface.start(true);
    try std.testing.expect(surface.started);
}

test "public api rejects late restart" {
    var surface = Surface.init();
    try surface.start(true);
    try std.testing.expectError(errors.FluxError.invalid_state, surface.start(true));
}
