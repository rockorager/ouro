//! Allocation-free protocol-independent compositor surface state.

const std = @import("std");
const objects = @import("objects.zig");

pub const RegionPool = @import("region.zig").Pool;
pub const Region = @import("region.zig").Region;
pub const RegionRectangle = @import("region.zig").Rectangle;
pub const SurfaceRegions = @import("region.zig").SurfaceRegions;
pub const FramePool = @import("frame.zig").Pool;
pub const FrameQueue = @import("frame.zig").Queue;
pub const FrameBatch = @import("frame.zig").Batch;
pub const SubsurfaceGraph = @import("subsurface.zig").Graph;
pub const ReleasePool = @import("release.zig").Pool;
pub const ReleaseQueue = @import("release.zig").Queue;
pub const ReleaseBatch = @import("release.zig").Batch;
pub const ContentUpdateScheduler = @import("content_update.zig").Scheduler;
pub const ContentUpdateKind = @import("content_update.zig").Kind;

pub const Error = error{
    InvalidRole,
    WrongRole,
    RoleObjectActive,
    DefunctRoleObject,
    InvalidSize,
    InvalidScale,
    InvalidTransform,
    InvalidOffset,
};

/// Application-defined permanent surface role identity. Zero is reserved for
/// the absence of a role; compositors may use enum integer values or hashes of
/// static role names.
pub const RoleId = u64;

pub const Role = struct {
    id: RoleId = 0,
    object_active: bool = false,

    /// Assigns a permanent role. Repeating the same objectless role is valid;
    /// creating a second live role object is not.
    pub fn assign(role: *Role, id: RoleId, has_object: bool) Error!void {
        if (id == 0) return error.InvalidRole;
        if (role.id != 0 and role.id != id) return error.WrongRole;
        if (has_object and role.object_active) return error.RoleObjectActive;
        role.id = id;
        if (has_object) role.object_active = true;
    }

    /// Marks a role object destroyed without removing the permanent role.
    pub fn deactivateObject(role: *Role, id: RoleId) Error!void {
        if (id == 0 or role.id != id) return error.WrongRole;
        if (!role.object_active) return error.DefunctRoleObject;
        role.object_active = false;
    }

    pub fn validateDestroy(role: Role) Error!void {
        if (role.object_active) return error.DefunctRoleObject;
    }
};

pub const Point = struct {
    x: i32 = 0,
    y: i32 = 0,
};

/// Conservative damage accumulator. It stores one bounding rectangle rather
/// than allocating an exact region; overdraw is safe and keeps each surface's
/// hot pending state fixed-size.
pub const Damage = struct {
    min_x: i64 = 0,
    min_y: i64 = 0,
    max_x: i64 = 0,
    max_y: i64 = 0,
    empty: bool = true,

    pub fn add(damage: *Damage, x: i32, y: i32, width: i32, height: i32) void {
        if (width <= 0 or height <= 0) return;
        const min_x: i64 = x;
        const min_y: i64 = y;
        const max_x = min_x + @as(i64, width);
        const max_y = min_y + @as(i64, height);
        if (damage.empty) {
            damage.* = .{
                .min_x = min_x,
                .min_y = min_y,
                .max_x = max_x,
                .max_y = max_y,
                .empty = false,
            };
            return;
        }
        damage.min_x = @min(damage.min_x, min_x);
        damage.min_y = @min(damage.min_y, min_y);
        damage.max_x = @max(damage.max_x, max_x);
        damage.max_y = @max(damage.max_y, max_y);
    }
};

pub const Transform = enum(u3) {
    normal,
    @"90",
    @"180",
    @"270",
    flipped,
    flipped_90,
    flipped_180,
    flipped_270,

    pub fn fromProtocol(value: i32) Error!Transform {
        if (value < 0 or value > 7) return error.InvalidTransform;
        return @enumFromInt(value);
    }
};

pub const Buffer = struct {
    handle: objects.Handle,
    width: u32,
    height: u32,
};

pub const Attachment = struct {
    buffer: ?Buffer,
    offset: Point,
};

/// One atomic content update produced by `Surface.commit`. Region snapshots,
/// frame callbacks, viewport state, and role-specific state compose alongside
/// this value at the application boundary.
pub const Update = struct {
    sequence: u64,
    attachment: ?Attachment,
    surface_damage: Damage,
    buffer_damage: Damage,
    transform: Transform,
    scale: i32,
    offset: Point,
};

