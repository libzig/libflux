const std = @import("std");
const errors = @import("errors.zig");
const transport_adapter = @import("transport_adapter.zig");
const h3_framing = @import("h3_framing.zig");
const h3_transaction = @import("h3_transaction.zig");

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    authority: []const u8,
    body: []const u8,
};

pub const Response = struct {
    status: u16,
    body: []u8,
};

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

pub const Client = struct {
    allocator: std.mem.Allocator,
    adapter: *transport_adapter.Adapter,
    transactions: h3_transaction.Manager,

    pub fn init(allocator: std.mem.Allocator, adapter: *transport_adapter.Adapter) Client {
        return .{
            .allocator = allocator,
            .adapter = adapter,
            .transactions = h3_transaction.Manager.init(allocator),
        };
    }

    pub fn deinit(self: *Client) void {
        self.transactions.deinit();
    }

    pub fn send_request(self: *Client, request: Request) errors.FluxError!u64 {
        const stream_id = try self.adapter.open_stream(true);
        try self.transactions.open(stream_id);

        const encoded_headers = try encode_request_headers(self.allocator, request);
        defer self.allocator.free(encoded_headers);

        const headers_frame = try h3_framing.encode_headers(self.allocator, encoded_headers);
        defer self.allocator.free(headers_frame);

        _ = try self.adapter.send_stream_data(stream_id, headers_frame);
        try self.transactions.send_request_headers(stream_id, headers_frame.len);

        const body_frame = try h3_framing.encode_data(self.allocator, request.body);
        defer self.allocator.free(body_frame);

        _ = try self.adapter.send_stream_data(stream_id, body_frame);
        try self.transactions.send_request_data(stream_id, body_frame.len, true);

        return stream_id;
    }

    pub fn recv_response(self: *Client, stream_id: u64) errors.FluxError!Response {
        var decoder = h3_framing.Decoder.init(self.allocator);
        defer decoder.deinit();

        var status: ?u16 = null;
        var body_seen = false;
        var body_accum: std.ArrayList(u8) = .{};
        defer body_accum.deinit(self.allocator);

        while (true) {
            var event = try take_next_adapter_event(self.adapter);
            defer self.adapter.release_event(&event);

            switch (event.kind) {
                .stream_data => {
                    if (event.stream_id.? != stream_id) {
                        return errors.FluxError.invalid_state;
                    }

                    try decoder.feed(event.payload.?);
                    while (decoder.next_frame()) |frame_value| {
                        var frame = frame_value;
                        defer decoder.release_frame(&frame);

                        switch (frame) {
                            .headers => |payload| {
                                status = try parse_status_from_response_headers(payload);
                                try self.transactions.recv_response_headers(stream_id, payload.len);
                            },
                            .data => |payload| {
                                body_seen = true;
                                body_accum.appendSlice(self.allocator, payload) catch {
                                    return errors.FluxError.internal_failure;
                                };
                            },
                            .unknown => {},
                        }
                    }

                    if (status != null and body_seen) {
                        try self.transactions.recv_response_data(stream_id, body_accum.items.len, true);
                        return .{
                            .status = status.?,
                            .body = body_accum.toOwnedSlice(self.allocator) catch {
                                return errors.FluxError.internal_failure;
                            },
                        };
                    }
                },
                else => {},
            }
        }
    }
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    adapter: *transport_adapter.Adapter,
    transactions: h3_transaction.Manager,

    pub fn init(allocator: std.mem.Allocator, adapter: *transport_adapter.Adapter) Server {
        return .{
            .allocator = allocator,
            .adapter = adapter,
            .transactions = h3_transaction.Manager.init(allocator),
        };
    }

    pub fn deinit(self: *Server) void {
        self.transactions.deinit();
    }

    pub fn recv_request(self: *Server) errors.FluxError!struct { stream_id: u64, request: Request } {
        var decoder = h3_framing.Decoder.init(self.allocator);
        defer decoder.deinit();

        var partial_request: ?Request = null;
        var partial_stream_id: ?u64 = null;
        var body_seen = false;
        var body_accum: std.ArrayList(u8) = .{};
        defer body_accum.deinit(self.allocator);

        while (true) {
            var event = try take_next_adapter_event(self.adapter);
            defer self.adapter.release_event(&event);

            if (event.kind != .stream_data) {
                continue;
            }

            const stream_id = event.stream_id.?;
            if (self.transactions.get(stream_id) == null) {
                try self.transactions.open(stream_id);
            }

            if (partial_stream_id) |current| {
                if (current != stream_id) {
                    return errors.FluxError.invalid_state;
                }
            } else {
                partial_stream_id = stream_id;
            }

            try decoder.feed(event.payload.?);

            while (decoder.next_frame()) |frame_value| {
                var frame = frame_value;
                defer decoder.release_frame(&frame);

                switch (frame) {
                    .headers => |payload| {
                        if (partial_request) |old| {
                            self.allocator.free(old.method);
                            self.allocator.free(old.path);
                            self.allocator.free(old.authority);
                        }
                        partial_request = try parse_request_headers(self.allocator, payload);
                        try self.transactions.send_request_headers(stream_id, payload.len);
                    },
                    .data => |payload| {
                        body_seen = true;
                        body_accum.appendSlice(self.allocator, payload) catch {
                            return errors.FluxError.internal_failure;
                        };
                    },
                    .unknown => {},
                }
            }

            if (partial_request) |req| {
                if (!body_seen) {
                    continue;
                }

                const body_owned = body_accum.toOwnedSlice(self.allocator) catch {
                    return errors.FluxError.internal_failure;
                };

                try self.transactions.send_request_data(stream_id, body_owned.len, true);

                return .{
                    .stream_id = stream_id,
                    .request = .{
                        .method = req.method,
                        .path = req.path,
                        .authority = req.authority,
                        .body = body_owned,
                    },
                };
            }
        }
    }

    pub fn send_response(self: *Server, stream_id: u64, status: u16, body: []const u8) errors.FluxError!void {
        if (self.transactions.get(stream_id) == null) {
            return errors.FluxError.invalid_argument;
        }

        const headers_payload = try encode_response_headers(self.allocator, status);
        defer self.allocator.free(headers_payload);

        const headers_frame = try h3_framing.encode_headers(self.allocator, headers_payload);
        defer self.allocator.free(headers_frame);

        _ = try self.adapter.send_stream_data(stream_id, headers_frame);
        try self.transactions.recv_response_headers(stream_id, headers_frame.len);

        const data_frame = try h3_framing.encode_data(self.allocator, body);
        defer self.allocator.free(data_frame);

        _ = try self.adapter.send_stream_data(stream_id, data_frame);
        try self.transactions.recv_response_data(stream_id, data_frame.len, true);
    }
};

