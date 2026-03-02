const std = @import("std");
const errors = @import("errors.zig");

pub const HeaderField = struct {
    name: []const u8,
    value: []const u8,
};

const StaticEntry = struct {
    index: u16,
    name: []const u8,
    value: []const u8,
};

// Minimal static table subset required for early HTTP/3 request/response flows.
const STATIC_TABLE = [_]StaticEntry{
    .{ .index = 17, .name = ":method", .value = "GET" },
    .{ .index = 20, .name = ":method", .value = "POST" },
    .{ .index = 22, .name = ":scheme", .value = "https" },
    .{ .index = 23, .name = ":status", .value = "200" },
    .{ .index = 24, .name = ":status", .value = "204" },
    .{ .index = 25, .name = ":status", .value = "206" },
    .{ .index = 27, .name = ":status", .value = "304" },
    .{ .index = 28, .name = ":status", .value = "400" },
    .{ .index = 29, .name = ":status", .value = "404" },
    .{ .index = 30, .name = ":status", .value = "503" },
    .{ .index = 31, .name = "accept", .value = "*/*" },
    .{ .index = 33, .name = "accept-encoding", .value = "gzip, deflate, br" },
    .{ .index = 46, .name = "content-type", .value = "application/json" },
    .{ .index = 59, .name = "cache-control", .value = "no-cache" },
};

