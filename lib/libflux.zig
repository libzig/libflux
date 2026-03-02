const std = @import("std");
pub const transport_adapter = @import("transport_adapter.zig");
pub const transport_harness = @import("transport_harness.zig");
pub const h3_core = @import("h3_core.zig");
pub const qpack = @import("qpack.zig");
pub const wt_core = @import("wt_core.zig");
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
            .wt = wt_core.Core.init(),
            .api = public_api.Surface.init(),
        };
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
