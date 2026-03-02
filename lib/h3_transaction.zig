const std = @import("std");
const errors = @import("errors.zig");

pub const TransactionState = enum {
    open,
    half_closed_local,
    half_closed_remote,
    closed,
    cancelled,
    errored,
};

pub const Transaction = struct {
    stream_id: u64,
    state: TransactionState,
    request_headers_sent: bool,
    response_headers_received: bool,
    bytes_sent: usize,
    bytes_received: usize,
};

pub const Event = union(enum) {
    opened: u64,
    half_closed_local: u64,
    half_closed_remote: u64,
    closed: u64,
    cancelled: u64,
    errored: u64,
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    transactions: std.AutoHashMap(u64, Transaction),
    events: std.ArrayList(Event),

    pub fn init(allocator: std.mem.Allocator) Manager {
        return .{
            .allocator = allocator,
            .transactions = std.AutoHashMap(u64, Transaction).init(allocator),
            .events = .{},
        };
    }

    pub fn deinit(self: *Manager) void {
        self.transactions.deinit();
        self.events.deinit(self.allocator);
    }

    pub fn open(self: *Manager, stream_id: u64) errors.FluxError!void {
        if (self.transactions.contains(stream_id)) {
            return errors.FluxError.invalid_state;
        }

        self.transactions.put(stream_id, .{
            .stream_id = stream_id,
            .state = .open,
            .request_headers_sent = false,
            .response_headers_received = false,
            .bytes_sent = 0,
            .bytes_received = 0,
        }) catch {
            return errors.FluxError.internal_failure;
        };

        try self.push_event(.{ .opened = stream_id });
    }

    pub fn send_request_headers(self: *Manager, stream_id: u64, encoded_len: usize) errors.FluxError!void {
        const tx = try self.must_get_mut(stream_id);
        try ensure_active(tx.state);

        tx.request_headers_sent = true;
        tx.bytes_sent += encoded_len;
    }

    pub fn send_request_data(self: *Manager, stream_id: u64, encoded_len: usize, fin: bool) errors.FluxError!void {
        const tx = try self.must_get_mut(stream_id);
        try ensure_active(tx.state);

        if (!tx.request_headers_sent) {
            tx.state = .errored;
            try self.push_event(.{ .errored = stream_id });
            return errors.FluxError.frame_unexpected;
        }

        tx.bytes_sent += encoded_len;
        if (fin) {
            try self.close_local(stream_id);
        }
    }

    pub fn recv_response_headers(self: *Manager, stream_id: u64, encoded_len: usize) errors.FluxError!void {
        const tx = try self.must_get_mut(stream_id);
        try ensure_active(tx.state);

        tx.response_headers_received = true;
        tx.bytes_received += encoded_len;
    }

    pub fn recv_response_data(self: *Manager, stream_id: u64, encoded_len: usize, fin: bool) errors.FluxError!void {
        const tx = try self.must_get_mut(stream_id);
        try ensure_active(tx.state);

        if (!tx.response_headers_received) {
            tx.state = .errored;
            try self.push_event(.{ .errored = stream_id });
            return errors.FluxError.frame_unexpected;
        }

        tx.bytes_received += encoded_len;
        if (fin) {
            try self.close_remote(stream_id);
        }
    }

    pub fn close_local(self: *Manager, stream_id: u64) errors.FluxError!void {
        const tx = try self.must_get_mut(stream_id);
        switch (tx.state) {
            .open => {
                tx.state = .half_closed_local;
                try self.push_event(.{ .half_closed_local = stream_id });
            },
            .half_closed_remote => {
                tx.state = .closed;
                try self.push_event(.{ .closed = stream_id });
            },
            .half_closed_local, .closed => return,
            .cancelled, .errored => return errors.FluxError.invalid_state,
        }
    }

    pub fn close_remote(self: *Manager, stream_id: u64) errors.FluxError!void {
        const tx = try self.must_get_mut(stream_id);
        switch (tx.state) {
            .open => {
                tx.state = .half_closed_remote;
                try self.push_event(.{ .half_closed_remote = stream_id });
            },
            .half_closed_local => {
                tx.state = .closed;
                try self.push_event(.{ .closed = stream_id });
            },
            .half_closed_remote, .closed => return,
            .cancelled, .errored => return errors.FluxError.invalid_state,
        }
    }

    pub fn cancel_local(self: *Manager, stream_id: u64) errors.FluxError!void {
        const tx = try self.must_get_mut(stream_id);
        if (tx.state == .closed) {
            return errors.FluxError.invalid_state;
        }

        tx.state = .cancelled;
        try self.push_event(.{ .cancelled = stream_id });
    }

    pub fn cancel_remote(self: *Manager, stream_id: u64) errors.FluxError!void {
        try self.cancel_local(stream_id);
    }

    pub fn get(self: *Manager, stream_id: u64) ?Transaction {
        return self.transactions.get(stream_id);
    }

    pub fn next_event(self: *Manager) ?Event {
        if (self.events.items.len == 0) {
            return null;
        }

        return self.events.orderedRemove(0);
    }

    fn push_event(self: *Manager, event: Event) errors.FluxError!void {
        self.events.append(self.allocator, event) catch {
            return errors.FluxError.internal_failure;
        };
    }

    fn must_get_mut(self: *Manager, stream_id: u64) errors.FluxError!*Transaction {
        const tx = self.transactions.getPtr(stream_id) orelse {
            return errors.FluxError.invalid_argument;
        };

        return tx;
    }
};

