//! Narrow, replaceable libdrm atomic-commit boundary. Requests and mode blobs
//! are created outside Ouro's commit/completion turns and contain no borrowed
//! libdrm pointers. Event dispatch is single-thread serialized from bytes read
//! by the runtime's shared io_uring.

const std = @import("std");
const drm = @import("manager.zig");

const c = @cImport({
    @cInclude("xf86drm.h");
    @cInclude("xf86drmMode.h");
});

pub const Request = *anyopaque;

pub const CommitFlags = packed struct(u4) {
    test_only: bool = false,
    allow_modeset: bool = false,
    nonblock: bool = false,
    page_flip_event: bool = false,
};

pub const FlipCallback = *const fn (
    userdata: *anyopaque,
    sequence: u32,
    seconds: u32,
    microseconds: u32,
    crtc_id: u32,
) callconv(.c) void;

pub const Platform = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        create_blob: *const fn (*anyopaque, std.posix.fd_t, drm.Mode) anyerror!u32,
        create_property_blob: *const fn (*anyopaque, std.posix.fd_t, []const u8) anyerror!u32,
        destroy_blob: *const fn (*anyopaque, std.posix.fd_t, u32) anyerror!void,
        create_request: *const fn (*anyopaque) anyerror!Request,
        destroy_request: *const fn (*anyopaque, Request) void,
        reset_request: *const fn (*anyopaque, Request) void,
        add_property: *const fn (*anyopaque, Request, u32, u32, u64) anyerror!void,
        commit: *const fn (*anyopaque, std.posix.fd_t, Request, CommitFlags, ?*anyopaque) anyerror!void,
        handle_events: *const fn (*anyopaque, []const u8, FlipCallback) anyerror!void,
    };

    pub fn createBlob(self: Platform, fd: std.posix.fd_t, mode: drm.Mode) !u32 {
        return self.vtable.create_blob(self.context, fd, mode);
    }

    pub fn createPropertyBlob(self: Platform, fd: std.posix.fd_t, bytes: []const u8) !u32 {
        if (bytes.len == 0) return error.InvalidPropertyBlob;
        return self.vtable.create_property_blob(self.context, fd, bytes);
    }

    pub fn destroyBlob(self: Platform, fd: std.posix.fd_t, id: u32) !void {
        return self.vtable.destroy_blob(self.context, fd, id);
    }

    pub fn createRequest(self: Platform) !Request {
        return self.vtable.create_request(self.context);
    }

    pub fn destroyRequest(self: Platform, request: Request) void {
        self.vtable.destroy_request(self.context, request);
    }

    pub fn resetRequest(self: Platform, request: Request) void {
        self.vtable.reset_request(self.context, request);
    }

    pub fn addProperty(self: Platform, request: Request, object: u32, property: u32, value: u64) !void {
        if (object == 0 or property == 0) return error.InvalidProperty;
        return self.vtable.add_property(self.context, request, object, property, value);
    }

    pub fn commit(
        self: Platform,
        fd: std.posix.fd_t,
        request: Request,
        flags: CommitFlags,
        userdata: ?*anyopaque,
    ) !void {
        return self.vtable.commit(self.context, fd, request, flags, userdata);
    }

    pub fn handleEvents(self: Platform, bytes: []const u8, callback: FlipCallback) !void {
        return self.vtable.handle_events(self.context, bytes, callback);
    }
};

var real_context: u8 = 0;
pub const real: Platform = .{ .context = &real_context, .vtable = &real_vtable };

const real_vtable: Platform.VTable = .{
    .create_blob = realCreateBlob,
    .create_property_blob = realCreatePropertyBlob,
    .destroy_blob = realDestroyBlob,
    .create_request = realCreateRequest,
    .destroy_request = realDestroyRequest,
    .reset_request = realResetRequest,
    .add_property = realAddProperty,
    .commit = realCommit,
    .handle_events = realHandleEvents,
};

fn realCreateBlob(_: *anyopaque, fd: std.posix.fd_t, mode: drm.Mode) !u32 {
    const native = nativeMode(mode);
    var id: u32 = 0;
    if (c.drmModeCreatePropertyBlob(fd, &native, @sizeOf(c.drmModeModeInfo), &id) != 0 or id == 0)
        return error.CreateModeBlobFailed;
    return id;
}

fn realCreatePropertyBlob(_: *anyopaque, fd: std.posix.fd_t, bytes: []const u8) !u32 {
    var id: u32 = 0;
    if (c.drmModeCreatePropertyBlob(fd, bytes.ptr, bytes.len, &id) != 0 or id == 0)
        return error.CreatePropertyBlobFailed;
    return id;
}

fn realDestroyBlob(_: *anyopaque, fd: std.posix.fd_t, id: u32) !void {
    if (c.drmModeDestroyPropertyBlob(fd, id) != 0) return error.DestroyModeBlobFailed;
}

fn realCreateRequest(_: *anyopaque) !Request {
    return @ptrCast(c.drmModeAtomicAlloc() orelse return error.CreateAtomicRequestFailed);
}

