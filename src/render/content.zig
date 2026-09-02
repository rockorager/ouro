//! Byte-bounded renderer-side ownership of committed surface pixels.
//!
//! Callers prepare a complete candidate transactionally, then publish it at
//! the same non-fallible edge as scene/presentation metadata. A uniquely-owned
//! current handle can be consumed in place: cancellation leaves it unchanged,
//! while publication patches it and advances its generation. Handles expose no
//! address or backend allocation detail, so backend-native content can replace
//! this CPU backing without changing surface lifetime semantics.

const std = @import("std");
const render = @import("types.zig");
const libc = @cImport(@cInclude("string.h"));

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
    allocate_native_fn: ?*const fn (*anyopaque, render.Size, render.PixelFormat) anyerror!render.NativeBacking = null,
    prepare_native_fn: ?*const fn (*anyopaque, render.NativeBacking, render.SampleIdentity, render.ExternalSource) anyerror!void = null,
    cancel_native_fn: ?*const fn (*anyopaque, render.NativeBacking, render.SampleIdentity) void = null,
    release_native_fn: ?*const fn (*anyopaque, u64) void = null,
    pinned_native_fn: ?*const fn (*anyopaque, u64) bool = null,
    ready_native_fn: ?*const fn (*anyopaque, u64, render.SampleIdentity) bool = null,
    validate_retained_external_fn: ?*const fn (*anyopaque, render.ExternalSource, render.Size, render.PixelFormat) anyerror!void = null,

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
    retain_pixels: bool = false,
};

