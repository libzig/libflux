const std = @import("std");
const transport_adapter = @import("transport_adapter.zig");

pub const Harness = struct {
    adapter: *transport_adapter.Adapter,

    pub fn init(adapter: *transport_adapter.Adapter) Harness {
        return .{ .adapter = adapter };
    }

    pub fn open_stream_and_inject_reply(
        self: *Harness,
        request_payload: []const u8,
        response_payload: []const u8,
    ) !u64 {
        const stream_id = try self.adapter.open_stream(true);
        _ = try self.adapter.send_stream_data(stream_id, request_payload);
        try self.adapter.inject_stream_data(stream_id, response_payload);
        return stream_id;
    }

    pub fn inject_datagram(self: *Harness, payload: []const u8) !void {
        try self.adapter.inject_datagram_received(payload);
    }
};

test "harness drives deterministic stream exchange" {
    var adapter = transport_adapter.Adapter.init(std.testing.allocator);
    defer adapter.deinit();

    var harness = Harness.init(&adapter);
    const stream_id = try harness.open_stream_and_inject_reply("req", "resp");
    try std.testing.expectEqual(@as(u64, 0), stream_id);

    {
        var event = adapter.next_event().?; // stream_opened
        defer adapter.release_event(&event);
        try std.testing.expectEqual(transport_adapter.EventKind.stream_opened, event.kind);
    }

    {
        var event = adapter.next_event().?; // req
        defer adapter.release_event(&event);
        try std.testing.expectEqual(transport_adapter.EventKind.stream_data, event.kind);
        try std.testing.expectEqualStrings("req", event.payload.?);
    }

    {
        var event = adapter.next_event().?; // resp
        defer adapter.release_event(&event);
        try std.testing.expectEqual(transport_adapter.EventKind.stream_data, event.kind);
        try std.testing.expectEqualStrings("resp", event.payload.?);
    }
}
