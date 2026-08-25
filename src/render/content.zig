//! Bounded renderer-side ownership of committed surface pixels.
//!
//! Callers prepare a complete candidate transactionally, then publish it at
//! the same non-fallible edge as scene/presentation metadata. A uniquely-owned
//! current handle can be consumed in place: cancellation leaves it unchanged,
//! while publication patches it and advances its generation. Handles expose no
//! address or backend allocation detail, so backend-native content can replace
//! this CPU backing without changing surface lifetime semantics.

const std = @import("std");
const render = @import("types.zig");

pub const Handle = packed struct {
    index: u32,
    generation: u32,
};

pub const Prepared = struct {
    index: u32,
    generation: u32,
    replaces: bool = false,
};

pub const Config = struct {
    version_capacity: usize,
    byte_capacity: usize,
};

pub const Allocation = struct {
    bytes: []u8,
    upload: ?render.UploadBacking = null,
};

pub const Provider = struct {
    context: *anyopaque,
    allocate_fn: *const fn (*anyopaque, usize) anyerror!Allocation,
    release_fn: *const fn (*anyopaque, u64) void,
    pinned_fn: *const fn (*anyopaque, u64) bool,

    pub fn allocate(self: Provider, size: usize) !Allocation {
        return self.allocate_fn(self.context, size);
    }

    pub fn release(self: Provider, token: u64) void {
        self.release_fn(self.context, token);
    }

    pub fn pinned(self: Provider, token: u64) bool {
        return self.pinned_fn(self.context, token);
    }
};

const State = enum { free, prepared, published, replacing };

const Replacement = struct {
    identity: render.SampleIdentity,
    source: render.Source,
    damage: render.UploadDamage,
};