fn ensure_active(state: TransactionState) errors.FluxError!void {
    return switch (state) {
        .open, .half_closed_local, .half_closed_remote => {},
        .closed, .cancelled, .errored => errors.FluxError.invalid_state,
    };
}

test "transaction closes deterministically after local then remote eos" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();

    try manager.open(0);
    try manager.send_request_headers(0, 11);
    try manager.send_request_data(0, 4, true);
    try manager.recv_response_headers(0, 10);
    try manager.recv_response_data(0, 5, true);

    const tx = manager.get(0).?;
    try std.testing.expectEqual(TransactionState.closed, tx.state);
}

test "transaction closes deterministically after remote then local eos" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();

    try manager.open(4);
    try manager.send_request_headers(4, 12);
    try manager.recv_response_headers(4, 7);
    try manager.recv_response_data(4, 3, true);

    var tx = manager.get(4).?;
    try std.testing.expectEqual(TransactionState.half_closed_remote, tx.state);

    try manager.send_request_data(4, 9, true);
    tx = manager.get(4).?;
    try std.testing.expectEqual(TransactionState.closed, tx.state);
}

test "transaction rejects response data before response headers" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();

    try manager.open(8);
    try manager.send_request_headers(8, 10);
    try std.testing.expectError(errors.FluxError.frame_unexpected, manager.recv_response_data(8, 1, false));

    const tx = manager.get(8).?;
    try std.testing.expectEqual(TransactionState.errored, tx.state);
}

test "transaction rejects request data before request headers" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();

    try manager.open(12);
    try std.testing.expectError(errors.FluxError.frame_unexpected, manager.send_request_data(12, 2, false));

    const tx = manager.get(12).?;
    try std.testing.expectEqual(TransactionState.errored, tx.state);
}

test "transaction cancellation propagates to terminal state" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();

    try manager.open(16);
    try manager.send_request_headers(16, 10);
    try manager.cancel_remote(16);

    const tx = manager.get(16).?;
    try std.testing.expectEqual(TransactionState.cancelled, tx.state);
    try std.testing.expectError(errors.FluxError.invalid_state, manager.recv_response_headers(16, 1));
}

test "transaction event ordering for open close cancel" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();

    try manager.open(20);
    try manager.send_request_headers(20, 4);
    try manager.close_local(20);
    try manager.cancel_local(20);

    try std.testing.expect(manager.next_event().? == .opened);
    try std.testing.expect(manager.next_event().? == .half_closed_local);
    try std.testing.expect(manager.next_event().? == .cancelled);
    try std.testing.expect(manager.next_event() == null);
}
