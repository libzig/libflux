const std = @import("std");

pub const Core = struct {
    sessions_open: usize,

    pub fn init() Core {
        return .{ .sessions_open = 0 };
    }

    pub fn open_session(self: *Core) void {
        self.sessions_open += 1;
    }

    pub fn close_session(self: *Core) void {
        if (self.sessions_open == 0) return;
        self.sessions_open -= 1;
    }
};

test "wt core tracks session count" {
    var core = Core.init();
    try std.testing.expectEqual(@as(usize, 0), core.sessions_open);

    core.open_session();
    try std.testing.expectEqual(@as(usize, 1), core.sessions_open);

    core.close_session();
    try std.testing.expectEqual(@as(usize, 0), core.sessions_open);
}