pub const Surface = struct {
    role: Role = .{},
    sequence: u64 = 0,
    current_buffer: ?Buffer = null,
    current_transform: Transform = .normal,
    current_scale: i32 = 1,

    pending_buffer: ?Buffer = null,
    pending_attach_offset: Point = .{},
    attach_changed: bool = false,
    pending_surface_damage: Damage = .{},
    pending_buffer_damage: Damage = .{},
    pending_transform: Transform = .normal,
    pending_scale: i32 = 1,
    pending_offset: Point = .{},

    /// Applies wl_surface.attach validation and replaces the pending buffer.
    pub fn attach(
        surface: *Surface,
        version: u32,
        buffer: ?Buffer,
        x: i32,
        y: i32,
    ) Error!void {
        if (version >= 5 and (x != 0 or y != 0)) return error.InvalidOffset;
        if (buffer) |value| if (value.width == 0 or value.height == 0)
            return error.InvalidSize;
        surface.pending_buffer = buffer;
        surface.pending_attach_offset = if (version < 5) .{ .x = x, .y = y } else .{};
        surface.attach_changed = true;
    }

    pub fn damage(surface: *Surface, x: i32, y: i32, width: i32, height: i32) void {
        surface.pending_surface_damage.add(x, y, width, height);
    }

    pub fn damageBuffer(surface: *Surface, x: i32, y: i32, width: i32, height: i32) void {
        surface.pending_buffer_damage.add(x, y, width, height);
    }

    pub fn setTransform(surface: *Surface, value: i32) Error!void {
        surface.pending_transform = try Transform.fromProtocol(value);
    }

    pub fn setScale(surface: *Surface, scale: i32) Error!void {
        if (scale <= 0) return error.InvalidScale;
        surface.pending_scale = scale;
    }

    pub fn setOffset(surface: *Surface, x: i32, y: i32) void {
        surface.pending_offset = .{ .x = x, .y = y };
    }

    pub fn hasPendingBufferAttachment(surface: Surface) bool {
        return surface.attach_changed and surface.pending_buffer != null;
    }

    /// Validates the effective buffer geometry without mutating pending state.
    pub fn validateCommit(surface: Surface) Error!void {
        const buffer = if (surface.attach_changed)
            surface.pending_buffer
        else
            surface.current_buffer;
        if (buffer) |value| {
            const scale: u32 = @intCast(surface.pending_scale);
            if (value.width % scale != 0 or value.height % scale != 0)
                return error.InvalidSize;
        }
    }

    /// Atomically applies persistent scalar state and extracts one-shot state.
    pub fn commit(surface: *Surface) Error!Update {
        try surface.validateCommit();
        return surface.publishCommit();
    }

    fn publishCommit(surface: *Surface) Update {
        surface.sequence +%= 1;
        const attachment: ?Attachment = if (surface.attach_changed) .{
            .buffer = surface.pending_buffer,
            .offset = surface.pending_attach_offset,
        } else null;
        if (surface.attach_changed) surface.current_buffer = surface.pending_buffer;
        surface.current_transform = surface.pending_transform;
        surface.current_scale = surface.pending_scale;
        const update: Update = .{
            .sequence = surface.sequence,
            .attachment = attachment,
            .surface_damage = surface.pending_surface_damage,
            .buffer_damage = surface.pending_buffer_damage,
            .transform = surface.current_transform,
            .scale = surface.current_scale,
            .offset = surface.pending_offset,
        };
        surface.pending_buffer = null;
        surface.pending_attach_offset = .{};
        surface.attach_changed = false;
        surface.pending_surface_damage = .{};
        surface.pending_buffer_damage = .{};
        surface.pending_offset = .{};
        return update;
    }

    pub fn validateDestroy(surface: Surface) Error!void {
        try surface.role.validateDestroy();
    }
};

