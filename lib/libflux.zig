const std = @import("std");
pub const transport_adapter = @import("transport_adapter.zig");
pub const transport_harness = @import("transport_harness.zig");
pub const h3_core = @import("h3_core.zig");
pub const h3_control_reader = @import("h3_control_reader.zig");
pub const h3_control_writer = @import("h3_control_writer.zig");
pub const h3_framing = @import("h3_framing.zig");
pub const h3_transaction = @import("h3_transaction.zig");
pub const qpack = @import("qpack.zig");
pub const wt_core = @import("wt_core.zig");
pub const wt_capsule = @import("wt_capsule.zig");
pub const lsquic_parity = @import("lsquic_parity.zig");
pub const negative_corpus = @import("negative_corpus.zig");
pub const interop_scenarios = @import("interop_scenarios.zig");
pub const public_api = @import("public_api.zig");
pub const errors = @import("errors.zig");

pub const LIBFLUX_VERSION = "0.0.1";

pub const Runtime = struct {
    adapter: transport_adapter.Adapter,
    h3: h3_core.Core,
    qpack_engine: qpack.Engine,
    wt: wt_core.Core,
    api: public_api.Surface,

    pub fn init(allocator: std.mem.Allocator) Runtime {
        return .{
            .adapter = transport_adapter.Adapter.init(allocator),
            .h3 = h3_core.Core.init(),
            .qpack_engine = qpack.Engine.init(),
            .wt = wt_core.Core.init(allocator),
            .api = public_api.Surface.init(),
        };
    }

    pub fn start_with_alpn(self: *Runtime, negotiated_alpn: []const u8) errors.FluxError!void {
        try self.h3.validate_alpn(negotiated_alpn);
        try self.h3.mark_ready();
        try self.api.start(self.h3.ready);
    }
};

pub fn version() []const u8 {
    return LIBFLUX_VERSION;
}

test "library version is defined" {
    try std.testing.expect(version().len != 0);
}

test "runtime scaffold initializes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const runtime = Runtime.init(arena.allocator());
    try std.testing.expect(runtime.h3.ready == false);
    try std.testing.expect(runtime.api.started == false);
}

test "runtime starts only with h3 alpn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var runtime = Runtime.init(arena.allocator());
    try std.testing.expectError(errors.FluxError.invalid_state, runtime.start_with_alpn("hq-29"));
    try std.testing.expect(!runtime.api.started);

    try runtime.start_with_alpn("h3");
    try std.testing.expect(runtime.h3.ready);
    try std.testing.expect(runtime.api.started);
}

test "runtime rejects late start" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var runtime = Runtime.init(arena.allocator());
    try runtime.start_with_alpn("h3");
    try std.testing.expectError(errors.FluxError.invalid_state, runtime.start_with_alpn("h3"));
}

test {
    std.testing.refAllDecls(@This());
}