fn take_next_adapter_event(adapter: *transport_adapter.Adapter) errors.FluxError!transport_adapter.Event {
    const event = adapter.next_event() orelse {
        return errors.FluxError.invalid_state;
    };

    return event;
}

fn encode_request_headers(allocator: std.mem.Allocator, request: Request) errors.FluxError![]u8 {
    return std.fmt.allocPrint(
        allocator,
        ":method={s}\n:path={s}\n:authority={s}\n",
        .{ request.method, request.path, request.authority },
    ) catch {
        return errors.FluxError.internal_failure;
    };
}

fn encode_response_headers(allocator: std.mem.Allocator, status: u16) errors.FluxError![]u8 {
    return std.fmt.allocPrint(allocator, ":status={d}\n", .{status}) catch {
        return errors.FluxError.internal_failure;
    };
}

fn parse_request_headers(allocator: std.mem.Allocator, encoded: []const u8) errors.FluxError!Request {
    var method: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var authority: ?[]const u8 = null;

    var iter = std.mem.splitScalar(u8, encoded, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, ":method=")) method = line[8..];
        if (std.mem.startsWith(u8, line, ":path=")) path = line[6..];
        if (std.mem.startsWith(u8, line, ":authority=")) authority = line[11..];
    }

    if (method == null or path == null or authority == null) {
        return errors.FluxError.protocol_violation;
    }

    const method_owned = allocator.dupe(u8, method.?) catch return errors.FluxError.internal_failure;
    errdefer allocator.free(method_owned);
    const path_owned = allocator.dupe(u8, path.?) catch return errors.FluxError.internal_failure;
    errdefer allocator.free(path_owned);
    const authority_owned = allocator.dupe(u8, authority.?) catch return errors.FluxError.internal_failure;

    return .{
        .method = method_owned,
        .path = path_owned,
        .authority = authority_owned,
        .body = &.{},
    };
}

fn parse_status_from_response_headers(encoded: []const u8) errors.FluxError!u16 {
    var iter = std.mem.splitScalar(u8, encoded, '\n');
    while (iter.next()) |line| {
        if (std.mem.startsWith(u8, line, ":status=")) {
            return std.fmt.parseInt(u16, line[8..], 10) catch {
                return errors.FluxError.protocol_violation;
            };
        }
    }

    return errors.FluxError.protocol_violation;
}

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

test "in-memory client server request response exchange" {
    var adapter = transport_adapter.Adapter.init(std.testing.allocator);
    defer adapter.deinit();

    var client = Client.init(std.testing.allocator, &adapter);
    defer client.deinit();

    var server = Server.init(std.testing.allocator, &adapter);
    defer server.deinit();

    const stream_id = try client.send_request(.{
        .method = "GET",
        .path = "/status",
        .authority = "example.test",
        .body = "ping",
    });

    const incoming = try server.recv_request();
    defer std.testing.allocator.free(incoming.request.method);
    defer std.testing.allocator.free(incoming.request.path);
    defer std.testing.allocator.free(incoming.request.authority);
    defer std.testing.allocator.free(incoming.request.body);

    try std.testing.expectEqual(stream_id, incoming.stream_id);
    try std.testing.expectEqualStrings("GET", incoming.request.method);
    try std.testing.expectEqualStrings("/status", incoming.request.path);
    try std.testing.expectEqualStrings("example.test", incoming.request.authority);
    try std.testing.expectEqualStrings("ping", incoming.request.body);

    try server.send_response(stream_id, 200, "pong");

    const response = try client.recv_response(stream_id);
    defer std.testing.allocator.free(response.body);

    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("pong", response.body);
}