pub const ControlSync = struct {
    const StreamKind = enum { encoder, decoder };

    allocator: std.mem.Allocator,
    encoder_out: std.ArrayList(u8),
    decoder_out: std.ArrayList(u8),
    encoder_in: std.ArrayList(u8),
    decoder_in: std.ArrayList(u8),
    known_insert_count: u64,
    acked_insert_count: u64,
    blocked_streams: std.AutoHashMap(u64, u64),

    pub fn init(allocator: std.mem.Allocator) ControlSync {
        return .{
            .allocator = allocator,
            .encoder_out = .{},
            .decoder_out = .{},
            .encoder_in = .{},
            .decoder_in = .{},
            .known_insert_count = 0,
            .acked_insert_count = 0,
            .blocked_streams = std.AutoHashMap(u64, u64).init(allocator),
        };
    }

    pub fn deinit(self: *ControlSync) void {
        self.encoder_out.deinit(self.allocator);
        self.decoder_out.deinit(self.allocator);
        self.encoder_in.deinit(self.allocator);
        self.decoder_in.deinit(self.allocator);
        self.blocked_streams.deinit();
    }

    pub fn queue_insert_instruction(self: *ControlSync, name: []const u8, value: []const u8) errors.FluxError!u64 {
        self.known_insert_count += 1;
        const line = std.fmt.allocPrint(self.allocator, "ins:{d}:{s}={s}\n", .{ self.known_insert_count, name, value }) catch {
            return errors.FluxError.internal_failure;
        };
        defer self.allocator.free(line);

        self.encoder_out.appendSlice(self.allocator, line) catch {
            return errors.FluxError.internal_failure;
        };

        return self.known_insert_count;
    }

    pub fn queue_section_ack(self: *ControlSync, stream_id: u64, insert_count: u64) errors.FluxError!void {
        const line = std.fmt.allocPrint(self.allocator, "ack:{d}:{d}\n", .{ stream_id, insert_count }) catch {
            return errors.FluxError.internal_failure;
        };
        defer self.allocator.free(line);

        self.decoder_out.appendSlice(self.allocator, line) catch {
            return errors.FluxError.internal_failure;
        };
    }

    pub fn queue_stream_cancel(self: *ControlSync, stream_id: u64) errors.FluxError!void {
        const line = std.fmt.allocPrint(self.allocator, "cancel:{d}\n", .{stream_id}) catch {
            return errors.FluxError.internal_failure;
        };
        defer self.allocator.free(line);

        self.decoder_out.appendSlice(self.allocator, line) catch {
            return errors.FluxError.internal_failure;
        };
    }

    pub fn queue_insert_count_increment(self: *ControlSync, delta: u64) errors.FluxError!void {
        const line = std.fmt.allocPrint(self.allocator, "inc:{d}\n", .{delta}) catch {
            return errors.FluxError.internal_failure;
        };
        defer self.allocator.free(line);

        self.decoder_out.appendSlice(self.allocator, line) catch {
            return errors.FluxError.internal_failure;
        };
    }

    pub fn drain_encoder_chunk(self: *ControlSync, max_bytes: usize) errors.FluxError![]u8 {
        return drain_chunk(self.allocator, &self.encoder_out, max_bytes);
    }

    pub fn drain_decoder_chunk(self: *ControlSync, max_bytes: usize) errors.FluxError![]u8 {
        return drain_chunk(self.allocator, &self.decoder_out, max_bytes);
    }

    pub fn recv_encoder_bytes(self: *ControlSync, bytes: []const u8) errors.FluxError!void {
        self.encoder_in.appendSlice(self.allocator, bytes) catch {
            return errors.FluxError.internal_failure;
        };
        try process_line_buffer(self, .encoder);
    }

    pub fn recv_decoder_bytes(self: *ControlSync, bytes: []const u8) errors.FluxError!void {
        self.decoder_in.appendSlice(self.allocator, bytes) catch {
            return errors.FluxError.internal_failure;
        };
        try process_line_buffer(self, .decoder);
    }

    pub fn mark_stream_blocked(self: *ControlSync, stream_id: u64, required_insert_count: u64) errors.FluxError!void {
        if (required_insert_count <= self.acked_insert_count) {
            _ = self.blocked_streams.remove(stream_id);
            return;
        }

        self.blocked_streams.put(stream_id, required_insert_count) catch {
            return errors.FluxError.internal_failure;
        };
    }

    pub fn is_stream_blocked(self: *ControlSync, stream_id: u64) bool {
        return self.blocked_streams.contains(stream_id);
    }

    fn process_line_buffer(self: *ControlSync, which: StreamKind) errors.FluxError!void {
        const buf = switch (which) {
            .encoder => &self.encoder_in,
            .decoder => &self.decoder_in,
        };

        while (std.mem.indexOfScalar(u8, buf.items, '\n')) |nl| {
            const line = buf.items[0..nl];
            try self.process_control_line(which, line);

            const remaining = buf.items.len - (nl + 1);
            std.mem.copyForwards(u8, buf.items[0..remaining], buf.items[nl + 1 ..]);
            buf.shrinkRetainingCapacity(remaining);
        }
    }

    fn process_control_line(self: *ControlSync, which: StreamKind, line: []const u8) errors.FluxError!void {
        if (line.len == 0) {
            return;
        }

        if (which == .encoder) {
            if (!std.mem.startsWith(u8, line, "ins:")) {
                return errors.FluxError.protocol_violation;
            }

            const rest = line[4..];
            const sep = std.mem.indexOfScalar(u8, rest, ':') orelse return errors.FluxError.protocol_violation;
            const insert_count = std.fmt.parseInt(u64, rest[0..sep], 10) catch return errors.FluxError.protocol_violation;
            if (insert_count > self.known_insert_count) {
                self.known_insert_count = insert_count;
            }
            return;
        }

        if (std.mem.startsWith(u8, line, "ack:")) {
            const rest = line[4..];
            const sep = std.mem.indexOfScalar(u8, rest, ':') orelse return errors.FluxError.protocol_violation;
            _ = std.fmt.parseInt(u64, rest[0..sep], 10) catch return errors.FluxError.protocol_violation;
            const insert_count = std.fmt.parseInt(u64, rest[sep + 1 ..], 10) catch return errors.FluxError.protocol_violation;
            try self.update_acked_insert_count(insert_count);
            return;
        }

        if (std.mem.startsWith(u8, line, "inc:")) {
            const delta = std.fmt.parseInt(u64, line[4..], 10) catch return errors.FluxError.protocol_violation;
            try self.update_acked_insert_count(self.acked_insert_count + delta);
            return;
        }

        if (std.mem.startsWith(u8, line, "cancel:")) {
            _ = std.fmt.parseInt(u64, line[7..], 10) catch return errors.FluxError.protocol_violation;
            return;
        }

        return errors.FluxError.protocol_violation;
    }

    fn update_acked_insert_count(self: *ControlSync, count: u64) errors.FluxError!void {
        if (count > self.known_insert_count) {
            return errors.FluxError.protocol_violation;
        }

        if (count > self.acked_insert_count) {
            self.acked_insert_count = count;
        }

        var to_remove: std.ArrayList(u64) = .{};
        defer to_remove.deinit(self.allocator);

        var it = self.blocked_streams.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* <= self.acked_insert_count) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch {
                    return errors.FluxError.internal_failure;
                };
            }
        }

        for (to_remove.items) |stream_id| {
            _ = self.blocked_streams.remove(stream_id);
        }
    }
};

