const std = @import("std");

pub const Engine = struct {
    dynamic_table_enabled: bool,
    max_table_capacity: usize,

    pub fn init() Engine {
        return .{
            .dynamic_table_enabled = false,
            .max_table_capacity = 0,
        };
    }

    pub fn enable_dynamic_table(self: *Engine, capacity: usize) void {
        self.dynamic_table_enabled = true;
        self.max_table_capacity = capacity;
    }
};

test "qpack engine starts in static-only mode" {
    const engine = Engine.init();
    try std.testing.expect(!engine.dynamic_table_enabled);
    try std.testing.expectEqual(@as(usize, 0), engine.max_table_capacity);
}