const Slot = struct {
    state: State = .free,
    generation: u32 = 0,
    identity: render.SampleIdentity = undefined,
    source: render.Source = undefined,
    current: bool = false,
    replacement: ?Replacement = null,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    slots: []Slot,
    byte_capacity: usize,
    used_bytes: usize = 0,
    provider: ?Provider = null,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Store {
        return initWithProvider(allocator, config, null);
    }

    pub fn initWithProvider(
        allocator: std.mem.Allocator,
        config: Config,
        provider: ?Provider,
    ) !Store {
        if (config.version_capacity == 0 or
            config.version_capacity > std.math.maxInt(u32) or
            config.byte_capacity == 0)
            return error.InvalidConfig;
        const slots = try allocator.alloc(Slot, config.version_capacity);
        @memset(slots, .{});
        return .{
            .allocator = allocator,
            .slots = slots,
            .byte_capacity = config.byte_capacity,
            .provider = provider,
        };
    }

    pub fn deinit(self: *Store) void {
        for (self.slots) |slot| if (slot.state != .free)
            self.releaseBytes(slot.source);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    /// Copies a borrowed SHM source into a new immutable renderer-owned
    /// version. Compatible commits inherit predecessor pixels and patch only
    /// canonical upload damage; the first or incompatible commit is full.
    pub fn prepare(
        self: *Store,
        identity: render.SampleIdentity,
        source: render.Source,
        damage: render.UploadDamage,
    ) !Prepared {
        if (identity.surface == 0 or identity.commit_sequence == 0)
            return error.InvalidIdentity;
        const packed_stride = std.math.mul(u32, source.size.width, 4) catch
            return error.InvalidSource;
        if (source.size.width == 0 or source.size.height == 0 or
            source.stride < packed_stride)
            return error.InvalidSource;
        const source_length = std.math.mul(usize, source.stride, source.size.height) catch
            return error.InvalidSource;
        const packed_length = std.math.mul(usize, packed_stride, source.size.height) catch
            return error.InvalidSource;
        if (source_length > source.bytes.len) return error.InvalidSource;

        const predecessor = self.currentSlot(identity.surface);
        if (predecessor) |slot| {
            if (identity.commit_sequence <= slot.identity.commit_sequence)
                return error.StaleCommit;
            const next = std.math.add(
                u64,
                slot.identity.commit_sequence,
                1,
            ) catch return error.NonAdjacentCommit;
            if (identity.commit_sequence != next) return error.NonAdjacentCommit;
        }
        const compatible = if (predecessor) |slot|
            std.meta.eql(slot.source.size, source.size) and slot.source.format == source.format
        else
            false;
        const index = self.freeSlot() orelse return error.VersionCapacityExceeded;
        if (packed_length > self.byte_capacity - self.used_bytes)
            return error.ByteCapacityExceeded;
        // Full candidates can be copied straight into device upload memory.
        // Partial histories remain CPU-owned so future adjacent commits can
        // patch them in place without racing a GPU read or cloning the frame.
        const allocation = try self.allocateBytes(
            packed_length,
            !compatible or coversSource(damage, source.size),
        );
        const bytes = allocation.bytes;
        errdefer self.releaseBytes(.{
            .size = source.size,
            .stride = packed_stride,
            .format = source.format,
            .bytes = bytes,
            .upload = allocation.upload,
        });

        if (compatible and !coversSource(damage, source.size)) {
            @memcpy(bytes, predecessor.?.source.bytes);
            copyDamage(bytes, packed_stride, source, damage);
        } else {
            copyFull(bytes, packed_stride, source);
        }

        var slot = &self.slots[index];
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        slot.state = .prepared;
        slot.identity = identity;
        slot.source = .{
            .size = source.size,
            .stride = packed_stride,
            .format = source.format,
            .bytes = bytes,
            .upload = allocation.upload,
        };
        slot.current = false;
        self.used_bytes += packed_length;
        return .{ .index = @intCast(index), .generation = slot.generation };
    }

    /// Prepares a normal immutable version, except when `previous` names the
    /// uniquely-owned compatible current version. That case reserves an
    /// allocation-free replacement whose borrowed source is consumed only by
    /// `publish`; `cancel` restores the previous published version unchanged.
    pub fn prepareReplacing(
        self: *Store,
        previous: ?Handle,
        identity: render.SampleIdentity,
        source: render.Source,
        damage: render.UploadDamage,
    ) !Prepared {
        const handle = previous orelse return self.prepare(identity, source, damage);
        if (handle.index >= self.slots.len) return error.StaleContent;
        const slot = &self.slots[handle.index];
        if (slot.state != .published or slot.generation != handle.generation or
            !slot.current)
            return error.StaleContent;
        if (slot.identity.surface != identity.surface)
            return self.prepare(identity, source, damage);
        if (identity.commit_sequence <= slot.identity.commit_sequence)
            return error.StaleCommit;
        const next = std.math.add(u64, slot.identity.commit_sequence, 1) catch
            return error.NonAdjacentCommit;
        if (identity.commit_sequence != next) return error.NonAdjacentCommit;

        const packed_stride = std.math.mul(u32, source.size.width, 4) catch
            return error.InvalidSource;
        if (source.size.width == 0 or source.size.height == 0 or
            source.stride < packed_stride)
            return error.InvalidSource;
        const source_length = std.math.mul(usize, source.stride, source.size.height) catch
            return error.InvalidSource;
        const packed_length = std.math.mul(usize, packed_stride, source.size.height) catch
            return error.InvalidSource;
        if (source_length > source.bytes.len) return error.InvalidSource;

        if (!std.meta.eql(slot.source.size, source.size) or
            slot.source.format != source.format or slot.source.bytes.len != packed_length)
            return self.prepare(identity, source, damage);
        if (self.provider) |provider| if (slot.source.upload) |upload|
            if (provider.pinned(upload.token)) return self.prepare(identity, source, damage);
        slot.state = .replacing;
        slot.replacement = .{
            .identity = identity,
            .source = source,
            .damage = damage,
        };
        return .{
            .index = handle.index,
            .generation = handle.generation,
            .replaces = true,
        };
    }

    pub fn cancel(self: *Store, prepared: Prepared) void {
        const slot = self.preparedSlot(prepared) orelse return;
        if (prepared.replaces) {
            slot.replacement = null;
            slot.state = .published;
        } else {
            self.free(slot);
        }
    }

    /// Publishes after all fallible scene and presentation admission. The
    /// replacement form consumes the previous handle and mutates its allocation
    /// only at this non-fallible edge.
    pub fn publish(self: *Store, prepared: Prepared) Handle {
        const slot = self.preparedSlot(prepared) orelse unreachable;
        if (prepared.replaces) {
            const replacement = slot.replacement orelse unreachable;
            const packed_stride = slot.source.stride;
            if (coversSource(replacement.damage, replacement.source.size)) {
                copyFull(@constCast(slot.source.bytes), packed_stride, replacement.source);
            } else {
                copyDamage(
                    @constCast(slot.source.bytes),
                    packed_stride,
                    replacement.source,
                    replacement.damage,
                );
            }
            slot.generation +%= 1;
            if (slot.generation == 0) slot.generation = 1;
            slot.identity = replacement.identity;
            slot.replacement = null;
            slot.state = .published;
            return .{ .index = prepared.index, .generation = slot.generation };
        }
        for (self.slots) |*earlier| {
            if (earlier.state == .published and earlier.current and
                earlier.identity.surface == slot.identity.surface)
                earlier.current = false;
        }
        slot.state = .published;
        slot.current = true;
        return .{ .index = prepared.index, .generation = prepared.generation };
    }

    pub fn resolve(self: *const Store, handle: Handle) !render.Source {
        if (handle.index >= self.slots.len) return error.StaleContent;
        const slot = &self.slots[handle.index];
        if ((slot.state != .published and slot.state != .replacing) or
            slot.generation != handle.generation)
            return error.StaleContent;
        return slot.source;
    }

    pub fn release(self: *Store, handle: Handle) void {
        if (handle.index >= self.slots.len) return;
        const slot = &self.slots[handle.index];
        if (slot.state != .published or slot.generation != handle.generation) return;
        self.free(slot);
    }

    /// Removes only the registry's current pointer. Retained handles remain
    /// valid until their individual owners and future GPU submissions retire.
    pub fn destroySurface(self: *Store, surface: u64) void {
        for (self.slots) |*slot| {
            if (slot.state == .published and slot.current and
                slot.identity.surface == surface)
                slot.current = false;
        }
    }

    pub fn allocatedBytes(self: *const Store) usize {
        return self.slots.len * @sizeOf(Slot) + self.used_bytes;
    }

    fn currentSlot(self: *const Store, surface: u64) ?*const Slot {
        for (self.slots) |*slot| if (slot.state == .published and
            slot.current and slot.identity.surface == surface)
            return slot;
        return null;
    }

    fn freeSlot(self: *const Store) ?usize {
        for (self.slots, 0..) |slot, index| if (slot.state == .free) return index;
        return null;
    }

    fn preparedSlot(self: *Store, prepared: Prepared) ?*Slot {
        if (prepared.index >= self.slots.len) return null;
        const slot = &self.slots[prepared.index];
        const expected_state: State = if (prepared.replaces) .replacing else .prepared;
        if (slot.state != expected_state or slot.generation != prepared.generation) return null;
        return slot;
    }

    fn free(self: *Store, slot: *Slot) void {
        self.used_bytes -= slot.source.bytes.len;
        self.releaseBytes(slot.source);
        const generation = slot.generation;
        slot.* = .{ .generation = generation };
    }

    fn allocateBytes(self: *Store, size: usize, native: bool) !Allocation {
        if (native) if (self.provider) |provider| return provider.allocate(size);
        const bytes = try self.allocator.alloc(u8, size);
        return .{ .bytes = bytes };
    }

    fn releaseBytes(self: *Store, source: render.Source) void {
        if (source.upload) |upload| if (self.provider) |provider| {
            provider.release(upload.token);
            return;
        };
        self.allocator.free(@constCast(source.bytes));
    }
};

fn copyFull(destination: []u8, packed_stride: u32, source: render.Source) void {
    for (0..source.size.height) |row| {
        const source_start = @as(usize, source.stride) * row;
        const destination_start = @as(usize, packed_stride) * row;
        @memcpy(
            destination[destination_start..][0..packed_stride],
            source.bytes[source_start..][0..packed_stride],
        );
    }
}

fn coversSource(damage: render.UploadDamage, size: render.Size) bool {
    for (damage.items()) |rect| if (rect.min_x <= 0 and rect.min_y <= 0 and
        rect.max_x >= size.width and rect.max_y >= size.height) return true;
    return false;
}

fn copyDamage(
    destination: []u8,
    packed_stride: u32,
    source: render.Source,
    damage: render.UploadDamage,
) void {
    for (damage.items()) |rect|
        copyRect(destination, packed_stride, source, rect);
}

fn copyRect(
    destination: []u8,
    packed_stride: u32,
    source: render.Source,
    damage: render.UploadRect,
) void {
    const min_x: u32 = @intCast(std.math.clamp(damage.min_x, 0, @as(i64, source.size.width)));
    const min_y: u32 = @intCast(std.math.clamp(damage.min_y, 0, @as(i64, source.size.height)));
    const max_x: u32 = @intCast(std.math.clamp(damage.max_x, 0, @as(i64, source.size.width)));
    const max_y: u32 = @intCast(std.math.clamp(damage.max_y, 0, @as(i64, source.size.height)));
    if (min_x >= max_x or min_y >= max_y) return;
    const byte_x = @as(usize, min_x) * 4;
    const byte_count = @as(usize, max_x - min_x) * 4;
    for (min_y..max_y) |row| {
        const source_start = @as(usize, source.stride) * row + byte_x;
        const destination_start = @as(usize, packed_stride) * row + byte_x;
        @memcpy(
            destination[destination_start..][0..byte_count],
            source.bytes[source_start..][0..byte_count],
        );
    }
}

fn testDamage(rects: []const render.UploadRect) render.UploadDamage {
    var damage: render.UploadDamage = .{};
    std.debug.assert(rects.len <= damage.rects.len);
    @memcpy(damage.rects[0..rects.len], rects);
    damage.count = @intCast(rects.len);
    return damage;
}

fn testSource(bytes: []const u8, width: u32, height: u32, stride: u32) render.Source {
    return .{
        .size = .{ .width = width, .height = height },
        .stride = stride,
        .format = .xrgb8888,
        .bytes = bytes,
    };
}

const TestProvider = struct {
    storage: [64]u8 = undefined,
    used: usize = 0,
    references: [4]u8 = @splat(0),

    fn provider(self: *TestProvider) Provider {
        return .{
            .context = self,
            .allocate_fn = allocate,
            .release_fn = release,
            .pinned_fn = pinned,
        };
    }

    fn allocate(context: *anyopaque, size: usize) !Allocation {
        const self: *TestProvider = @ptrCast(@alignCast(context));
        if (self.used + size > self.storage.len) return error.OutOfMemory;
        var index: usize = 0;
        while (index < self.references.len and self.references[index] != 0) : (index += 1) {}
        if (index == self.references.len) return error.OutOfMemory;
        const offset = self.used;
        self.used += size;
        self.references[index] = 1;
        return .{
            .bytes = self.storage[offset..][0..size],
            .upload = .{
                .owner = context,
                .token = index + 1,
                .offset = offset,
            },
        };
    }

    fn release(context: *anyopaque, token: u64) void {
        const self: *TestProvider = @ptrCast(@alignCast(context));
        const index: usize = @intCast(token - 1);
        std.debug.assert(self.references[index] > 0);
        self.references[index] -= 1;
    }

    fn pinned(context: *anyopaque, token: u64) bool {
        const self: *TestProvider = @ptrCast(@alignCast(context));
        const index: usize = @intCast(token - 1);
        return self.references[index] > 1;
    }

    fn retain(self: *TestProvider, token: u64) void {
        const index: usize = @intCast(token - 1);
        std.debug.assert(self.references[index] > 0);
        self.references[index] += 1;
    }
};

test "render-content: alternating buffers patch one logical surface history" {
    var store = try Store.init(std.testing.allocator, .{ .version_capacity = 3, .byte_capacity = 48 });
    defer store.deinit();
    const first = [_]u8{
        1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4,
    };
    const a = store.publish(try store.prepare(
        .{ .surface = 7, .commit_sequence = 1 },
        testSource(&first, 2, 2, 8),
        .{},
    ));
    const second = [_]u8{
        9, 9, 9, 9, 8, 8, 8, 8,
        7, 7, 7, 7, 6, 6, 6, 6,
    };
    const b = store.publish(try store.prepare(
        .{ .surface = 7, .commit_sequence = 2 },
        testSource(&second, 2, 2, 8),
        testDamage(&.{.{ .min_x = 1, .min_y = 0, .max_x = 2, .max_y = 1 }}),
    ));
    try std.testing.expectEqualSlices(u8, &.{
        1, 1, 1, 1, 8, 8, 8, 8,
        3, 3, 3, 3, 4, 4, 4, 4,
    }, (try store.resolve(b)).bytes);
    const third = [_]u8{
        5, 5, 5, 5, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
    };
    const c = store.publish(try store.prepare(
        .{ .surface = 7, .commit_sequence = 3 },
        testSource(&third, 2, 2, 8),
        testDamage(&.{.{ .min_x = 0, .min_y = 0, .max_x = 1, .max_y = 1 }}),
    ));
    try std.testing.expectEqualSlices(u8, &.{
        5, 5, 5, 5, 8, 8, 8, 8,
        3, 3, 3, 3, 4, 4, 4, 4,
    }, (try store.resolve(c)).bytes);
    try std.testing.expectEqualSlices(u8, &first, (try store.resolve(a)).bytes);
    store.release(a);
    store.release(b);
    store.release(c);
}

test "render-content: sparse replacement copies only each damaged rectangle" {
    var store = try Store.init(std.testing.allocator, .{ .version_capacity = 1, .byte_capacity = 16 });
    defer store.deinit();
    const first = [_]u8{
        1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4,
    };
    const old = store.publish(try store.prepare(
        .{ .surface = 1, .commit_sequence = 1 },
        testSource(&first, 4, 1, 16),
        .{},
    ));
    const second = [_]u8{
        9, 9, 9, 9, 8, 8, 8, 8, 7, 7, 7, 7, 6, 6, 6, 6,
    };
    const current = store.publish(try store.prepareReplacing(
        old,
        .{ .surface = 1, .commit_sequence = 2 },
        testSource(&second, 4, 1, 16),
        testDamage(&.{
            .{ .min_x = 0, .min_y = 0, .max_x = 1, .max_y = 1 },
            .{ .min_x = 3, .min_y = 0, .max_x = 4, .max_y = 1 },
        }),
    ));
    try std.testing.expectEqualSlices(u8, &.{
        9, 9, 9, 9, 2, 2, 2, 2, 3, 3, 3, 3, 6, 6, 6, 6,
    }, (try store.resolve(current)).bytes);
    store.release(current);
}

test "render-content: prepare failure and cancellation preserve published content" {
    var store = try Store.init(std.testing.allocator, .{ .version_capacity = 2, .byte_capacity = 8 });
    defer store.deinit();
    const first = [_]u8{ 1, 2, 3, 4 };
    const handle = store.publish(try store.prepare(
        .{ .surface = 1, .commit_sequence = 1 },
        testSource(&first, 1, 1, 4),
        .{},
    ));
    const second = [_]u8{ 5, 6, 7, 8 };
    try std.testing.expectError(error.NonAdjacentCommit, store.prepare(
        .{ .surface = 1, .commit_sequence = 3 },
        testSource(&second, 1, 1, 4),
        .{},
    ));
    const prepared = try store.prepare(
        .{ .surface = 1, .commit_sequence = 2 },
        testSource(&second, 1, 1, 4),
        testDamage(&.{.{ .min_x = 0, .min_y = 0, .max_x = 1, .max_y = 1 }}),
    );
    try std.testing.expectError(error.VersionCapacityExceeded, store.prepare(
        .{ .surface = 2, .commit_sequence = 1 },
        testSource(&second, 1, 1, 4),
        .{},
    ));
    store.cancel(prepared);
    try std.testing.expectEqualSlices(u8, &first, (try store.resolve(handle)).bytes);
    store.release(handle);
}

test "render-content: unique replacement is transactional and allocation-free" {
    var store = try Store.init(std.testing.allocator, .{ .version_capacity = 2, .byte_capacity = 32 });
    defer store.deinit();
    const first = [_]u8{
        1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4,
    };
    const old = store.publish(try store.prepare(
        .{ .surface = 1, .commit_sequence = 1 },
        testSource(&first, 2, 2, 8),
        .{},
    ));
    const allocated = store.allocatedBytes();
    const second = [_]u8{
        9, 9, 9, 9, 8, 8, 8, 8,
        7, 7, 7, 7, 6, 6, 6, 6,
    };
    const damage = testDamage(&.{.{
        .min_x = 1,
        .min_y = 0,
        .max_x = 2,
        .max_y = 1,
    }});
    const cancelled = try store.prepareReplacing(
        old,
        .{ .surface = 1, .commit_sequence = 2 },
        testSource(&second, 2, 2, 8),
        damage,
    );
    try std.testing.expect(cancelled.replaces);
    try std.testing.expectEqualSlices(u8, &first, (try store.resolve(old)).bytes);
    store.cancel(cancelled);
    try std.testing.expectEqualSlices(u8, &first, (try store.resolve(old)).bytes);

    const prepared = try store.prepareReplacing(
        old,
        .{ .surface = 1, .commit_sequence = 2 },
        testSource(&second, 2, 2, 8),
        damage,
    );
    const current = store.publish(prepared);
    try std.testing.expectEqual(allocated, store.allocatedBytes());
    try std.testing.expectError(error.StaleContent, store.resolve(old));
    try std.testing.expectEqualSlices(u8, &.{
        1, 1, 1, 1, 8, 8, 8, 8,
        3, 3, 3, 3, 4, 4, 4, 4,
    }, (try store.resolve(current)).bytes);
    store.release(current);
}

test "render-content: GPU-pinned provider backing uses transactional copy-on-write" {
    var backing: TestProvider = .{};
    var store = try Store.initWithProvider(
        std.testing.allocator,
        .{ .version_capacity = 2, .byte_capacity = 16 },
        backing.provider(),
    );
    defer store.deinit();
    const first = [_]u8{ 1, 2, 3, 4, 9, 10, 11, 12 };
    const old = store.publish(try store.prepare(
        .{ .surface = 1, .commit_sequence = 1 },
        testSource(&first, 2, 1, 8),
        .{},
    ));
    const old_source = try store.resolve(old);
    const old_token = old_source.upload.?.token;
    backing.retain(old_token);

    const second = [_]u8{ 5, 6, 7, 8, 13, 14, 15, 16 };
    const cancelled = try store.prepareReplacing(
        old,
        .{ .surface = 1, .commit_sequence = 2 },
        testSource(&second, 2, 1, 8),
        testDamage(&.{.{ .min_x = 0, .min_y = 0, .max_x = 1, .max_y = 1 }}),
    );
    try std.testing.expect(!cancelled.replaces);
    store.cancel(cancelled);
    try std.testing.expectEqualSlices(u8, &first, (try store.resolve(old)).bytes);
    try std.testing.expectEqual(@as(u8, 2), backing.references[0]);
    try std.testing.expectEqual(@as(u8, 0), backing.references[1]);

    const prepared = try store.prepareReplacing(
        old,
        .{ .surface = 1, .commit_sequence = 2 },
        testSource(&second, 2, 1, 8),
        testDamage(&.{.{ .min_x = 0, .min_y = 0, .max_x = 1, .max_y = 1 }}),
    );
    const current = store.publish(prepared);
    const current_source = try store.resolve(current);
    try std.testing.expect(current_source.upload == null);
    try std.testing.expectEqualSlices(u8, &.{ 5, 6, 7, 8, 9, 10, 11, 12 }, current_source.bytes);
    store.release(old);
    try std.testing.expectEqual(@as(u8, 1), backing.references[0]);
    store.release(current);
    try std.testing.expectEqual(@as(u8, 0), backing.references[1]);
    TestProvider.release(&backing, old_token);
    try std.testing.expectEqual(@as(u8, 0), backing.references[0]);
}

test "render-content: stale generation destruction does not invalidate handles" {
    var store = try Store.init(std.testing.allocator, .{ .version_capacity = 1, .byte_capacity = 4 });
    defer store.deinit();
    const bytes = [_]u8{ 1, 2, 3, 4 };
    const handle = store.publish(try store.prepare(
        .{ .surface = (@as(u64, 4) << 32) | 2, .commit_sequence = 1 },
        testSource(&bytes, 1, 1, 4),
        .{},
    ));
    store.destroySurface((@as(u64, 3) << 32) | 2);
    store.destroySurface((@as(u64, 4) << 32) | 2);
    try std.testing.expectEqualSlices(u8, &bytes, (try store.resolve(handle)).bytes);
    store.release(handle);
    try std.testing.expectError(error.StaleContent, store.resolve(handle));
}