fn drain_chunk(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), max_bytes: usize) errors.FluxError![]u8 {
    if (max_bytes == 0) {
        return errors.FluxError.invalid_argument;
    }

    const n = @min(max_bytes, buffer.items.len);
    const out = allocator.alloc(u8, n) catch {
        return errors.FluxError.internal_failure;
    };
    @memcpy(out, buffer.items[0..n]);

    const remaining = buffer.items.len - n;
    std.mem.copyForwards(u8, buffer.items[0..remaining], buffer.items[n..]);
    buffer.shrinkRetainingCapacity(remaining);
    return out;
}

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

    pub fn encode_static_only(self: *const Engine, allocator: std.mem.Allocator, headers: []const HeaderField) errors.FluxError![]u8 {
        _ = self;

        var out: std.ArrayList(u8) = .{};
        defer out.deinit(allocator);

        for (headers) |header| {
            if (find_static_index(header.name, header.value)) |idx| {
                try write_indexed_line(allocator, &out, idx);
            } else {
                try write_literal_line(allocator, &out, header.name, header.value);
            }
        }

        return out.toOwnedSlice(allocator) catch {
            return errors.FluxError.internal_failure;
        };
    }

    pub fn decode_static_only(self: *const Engine, allocator: std.mem.Allocator, encoded: []const u8) errors.FluxError![]HeaderField {
        _ = self;

        var fields: std.ArrayList(HeaderField) = .{};
        defer {
            for (fields.items) |field| {
                allocator.free(field.name);
                allocator.free(field.value);
            }
            fields.deinit(allocator);
        }

        var lines = std.mem.splitScalar(u8, encoded, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;

            if (std.mem.startsWith(u8, line, "s:")) {
                const index = std.fmt.parseInt(u16, line[2..], 10) catch {
                    return errors.FluxError.protocol_violation;
                };

                const entry = find_static_entry(index) orelse {
                    return errors.FluxError.protocol_violation;
                };

                const name = allocator.dupe(u8, entry.name) catch return errors.FluxError.internal_failure;
                errdefer allocator.free(name);
                const value = allocator.dupe(u8, entry.value) catch return errors.FluxError.internal_failure;
                errdefer allocator.free(value);

                fields.append(allocator, .{ .name = name, .value = value }) catch {
                    return errors.FluxError.internal_failure;
                };
                continue;
            }

            if (std.mem.startsWith(u8, line, "l:")) {
                const body = line[2..];
                const separator = std.mem.indexOfScalar(u8, body, '=') orelse {
                    return errors.FluxError.protocol_violation;
                };

                const name_src = body[0..separator];
                const value_src = body[separator + 1 ..];
                if (name_src.len == 0) {
                    return errors.FluxError.protocol_violation;
                }

                const name = allocator.dupe(u8, name_src) catch return errors.FluxError.internal_failure;
                errdefer allocator.free(name);
                const value = allocator.dupe(u8, value_src) catch return errors.FluxError.internal_failure;
                errdefer allocator.free(value);

                fields.append(allocator, .{ .name = name, .value = value }) catch {
                    return errors.FluxError.internal_failure;
                };
                continue;
            }

            return errors.FluxError.protocol_violation;
        }

        return fields.toOwnedSlice(allocator) catch {
            return errors.FluxError.internal_failure;
        };
    }

    pub fn free_decoded_headers(self: *const Engine, allocator: std.mem.Allocator, headers: []HeaderField) void {
        _ = self;
        for (headers) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        allocator.free(headers);
    }
};

fn find_static_index(name: []const u8, value: []const u8) ?u16 {
    for (STATIC_TABLE) |entry| {
        if (std.mem.eql(u8, entry.name, name) and std.mem.eql(u8, entry.value, value)) {
            return entry.index;
        }
    }
    return null;
}

fn find_static_entry(index: u16) ?StaticEntry {
    for (STATIC_TABLE) |entry| {
        if (entry.index == index) {
            return entry;
        }
    }
    return null;
}

fn write_indexed_line(allocator: std.mem.Allocator, out: *std.ArrayList(u8), index: u16) errors.FluxError!void {
    const line = std.fmt.allocPrint(allocator, "s:{d}\n", .{index}) catch {
        return errors.FluxError.internal_failure;
    };
    defer allocator.free(line);

    out.appendSlice(allocator, line) catch {
        return errors.FluxError.internal_failure;
    };
}

fn write_literal_line(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, value: []const u8) errors.FluxError!void {
    const line = std.fmt.allocPrint(allocator, "l:{s}={s}\n", .{ name, value }) catch {
        return errors.FluxError.internal_failure;
    };
    defer allocator.free(line);

    out.appendSlice(allocator, line) catch {
        return errors.FluxError.internal_failure;
    };
}

test "qpack engine starts in static-only mode" {
    const engine = Engine.init();
    try std.testing.expect(!engine.dynamic_table_enabled);
    try std.testing.expectEqual(@as(usize, 0), engine.max_table_capacity);
}

