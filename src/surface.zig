//! Allocation-free protocol-independent compositor surface state.

const std = @import("std");
const objects = @import("wayring").objects;
const viewport = @import("viewport.zig");
const buffer_import = @import("buffer_import.zig");
const color = @import("render/color.zig");

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
pub const PresentationFeedbackPool = @import("presentation_feedback.zig").Pool;
pub const PresentationFeedbackPending = @import("presentation_feedback.zig").Pending;
pub const PresentationFeedbackBatch = @import("presentation_feedback.zig").Batch;
pub const ContentUpdateScheduler = @import("content_update.zig").Scheduler;
pub const ContentUpdateKind = @import("content_update.zig").Kind;
pub const AttachmentLeaseState = buffer_import.AttachmentState;
pub const BufferLease = buffer_import.Lease;
pub const Viewport = viewport.Viewport;
pub const ViewportState = viewport.State;
pub const SurfaceSize = viewport.Size;

/// Grow the shared callback pools while preserving their index-based queues.
/// Configured capacities are initial reservations rather than protocol limits.
pub fn growCallbackPool(allocator: std.mem.Allocator, pool: anytype) !void {
    const old_len = pool.nodes.len;
    if (old_len >= std.math.maxInt(u32) - 1) return error.OutOfMemory;
    const new_len = @min(std.math.maxInt(u32) - 1, old_len + @max(old_len, 1));
    pool.nodes = try allocator.realloc(pool.nodes, new_len);
    for (pool.nodes[old_len..], old_len..) |*node, index| {
        node.* = .{};
        node.next = if (index + 1 < new_len) @intCast(index + 1) else pool.free_head;
    }
    pool.free_head = @intCast(old_len);
}

