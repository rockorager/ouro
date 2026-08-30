//! Bounded routing for Ouro operations sharing Wayring's io_uring.

const std = @import("std");
const wayring_completion = @import("wayring").completion;

const none = std.math.maxInt(u32);
const max_slots = @as(usize, 1) << 24;

/// Ouro's low-byte tags. Wayring reserves the values recognized by
/// `wayring.completion.Token.decode`, currently 1 through 5.
pub const Kind = enum(u8) {
    timer = 0x80,
    backend_ready = 0x81,
    input_ready = 0x82,
    renderer_fence = 0x83,
    copy = 0x84,
    shutdown = 0x85,
    icc_worker = 0x86,
    security_accept = 0x87,
    security_close = 0x88,
    security_cancel = 0x89,
    hotplug_ready = 0x8a,
};

pub const DecodeError = error{
    WayringToken,
    UnknownKind,
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidConfig,
    Exhausted,
    StaleToken,
};

/// Identity placed directly in an io_uring SQE's `user_data` field.
pub const Token = struct {
    kind: Kind,
    slot: u24,
    generation: u32,

    pub fn encode(token: Token) u64 {
        return @intFromEnum(token.kind) |
            (@as(u64, token.slot) << 8) |
            (@as(u64, token.generation) << 32);
    }

    /// Decodes namespace and fields only. Use `Router.route` to establish that
    /// a token still names a live Ouro operation.
    pub fn decode(value: u64) DecodeError!Token {
        if (wayring_completion.Token.decode(value)) |_| {
            return error.WayringToken;
        } else |_| {}

        const kind = std.enums.fromInt(Kind, @as(u8, @truncate(value))) orelse
            return error.UnknownKind;
        return .{
            .kind = kind,
            .slot = @truncate(value >> 8),
            .generation = @truncate(value >> 32),
        };
    }
};

/// Fixed-capacity allocation of generation-safe Ouro completion identities.
/// The router must remain alive while its tokens may still complete.
pub const Router = struct {
    const Slot = struct {
        active: bool = false,
        generation: u32 = 1,
        next_free: u32 = none,
        kind: Kind = undefined,
    };

    slots: []Slot,
    free_head: u32,
    free_count: usize,
    active_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) Error!Router {
        if (capacity == 0 or capacity > max_slots) return error.InvalidConfig;
        const slots = try allocator.alloc(Slot, capacity);
        for (slots, 0..) |*slot, index| slot.* = .{
            .next_free = if (index + 1 < slots.len) @intCast(index + 1) else none,
        };
        return .{
            .slots = slots,
            .free_head = 0,
            .free_count = capacity,
        };
    }

    pub fn deinit(router: *Router, allocator: std.mem.Allocator) void {
        std.debug.assert(router.active_count == 0);
        allocator.free(router.slots);
        router.* = undefined;
    }

    pub fn available(router: Router) usize {
        return router.free_count;
    }

    pub fn acquire(router: *Router, kind: Kind) Error!Token {
        if (router.free_head == none) return error.Exhausted;
        const index = router.free_head;
        const slot = &router.slots[index];
        router.free_head = slot.next_free;
        slot.active = true;
        slot.kind = kind;
        router.free_count -= 1;
        router.active_count += 1;
        return .{
            .kind = kind,
            .slot = @intCast(index),
            .generation = slot.generation,
        };
    }

    /// Returns a live Ouro token, or null for Wayring, unknown, stale, forged,
    /// and already-retired `user_data` values.
    pub fn route(router: *const Router, user_data: u64) ?Token {
        const token = Token.decode(user_data) catch return null;
        if (token.slot >= router.slots.len) return null;
        const slot = &router.slots[token.slot];
        if (!slot.active or slot.generation != token.generation or
            slot.kind != token.kind)
            return null;
        return token;
    }

    /// Invalidates an operation after its terminal completion or cancellation.
    /// Later CQEs carrying this token can no longer route. A slot whose
    /// generation is exhausted is permanently removed rather than wrapping and
    /// allowing an old CQE to alias a new operation.
    pub fn retire(router: *Router, token: Token) Error!void {
        if (token.slot >= router.slots.len) return error.StaleToken;
        const slot = &router.slots[token.slot];
        if (!slot.active or slot.generation != token.generation or
            slot.kind != token.kind)
            return error.StaleToken;

        slot.active = false;
        router.active_count -= 1;
        if (slot.generation != std.math.maxInt(u32)) {
            slot.generation += 1;
            slot.next_free = router.free_head;
            router.free_head = token.slot;
            router.free_count += 1;
        } else {
            slot.next_free = none;
        }
    }
};

test "Ouro tokens encode decode and route by kind" {
    var router = try Router.init(std.testing.allocator, 2);
    defer router.deinit(std.testing.allocator);

    const timer = try router.acquire(.timer);
    const copy = try router.acquire(.copy);
    try std.testing.expectEqual(timer, try Token.decode(timer.encode()));
    try std.testing.expectEqual(copy, router.route(copy.encode()).?);
    try std.testing.expectEqual(Kind.timer, router.route(timer.encode()).?.kind);

    try router.retire(timer);
    try router.retire(copy);
}

test "slot reuse rejects stale completion" {
    var router = try Router.init(std.testing.allocator, 1);
    defer router.deinit(std.testing.allocator);

    const stale = try router.acquire(.backend_ready);
    try router.retire(stale);
    const current = try router.acquire(.input_ready);

    try std.testing.expect(router.route(stale.encode()) == null);
    try std.testing.expectEqual(current, router.route(current.encode()).?);
    try std.testing.expectEqual(stale.slot, current.slot);
    try std.testing.expect(stale.generation != current.generation);
    try router.retire(current);
}

test "Wayring namespace unknown kinds and forged kinds do not route" {
    var router = try Router.init(std.testing.allocator, 1);
    defer router.deinit(std.testing.allocator);
    const token = try router.acquire(.renderer_fence);

    const wayring = (wayring_completion.Token{
        .operation = .receive,
        .slot = token.slot,
        .generation = token.generation,
    }).encode();
    try std.testing.expectError(error.WayringToken, Token.decode(wayring));
    try std.testing.expect(router.route(wayring) == null);
    try std.testing.expectError(error.UnknownKind, Token.decode(0x7f));
    try std.testing.expect(router.route(0x7f) == null);

    var forged = token;
    forged.kind = .copy;
    try std.testing.expect(router.route(forged.encode()) == null);
    try std.testing.expectError(error.StaleToken, router.retire(forged));
    try router.retire(token);
}

test "retirement is terminal and capacity is bounded" {
    var router = try Router.init(std.testing.allocator, 1);
    defer router.deinit(std.testing.allocator);

    const token = try router.acquire(.timer);
    try std.testing.expectEqual(@as(usize, 0), router.available());
    try std.testing.expectError(error.Exhausted, router.acquire(.copy));
    try router.retire(token);
    try std.testing.expect(router.route(token.encode()) == null);
    try std.testing.expectError(error.StaleToken, router.retire(token));
    try std.testing.expectEqual(@as(usize, 1), router.available());
}

test "exhausted generations never reenter the free list" {
    var router = try Router.init(std.testing.allocator, 1);
    defer router.deinit(std.testing.allocator);
    router.slots[0].generation = std.math.maxInt(u32);

    const final = try router.acquire(.copy);
    try router.retire(final);
    try std.testing.expect(router.route(final.encode()) == null);
    try std.testing.expectEqual(@as(usize, 0), router.available());
    try std.testing.expectError(error.Exhausted, router.acquire(.copy));
}