/// Transactional composition of one wl_surface commit with shared state pools
/// and the version-7 content-update scheduler.
pub fn CommitState(comptime Key: type) type {
    return struct {
        pub const Content = struct {
            surface: Update,
            regions: SurfaceRegions.Changes,
            frame_callbacks: ?FrameBatch,
            release_callbacks: ?ReleaseBatch,

            /// Releases callback ownership when an unapplied CU is discarded.
            pub fn deinit(content: *Content) void {
                if (content.frame_callbacks) |*batch| batch.deinit();
                if (content.release_callbacks) |*batch| batch.deinit();
                content.frame_callbacks = null;
                content.release_callbacks = null;
            }

            /// Frame callbacks become ready only when this CU applies.
            pub fn activateFrames(content: *Content, queue: *FrameQueue) usize {
                if (content.frame_callbacks) |*batch| {
                    const activated = queue.activate(batch);
                    content.frame_callbacks = null;
                    return activated;
                }
                return 0;
            }
        };

        pub const Scheduler = ContentUpdateScheduler(Key, Content);

        pub fn deinitQueue(queue: *Scheduler.Queue) void {
            queue.deinitWith(Content.deinit);
        }

        /// All failures occur before externally visible state mutation. The
        /// prepared scheduler plan is published synchronously after infallible
        /// surface, region, and callback ownership transitions.
        pub fn commit(
            scheduler: *Scheduler,
            queue: *Scheduler.Queue,
            surface: *Surface,
            regions: *SurfaceRegions,
            frames: *FrameQueue,
            releases: *ReleaseQueue,
            kind: ContentUpdateKind,
            child_dependencies: []const Scheduler.Token,
            constraints: u32,
        ) !Scheduler.Token {
            try surface.validateCommit();
            var scheduler_plan = try scheduler.prepareCommit(
                queue,
                kind,
                child_dependencies,
                constraints,
            );
            var region_plan = try regions.prepareCommit();
            defer region_plan.deinit();
            try releases.validateCommit(surface.hasPendingBufferAttachment());

            const content: Content = .{
                .surface = surface.publishCommit(),
                .regions = region_plan.publish(),
                .frame_callbacks = frames.detachPending(),
                .release_callbacks = releases.publishCommit(),
            };
            return scheduler.publishCommit(&scheduler_plan, content);
        }
    };
}

test "surface commits persistent and one-shot state atomically" {
    var surface: Surface = .{};
    const handle: objects.Handle = .{ .id = 9, .generation = 3 };
    const buffer: Buffer = .{ .handle = handle, .width = 10, .height = 6 };
    try surface.attach(4, buffer, 2, -3);
    surface.damage(10, 20, 3, 4);
    surface.damage(8, 30, 4, 2);
    surface.damageBuffer(-2, -4, 5, 6);
    try surface.setTransform(3);
    try surface.setScale(2);
    surface.setOffset(7, -8);

    const first = try surface.commit();
    try std.testing.expectEqual(@as(u64, 1), first.sequence);
    try std.testing.expectEqual(buffer, first.attachment.?.buffer.?);
    try std.testing.expectEqual(Point{ .x = 2, .y = -3 }, first.attachment.?.offset);
    try std.testing.expectEqual(@as(i64, 8), first.surface_damage.min_x);
    try std.testing.expectEqual(@as(i64, 32), first.surface_damage.max_y);
    try std.testing.expectEqual(Transform.@"270", first.transform);
    try std.testing.expectEqual(@as(i32, 2), first.scale);
    try std.testing.expectEqual(Point{ .x = 7, .y = -8 }, first.offset);

    const second = try surface.commit();
    try std.testing.expectEqual(@as(u64, 2), second.sequence);
    try std.testing.expectEqual(@as(?Attachment, null), second.attachment);
    try std.testing.expect(second.surface_damage.empty);
    try std.testing.expect(second.buffer_damage.empty);
    try std.testing.expectEqual(Transform.@"270", second.transform);
    try std.testing.expectEqual(@as(i32, 2), second.scale);
    try std.testing.expectEqual(Point{}, second.offset);
    try std.testing.expectEqual(buffer, surface.current_buffer.?);
}