fn realDestroyRequest(_: *anyopaque, request: Request) void {
    c.drmModeAtomicFree(@ptrCast(@alignCast(request)));
}

fn realResetRequest(_: *anyopaque, request: Request) void {
    c.drmModeAtomicSetCursor(@ptrCast(@alignCast(request)), 0);
}

fn realAddProperty(_: *anyopaque, request: Request, object: u32, property: u32, value: u64) !void {
    if (c.drmModeAtomicAddProperty(@ptrCast(@alignCast(request)), object, property, value) < 0)
        return error.AddAtomicPropertyFailed;
}

fn realCommit(
    _: *anyopaque,
    fd: std.posix.fd_t,
    request: Request,
    flags: CommitFlags,
    userdata: ?*anyopaque,
) !void {
    var native_flags: u32 = 0;
    if (flags.test_only) native_flags |= c.DRM_MODE_ATOMIC_TEST_ONLY;
    if (flags.allow_modeset) native_flags |= c.DRM_MODE_ATOMIC_ALLOW_MODESET;
    if (flags.nonblock) native_flags |= c.DRM_MODE_ATOMIC_NONBLOCK;
    if (flags.page_flip_event) native_flags |= c.DRM_MODE_PAGE_FLIP_EVENT;
    if (c.drmModeAtomicCommit(fd, @ptrCast(@alignCast(request)), native_flags, userdata) != 0)
        return error.AtomicCommitFailed;
}

fn realHandleEvents(_: *anyopaque, bytes: []const u8, callback: FlipCallback) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (bytes.len - offset < @sizeOf(c.struct_drm_event)) return error.TruncatedDrmEvent;
        const header = std.mem.bytesToValue(
            c.struct_drm_event,
            bytes[offset..][0..@sizeOf(c.struct_drm_event)],
        );
        const length: usize = @intCast(header.length);
        if (length < @sizeOf(c.struct_drm_event) or length > bytes.len - offset)
            return error.InvalidDrmEvent;
        if (header.type == c.DRM_EVENT_FLIP_COMPLETE) {
            if (length < @sizeOf(c.struct_drm_event_vblank)) return error.InvalidDrmEvent;
            const event = std.mem.bytesToValue(
                c.struct_drm_event_vblank,
                bytes[offset..][0..@sizeOf(c.struct_drm_event_vblank)],
            );
            if (event.user_data != 0) {
                const userdata: *anyopaque = @ptrFromInt(event.user_data);
                callback(userdata, event.sequence, event.tv_sec, event.tv_usec, event.crtc_id);
            }
        }
        offset += length;
    }
}

fn nativeMode(mode: drm.Mode) c.drmModeModeInfo {
    var result: c.drmModeModeInfo = std.mem.zeroes(c.drmModeModeInfo);
    result.clock = mode.clock;
    result.hdisplay = mode.hdisplay;
    result.hsync_start = mode.hsync_start;
    result.hsync_end = mode.hsync_end;
    result.htotal = mode.htotal;
    result.hskew = mode.hskew;
    result.vdisplay = mode.vdisplay;
    result.vsync_start = mode.vsync_start;
    result.vsync_end = mode.vsync_end;
    result.vtotal = mode.vtotal;
    result.vscan = mode.vscan;
    result.vrefresh = mode.vrefresh;
    result.flags = mode.flags;
    result.type = mode.mode_type;
    @memcpy(result.name[0..mode.name_len], mode.name[0..mode.name_len]);
    return result;
}

test "kms: atomic flag records remain deterministic and independent" {
    const test_flags: CommitFlags = .{ .test_only = true, .allow_modeset = true };
    const real_flags: CommitFlags = .{ .allow_modeset = true, .nonblock = true, .page_flip_event = true };
    try std.testing.expect(test_flags.test_only and !test_flags.nonblock);
    try std.testing.expect(!real_flags.test_only and real_flags.page_flip_event);
}

test "kms: DRM event bytes dispatch exact page-flip facts" {
    const Callback = struct {
        var called = false;
        var sequence: u32 = 0;

        fn handle(
            _: *anyopaque,
            value: u32,
            seconds: u32,
            microseconds: u32,
            crtc_id: u32,
        ) callconv(.c) void {
            called = seconds == 7 and microseconds == 11 and crtc_id == 13;
            sequence = value;
        }
    };
    Callback.called = false;
    Callback.sequence = 0;
    var userdata: u8 = 0;
    var event: c.struct_drm_event_vblank = std.mem.zeroes(c.struct_drm_event_vblank);
    event.base.type = c.DRM_EVENT_FLIP_COMPLETE;
    event.base.length = @sizeOf(c.struct_drm_event_vblank);
    event.user_data = @intFromPtr(&userdata);
    event.tv_sec = 7;
    event.tv_usec = 11;
    event.sequence = 17;
    event.crtc_id = 13;

    try real.handleEvents(std.mem.asBytes(&event), Callback.handle);
    try std.testing.expect(Callback.called);
    try std.testing.expectEqual(@as(u32, 17), Callback.sequence);
    try std.testing.expectError(error.TruncatedDrmEvent, real.handleEvents(&.{0}, Callback.handle));
}
