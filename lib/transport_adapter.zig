const std = @import("std");
const libfast = @import("libfast");
const errors = @import("errors.zig");

pub const EventKind = enum {
    stream_opened,
    stream_closed,
    stream_data,
    datagram_sent,
    datagram_received,
};

pub const Event = struct {
    kind: EventKind,
    stream_id: ?u64,
    payload: ?[]u8,
};

pub const AdapterMode = enum {
    fake,
    live,
};

pub const Adapter = struct {
    allocator: std.mem.Allocator,
    mode: AdapterMode,
    live_connection: ?*libfast.QuicConnection,
    datagram_enabled: bool,
    next_stream_id: u64,
    streams: std.AutoHashMap(u64, void),
    events: std.ArrayList(Event),

    pub fn init(allocator: std.mem.Allocator) Adapter {
        return .{
            .allocator = allocator,
            .mode = .fake,
            .live_connection = null,
            .datagram_enabled = false,
            .next_stream_id = 0,
            .streams = std.AutoHashMap(u64, void).init(allocator),
            .events = .{},
        };
    }

    pub fn deinit(self: *Adapter) void {
        while (self.events.items.len > 0) {
            var event = self.events.orderedRemove(0);
            self.release_event(&event);
        }

        self.events.deinit(self.allocator);
        self.streams.deinit();
    }

    pub fn attach_live_connection(self: *Adapter, connection: *libfast.QuicConnection) void {
        self.mode = .live;
        self.live_connection = connection;
    }

    pub fn open_stream(self: *Adapter, bidirectional: bool) errors.FluxError!u64 {
        return switch (self.mode) {
            .fake => self.open_stream_fake(),
            .live => self.open_stream_live(bidirectional),
        };
    }

    pub fn close_stream(self: *Adapter, stream_id: u64) errors.FluxError!void {
        return switch (self.mode) {
            .fake => self.close_stream_fake(stream_id),
            .live => self.close_stream_live(stream_id),
        };
    }

    pub fn send_stream_data(self: *Adapter, stream_id: u64, data: []const u8) errors.FluxError!usize {
        if (!self.streams.contains(stream_id)) {
            return errors.FluxError.invalid_argument;
        }

        return switch (self.mode) {
            .fake => self.send_stream_data_fake(stream_id, data),
            .live => self.send_stream_data_live(stream_id, data),
        };
    }

    pub fn inject_stream_data(self: *Adapter, stream_id: u64, data: []const u8) errors.FluxError!void {
        if (!self.streams.contains(stream_id)) {
            return errors.FluxError.invalid_argument;
        }

        const owned = try self.clone_payload(data);
        try self.append_event(.{
            .kind = .stream_data,
            .stream_id = stream_id,
            .payload = owned,
        });
    }

    pub fn set_datagram_enabled(self: *Adapter, enabled: bool) void {
        self.datagram_enabled = enabled;
    }

    pub fn send_datagram(self: *Adapter, data: []const u8) errors.FluxError!usize {
        if (!self.datagram_enabled) {
            return errors.FluxError.invalid_state;
        }

        const owned = try self.clone_payload(data);
        try self.append_event(.{
            .kind = .datagram_sent,
            .stream_id = null,
            .payload = owned,
        });

        return data.len;
    }

    pub fn inject_datagram_received(self: *Adapter, data: []const u8) errors.FluxError!void {
        if (!self.datagram_enabled) {
            return errors.FluxError.invalid_state;
        }

        const owned = try self.clone_payload(data);
        try self.append_event(.{
            .kind = .datagram_received,
            .stream_id = null,
            .payload = owned,
        });
    }

    pub fn next_event(self: *Adapter) ?Event {
        if (self.events.items.len == 0) {
            return null;
        }

        return self.events.orderedRemove(0);
    }

    pub fn release_event(self: *Adapter, event: *Event) void {
        if (event.payload) |payload| {
            self.allocator.free(payload);
            event.payload = null;
        }
    }

    fn open_stream_fake(self: *Adapter) errors.FluxError!u64 {
        const stream_id = self.next_stream_id;
        self.next_stream_id += 1;

        try self.put_stream(stream_id);
        try self.append_event(.{
            .kind = .stream_opened,
            .stream_id = stream_id,
            .payload = null,
        });
        return stream_id;
    }

    fn open_stream_live(self: *Adapter, bidirectional: bool) errors.FluxError!u64 {
        const connection = self.live_connection orelse return errors.FluxError.invalid_state;
        const stream_id = connection.openStream(bidirectional) catch {
            return errors.FluxError.invalid_state;
        };

        try self.put_stream(stream_id);
        try self.append_event(.{
            .kind = .stream_opened,
            .stream_id = stream_id,
            .payload = null,
        });
        return stream_id;
    }

    fn close_stream_fake(self: *Adapter, stream_id: u64) errors.FluxError!void {
        if (self.streams.remove(stream_id) == false) {
            return errors.FluxError.invalid_argument;
        }

        try self.append_event(.{
            .kind = .stream_closed,
            .stream_id = stream_id,
            .payload = null,
        });
    }

    fn close_stream_live(self: *Adapter, stream_id: u64) errors.FluxError!void {
        const connection = self.live_connection orelse return errors.FluxError.invalid_state;
        connection.closeStream(stream_id, 0) catch {
            return errors.FluxError.invalid_state;
        };

        _ = self.streams.remove(stream_id);
        try self.append_event(.{
            .kind = .stream_closed,
            .stream_id = stream_id,
            .payload = null,
        });
    }

    fn send_stream_data_fake(self: *Adapter, stream_id: u64, data: []const u8) errors.FluxError!usize {
        const owned = try self.clone_payload(data);
        try self.append_event(.{
            .kind = .stream_data,
            .stream_id = stream_id,
            .payload = owned,
        });

        return data.len;
    }

    fn send_stream_data_live(self: *Adapter, stream_id: u64, data: []const u8) errors.FluxError!usize {
        const connection = self.live_connection orelse return errors.FluxError.invalid_state;
        const written = connection.streamWrite(stream_id, data, libfast.StreamFinish.no_finish) catch {
            return errors.FluxError.backpressure;
        };

        if (written > 0) {
            const owned = try self.clone_payload(data[0..written]);
            try self.append_event(.{
                .kind = .stream_data,
                .stream_id = stream_id,
                .payload = owned,
            });
        }

        return written;
    }

    fn clone_payload(self: *Adapter, data: []const u8) errors.FluxError![]u8 {
        const owned = self.allocator.alloc(u8, data.len) catch {
            return errors.FluxError.internal_failure;
        };

        @memcpy(owned, data);
        return owned;
    }

    fn append_event(self: *Adapter, event: Event) errors.FluxError!void {
        self.events.append(self.allocator, event) catch {
            return errors.FluxError.internal_failure;
        };
    }

    fn put_stream(self: *Adapter, stream_id: u64) errors.FluxError!void {
        self.streams.put(stream_id, {}) catch {
            return errors.FluxError.internal_failure;
        };
    }
};