test "transactional surface commit publishes callback ownership with its CU" {
    const State = CommitState(objects.Handle);
    var region_pool = try RegionPool.init(std.testing.allocator, 6);
    defer region_pool.deinit(std.testing.allocator);
    var source = Region.init(&region_pool);
    defer source.deinit();
    try source.add(.{ .x = 1, .y = 2, .width = 3, .height = 4 });
    var regions = SurfaceRegions.init(&region_pool);
    defer regions.deinit();
    try regions.setOpaque(&source);
    var frame_pool = try FramePool.init(std.testing.allocator, 1);
    defer frame_pool.deinit(std.testing.allocator);
    var frames = FrameQueue.init(&frame_pool);
    defer frames.deinit();
    var release_pool = try ReleasePool.init(std.testing.allocator, 1);
    defer release_pool.deinit(std.testing.allocator);
    var releases = ReleaseQueue.init(&release_pool);
    defer releases.deinit();
    var scheduler = try State.Scheduler.init(std.testing.allocator, 1, 1);
    defer scheduler.deinit(std.testing.allocator);
    const surface_key: objects.Handle = .{ .id = 2, .generation = 1 };
    var queue = State.Scheduler.Queue.init(&scheduler, surface_key);
    defer queue.deinit();
    var surface: Surface = .{};
    const buffer: Buffer = .{
        .handle = .{ .id = 3, .generation = 1 },
        .width = 2,
        .height = 2,
    };
    const frame_callback: objects.Handle = .{ .id = 4, .generation = 1 };
    const release_callback: objects.Handle = .{ .id = 5, .generation = 1 };
    try surface.attach(7, buffer, 0, 0);
    try frames.addPending(frame_callback);
    try releases.request(release_callback);

    _ = try State.commit(
        &scheduler,
        &queue,
        &surface,
        &regions,
        &frames,
        &releases,
        .desync,
        &.{},
        0,
    );
    try std.testing.expectEqual(@as(u64, 1), surface.sequence);
    try std.testing.expectEqual(@as(usize, 1), regions.current_opaque.count);
    try std.testing.expectEqual(@as(?objects.Handle, null), frames.peekReady());
    var applied: [1]State.Scheduler.Applied = undefined;
    const result = try scheduler.tryApply(&queue, &applied);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    var content = result[0].payload;
    defer content.deinit();
    try std.testing.expectEqual(@as(usize, 1), content.activateFrames(&frames));
    try std.testing.expectEqual(frame_callback, frames.peekReady().?);
    try std.testing.expectEqual(release_callback, content.release_callbacks.?.peek().?);
    try frames.consumeReady(frame_callback);
    try content.release_callbacks.?.consume(release_callback);
}

test "transactional surface commit rolls back every preflight failure" {
    const State = CommitState(objects.Handle);
    var region_pool = try RegionPool.init(std.testing.allocator, 4);
    defer region_pool.deinit(std.testing.allocator);
    var source = Region.init(&region_pool);
    defer source.deinit();
    try source.add(.{ .x = 1, .y = 2, .width = 3, .height = 4 });
    var regions = SurfaceRegions.init(&region_pool);
    defer regions.deinit();
    try regions.setOpaque(&source);
    var frame_pool = try FramePool.init(std.testing.allocator, 1);
    defer frame_pool.deinit(std.testing.allocator);
    var frames = FrameQueue.init(&frame_pool);
    defer frames.deinit();
    var release_pool = try ReleasePool.init(std.testing.allocator, 1);
    defer release_pool.deinit(std.testing.allocator);
    var releases = ReleaseQueue.init(&release_pool);
    defer releases.deinit();
    var scheduler = try State.Scheduler.init(std.testing.allocator, 1, 1);
    defer scheduler.deinit(std.testing.allocator);
    const surface_key: objects.Handle = .{ .id = 2, .generation = 1 };
    var queue = State.Scheduler.Queue.init(&scheduler, surface_key);
    defer queue.deinit();
    var surface: Surface = .{};
    const frame_callback: objects.Handle = .{ .id = 4, .generation = 1 };
    const release_callback: objects.Handle = .{ .id = 5, .generation = 1 };
    try frames.addPending(frame_callback);
    try releases.request(release_callback);

    try std.testing.expectError(error.MissingBuffer, State.commit(
        &scheduler,
        &queue,
        &surface,
        &regions,
        &frames,
        &releases,
        .desync,
        &.{},
        0,
    ));
    try std.testing.expectEqual(@as(u64, 0), surface.sequence);
    try std.testing.expectEqual(@as(usize, 0), regions.current_opaque.count);
    try std.testing.expect(regions.opaque_dirty);
    try std.testing.expectEqual(@as(usize, 1), frames.pending_count);
    try std.testing.expectEqual(@as(usize, 1), releases.count);
    try std.testing.expectEqual(@as(usize, 0), queue.count);

    try surface.attach(7, .{
        .handle = .{ .id = 3, .generation = 1 },
        .width = 3,
        .height = 2,
    }, 0, 0);
    try surface.setScale(2);
    try std.testing.expectError(error.InvalidSize, State.commit(
        &scheduler,
        &queue,
        &surface,
        &regions,
        &frames,
        &releases,
        .desync,
        &.{},
        0,
    ));
    try std.testing.expectEqual(@as(u64, 0), surface.sequence);
    try std.testing.expect(surface.attach_changed);
    try std.testing.expectEqual(@as(usize, 0), regions.current_opaque.count);
    try std.testing.expect(regions.opaque_dirty);
    try std.testing.expectEqual(@as(usize, 1), frames.pending_count);
    try std.testing.expectEqual(@as(usize, 1), releases.count);
    try std.testing.expectEqual(@as(usize, 0), queue.count);
}

