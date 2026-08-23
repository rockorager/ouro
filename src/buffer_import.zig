//! Bounded ownership for compositor buffer import backing.

const std = @import("std");

const none = std.math.maxInt(u32);

pub const Error = std.mem.Allocator.Error || error{
    InvalidConfig,
    Exhausted,
    WrongRegistry,
    StaleLease,
    AttachmentMismatch,
};

pub const Token = struct {
    index: u32,
    generation: u32,
};

/// Type-erased ownership of one registry slot. Move this value between pending
/// attachment and content-update owners; do not copy it. The backing itself is
/// kept outside semantic surface state and may be SHM, dmabuf, or another
/// importer-specific type.
pub const Lease = struct {
    registry: *anyopaque,
    token: Token,
    release_fn: *const fn (*anyopaque, Token) void,

    pub fn deinit(lease: *Lease) void {
        lease.release_fn(lease.registry, lease.token);
        lease.* = undefined;
    }
};

/// One surface's pending attachment lease. A replacement releases displaced
/// pending ownership immediately; commit transfers ownership without failure.
pub const AttachmentState = struct {
    pending: ?Lease = null,
    changed: bool = false,

    pub fn deinit(state: *AttachmentState) void {
        if (state.pending) |*lease| lease.deinit();
        state.* = .{};
    }

    pub fn attach(state: *AttachmentState, lease: ?Lease) void {
        if (state.pending) |*displaced| displaced.deinit();
        state.pending = lease;
        state.changed = true;
    }

    pub fn validateCommit(
        state: AttachmentState,
        attachment_changed: bool,
        has_buffer: bool,
    ) Error!void {
        if (state.changed != attachment_changed or
            (state.changed and (state.pending != null) != has_buffer))
            return error.AttachmentMismatch;
    }

    pub fn publishCommit(state: *AttachmentState) ?Lease {
        if (!state.changed) return null;
        const lease = state.pending;
        state.pending = null;
        state.changed = false;
        return lease;
    }
};

/// Generation-safe fixed-capacity storage for importer-specific backing.
/// `dispose` relinquishes the actual backing when the final Ouro owner drops
/// the returned lease. An active registry must remain at a stable address.
pub fn Registry(comptime Backing: type) type {
    return struct {
        const Self = @This();
        const Dispose = *const fn (?*anyopaque, Backing) void;

        const Slot = struct {
            active: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            backing: Backing = undefined,
        };

        slots: []Slot,
        free_head: u32,
        active_count: usize = 0,
        dispose_context: ?*anyopaque,
        dispose: Dispose,

        pub fn init(
            allocator: std.mem.Allocator,
            capacity: usize,
            dispose_context: ?*anyopaque,
            dispose: Dispose,
        ) Error!Self {
            if (capacity == 0 or capacity >= none) return error.InvalidConfig;
            const slots = try allocator.alloc(Slot, capacity);
            for (slots, 0..) |*slot, index| slot.* = .{
                .next_free = if (index + 1 < slots.len) @intCast(index + 1) else none,
            };
            return .{
                .slots = slots,
                .free_head = 0,
                .dispose_context = dispose_context,
                .dispose = dispose,
            };
        }

        pub fn deinit(registry: *Self, allocator: std.mem.Allocator) void {
            std.debug.assert(registry.active_count == 0);
            allocator.free(registry.slots);
            registry.* = undefined;
        }

        pub fn available(registry: Self) usize {
            return registry.slots.len - registry.active_count;
        }

        pub fn acquire(registry: *Self, backing: Backing) Error!Lease {
            if (registry.free_head == none) return error.Exhausted;
            const index = registry.free_head;
            const slot = &registry.slots[index];
            registry.free_head = slot.next_free;
            slot.active = true;
            slot.backing = backing;
            registry.active_count += 1;
            return .{
                .registry = registry,
                .token = .{ .index = index, .generation = slot.generation },
                .release_fn = releaseErased,
            };
        }

        pub fn get(registry: *Self, lease: Lease) Error!*Backing {
            if (lease.registry != @as(*anyopaque, @ptrCast(registry)) or
                lease.release_fn != releaseErased)
                return error.WrongRegistry;
            return registry.resolve(lease.token);
        }

        fn resolve(registry: *Self, token: Token) Error!*Backing {
            if (token.index >= registry.slots.len) return error.StaleLease;
            const slot = &registry.slots[token.index];
            if (!slot.active or slot.generation != token.generation)
                return error.StaleLease;
            return &slot.backing;
        }

        fn releaseErased(context: *anyopaque, token: Token) void {
            const registry: *Self = @ptrCast(@alignCast(context));
            const slot = if (token.index < registry.slots.len)
                &registry.slots[token.index]
            else
                unreachable;
            if (!slot.active or slot.generation != token.generation) unreachable;
            const backing = slot.backing;
            slot.active = false;
            slot.generation +%= 1;
            slot.next_free = registry.free_head;
            registry.free_head = token.index;
            registry.active_count -= 1;
            registry.dispose(registry.dispose_context, backing);
        }
    };
}

test "attachment leases replace transfer and reject stale generations" {
    const TestRegistry = Registry(u32);
    var disposed: u32 = 0;
    const Dispose = struct {
        fn backing(context: ?*anyopaque, value: u32) void {
            const total: *u32 = @ptrCast(@alignCast(context.?));
            total.* += value;
        }
    };
    var registry = try TestRegistry.init(std.testing.allocator, 1, &disposed, Dispose.backing);
    defer registry.deinit(std.testing.allocator);
    var state: AttachmentState = .{};
    defer state.deinit();

    const first = try registry.acquire(2);
    const stale = first;
    state.attach(first);
    state.attach(null);
    try std.testing.expectEqual(@as(u32, 2), disposed);
    try std.testing.expectError(error.StaleLease, registry.get(stale));

    const second = try registry.acquire(3);
    try std.testing.expectError(error.StaleLease, registry.get(stale));
    state.attach(second);
    try state.validateCommit(true, true);
    var committed = state.publishCommit().?;
    try std.testing.expectEqual(@as(u32, 3), (try registry.get(committed)).*);
    committed.deinit();
    try std.testing.expectEqual(@as(u32, 5), disposed);
    try std.testing.expectEqual(@as(usize, 1), registry.available());
}

test "attachment validation preserves pending lease ownership" {
    const TestRegistry = Registry(u8);
    const Dispose = struct {
        fn backing(_: ?*anyopaque, _: u8) void {}
    };
    var registry = try TestRegistry.init(std.testing.allocator, 1, null, Dispose.backing);
    defer registry.deinit(std.testing.allocator);
    var state: AttachmentState = .{};
    defer state.deinit();
    state.attach(try registry.acquire(1));

    try std.testing.expectError(error.AttachmentMismatch, state.validateCommit(false, true));
    try std.testing.expectEqual(@as(usize, 0), registry.available());
    state.deinit();
    try std.testing.expectEqual(@as(usize, 1), registry.available());
}
