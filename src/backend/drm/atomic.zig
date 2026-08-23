//! Narrow, replaceable libdrm atomic-commit boundary. Requests and mode blobs
//! are created outside Ouro's commit/completion turns and contain no borrowed
//! libdrm pointers. Event dispatch is single-thread serialized.

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
        destroy_blob: *const fn (*anyopaque, std.posix.fd_t, u32) anyerror!void,
        create_request: *const fn (*anyopaque) anyerror!Request,
        destroy_request: *const fn (*anyopaque, Request) void,
        reset_request: *const fn (*anyopaque, Request) void,
        add_property: *const fn (*anyopaque, Request, u32, u32, u64) anyerror!void,
        commit: *const fn (*anyopaque, std.posix.fd_t, Request, CommitFlags, ?*anyopaque) anyerror!void,
        handle_events: *const fn (*anyopaque, std.posix.fd_t, FlipCallback) anyerror!void,
    };

    pub fn createBlob(self: Platform, fd: std.posix.fd_t, mode: drm.Mode) !u32 {
        return self.vtable.create_blob(self.context, fd, mode);
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

    pub fn handleEvents(self: Platform, fd: std.posix.fd_t, callback: FlipCallback) !void {
        return self.vtable.handle_events(self.context, fd, callback);
    }
};

const RealContext = struct { callback: FlipCallback = undefined };
var real_context: RealContext = .{};
pub const real: Platform = .{ .context = &real_context, .vtable = &real_vtable };

const real_vtable: Platform.VTable = .{
    .create_blob = realCreateBlob,
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

fn realHandleEvents(context: *anyopaque, fd: std.posix.fd_t, callback: FlipCallback) !void {
    const self: *RealContext = @ptrCast(@alignCast(context));
    self.callback = callback;
    var event_context: c.drmEventContext = std.mem.zeroes(c.drmEventContext);
    event_context.version = 3;
    event_context.page_flip_handler2 = realPageFlip;
    if (c.drmHandleEvent(fd, &event_context) != 0) return error.HandleDrmEventFailed;
}

fn realPageFlip(
    _: c_int,
    sequence: c_uint,
    seconds: c_uint,
    microseconds: c_uint,
    crtc_id: c_uint,
    userdata: ?*anyopaque,
) callconv(.c) void {
    real_context.callback(userdata orelse return, sequence, seconds, microseconds, crtc_id);
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