test "fake adapter open close and stream data" {
    var adapter = Adapter.init(std.testing.allocator);
    defer adapter.deinit();

    const stream_id = try adapter.open_stream(true);
    try std.testing.expectEqual(@as(u64, 0), stream_id);

    const sent = try adapter.send_stream_data(stream_id, "ping");
    try std.testing.expectEqual(@as(usize, 4), sent);

    try adapter.close_stream(stream_id);

    {
        var event = adapter.next_event().?;
        defer adapter.release_event(&event);
        try std.testing.expectEqual(EventKind.stream_opened, event.kind);
    }

    {
        var event = adapter.next_event().?;
        defer adapter.release_event(&event);
        try std.testing.expectEqual(EventKind.stream_data, event.kind);
        try std.testing.expectEqualStrings("ping", event.payload.?);
    }

    {
        var event = adapter.next_event().?;
        defer adapter.release_event(&event);
        try std.testing.expectEqual(EventKind.stream_closed, event.kind);
    }
}

test "fake datagram path and ordering" {
    var adapter = Adapter.init(std.testing.allocator);
    defer adapter.deinit();

    adapter.set_datagram_enabled(true);
    _ = try adapter.send_datagram("dg-out");
    try adapter.inject_datagram_received("dg-in");

    {
        var event = adapter.next_event().?;
        defer adapter.release_event(&event);
        try std.testing.expectEqual(EventKind.datagram_sent, event.kind);
        try std.testing.expectEqualStrings("dg-out", event.payload.?);
    }

    {
        var event = adapter.next_event().?;
        defer adapter.release_event(&event);
        try std.testing.expectEqual(EventKind.datagram_received, event.kind);
        try std.testing.expectEqualStrings("dg-in", event.payload.?);
    }
}

test "live adapter maps connection-not-established to invalid_state" {
    const config = libfast.QuicConfig.sshClient("example.com", "secret");
    var conn = try libfast.QuicConnection.init(std.testing.allocator, config);
    defer conn.deinit();

    var adapter = Adapter.init(std.testing.allocator);
    defer adapter.deinit();
    adapter.attach_live_connection(&conn);

    try std.testing.expectError(errors.FluxError.invalid_state, adapter.open_stream(true));
}
