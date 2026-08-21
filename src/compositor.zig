//! Allocation-free protocol-independent compositor surface state.

const std = @import("std");
const objects = @import("objects.zig");

pub const RegionPool = @import("region.zig").Pool;
pub const Region = @import("region.zig").Region;
pub const RegionRectangle = @import("region.zig").Rectangle;
pub const SurfaceRegions = @import("region.zig").SurfaceRegions;
pub const FramePool = @import("frame.zig").Pool;
pub const FrameQueue = @import("frame.zig").Queue;
pub const SubsurfaceGraph = @import("subsurface.zig").Graph;
pub const ReleasePool = @import("release.zig").Pool;
pub const ReleaseQueue = @import("release.zig").Queue;
pub const ReleaseBatch = @import("release.zig").Batch;

pub const Error = error{
    InvalidRole,
    WrongRole,
    RoleObjectActive,
    DefunctRoleObject,
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

pub const Attachment = struct {
    buffer: ?objects.Handle,
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
    current_buffer: ?objects.Handle = null,
    current_transform: Transform = .normal,
    current_scale: i32 = 1,

    pending_buffer: ?objects.Handle = null,
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
        buffer: ?objects.Handle,
        x: i32,
        y: i32,
    ) Error!void {
        if (version >= 5 and (x != 0 or y != 0)) return error.InvalidOffset;
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

    /// Atomically applies persistent scalar state and extracts one-shot state.
    pub fn commit(surface: *Surface) Update {
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

test "surface commits persistent and one-shot state atomically" {
    var surface: Surface = .{};
    const buffer: objects.Handle = .{ .id = 9, .generation = 3 };
    try surface.attach(4, buffer, 2, -3);
    surface.damage(10, 20, 3, 4);
    surface.damage(8, 30, 4, 2);
    surface.damageBuffer(-2, -4, 5, 6);
    try surface.setTransform(3);
    try surface.setScale(2);
    surface.setOffset(7, -8);

    const first = surface.commit();
    try std.testing.expectEqual(@as(u64, 1), first.sequence);
    try std.testing.expectEqual(buffer, first.attachment.?.buffer.?);
    try std.testing.expectEqual(Point{ .x = 2, .y = -3 }, first.attachment.?.offset);
    try std.testing.expectEqual(@as(i64, 8), first.surface_damage.min_x);
    try std.testing.expectEqual(@as(i64, 32), first.surface_damage.max_y);
    try std.testing.expectEqual(Transform.@"270", first.transform);
    try std.testing.expectEqual(@as(i32, 2), first.scale);
    try std.testing.expectEqual(Point{ .x = 7, .y = -8 }, first.offset);

    const second = surface.commit();
    try std.testing.expectEqual(@as(u64, 2), second.sequence);
    try std.testing.expectEqual(@as(?Attachment, null), second.attachment);
    try std.testing.expect(second.surface_damage.empty);
    try std.testing.expect(second.buffer_damage.empty);
    try std.testing.expectEqual(Transform.@"270", second.transform);
    try std.testing.expectEqual(@as(i32, 2), second.scale);
    try std.testing.expectEqual(Point{}, second.offset);
    try std.testing.expectEqual(buffer, surface.current_buffer.?);
}

test "surface validates offsets scale transform and permanent roles" {
    var surface: Surface = .{};
    try std.testing.expectError(error.InvalidOffset, surface.attach(5, null, 1, 0));
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
