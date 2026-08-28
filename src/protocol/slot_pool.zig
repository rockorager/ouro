//! Growable pointer-stable ownership for protocol resource contexts.

const std = @import("std");

pub const none = std.math.maxInt(u32);

pub const Header = struct {
    active: bool = false,
    generation: u32 = 1,
    index: u32 = none,
    next_free: u32 = none,
};

/// `T` must have a `header: Header` field and defaults for every other field.
/// Entries stay at stable heap addresses until pool deinitialization so they
/// are safe to retain as Wayring object contexts while the pointer table grows.
pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        entries: std.ArrayListUnmanaged(*T) = .empty,
        free_head: u32 = none,

        pub fn init(allocator: std.mem.Allocator, initial_capacity: usize) !Self {
            if (initial_capacity == 0 or initial_capacity >= none)
                return error.InvalidConfig;
            var pool: Self = .{ .allocator = allocator };
            try pool.entries.ensureTotalCapacity(allocator, initial_capacity);
            return pool;
        }

        pub fn deinit(pool: *Self) void {
            for (pool.entries.items) |entry| pool.allocator.destroy(entry);
            pool.entries.deinit(pool.allocator);
            pool.* = undefined;
        }

        pub fn acquire(pool: *Self) !*T {
            if (pool.free_head != none) {
                const slot = pool.entries.items[pool.free_head];
                pool.free_head = slot.header.next_free;
                slot.* = .{ .header = .{
                    .active = true,
                    .generation = slot.header.generation,
                    .index = slot.header.index,
                } };
                return slot;
            }
            if (pool.entries.items.len >= none) return error.OutOfMemory;
            const slot = try pool.allocator.create(T);
            errdefer pool.allocator.destroy(slot);
            const index: u32 = @intCast(pool.entries.items.len);
            slot.* = .{ .header = .{ .active = true, .index = index } };
            try pool.entries.append(pool.allocator, slot);
            return slot;
        }

        pub fn release(pool: *Self, slot: *T) void {
            std.debug.assert(slot.header.active);
            const index = slot.header.index;
            std.debug.assert(index < pool.entries.items.len and pool.entries.items[index] == slot);
            slot.* = .{ .header = .{
                .generation = nextGeneration(slot.header.generation),
                .index = index,
                .next_free = pool.free_head,
            } };
            pool.free_head = index;
        }

        pub fn at(pool: *Self, index: u32) ?*T {
            if (index >= pool.entries.items.len) return null;
            const slot = pool.entries.items[index];
            return if (slot.header.active) slot else null;
        }

        pub fn fromContext(pool: *Self, context: ?*anyopaque) ?*T {
            const slot: *T = @ptrCast(@alignCast(context orelse return null));
            if (!slot.header.active or slot.header.index >= pool.entries.items.len or
                pool.entries.items[slot.header.index] != slot)
                return null;
            return slot;
        }
    };
}

fn nextGeneration(generation: u32) u32 {
    const next = generation +% 1;
    return if (next == 0) 1 else next;
}

test "slot pool grows without moving live contexts and reuses released slots" {
    const Entry = struct {
        header: Header = .{},
        value: u32 = 0,
    };
    var pool = try Pool(Entry).init(std.testing.allocator, 1);
    defer pool.deinit();

    const first = try pool.acquire();
    first.value = 7;
    const second = try pool.acquire();
    try std.testing.expect(first == pool.entries.items[0]);
    try std.testing.expectEqual(@as(u32, 7), first.value);
    try std.testing.expect(pool.fromContext(first) == first);

    const generation = second.header.generation;
    pool.release(second);
    try std.testing.expect(pool.fromContext(second) == null);
    const reused = try pool.acquire();
    try std.testing.expect(reused == second);
    try std.testing.expect(reused.header.generation != generation);
}
