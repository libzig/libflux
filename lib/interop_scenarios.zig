const std = @import("std");
const errors = @import("errors.zig");
const public_api = @import("public_api.zig");
const transport_adapter = @import("transport_adapter.zig");
const wt_core = @import("wt_core.zig");

pub const ScenarioResult = struct {
    request_response_ok: bool,
    wt_session_ok: bool,
    wt_datagram_ok: bool,

    pub fn all_passed(self: ScenarioResult) bool {
        return self.request_response_ok and self.wt_session_ok and self.wt_datagram_ok;
    }
};

pub const ExternalInteropStatus = enum {
    available,
    missing,
};

pub fn run_in_memory_scenario(allocator: std.mem.Allocator) errors.FluxError!ScenarioResult {
    var adapter = transport_adapter.Adapter.init(allocator);
    defer adapter.deinit();
    adapter.set_datagram_enabled(true);

    var client = public_api.Client.init(allocator, &adapter);
    defer client.deinit();

    var server = public_api.Server.init(allocator, &adapter);
    defer server.deinit();

    const stream_id = try client.send_request(.{
        .method = "GET",
        .path = "/interop",
        .authority = "interop.local",
        .body = "ping",
    });

    const incoming = try server.recv_request();
    defer allocator.free(incoming.request.method);
    defer allocator.free(incoming.request.path);
    defer allocator.free(incoming.request.authority);
    defer allocator.free(incoming.request.body);

    if (incoming.stream_id != stream_id) {
        return errors.FluxError.invalid_state;
    }

    try server.send_response(stream_id, 200, "pong");
    const response = try client.recv_response(stream_id);
    defer allocator.free(response.body);

    const rr_ok = response.status == 200 and std.mem.eql(u8, response.body, "pong");

    var wt = wt_core.Core.init(allocator);
    defer wt.deinit();
    wt.apply_negotiated_features(.{
        .connect_protocol_enabled = true,
        .h3_datagram_enabled = true,
        .webtransport_enabled = true,
        .webtransport_max_sessions = 2,
    });

    const session_id = try wt.open_session_id();
    _ = wt.next_session_event();
    const wt_session_ok = session_id > 0;

    _ = try wt.send_session_datagram(&adapter, session_id, 5, "dgram");
    var sent = adapter.next_event() orelse return errors.FluxError.invalid_state;
    defer adapter.release_event(&sent);
    if (sent.kind != .datagram_sent) {
        return errors.FluxError.invalid_state;
    }

    try adapter.inject_datagram_received(sent.payload.?);
    const recv = try wt.recv_session_datagram(&adapter);
    defer wt.free_session_datagram(recv);
    const wt_dgram_ok = recv.session_id == session_id and recv.context_id == 5 and std.mem.eql(u8, recv.payload, "dgram");

    return .{
        .request_response_ok = rr_ok,
        .wt_session_ok = wt_session_ok,
        .wt_datagram_ok = wt_dgram_ok,
    };
}

pub fn external_lsquic_target_available() bool {
    std.fs.cwd().access("tools/lsquic_live_interop.sh", .{}) catch {
        return false;
    };
    return true;
}

pub fn external_lsquic_target_status() ExternalInteropStatus {
    if (external_lsquic_target_available()) {
        return .available;
    }
    return .missing;
}

test "interop in-memory scenario passes" {
    const result = try run_in_memory_scenario(std.testing.allocator);
    try std.testing.expect(result.all_passed());
}

test "interop external target is discoverable or explicitly skipped" {
    // This test intentionally does not require live network interop.
    // It validates that we have a scriptable external target path.
    try std.testing.expectEqual(ExternalInteropStatus.available, external_lsquic_target_status());
}

test "interop matrix asserts all dimensions" {
    const result = try run_in_memory_scenario(std.testing.allocator);
    try std.testing.expect(result.request_response_ok);
    try std.testing.expect(result.wt_session_ok);
    try std.testing.expect(result.wt_datagram_ok);
    try std.testing.expect(result.all_passed());
}