pub const Error = viewport.Error || error{
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

pub const upload_damage_rect_capacity = 8;

/// Allocation-free upload region. Rectangles remain disjoint; overlapping
/// requests merge conservatively, and capacity overflow collapses to one bound.
pub const UploadDamage = struct {
    rects: [upload_damage_rect_capacity]Damage =
        [_]Damage{.{}} ** upload_damage_rect_capacity,
    count: u8 = 0,

    pub fn items(damage: *const UploadDamage) []const Damage {
        return damage.rects[0..damage.count];
    }

    fn add(upload: *UploadDamage, x: i32, y: i32, width: i32, height: i32) void {
        if (width <= 0 or height <= 0) return;
        upload.addDamage(.{
            .min_x = x,
            .min_y = y,
            .max_x = @as(i64, x) + width,
            .max_y = @as(i64, y) + height,
            .empty = false,
        });
    }

    fn addDamage(upload: *UploadDamage, value: Damage) void {
        if (value.empty) return;
        var merged = value;
        var index: usize = 0;
        while (index < upload.count) {
            if (!overlaps(upload.rects[index], merged)) {
                index += 1;
                continue;
            }
            unionDamage(&merged, upload.rects[index]);
            upload.count -= 1;
            upload.rects[index] = upload.rects[upload.count];
            // The larger merged bound can overlap an earlier rectangle that
            // did not overlap the original input, so recheck the whole region.
            index = 0;
        }
        if (upload.count < upload.rects.len) {
            upload.rects[upload.count] = merged;
            upload.count += 1;
            return;
        }
        for (upload.items()) |rect| unionDamage(&merged, rect);
        upload.rects[0] = merged;
        upload.count = 1;
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

pub const PresentationHint = enum {
    vsync,
    async,
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
    /// Both protocol damage domains mapped to native buffer pixels. This is the
    /// renderer import/update domain; scene/output damage remains separate.
    upload_damage: UploadDamage,
    transform: Transform,
    scale: i32,
    offset: Point,
    viewport: ViewportState,
    size: SurfaceSize,
    color_description: color.Description,
    color_representation: color.Representation,
    content_type: u32 = 0,
    presentation_hint: PresentationHint = .vsync,
    fifo_set: bool = false,
    fifo_wait: bool = false,
};

pub const Surface = struct {
    role: Role = .{},
    sequence: u64 = 0,
    current_buffer: ?Buffer = null,
    current_transform: Transform = .normal,
    current_scale: i32 = 1,
    current_content_type: u32 = 0,
    current_presentation_hint: PresentationHint = .vsync,
    viewport: Viewport = .{},
    current_color_description: color.Description = .srgb,
    current_color_representation: color.Representation = .{},

    pending_buffer: ?Buffer = null,
    pending_attach_offset: Point = .{},
    attach_changed: bool = false,
    pending_surface_damage: Damage = .{},
    pending_buffer_damage: Damage = .{},
    pending_surface_upload_damage: UploadDamage = .{},
    pending_buffer_upload_damage: UploadDamage = .{},
    pending_transform: Transform = .normal,
    pending_scale: i32 = 1,
    pending_offset: Point = .{},
    pending_color_description: color.Description = .srgb,
    pending_color_representation: color.Representation = .{},
    pending_content_type: u32 = 0,
    pending_presentation_hint: PresentationHint = .vsync,
    pending_fifo_set: bool = false,
    pending_fifo_wait: bool = false,

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
        surface.pending_surface_upload_damage.add(x, y, width, height);
    }

    pub fn damageBuffer(surface: *Surface, x: i32, y: i32, width: i32, height: i32) void {
        surface.pending_buffer_damage.add(x, y, width, height);
        surface.pending_buffer_upload_damage.add(x, y, width, height);
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

    pub fn setColorDescription(surface: *Surface, description: color.Description) !void {
        try description.validate();
        surface.pending_color_description = description;
    }

    pub fn unsetColorDescription(surface: *Surface) void {
        surface.pending_color_description = .srgb;
    }

    pub fn setColorRepresentation(surface: *Surface, representation: color.Representation) void {
        surface.pending_color_representation = representation;
    }

    pub fn setContentType(surface: *Surface, content_type: u32) void {
        surface.pending_content_type = content_type;
    }

    pub fn setPresentationHint(surface: *Surface, hint: PresentationHint) void {
        surface.pending_presentation_hint = hint;
    }

    pub fn setFifoBarrier(surface: *Surface) void {
        surface.pending_fifo_set = true;
    }

    pub fn waitFifoBarrier(surface: *Surface) void {
        surface.pending_fifo_wait = true;
    }

    pub fn hasPendingBufferAttachment(surface: Surface) bool {
        return surface.attach_changed and surface.pending_buffer != null;
    }

    /// Returns the exact logical extent of the currently committed content.
    pub fn committedSize(surface: Surface) SurfaceSize {
        const buffer = surface.current_buffer orelse return .{ .width = 0, .height = 0 };
        const swaps_axes = switch (surface.current_transform) {
            .@"90", .@"270", .flipped_90, .flipped_270 => true,
            else => false,
        };
        const scale: u32 = @intCast(surface.current_scale);
        const content_size: SurfaceSize = if (swaps_axes)
            .{ .width = buffer.height / scale, .height = buffer.width / scale }
        else
            .{ .width = buffer.width / scale, .height = buffer.height / scale };
        return surface.viewport.current.surfaceSize(content_size);
    }

    /// Returns the logical extent and buffer presence that a commit would
    /// publish, without mutating pending state. Role adapters use this to
    /// enforce configure dimensions before core publication.
    pub fn prospectiveContent(surface: Surface) Error!struct { has_buffer: bool, size: SurfaceSize } {
        const buffer = if (surface.attach_changed) surface.pending_buffer else surface.current_buffer;
        try surface.validateCommit();
        if (buffer == null) return .{ .has_buffer = false, .size = .{ .width = 0, .height = 0 } };
        const content_size = surface.contentSize(buffer).?;
        return .{ .has_buffer = true, .size = surface.viewport.pending.surfaceSize(content_size) };
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
        try surface.viewport.validateCommit(surface.contentSize(buffer));
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
        surface.current_color_description = surface.pending_color_description;
        surface.current_color_representation = surface.pending_color_representation;
        surface.current_content_type = surface.pending_content_type;
        surface.current_presentation_hint = surface.pending_presentation_hint;
        const content_size = surface.contentSize(surface.current_buffer);
        const viewport_state = surface.viewport.publishCommit();
        const upload_damage = canonicalBufferDamage(
            surface.pending_surface_upload_damage,
            surface.pending_buffer_upload_damage,
            surface.current_buffer,
            surface.current_transform,
            surface.current_scale,
            viewport_state,
        );
        const update: Update = .{
            .sequence = surface.sequence,
            .attachment = attachment,
            .surface_damage = surface.pending_surface_damage,
            .buffer_damage = surface.pending_buffer_damage,
            .upload_damage = upload_damage,
            .transform = surface.current_transform,
            .scale = surface.current_scale,
            .offset = surface.pending_offset,
            .viewport = viewport_state,
            .size = viewport_state.surfaceSize(content_size),
            .color_description = surface.current_color_description,
            .color_representation = surface.current_color_representation,
            .content_type = surface.current_content_type,
            .presentation_hint = surface.current_presentation_hint,
            .fifo_set = surface.pending_fifo_set,
            .fifo_wait = surface.pending_fifo_wait,
        };
        surface.pending_buffer = null;
        surface.pending_attach_offset = .{};
        surface.attach_changed = false;
        surface.pending_surface_damage = .{};
        surface.pending_buffer_damage = .{};
        surface.pending_surface_upload_damage = .{};
        surface.pending_buffer_upload_damage = .{};
        surface.pending_offset = .{};
        surface.pending_fifo_set = false;
        surface.pending_fifo_wait = false;
        return update;
    }

    fn contentSize(surface: Surface, buffer: ?Buffer) ?SurfaceSize {
        const value = buffer orelse return null;
        const swaps_axes = switch (surface.pending_transform) {
            .@"90", .@"270", .flipped_90, .flipped_270 => true,
            else => false,
        };
        const width = if (swaps_axes) value.height else value.width;
        const height = if (swaps_axes) value.width else value.height;
        const scale: u32 = @intCast(surface.pending_scale);
        return .{ .width = width / scale, .height = height / scale };
    }

    pub fn validateDestroy(surface: Surface) Error!void {
        try surface.role.validateDestroy();
    }
};

/// Converts `wl_surface.damage` from final surface coordinates back through
/// viewport destination/source, buffer scale, and inverse buffer transform,
/// then combines it with `damage_buffer`. Rectangles are conservatively rounded
/// outward and clipped to the native buffer extent.
fn canonicalBufferDamage(
    surface_damage: UploadDamage,
    buffer_damage: UploadDamage,
    buffer: ?Buffer,
    transform: Transform,
    scale_value: i32,
    viewport_state: ViewportState,
) UploadDamage {
    const value = buffer orelse return .{};
    var result: UploadDamage = .{};
    for (buffer_damage.items()) |damage|
        result.addDamage(clipDamage(damage, value.width, value.height));
    for (surface_damage.items()) |damage| result.addDamage(mapSurfaceDamage(
        damage,
        value,
        transform,
        @intCast(scale_value),
        viewport_state,
    ));
    return result;
}

fn mapSurfaceDamage(
    damage: Damage,
    buffer: Buffer,
    transform: Transform,
    scale: u32,
    viewport_state: ViewportState,
) Damage {
    if (damage.empty) return .{};
    const swaps_axes = transformSwapsAxes(transform);
    const transformed_width: u32 = if (swaps_axes) buffer.height else buffer.width;
    const transformed_height: u32 = if (swaps_axes) buffer.width else buffer.height;
    const content_width = transformed_width / scale;
    const content_height = transformed_height / scale;
    const configured_source = viewport_state.source();
    const source_start_x: i128 = if (configured_source) |source| source.x else 0;
    const source_start_y: i128 = if (configured_source) |source| source.y else 0;
    const source_width: i128 = if (configured_source) |source|
        source.width
    else
        @as(i128, content_width) * viewport.fixed_one;
    const source_height: i128 = if (configured_source) |source|
        source.height
    else
        @as(i128, content_height) * viewport.fixed_one;
    const destination = viewport_state.destination() orelse if (configured_source) |source|
        SurfaceSize{
            .width = @intCast(@divExact(source.width, viewport.fixed_one)),
            .height = @intCast(@divExact(source.height, viewport.fixed_one)),
        }
    else
        SurfaceSize{ .width = content_width, .height = content_height };
    const clipped = clipEdges(
        damage,
        destination.width,
        destination.height,
    ) orelse return .{};

    const source_x = mapInterval(
        clipped[0],
        clipped[2],
        source_start_x,
        source_width,
        destination.width,
    );
    const source_y = mapInterval(
        clipped[1],
        clipped[3],
        source_start_y,
        source_height,
        destination.height,
    );
    const transformed_x = fixedToPixels(source_x, scale, transformed_width);
    const transformed_y = fixedToPixels(source_y, scale, transformed_height);
    return inverseTransformDamage(
        transformed_x,
        transformed_y,
        buffer.width,
        buffer.height,
        transform,
    );
}

fn transformSwapsAxes(transform: Transform) bool {
    return switch (transform) {
        .@"90", .@"270", .flipped_90, .flipped_270 => true,
        else => false,
    };
}

fn clipDamage(damage: Damage, width: u32, height: u32) Damage {
    const edges = clipEdges(damage, width, height) orelse return .{};
    return damageFromEdges(edges[0], edges[1], edges[2], edges[3]);
}

fn clipEdges(damage: Damage, width: u32, height: u32) ?[4]i128 {
    if (damage.empty) return null;
    const left = @max(@as(i128, 0), damage.min_x);
    const top = @max(@as(i128, 0), damage.min_y);
    const right = @min(@as(i128, width), damage.max_x);
    const bottom = @min(@as(i128, height), damage.max_y);
    if (right <= left or bottom <= top) return null;
    return .{ left, top, right, bottom };
}

fn mapInterval(
    start: i128,
    end: i128,
    source_start: i128,
    source_extent: i128,
    destination_extent: u32,
) [2]i128 {
    const denominator: i128 = destination_extent;
    return .{
        source_start + @divFloor(start * source_extent, denominator),
        source_start + divCeil(end * source_extent, denominator),
    };
}

fn fixedToPixels(interval: [2]i128, scale: u32, extent: u32) [2]i128 {
    const one: i128 = viewport.fixed_one;
    return .{
        @max(@as(i128, 0), @divFloor(interval[0] * scale, one)),
        @min(@as(i128, extent), divCeil(interval[1] * scale, one)),
    };
}

fn divCeil(numerator: i128, denominator: i128) i128 {
    return -@divFloor(-numerator, denominator);
}

fn inverseTransformDamage(
    x: [2]i128,
    y: [2]i128,
    width: u32,
    height: u32,
    transform: Transform,
) Damage {
    const w: i128 = width;
    const h: i128 = height;
    const edges: [4]i128 = switch (transform) {
        .normal => .{ x[0], y[0], x[1], y[1] },
        .@"90" => .{ y[0], h - x[1], y[1], h - x[0] },
        .@"180" => .{ w - x[1], h - y[1], w - x[0], h - y[0] },
        .@"270" => .{ w - y[1], x[0], w - y[0], x[1] },
        .flipped => .{ w - x[1], y[0], w - x[0], y[1] },
        .flipped_90 => .{ y[0], x[0], y[1], x[1] },
        .flipped_180 => .{ x[0], h - y[1], x[1], h - y[0] },
        .flipped_270 => .{ w - y[1], h - x[1], w - y[0], h - x[0] },
    };
    return damageFromEdges(edges[0], edges[1], edges[2], edges[3]);
}

fn damageFromEdges(left: i128, top: i128, right: i128, bottom: i128) Damage {
    if (right <= left or bottom <= top) return .{};
    return .{
        .min_x = @intCast(left),
        .min_y = @intCast(top),
        .max_x = @intCast(right),
        .max_y = @intCast(bottom),
        .empty = false,
    };
}

fn unionDamage(destination: *Damage, source: Damage) void {
    if (source.empty) return;
    if (destination.empty) {
        destination.* = source;
        return;
    }
    destination.min_x = @min(destination.min_x, source.min_x);
    destination.min_y = @min(destination.min_y, source.min_y);
    destination.max_x = @max(destination.max_x, source.max_x);
    destination.max_y = @max(destination.max_y, source.max_y);
}

fn overlaps(a: Damage, b: Damage) bool {
    return !a.empty and !b.empty and a.min_x < b.max_x and b.min_x < a.max_x and
        a.min_y < b.max_y and b.min_y < a.max_y;
}

/// Transactional composition of one wl_surface commit with shared state pools
/// and the version-7 content-update scheduler.
pub fn CommitState(comptime Key: type) type {
    return struct {
        pub const Content = struct {
            surface: Update,
            regions: SurfaceRegions.Changes,
            frame_callbacks: ?FrameBatch,
            release_callbacks: ?ReleaseBatch,
            presentation_feedback: ?PresentationFeedbackBatch,
            attachment_lease: ?BufferLease,

            /// Releases callback and import ownership when an unapplied CU is discarded.
            pub fn deinit(content: *Content) void {
                if (content.frame_callbacks) |*batch| batch.deinit();
                if (content.release_callbacks) |*batch| batch.deinit();
                if (content.presentation_feedback) |*batch| batch.deinit();
                if (content.attachment_lease) |*lease| lease.deinit();
                content.frame_callbacks = null;
                content.release_callbacks = null;
                content.presentation_feedback = null;
                content.attachment_lease = null;
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

            pub fn discardFeedbackTo(
                content: *Content,
                pending: *PresentationFeedbackPending,
            ) void {
                if (content.presentation_feedback) |*batch| pending.absorb(batch);
                content.presentation_feedback = null;
                content.deinit();
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
            return commitInner(
                scheduler,
                queue,
                surface,
                regions,
                frames,
                releases,
                null,
                null,
                kind,
                child_dependencies,
                constraints,
            );
        }

        /// Commits an attachment lease into the same content update as its
        /// semantic surface attachment. Every fallible preflight completes
        /// before pending ownership is transferred.
        pub fn commitWithAttachment(
            scheduler: *Scheduler,
            queue: *Scheduler.Queue,
            surface: *Surface,
            regions: *SurfaceRegions,
            frames: *FrameQueue,
            releases: *ReleaseQueue,
            attachment: *AttachmentLeaseState,
            kind: ContentUpdateKind,
            child_dependencies: []const Scheduler.Token,
            constraints: u32,
        ) !Scheduler.Token {
            return commitInner(
                scheduler,
                queue,
                surface,
                regions,
                frames,
                releases,
                null,
                attachment,
                kind,
                child_dependencies,
                constraints,
            );
        }

        pub fn commitWithAttachmentAndFeedback(
            scheduler: *Scheduler,
            queue: *Scheduler.Queue,
            surface: *Surface,
            regions: *SurfaceRegions,
            frames: *FrameQueue,
            releases: *ReleaseQueue,
            feedback: *PresentationFeedbackPending,
            attachment: *AttachmentLeaseState,
            kind: ContentUpdateKind,
            child_dependencies: []const Scheduler.Token,
            constraints: u32,
        ) !Scheduler.Token {
            return commitInner(
                scheduler,
                queue,
                surface,
                regions,
                frames,
                releases,
                feedback,
                attachment,
                kind,
                child_dependencies,
                constraints,
            );
        }

        fn commitInner(
            scheduler: *Scheduler,
            queue: *Scheduler.Queue,
            surface: *Surface,
            regions: *SurfaceRegions,
            frames: *FrameQueue,
            releases: *ReleaseQueue,
            feedback: ?*PresentationFeedbackPending,
            attachment: ?*AttachmentLeaseState,
            kind: ContentUpdateKind,
            child_dependencies: []const Scheduler.Token,
            constraints: u32,
        ) !Scheduler.Token {
            try surface.validateCommit();
            if (attachment) |state| try state.validateCommit(
                surface.attach_changed,
                surface.hasPendingBufferAttachment(),
            );
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
                .presentation_feedback = if (feedback) |pending| pending.publishCommit() else null,
                .attachment_lease = if (attachment) |state| state.publishCommit() else null,
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
    var display_p3 = color.Description.srgb;
    display_p3.primaries.red = .{ .x = 0.68, .y = 0.32 };
    display_p3.primaries.green = .{ .x = 0.265, .y = 0.69 };
    try surface.setColorDescription(display_p3);
    surface.setColorRepresentation(.{ .alpha_mode = .straight });

    const first = try surface.commit();
    try std.testing.expectEqual(@as(u64, 1), first.sequence);
    try std.testing.expectEqual(buffer, first.attachment.?.buffer.?);
    try std.testing.expectEqual(Point{ .x = 2, .y = -3 }, first.attachment.?.offset);
    try std.testing.expectEqual(@as(i64, 8), first.surface_damage.min_x);
    try std.testing.expectEqual(@as(i64, 32), first.surface_damage.max_y);
    try std.testing.expectEqual(Transform.@"270", first.transform);
    try std.testing.expectEqual(@as(i32, 2), first.scale);
    try std.testing.expectEqual(Point{ .x = 7, .y = -8 }, first.offset);
    try std.testing.expectEqual(display_p3, first.color_description);
    try std.testing.expectEqual(color.AlphaMode.straight, first.color_representation.alpha_mode);

    const second = try surface.commit();
    try std.testing.expectEqual(@as(u64, 2), second.sequence);
    try std.testing.expectEqual(@as(?Attachment, null), second.attachment);
    try std.testing.expect(second.surface_damage.empty);
    try std.testing.expect(second.buffer_damage.empty);
    try std.testing.expectEqual(Transform.@"270", second.transform);
    try std.testing.expectEqual(@as(i32, 2), second.scale);
    try std.testing.expectEqual(Point{}, second.offset);
    try std.testing.expectEqual(display_p3, second.color_description);
    try std.testing.expectEqual(color.AlphaMode.straight, second.color_representation.alpha_mode);
    try std.testing.expectEqual(buffer, surface.current_buffer.?);
}

test "surface content type is double buffered and preserves unknown values" {
    var surface: Surface = .{};

    surface.setContentType(77);
    const unknown = try surface.commit();
    try std.testing.expectEqual(@as(u32, 77), unknown.content_type);
    try std.testing.expectEqual(@as(u32, 77), surface.current_content_type);

    surface.setContentType(3);
    try std.testing.expectEqual(@as(u32, 77), unknown.content_type);
    try std.testing.expectEqual(@as(u32, 77), surface.current_content_type);
    const game = try surface.commit();
    try std.testing.expectEqual(@as(u32, 3), game.content_type);

    surface.setContentType(0);
    const cleared = try surface.commit();
    try std.testing.expectEqual(@as(u32, 0), cleared.content_type);
    try std.testing.expectEqual(@as(u32, 0), surface.current_content_type);
}

test "surface presentation hint is double buffered" {
    var surface: Surface = .{};

    surface.setPresentationHint(.async);
    try std.testing.expectEqual(PresentationHint.vsync, surface.current_presentation_hint);
    const asynchronous = try surface.commit();
    try std.testing.expectEqual(PresentationHint.async, asynchronous.presentation_hint);
    try std.testing.expectEqual(PresentationHint.async, surface.current_presentation_hint);

    surface.setPresentationHint(.vsync);
    try std.testing.expectEqual(PresentationHint.async, asynchronous.presentation_hint);
    try std.testing.expectEqual(PresentationHint.async, surface.current_presentation_hint);
    const synchronized = try surface.commit();
    try std.testing.expectEqual(PresentationHint.vsync, synchronized.presentation_hint);
}

test "surface FIFO requests are one-shot commit state" {
    var surface: Surface = .{};

    surface.setFifoBarrier();
    surface.setFifoBarrier();
    surface.waitFifoBarrier();
    const constrained = try surface.commit();
    try std.testing.expect(constrained.fifo_set);
    try std.testing.expect(constrained.fifo_wait);

    const next = try surface.commit();
    try std.testing.expect(!next.fifo_set);
    try std.testing.expect(!next.fifo_wait);
    try std.testing.expect(constrained.fifo_set);
    try std.testing.expect(constrained.fifo_wait);
}

test "surface viewport validates transformed and scaled content atomically" {
    var surface: Surface = .{};
    const buffer: Buffer = .{
        .handle = .{ .id = 9, .generation = 3 },
        .width = 20,
        .height = 12,
    };
    try surface.attach(7, buffer, 0, 0);
    try surface.setTransform(1);
    try surface.setScale(2);
    try surface.viewport.setSource(256, 512, 1024, 1536);
    try surface.viewport.setDestination(8, 12);

    const update = try surface.commit();
    try std.testing.expectEqual(SurfaceSize{ .width = 8, .height = 12 }, update.size);
    try std.testing.expectEqual(surface.viewport.current, update.viewport);

    try surface.viewport.setDestination(-1, -1);
    try surface.viewport.setSource(0, 0, 257, 256);
    try std.testing.expectError(error.InvalidSize, surface.commit());
    try std.testing.expectEqual(@as(u64, 1), surface.sequence);
    try std.testing.expectEqual(SurfaceSize{ .width = 8, .height = 12 }, surface.viewport.current.surfaceSize(.{ .width = 6, .height = 10 }));

    try surface.viewport.setDestination(2, 1);
    try surface.viewport.setSource(0, 0, 1537, 256);
    try std.testing.expectError(error.OutOfBuffer, surface.commit());
    try std.testing.expectEqual(@as(u64, 1), surface.sequence);

    surface.viewport.clear();
    const cleared = try surface.commit();
    try std.testing.expectEqual(SurfaceSize{ .width = 6, .height = 10 }, cleared.size);
}

test "surface commit canonicalizes upload damage through every buffer transform" {
    const expected = [_]Damage{
        damageRect(0, 0, 1, 1),
        damageRect(0, 2, 1, 1),
        damageRect(3, 2, 1, 1),
        damageRect(3, 0, 1, 1),
        damageRect(3, 0, 1, 1),
        damageRect(0, 0, 1, 1),
        damageRect(0, 2, 1, 1),
        damageRect(3, 2, 1, 1),
    };
    for (expected, 0..) |want, transform| {
        var surface: Surface = .{};
        try surface.attach(7, .{
            .handle = .{ .id = 9, .generation = 3 },
            .width = 4,
            .height = 3,
        }, 0, 0);
        try surface.setTransform(@intCast(transform));
        surface.damage(0, 0, 1, 1);
        const update = try surface.commit();
        try expectUploadDamage(&.{want}, update.upload_damage);
    }
}

test "surface commit maps viewport damage outward and unions clipped buffer damage" {
    var surface: Surface = .{};
    try surface.attach(7, .{
        .handle = .{ .id = 9, .generation = 3 },
        .width = 20,
        .height = 12,
    }, 0, 0);
    try surface.setTransform(1);
    try surface.setScale(2);
    try surface.viewport.setSource(256, 512, 1024, 1536);
    try surface.viewport.setDestination(8, 12);
    surface.damage(2, 2, 2, 2);
    surface.damageBuffer(13, -2, 10, 3);

    const update = try surface.commit();
    try expectUploadDamage(&.{
        damageRect(13, 0, 7, 1),
        damageRect(6, 6, 2, 2),
    }, update.upload_damage);
    try std.testing.expectEqual(damageRect(2, 2, 2, 2), update.surface_damage);
    try std.testing.expectEqual(damageRect(13, -2, 10, 3), update.buffer_damage);
}

test "surface commit conservatively rounds fractional viewport upload damage" {
    var surface: Surface = .{};
    try surface.attach(7, .{
        .handle = .{ .id = 9, .generation = 3 },
        .width = 4,
        .height = 2,
    }, 0, 0);
    try surface.viewport.setSource(128, 0, 384, 256);
    try surface.viewport.setDestination(3, 1);
    surface.damage(1, 0, 1, 1);

    const update = try surface.commit();
    try expectUploadDamage(&.{damageRect(1, 0, 1, 1)}, update.upload_damage);
}

test "surface commit maps damage for buffers wider than viewport fixed point" {
    var surface: Surface = .{};
    try surface.attach(7, .{
        .handle = .{ .id = 9, .generation = 3 },
        .width = 8_388_608,
        .height = 1,
    }, 0, 0);
    surface.damage(0, 0, 1, 1);

    const update = try surface.commit();
    try expectUploadDamage(&.{damageRect(0, 0, 1, 1)}, update.upload_damage);
}

test "surface commit preserves sparse upload rectangles and bounds overflow" {
    var surface: Surface = .{};
    try surface.attach(7, .{
        .handle = .{ .id = 9, .generation = 3 },
        .width = 1920,
        .height = 1200,
    }, 0, 0);
    surface.damageBuffer(32, 32, 32, 32);
    surface.damageBuffer(1856, 1136, 32, 32);
    const sparse = try surface.commit();
    try expectUploadDamage(&.{
        damageRect(32, 32, 32, 32),
        damageRect(1856, 1136, 32, 32),
    }, sparse.upload_damage);

    for (0..upload_damage_rect_capacity + 1) |index|
        surface.damageBuffer(@intCast(index * 2), 0, 1, 1);
    const bounded = try surface.commit();
    try expectUploadDamage(&.{damageRect(0, 0, 17, 1)}, bounded.upload_damage);
}

test "surface upload damage merges transitive overlap" {
    var damage: UploadDamage = .{};
    damage.addDamage(damageRect(0, 0, 10, 10));
    damage.addDamage(damageRect(20, 5, 10, 10));
    damage.addDamage(damageRect(5, 11, 20, 9));
    try expectUploadDamage(&.{damageRect(0, 0, 30, 20)}, damage);
}

fn damageRect(x: i64, y: i64, width: i64, height: i64) Damage {
    return .{
        .min_x = x,
        .min_y = y,
        .max_x = x + width,
        .max_y = y + height,
        .empty = false,
    };
}

fn expectUploadDamage(expected: []const Damage, actual: UploadDamage) !void {
    try std.testing.expectEqual(expected.len, actual.count);
    for (expected, actual.items()) |want, value|
        try std.testing.expectEqual(want, value);
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

    const TestImports = buffer_import.Registry(u8);
    const Dispose = struct {
        fn backing(_: ?*anyopaque, _: u8) void {}
    };
    var imports = try TestImports.init(std.testing.allocator, 1, null, Dispose.backing);
    defer imports.deinit(std.testing.allocator);
    var attachment_lease: AttachmentLeaseState = .{};
    defer attachment_lease.deinit();
    try surface.attach(7, .{
        .handle = .{ .id = 3, .generation = 1 },
        .width = 3,
        .height = 2,
    }, 0, 0);
    attachment_lease.attach(try imports.acquire(1));
    try surface.setScale(2);
    try std.testing.expectError(error.InvalidSize, State.commitWithAttachment(
        &scheduler,
        &queue,
        &surface,
        &regions,
        &frames,
        &releases,
        &attachment_lease,
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
    try std.testing.expect(attachment_lease.pending != null);
    try std.testing.expectEqual(@as(usize, 0), imports.available());
}

test "discarding an unapplied transactional CU releases callback batches" {
    const State = CommitState(objects.Handle);
    const TestImports = buffer_import.Registry(u8);
    var disposed = false;
    const Dispose = struct {
        fn backing(context: ?*anyopaque, _: u8) void {
            const value: *bool = @ptrCast(@alignCast(context.?));
            value.* = true;
        }
    };
    var imports = try TestImports.init(std.testing.allocator, 1, &disposed, Dispose.backing);
    defer imports.deinit(std.testing.allocator);
    var attachment_lease: AttachmentLeaseState = .{};
    defer attachment_lease.deinit();
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
    attachment_lease.attach(try imports.acquire(1));
    try frames.addPending(.{ .id = 4, .generation = 1 });
    try releases.request(.{ .id = 5, .generation = 1 });
    _ = try State.commitWithAttachment(
        &scheduler,
        &queue,
        &surface,
        &regions,
        &frames,
        &releases,
        &attachment_lease,
        .sync,
        &.{},
        0,
    );
    State.deinitQueue(&queue);
    try std.testing.expectEqual(@as(usize, 1), frame_pool.available());
    try std.testing.expectEqual(@as(usize, 1), release_pool.available());
    try std.testing.expect(disposed);
    try std.testing.expectEqual(@as(usize, 1), imports.available());
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