test "discarding an unapplied transactional CU releases callback batches" {
    const State = CommitState(objects.Handle);
    var region_pool = try RegionPool.init(std.testing.allocator, 1);
    defer region_pool.deinit(std.testing.allocator);
    var regions = SurfaceRegions.init(&region_pool);
    defer regions.deinit();
    var frame_pool = try FramePool.init(std.testing.allocator, 1);
    defer frame_pool.deinit(std.testing.allocator);
    var frames = FrameQueue.init(&frame_pool);
    defer frames.deinit();
    var release_pool = try ReleasePool.init(std.testing.allocator, 1);
    defer release_pool.deinit(std.testing.allocator);
    var releases = ReleaseQueue.init(&release_pool);
    defer releases.deinit();
    var scheduler = try State.Scheduler.init(std.testing.allocator, 1, 1);
    defer scheduler.deinit(std.testing.allocator);
    const surface_key: objects.Handle = .{ .id = 2, .generation = 1 };
    var queue = State.Scheduler.Queue.init(&scheduler, surface_key);
    var surface: Surface = .{};
    const buffer: Buffer = .{
        .handle = .{ .id = 3, .generation = 1 },
        .width = 2,
        .height = 2,
    };
    try surface.attach(7, buffer, 0, 0);
    try frames.addPending(.{ .id = 4, .generation = 1 });
    try releases.request(.{ .id = 5, .generation = 1 });
    _ = try State.commit(
        &scheduler,
        &queue,
        &surface,
        &regions,
        &frames,
        &releases,
        .sync,
        &.{},
        0,
    );
    State.deinitQueue(&queue);
    try std.testing.expectEqual(@as(usize, 1), frame_pool.available());
    try std.testing.expectEqual(@as(usize, 1), release_pool.available());
}

test "surface validates offsets scale transform and permanent roles" {
    var surface: Surface = .{};
    try std.testing.expectError(error.InvalidOffset, surface.attach(5, null, 1, 0));
    try std.testing.expectError(error.InvalidSize, surface.attach(7, .{
        .handle = .{ .id = 2, .generation = 1 },
        .width = 0,
        .height = 1,
    }, 0, 0));
    try std.testing.expectError(error.InvalidScale, surface.setScale(0));
    try std.testing.expectError(error.InvalidTransform, surface.setTransform(8));

    try surface.role.assign(11, true);
    try surface.role.assign(11, false);
    try std.testing.expect(surface.role.object_active);
    try std.testing.expectError(error.RoleObjectActive, surface.role.assign(11, true));
    try std.testing.expectError(error.WrongRole, surface.role.assign(12, false));
    try std.testing.expectError(error.DefunctRoleObject, surface.validateDestroy());
    try surface.role.deactivateObject(11);
    try surface.validateDestroy();
    try surface.role.assign(11, true);
}

test "surface rejects buffer dimensions not divisible by scale transactionally" {
    var surface: Surface = .{};
    const first: Buffer = .{
        .handle = .{ .id = 2, .generation = 1 },
        .width = 6,
        .height = 4,
    };
    try surface.attach(7, first, 0, 0);
    try surface.setScale(2);
    _ = try surface.commit();

    try surface.setScale(4);
    try std.testing.expectError(error.InvalidSize, surface.commit());
    try std.testing.expectEqual(@as(u64, 1), surface.sequence);
    try std.testing.expectEqual(@as(i32, 2), surface.current_scale);
    try std.testing.expectEqual(@as(i32, 4), surface.pending_scale);

    const second: Buffer = .{
        .handle = .{ .id = 3, .generation = 1 },
        .width = 8,
        .height = 4,
    };
    try surface.attach(7, second, 0, 0);
    const update = try surface.commit();
    try std.testing.expectEqual(second, update.attachment.?.buffer.?);
    try std.testing.expectEqual(@as(i32, 4), surface.current_scale);
}