const Slot = struct {
    state: State = .free,
    generation: u32 = 0,
    identity: render.SampleIdentity = undefined,
    source: render.Source = undefined,
    current: bool = false,
    replacement: ?Replacement = null,
    accounted_bytes: usize = 0,
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

        const predecessor_index = self.currentSlotIndex(identity.surface);
        const predecessor = if (predecessor_index) |index| &self.slots[index] else null;
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
        if (packed_length > self.byte_capacity - self.used_bytes)
            return error.ByteCapacityExceeded;
        const index = try self.claimSlot();
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
            @memcpy(bytes, self.slots[predecessor_index.?].source.bytes);
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
        slot.accounted_bytes = packed_length;
        slot.current = false;
        self.used_bytes += packed_length;
        return .{ .index = @intCast(index), .generation = slot.generation };
    }

    /// Transactionally imports an external DMA-BUF into an immutable native
    /// destination. A compatible unpinned adjacent version can reuse that
    /// destination; no renderer operation occurs until the renderer observes
    /// the published source.
    pub fn prepareReplacingExternal(
        self: *Store,
        previous: ?Handle,
        identity: render.SampleIdentity,
        source: render.Source,
        damage: render.UploadDamage,
    ) !Prepared {
        try validateExternal(identity, source);
        const logical_bytes = std.math.mul(usize, source.stride, source.size.height) catch
            return error.InvalidSource;

        if (previous) |handle| reuse: {
            if (handle.index >= self.slots.len) return error.StaleContent;
            const slot = &self.slots[handle.index];
            if (slot.state != .published or slot.generation != handle.generation or !slot.current)
                return error.StaleContent;
            if (slot.identity.surface != identity.surface) break :reuse;
            if (identity.commit_sequence <= slot.identity.commit_sequence) return error.StaleCommit;
            const next = std.math.add(u64, slot.identity.commit_sequence, 1) catch
                return error.NonAdjacentCommit;
            if (identity.commit_sequence != next) return error.NonAdjacentCommit;
            if (slot.source.native == null or !std.meta.eql(slot.source.size, source.size) or
                slot.source.stride != source.stride or slot.source.format != source.format or
                slot.accounted_bytes != logical_bytes)
                break :reuse;
            const provider = self.provider orelse return error.NativeProviderUnavailable;
            const pinned_fn = provider.pinned_native_fn orelse return error.NativeProviderUnavailable;
            if (pinned_fn(provider.context, slot.source.native.?.token)) break :reuse;
            const prepare_fn = provider.prepare_native_fn orelse return error.NativeProviderUnavailable;
            try prepare_fn(provider.context, slot.source.native.?, identity, source.external.?);
            slot.state = .replacing;
            slot.replacement = .{ .identity = identity, .source = source, .damage = damage };
            return .{ .index = handle.index, .generation = handle.generation, .replaces = true };
        }

        const predecessor = self.currentSlot(identity.surface);
        if (predecessor) |slot| {
            if (identity.commit_sequence <= slot.identity.commit_sequence) return error.StaleCommit;
            const next = std.math.add(u64, slot.identity.commit_sequence, 1) catch
                return error.NonAdjacentCommit;
            if (identity.commit_sequence != next) return error.NonAdjacentCommit;
        }
        if (logical_bytes > self.byte_capacity - self.used_bytes) return error.ByteCapacityExceeded;
        const index = try self.claimSlot();
        const provider = self.provider orelse return error.NativeProviderUnavailable;
        const allocate_fn = provider.allocate_native_fn orelse return error.NativeProviderUnavailable;
        const prepare_fn = provider.prepare_native_fn orelse return error.NativeProviderUnavailable;
        _ = provider.release_native_fn orelse return error.NativeProviderUnavailable;
        const native = try allocate_fn(provider.context, source.size, source.format);
        errdefer if (provider.release_native_fn) |release_fn| release_fn(provider.context, native.token);
        try prepare_fn(provider.context, native, identity, source.external.?);
        var slot = &self.slots[index];
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        slot.state = .prepared;
        slot.identity = identity;
        slot.source = source;
        slot.source.native = native;
        slot.accounted_bytes = logical_bytes;
        slot.current = false;
        self.used_bytes += logical_bytes;
        return .{ .index = @intCast(index), .generation = slot.generation };
    }

    /// Retains external DMA-BUF metadata as the authoritative content instead
    /// of allocating a compositor-owned snapshot. The caller must retain the
    /// corresponding protocol buffer lease until this version is replaced or
    /// detached and all submitted renderer use has completed.
    pub fn prepareReplacingRetainedExternal(
        self: *Store,
        previous: ?Handle,
        identity: render.SampleIdentity,
        source: render.Source,
    ) !Prepared {
        try validateExternal(identity, source);
        const provider = self.provider orelse return error.NativeProviderUnavailable;
        const validate_fn = provider.validate_retained_external_fn orelse
            return error.NativeProviderUnavailable;
        try validate_fn(provider.context, source.external.?, source.size, source.format);
        const logical_bytes = std.math.mul(usize, source.stride, source.size.height) catch
            return error.InvalidSource;

        if (previous) |handle| reuse: {
            if (handle.index >= self.slots.len) return error.StaleContent;
            const slot = &self.slots[handle.index];
            if (slot.state != .published or slot.generation != handle.generation or !slot.current)
                return error.StaleContent;
            if (slot.identity.surface != identity.surface or slot.source.external == null or
                slot.accounted_bytes != logical_bytes)
                break :reuse;
            if (identity.commit_sequence <= slot.identity.commit_sequence) return error.StaleCommit;
            const next = std.math.add(u64, slot.identity.commit_sequence, 1) catch
                return error.NonAdjacentCommit;
            if (identity.commit_sequence != next) return error.NonAdjacentCommit;
            slot.state = .replacing;
            slot.replacement = .{ .identity = identity, .source = source, .damage = .{} };
            return .{ .index = handle.index, .generation = handle.generation, .replaces = true };
        }

        const predecessor = self.currentSlot(identity.surface);
        if (predecessor) |slot| {
            if (identity.commit_sequence <= slot.identity.commit_sequence) return error.StaleCommit;
            const next = std.math.add(u64, slot.identity.commit_sequence, 1) catch
                return error.NonAdjacentCommit;
            if (identity.commit_sequence != next) return error.NonAdjacentCommit;
        }
        if (logical_bytes > self.byte_capacity - self.used_bytes) return error.ByteCapacityExceeded;
        const index = try self.claimSlot();
        var slot = &self.slots[index];
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        slot.state = .prepared;
        slot.identity = identity;
        slot.source = source;
        slot.accounted_bytes = logical_bytes;
        slot.current = false;
        self.used_bytes += logical_bytes;
        return .{ .index = @intCast(index), .generation = slot.generation };
    }

    /// Retains stable SHM bytes as authoritative Pixman content. The caller
    /// owns the matching protocol lease until this version is replaced or
    /// detached; Store accounts the bytes but never copies or frees them.
    pub fn prepareReplacingRetainedShm(
        self: *Store,
        previous: ?Handle,
        identity: render.SampleIdentity,
        source: render.Source,
    ) !Prepared {
        const logical_bytes = try validateRetainedShm(identity, source);

        if (previous) |handle| reuse: {
            if (handle.index >= self.slots.len) return error.StaleContent;
            const slot = &self.slots[handle.index];
            if (slot.state != .published or slot.generation != handle.generation or !slot.current)
                return error.StaleContent;
            if (slot.identity.surface != identity.surface or !slot.source.retained_shm or
                slot.accounted_bytes != logical_bytes)
                break :reuse;
            if (identity.commit_sequence <= slot.identity.commit_sequence) return error.StaleCommit;
            const next = std.math.add(u64, slot.identity.commit_sequence, 1) catch
                return error.NonAdjacentCommit;
            if (identity.commit_sequence != next) return error.NonAdjacentCommit;
            slot.state = .replacing;
            slot.replacement = .{ .identity = identity, .source = source, .damage = .{} };
            return .{ .index = handle.index, .generation = handle.generation, .replaces = true };
        }

        const predecessor = self.currentSlot(identity.surface);
        if (predecessor) |slot| {
            if (identity.commit_sequence <= slot.identity.commit_sequence) return error.StaleCommit;
            const next = std.math.add(u64, slot.identity.commit_sequence, 1) catch
                return error.NonAdjacentCommit;
            if (identity.commit_sequence != next) return error.NonAdjacentCommit;
        }
        if (logical_bytes > self.byte_capacity - self.used_bytes) return error.ByteCapacityExceeded;
        const index = try self.claimSlot();
        var slot = &self.slots[index];
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        slot.state = .prepared;
        slot.identity = identity;
        slot.source = source;
        slot.accounted_bytes = logical_bytes;
        slot.current = false;
        self.used_bytes += logical_bytes;
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

    /// Advances one surface's content identity while retaining its exact
    /// renderer-owned pixels. This represents a wl_surface commit without an
    /// attach request: metadata and callbacks change, but the current buffer
    /// contents do not.
    pub fn prepareRetaining(
        self: *Store,
        previous: Handle,
        identity: render.SampleIdentity,
    ) !Prepared {
        if (previous.index >= self.slots.len) return error.StaleContent;
        const slot = &self.slots[previous.index];
        if (slot.state != .published or slot.generation != previous.generation or
            !slot.current)
            return error.StaleContent;
        if (identity.surface == 0 or slot.identity.surface != identity.surface)
            return error.InvalidIdentity;
        if (identity.commit_sequence <= slot.identity.commit_sequence)
            return error.StaleCommit;
        const next = std.math.add(u64, slot.identity.commit_sequence, 1) catch
            return error.NonAdjacentCommit;
        if (identity.commit_sequence != next) return error.NonAdjacentCommit;
        slot.state = .replacing;
        slot.replacement = .{
            .identity = identity,
            .source = slot.source,
            .damage = .{},
            .retain_pixels = true,
        };
        return .{
            .index = previous.index,
            .generation = previous.generation,
            .replaces = true,
        };
    }

    pub fn cancel(self: *Store, prepared: Prepared) void {
        const slot = self.preparedSlot(prepared) orelse return;
        const retains_pixels = prepared.replaces and slot.replacement.?.retain_pixels;
        if (!retains_pixels) if (slot.source.native) |native| if (self.provider) |provider|
            if (provider.cancel_native_fn) |cancel_fn| {
                const identity = if (prepared.replaces)
                    slot.replacement.?.identity
                else
                    slot.identity;
                cancel_fn(provider.context, native, identity);
            };
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
            if (replacement.retain_pixels) {
                slot.generation +%= 1;
                if (slot.generation == 0) slot.generation = 1;
                slot.identity = replacement.identity;
                slot.replacement = null;
                slot.state = .published;
                return .{ .index = prepared.index, .generation = slot.generation };
            }
            if (slot.source.native != null) {
                slot.generation +%= 1;
                if (slot.generation == 0) slot.generation = 1;
                slot.identity = replacement.identity;
                slot.source.external = replacement.source.external;
                slot.replacement = null;
                slot.state = .published;
                return .{ .index = prepared.index, .generation = slot.generation };
            }
            if (slot.source.external != null) {
                slot.generation +%= 1;
                if (slot.generation == 0) slot.generation = 1;
                slot.identity = replacement.identity;
                slot.source = replacement.source;
                slot.replacement = null;
                slot.state = .published;
                return .{ .index = prepared.index, .generation = slot.generation };
            }
            if (slot.source.retained_shm) {
                slot.generation +%= 1;
                if (slot.generation == 0) slot.generation = 1;
                slot.identity = replacement.identity;
                slot.source = replacement.source;
                slot.replacement = null;
                slot.state = .published;
                return .{ .index = prepared.index, .generation = slot.generation };
            }
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

    pub fn ready(self: *const Store, handle: Handle) bool {
        if (handle.index >= self.slots.len) return false;
        const slot = &self.slots[handle.index];
        if ((slot.state != .published and slot.state != .replacing) or
            slot.generation != handle.generation) return false;
        const native = slot.source.native orelse return true;
        const provider = self.provider orelse return false;
        const ready_fn = provider.ready_native_fn orelse return false;
        return ready_fn(provider.context, native.token, slot.identity);
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

    fn currentSlotIndex(self: *const Store, surface: u64) ?usize {
        for (self.slots, 0..) |slot, index| if (slot.state == .published and
            slot.current and slot.identity.surface == surface)
            return index;
        return null;
    }

    fn freeSlot(self: *const Store) ?usize {
        for (self.slots, 0..) |slot, index| if (slot.state == .free) return index;
        return null;
    }

    fn claimSlot(self: *Store) !usize {
        if (self.freeSlot()) |index| return index;
        if (self.slots.len == std.math.maxInt(u32))
            return error.VersionCapacityExceeded;
        const old_len = self.slots.len;
        const doubled = std.math.mul(usize, old_len, 2) catch std.math.maxInt(u32);
        const new_len = @min(doubled, std.math.maxInt(u32));
        self.slots = try self.allocator.realloc(self.slots, new_len);
        @memset(self.slots[old_len..], .{});
        return old_len;
    }

    fn preparedSlot(self: *Store, prepared: Prepared) ?*Slot {
        if (prepared.index >= self.slots.len) return null;
        const slot = &self.slots[prepared.index];
        const expected_state: State = if (prepared.replaces) .replacing else .prepared;
        if (slot.state != expected_state or slot.generation != prepared.generation) return null;
        return slot;
    }

    fn free(self: *Store, slot: *Slot) void {
        self.used_bytes -= slot.accounted_bytes;
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
        if (source.native) |native| if (self.provider) |provider| {
            if (provider.release_native_fn) |release_fn| release_fn(provider.context, native.token);
            return;
        };
        if (source.external != null) return;
        if (source.retained_shm) return;
        if (source.upload) |upload| if (self.provider) |provider| {
            provider.release(upload.token);
            return;
        };
        self.allocator.free(@constCast(source.bytes));
    }
};

fn validateExternal(identity: render.SampleIdentity, source: render.Source) !void {
    if (identity.surface == 0 or identity.commit_sequence == 0) return error.InvalidIdentity;
    const external = source.external orelse return error.InvalidSource;
    if (source.native != null or source.upload != null or source.bytes.len != 0 or
        source.size.width == 0 or source.size.height == 0 or source.stride == 0 or
        external.token == 0 or external.drm_format == 0 or
        external.plane_count == 0 or external.plane_count > 4)
        return error.InvalidSource;
    for (0..external.plane_count) |plane| if (external.fds[plane] < 0 or
        external.strides[plane] == 0) return error.InvalidSource;
}

fn validateRetainedShm(identity: render.SampleIdentity, source: render.Source) !usize {
    if (identity.surface == 0 or identity.commit_sequence == 0 or
        !source.retained_shm or source.native != null or source.upload != null or
        source.external != null or source.size.width == 0 or source.size.height == 0)
        return error.InvalidSource;
    const row_bytes = std.math.mul(u32, source.size.width, 4) catch
        return error.InvalidSource;
    if (source.stride < row_bytes) return error.InvalidSource;
    const logical_bytes = std.math.mul(usize, source.stride, source.size.height) catch
        return error.InvalidSource;
    if (source.bytes.len < logical_bytes) return error.InvalidSource;
    return logical_bytes;
}

fn copyFull(destination: []u8, packed_stride: u32, source: render.Source) void {
    if (source.stride == packed_stride) {
        _ = libc.memcpy(destination.ptr, source.bytes.ptr, destination.len);
        return;
    }
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

const NativeTestProvider = struct {
    cpu: TestProvider = .{},
    next_token: u64 = 10,
    allocations: usize = 0,
    releases: usize = 0,
    pinned_token: u64 = 0,
    ready_token: u64 = 0,
    ready_identity: render.SampleIdentity = .{ .surface = 0, .commit_sequence = 0 },
    retained_supported: bool = true,

    fn provider(self: *NativeTestProvider) Provider {
        return .{
            .context = self,
            .allocate_fn = cpuAllocate,
            .release_fn = cpuRelease,
            .pinned_fn = cpuPinned,
            .allocate_native_fn = allocateNative,
            .prepare_native_fn = prepareNative,
            .cancel_native_fn = cancelNative,
            .release_native_fn = releaseNative,
            .pinned_native_fn = pinnedNative,
            .ready_native_fn = readyNative,
            .validate_retained_external_fn = validateRetainedExternal,
        };
    }
    fn cpuAllocate(context: *anyopaque, size: usize) !Allocation {
        const self: *NativeTestProvider = @ptrCast(@alignCast(context));
        return TestProvider.allocate(&self.cpu, size);
    }
    fn cpuRelease(context: *anyopaque, token: u64) void {
        const self: *NativeTestProvider = @ptrCast(@alignCast(context));
        TestProvider.release(&self.cpu, token);
    }
    fn cpuPinned(context: *anyopaque, token: u64) bool {
        const self: *NativeTestProvider = @ptrCast(@alignCast(context));
        return TestProvider.pinned(&self.cpu, token);
    }
    fn allocateNative(context: *anyopaque, _: render.Size, _: render.PixelFormat) !render.NativeBacking {
        const self: *NativeTestProvider = @ptrCast(@alignCast(context));
        const token = self.next_token;
        self.next_token += 1;
        self.allocations += 1;
        return .{ .owner = context, .token = token };
    }
    fn prepareNative(_: *anyopaque, _: render.NativeBacking, _: render.SampleIdentity, _: render.ExternalSource) !void {}
    fn cancelNative(_: *anyopaque, _: render.NativeBacking, _: render.SampleIdentity) void {}
    fn releaseNative(context: *anyopaque, _: u64) void {
        const self: *NativeTestProvider = @ptrCast(@alignCast(context));
        self.releases += 1;
    }
    fn pinnedNative(context: *anyopaque, token: u64) bool {
        const self: *NativeTestProvider = @ptrCast(@alignCast(context));
        return self.pinned_token == token;
    }
    fn readyNative(context: *anyopaque, token: u64, identity: render.SampleIdentity) bool {
        const self: *NativeTestProvider = @ptrCast(@alignCast(context));
        return self.ready_token == token and std.meta.eql(self.ready_identity, identity);
    }
    fn validateRetainedExternal(
        context: *anyopaque,
        _: render.ExternalSource,
        _: render.Size,
        _: render.PixelFormat,
    ) !void {
        const self: *NativeTestProvider = @ptrCast(@alignCast(context));
        if (!self.retained_supported) return error.ExternalSamplingUnsupported;
    }
};

fn externalSource(context: *anyopaque, token: u64) render.Source {
    return .{
        .size = .{ .width = 2, .height = 2 },
        .stride = 8,
        .format = .xrgb8888,
        .bytes = &.{},
        .external = .{
            .context = context,
            .token = token,
            .alive_fn = externalAlive,
            .drm_format = 0x34325258,
            .modifier = 0,
            .plane_count = 1,
            .fds = .{ 3, -1, -1, -1 },
            .strides = .{ 8, 0, 0, 0 },
            .offsets = .{ 0, 0, 0, 0 },
        },
    };
}

fn externalAlive(_: *anyopaque, _: u64) bool {
    return true;
}

test "render-content: large packed full copy preserves every byte" {
    const width = 256;
    const height = 64;
    const size = width * height * 4;
    const source = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(source);
    const destination = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(destination);
    for (source, 0..) |*byte, index| byte.* = @truncate(index *% 131 +% 17);
    @memset(destination, 0);

    copyFull(destination, width * 4, testSource(source, width, height, width * 4));
    try std.testing.expectEqualSlices(u8, source, destination);
}

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
    try std.testing.expectError(error.ByteCapacityExceeded, store.prepare(
        .{ .surface = 2, .commit_sequence = 1 },
        testSource(&second, 1, 1, 4),
        .{},
    ));
    store.cancel(prepared);
    try std.testing.expectEqualSlices(u8, &first, (try store.resolve(handle)).bytes);
    store.release(handle);
}

test "render-content: versions grow beyond initial capacity with stable handles" {
    var store = try Store.init(std.testing.allocator, .{ .version_capacity = 1, .byte_capacity = 12 });
    defer store.deinit();
    const bytes = [_]u8{ 1, 2, 3, 4 };
    const first = store.publish(try store.prepare(
        .{ .surface = 1, .commit_sequence = 1 },
        testSource(&bytes, 1, 1, 4),
        .{},
    ));
    const second = store.publish(try store.prepare(
        .{ .surface = 2, .commit_sequence = 1 },
        testSource(&bytes, 1, 1, 4),
        .{},
    ));
    const third = store.publish(try store.prepare(
        .{ .surface = 3, .commit_sequence = 1 },
        testSource(&bytes, 1, 1, 4),
        .{},
    ));
    try std.testing.expect(store.slots.len >= 3);
    try std.testing.expectEqualSlices(u8, &bytes, (try store.resolve(first)).bytes);
    try std.testing.expectEqualSlices(u8, &bytes, (try store.resolve(second)).bytes);
    try std.testing.expectEqualSlices(u8, &bytes, (try store.resolve(third)).bytes);
    store.release(first);
    store.release(second);
    store.release(third);
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

test "render-content: retained commit advances identity without changing pixels" {
    var store = try Store.init(std.testing.allocator, .{ .version_capacity = 1, .byte_capacity = 16 });
    defer store.deinit();
    const bytes = [_]u8{ 1, 2, 3, 4 };
    const old = store.publish(try store.prepare(
        .{ .surface = 1, .commit_sequence = 1 },
        testSource(&bytes, 1, 1, 4),
        .{},
    ));
    const allocated = store.allocatedBytes();

    const cancelled = try store.prepareRetaining(
        old,
        .{ .surface = 1, .commit_sequence = 2 },
    );
    store.cancel(cancelled);
    try std.testing.expectEqualSlices(u8, &bytes, (try store.resolve(old)).bytes);

    const current = store.publish(try store.prepareRetaining(
        old,
        .{ .surface = 1, .commit_sequence = 2 },
    ));
    try std.testing.expectEqual(allocated, store.allocatedBytes());
    try std.testing.expectError(error.StaleContent, store.resolve(old));
    try std.testing.expectEqualSlices(u8, &bytes, (try store.resolve(current)).bytes);
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

test "render-content: external allocation publication readiness and exact accounting" {
    var backing: NativeTestProvider = .{};
    var store = try Store.initWithProvider(
        std.testing.allocator,
        .{ .version_capacity = 2, .byte_capacity = 16 },
        backing.provider(),
    );
    defer store.deinit();
    const baseline = store.allocatedBytes();
    const identity: render.SampleIdentity = .{ .surface = 8, .commit_sequence = 1 };
    const prepared = try store.prepareReplacingExternal(null, identity, externalSource(&backing, 101), .{});
    try std.testing.expectEqual(@as(usize, 1), backing.allocations);
    try std.testing.expectEqual(baseline + 16, store.allocatedBytes());
    const handle = store.publish(prepared);
    const source = try store.resolve(handle);
    try std.testing.expectEqual(@as(u64, 10), source.native.?.token);
    try std.testing.expectEqual(@as(u64, 101), source.external.?.token);
    try std.testing.expect(!store.ready(handle));
    backing.ready_token = 10;
    backing.ready_identity = identity;
    try std.testing.expect(store.ready(handle));
    backing.ready_identity.commit_sequence = 2;
    try std.testing.expect(!store.ready(handle));
    try std.testing.expectError(error.StaleCommit, store.prepareReplacingExternal(
        handle,
        identity,
        externalSource(&backing, 102),
        .{},
    ));
    store.release(handle);
    try std.testing.expectEqual(baseline, store.allocatedBytes());
    try std.testing.expectEqual(@as(usize, 1), backing.releases);
    try std.testing.expect(!store.ready(handle));
}

test "render-content: retained external replacement is metadata-only and capability-gated" {
    var backing: NativeTestProvider = .{};
    var store = try Store.initWithProvider(
        std.testing.allocator,
        .{ .version_capacity = 2, .byte_capacity = 16 },
        backing.provider(),
    );
    defer store.deinit();
    const baseline = store.allocatedBytes();
    const first = store.publish(try store.prepareReplacingRetainedExternal(
        null,
        .{ .surface = 9, .commit_sequence = 1 },
        externalSource(&backing, 301),
    ));
    try std.testing.expectEqual(@as(usize, 0), backing.allocations);
    try std.testing.expectEqual(baseline + 16, store.allocatedBytes());
    try std.testing.expect((try store.resolve(first)).native == null);
    try std.testing.expectEqual(@as(u64, 301), (try store.resolve(first)).external.?.token);
    try std.testing.expect(store.ready(first));

    const cancelled = try store.prepareReplacingRetainedExternal(
        first,
        .{ .surface = 9, .commit_sequence = 2 },
        externalSource(&backing, 302),
    );
    try std.testing.expect(cancelled.replaces);
    store.cancel(cancelled);
    try std.testing.expectEqual(@as(u64, 301), (try store.resolve(first)).external.?.token);
    const current = store.publish(try store.prepareReplacingRetainedExternal(
        first,
        .{ .surface = 9, .commit_sequence = 2 },
        externalSource(&backing, 302),
    ));
    try std.testing.expectError(error.StaleContent, store.resolve(first));
    try std.testing.expectEqual(@as(u64, 302), (try store.resolve(current)).external.?.token);
    store.release(current);
    try std.testing.expectEqual(baseline, store.allocatedBytes());

    backing.retained_supported = false;
    try std.testing.expectError(
        error.ExternalSamplingUnsupported,
        store.prepareReplacingRetainedExternal(
            null,
            .{ .surface = 10, .commit_sequence = 1 },
            externalSource(&backing, 303),
        ),
    );
}

test "render-content: retained SHM replacement borrows exact bytes without allocation" {
    var store = try Store.init(
        std.testing.allocator,
        .{ .version_capacity = 2, .byte_capacity = 16 },
    );
    defer store.deinit();
    const baseline = store.allocatedBytes();
    const first_bytes = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var first_source = testSource(&first_bytes, 2, 1, 8);
    first_source.retained_shm = true;
    const first = store.publish(try store.prepareReplacingRetainedShm(
        null,
        .{ .surface = 11, .commit_sequence = 1 },
        first_source,
    ));
    try std.testing.expectEqual(baseline + 8, store.allocatedBytes());
    try std.testing.expectEqual(@intFromPtr(&first_bytes), @intFromPtr((try store.resolve(first)).bytes.ptr));

    const second_bytes = [_]u8{ 9, 10, 11, 12, 13, 14, 15, 16 };
    var second_source = testSource(&second_bytes, 2, 1, 8);
    second_source.retained_shm = true;
    const prepared = try store.prepareReplacingRetainedShm(
        first,
        .{ .surface = 11, .commit_sequence = 2 },
        second_source,
    );
    try std.testing.expect(prepared.replaces);
    store.cancel(prepared);
    try std.testing.expectEqual(@intFromPtr(&first_bytes), @intFromPtr((try store.resolve(first)).bytes.ptr));
    const current = store.publish(try store.prepareReplacingRetainedShm(
        first,
        .{ .surface = 11, .commit_sequence = 2 },
        second_source,
    ));
    try std.testing.expectError(error.StaleContent, store.resolve(first));
    try std.testing.expectEqual(@intFromPtr(&second_bytes), @intFromPtr((try store.resolve(current)).bytes.ptr));
    store.release(current);
    try std.testing.expectEqual(baseline, store.allocatedBytes());
}

test "render-content: external adjacent replacement cancel reuse and pinned fallback" {
    var backing: NativeTestProvider = .{};
    var store = try Store.initWithProvider(
        std.testing.allocator,
        .{ .version_capacity = 2, .byte_capacity = 32 },
        backing.provider(),
    );
    defer store.deinit();
    const old = store.publish(try store.prepareReplacingExternal(
        null,
        .{ .surface = 3, .commit_sequence = 1 },
        externalSource(&backing, 201),
        .{},
    ));
    const cancelled = try store.prepareReplacingExternal(
        old,
        .{ .surface = 3, .commit_sequence = 2 },
        externalSource(&backing, 202),
        .{},
    );
    try std.testing.expect(cancelled.replaces);
    store.cancel(cancelled);
    try std.testing.expectEqual(@as(u64, 201), (try store.resolve(old)).external.?.token);
    try std.testing.expectEqual(@as(usize, 1), backing.allocations);

    const current = store.publish(try store.prepareReplacingExternal(
        old,
        .{ .surface = 3, .commit_sequence = 2 },
        externalSource(&backing, 202),
        .{},
    ));
    try std.testing.expectEqual(@as(u64, 10), (try store.resolve(current)).native.?.token);
    try std.testing.expectEqual(@as(u64, 202), (try store.resolve(current)).external.?.token);
    backing.pinned_token = 10;
    const fallback = try store.prepareReplacingExternal(
        current,
        .{ .surface = 3, .commit_sequence = 3 },
        externalSource(&backing, 203),
        .{},
    );
    try std.testing.expect(!fallback.replaces);
    try std.testing.expectEqual(@as(usize, 2), backing.allocations);
    store.cancel(fallback);
    try std.testing.expectEqual(@as(usize, 1), backing.releases);
    try std.testing.expectEqual(@as(u64, 202), (try store.resolve(current)).external.?.token);
    store.release(current);
    try std.testing.expectEqual(@as(usize, 2), backing.releases);
}
