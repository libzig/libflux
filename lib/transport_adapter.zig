const std = @import("std");

pub const Adapter = struct {
    allocator: std.mem.Allocator,
    stream_opened: bool,
    datagram_enabled: bool,

    pub fn init(allocator: std.mem.Allocator) Adapter {
        return .{
            .allocator = allocator,
            .stream_opened = false,
            .datagram_enabled = false,
        };
    }

    pub fn open_stream(self: *Adapter) void {
        self.stream_opened = true;
    }

    pub fn close_stream(self: *Adapter) void {
        self.stream_opened = false;
    }

    pub fn set_datagram_enabled(self: *Adapter, enabled: bool) void {
        self.datagram_enabled = enabled;
    }
};

test "adapter open and close stream toggles state" {
    var adapter = Adapter.init(std.testing.allocator);
    try std.testing.expect(!adapter.stream_opened);

    adapter.open_stream();
    try std.testing.expect(adapter.stream_opened);

    adapter.close_stream();
    try std.testing.expect(!adapter.stream_opened);
}