test "static-only encode uses indexed entries when available" {
    const engine = Engine.init();
    const encoded = try engine.encode_static_only(std.testing.allocator, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":status", .value = "200" },
        .{ .name = "x-test", .value = "v" },
    });
    defer std.testing.allocator.free(encoded);

    try std.testing.expect(std.mem.indexOf(u8, encoded, "s:17\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "s:23\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "l:x-test=v\n") != null);
}

test "static-only decode round-trips header fields" {
    const engine = Engine.init();

    const encoded = try engine.encode_static_only(std.testing.allocator, &.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.test" },
        .{ .name = ":path", .value = "/health" },
        .{ .name = "accept", .value = "*/*" },
    });
    defer std.testing.allocator.free(encoded);

    const decoded = try engine.decode_static_only(std.testing.allocator, encoded);
    defer engine.free_decoded_headers(std.testing.allocator, decoded);

    try std.testing.expectEqual(@as(usize, 5), decoded.len);
    try std.testing.expectEqualStrings(":method", decoded[0].name);
    try std.testing.expectEqualStrings("POST", decoded[0].value);
    try std.testing.expectEqualStrings(":scheme", decoded[1].name);
    try std.testing.expectEqualStrings("https", decoded[1].value);
    try std.testing.expectEqualStrings(":authority", decoded[2].name);
    try std.testing.expectEqualStrings("example.test", decoded[2].value);
    try std.testing.expectEqualStrings(":path", decoded[3].name);
    try std.testing.expectEqualStrings("/health", decoded[3].value);
    try std.testing.expectEqualStrings("accept", decoded[4].name);
    try std.testing.expectEqualStrings("*/*", decoded[4].value);
}

test "static-only decode rejects malformed entries" {
    const engine = Engine.init();

    try std.testing.expectError(errors.FluxError.protocol_violation, engine.decode_static_only(std.testing.allocator, "s:not-a-number\n"));
    try std.testing.expectError(errors.FluxError.protocol_violation, engine.decode_static_only(std.testing.allocator, "s:999\n"));
    try std.testing.expectError(errors.FluxError.protocol_violation, engine.decode_static_only(std.testing.allocator, "l:=bad\n"));
    try std.testing.expectError(errors.FluxError.protocol_violation, engine.decode_static_only(std.testing.allocator, "x:bad\n"));
}

test "control sync supports partial encoder stream drains" {
    var sync = ControlSync.init(std.testing.allocator);
    defer sync.deinit();

    _ = try sync.queue_insert_instruction("content-type", "application/json");
    _ = try sync.queue_insert_instruction("x-one", "alpha");

    const p1 = try sync.drain_encoder_chunk(10);
    defer std.testing.allocator.free(p1);
    const p2 = try sync.drain_encoder_chunk(10);
    defer std.testing.allocator.free(p2);
    const p3 = try sync.drain_encoder_chunk(1024);
    defer std.testing.allocator.free(p3);

    try std.testing.expect(p1.len > 0);
    try std.testing.expect(p2.len > 0);
    try std.testing.expect(p3.len > 0);
    try std.testing.expectEqual(@as(usize, 0), sync.encoder_out.items.len);
}

test "control sync full decoder write and ack unblocks streams" {
    var sync = ControlSync.init(std.testing.allocator);
    defer sync.deinit();

    _ = try sync.queue_insert_instruction("x-a", "1");
    _ = try sync.queue_insert_instruction("x-b", "2");
    try sync.mark_stream_blocked(9, 2);
    try std.testing.expect(sync.is_stream_blocked(9));

    try sync.queue_section_ack(9, 2);
    const decoder_bytes = try sync.drain_decoder_chunk(1024);
    defer std.testing.allocator.free(decoder_bytes);

    try sync.recv_decoder_bytes(decoder_bytes);
    try std.testing.expectEqual(@as(u64, 2), sync.acked_insert_count);
    try std.testing.expect(!sync.is_stream_blocked(9));
}

test "control sync parses increment cancel and rejects malformed lines" {
    var sync = ControlSync.init(std.testing.allocator);
    defer sync.deinit();

    _ = try sync.queue_insert_instruction("x", "y");
    _ = try sync.queue_insert_instruction("x2", "y2");
    try sync.recv_decoder_bytes("inc:1\n");
    try std.testing.expectEqual(@as(u64, 1), sync.acked_insert_count);
    try sync.recv_decoder_bytes("cancel:123\n");

    try std.testing.expectError(errors.FluxError.protocol_violation, sync.recv_decoder_bytes("ack:7:notnum\n"));
    try std.testing.expectError(errors.FluxError.protocol_violation, sync.recv_decoder_bytes("badline\n"));
}
