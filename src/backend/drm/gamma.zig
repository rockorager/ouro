//! Replaceable legacy DRM gamma boundary and exact-original restoration owner.
const std = @import("std");
const c = @cImport({
    @cInclude("xf86drmMode.h");
});

pub const Platform = struct {
    context: *anyopaque,
    size_fn: *const fn (*anyopaque, std.posix.fd_t, u32) anyerror!u32,
    get_fn: *const fn (*anyopaque, std.posix.fd_t, u32, []u16, []u16, []u16) anyerror!void,
    set_fn: *const fn (*anyopaque, std.posix.fd_t, u32, []const u16, []const u16, []const u16) anyerror!void,
};

var real_context: u8 = 0;
pub const real: Platform = .{ .context = &real_context, .size_fn = realSize, .get_fn = realGet, .set_fn = realSet };

fn realSize(_: *anyopaque, fd: std.posix.fd_t, crtc: u32) !u32 {
    const value = c.drmModeGetCrtc(fd, crtc) orelse return error.Unsupported;
    defer c.drmModeFreeCrtc(value);
    if (value.*.gamma_size <= 0) return error.Unsupported;
    return @intCast(value.*.gamma_size);
}
fn realGet(_: *anyopaque, fd: std.posix.fd_t, crtc: u32, r: []u16, g: []u16, b: []u16) !void {
    if (c.drmModeCrtcGetGamma(fd, crtc, @intCast(r.len), r.ptr, g.ptr, b.ptr) != 0) return error.ReadFailed;
}
fn realSet(_: *anyopaque, fd: std.posix.fd_t, crtc: u32, r: []const u16, g: []const u16, b: []const u16) !void {
    if (c.drmModeCrtcSetGamma(fd, crtc, @intCast(r.len), @constCast(r.ptr), @constCast(g.ptr), @constCast(b.ptr)) != 0) return error.WriteFailed;
}

pub const Owner = struct {
    allocator: std.mem.Allocator,
    platform: Platform,
    fd: std.posix.fd_t,
    crtc: u32,
    generation: u32,
    original: ?[]u16 = null,
    dirty: bool = false,

    pub fn size(self: *Owner) !u32 {
        return self.platform.size_fn(self.platform.context, self.fd, self.crtc);
    }
    pub fn apply(self: *Owner, generation: u32, ramps: []const u16) !void {
        if (generation != self.generation) return error.StaleGeneration;
        const n: usize = try std.math.divExact(usize, ramps.len, 3);
        if (n == 0 or n != try self.size()) return error.InvalidGammaSize;
        if (self.original == null) {
            const saved = try self.allocator.alloc(u16, ramps.len);
            errdefer self.allocator.free(saved);
            try self.platform.get_fn(self.platform.context, self.fd, self.crtc, saved[0..n], saved[n..][0..n], saved[2 * n ..]);
            self.original = saved;
        }
        try self.platform.set_fn(self.platform.context, self.fd, self.crtc, ramps[0..n], ramps[n..][0..n], ramps[2 * n ..]);
        self.dirty = true;
    }
    pub fn restore(self: *Owner, generation: u32) !void {
        if (!self.dirty) return;
        if (generation != self.generation) return error.StaleGeneration;
        const saved = self.original.?;
        const n = saved.len / 3;
        try self.platform.set_fn(self.platform.context, self.fd, self.crtc, saved[0..n], saved[n..][0..n], saved[2 * n ..]);
        self.dirty = false;
    }
    pub fn deinit(self: *Owner) void {
        std.debug.assert(!self.dirty);
        if (self.original) |value| self.allocator.free(value);
        self.* = undefined;
    }
};

test "drm gamma: snapshot is exact and failed restore remains retryable" {
    const Fake = struct {
        original: [3]u16 = .{ 7, 8, 9 },
        current: [3]u16 = .{ 7, 8, 9 },
        fail: bool = false,
        gets: usize = 0,
        fn size(_: *anyopaque, _: std.posix.fd_t, _: u32) !u32 {
            return 1;
        }
        fn get(ctx: *anyopaque, _: std.posix.fd_t, _: u32, r: []u16, g: []u16, b: []u16) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.gets += 1;
            r[0] = self.original[0];
            g[0] = self.original[1];
            b[0] = self.original[2];
        }
        fn set(ctx: *anyopaque, _: std.posix.fd_t, _: u32, r: []const u16, g: []const u16, b: []const u16) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.fail) return error.Failed;
            self.current = .{ r[0], g[0], b[0] };
        }
    };
    var fake = Fake{};
    var owner = Owner{ .allocator = std.testing.allocator, .platform = .{ .context = &fake, .size_fn = Fake.size, .get_fn = Fake.get, .set_fn = Fake.set }, .fd = -1, .crtc = 4, .generation = 2 };
    defer owner.deinit();
    try owner.apply(2, &.{ 1, 2, 3 });
    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 3 }, &fake.current);
    try std.testing.expectEqual(@as(usize, 1), fake.gets);
    try std.testing.expectError(error.StaleGeneration, owner.apply(3, &.{ 4, 5, 6 }));
    fake.fail = true;
    try std.testing.expectError(error.Failed, owner.restore(2));
    try std.testing.expect(owner.dirty);
    fake.fail = false;
    try owner.restore(2);
    try std.testing.expectEqualSlices(u16, &fake.original, &fake.current);
}
