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
