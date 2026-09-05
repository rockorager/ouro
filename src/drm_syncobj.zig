//! Owned Linux DRM syncobj timelines and points.
//!
//! Protocol resources retain `Timeline` references, while committed points
//! retain their own references independently. The device must remain at a
//! stable address until every imported timeline has been released.

const std = @import("std");
const linux = std.os.linux;

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("xf86drm.h");
    @cInclude("libdrm/drm.h");
    @cInclude("linux/dma-buf.h");
    @cInclude("sys/ioctl.h");
});

pub const Error = std.mem.Allocator.Error || error{
    Unsupported,
    DuplicateFailed,
    InvalidTimeline,
    CreateFailed,
    TransferFailed,
    Unavailable,
    ExportFailed,
    ImportFailed,
    SignalFailed,
    WaitFailed,
};

pub const Device = struct {
    allocator: std.mem.Allocator,
    fd: linux.fd_t,
    timeline_count: usize = 0,

    /// Duplicates a DRM descriptor and verifies both binary and timeline
    /// syncobj capabilities. The duplicate is always close-on-exec.
    pub fn init(allocator: std.mem.Allocator, source_fd: linux.fd_t) Error!Device {
        const duplicated = linux.fcntl(source_fd, linux.F.DUPFD_CLOEXEC, 0);
        if (linux.errno(duplicated) != .SUCCESS) return error.DuplicateFailed;
        const fd: linux.fd_t = @intCast(duplicated);
        errdefer _ = linux.close(fd);
        if (!hasCapability(fd, c.DRM_CAP_SYNCOBJ) or
            !hasCapability(fd, c.DRM_CAP_SYNCOBJ_TIMELINE))
            return error.Unsupported;
        return .{ .allocator = allocator, .fd = fd };
    }

    pub fn deinit(device: *Device) void {
        std.debug.assert(device.timeline_count == 0);
        _ = linux.close(device.fd);
        device.* = undefined;
    }

    /// Imports a syncobj FD. The caller retains ownership of `timeline_fd`.
    pub fn importTimeline(device: *Device, timeline_fd: linux.fd_t) Error!*Timeline {
        var handle: u32 = 0;
        if (c.drmSyncobjFDToHandle(device.fd, timeline_fd, &handle) != 0)
            return error.InvalidTimeline;
        errdefer _ = c.drmSyncobjDestroy(device.fd, handle);
        const timeline = try device.allocator.create(Timeline);
        timeline.* = .{ .device = device, .handle = handle };
        device.timeline_count += 1;
        return timeline;
    }

    fn createBinary(device: *Device) Error!u32 {
        var handle: u32 = 0;
        if (c.drmSyncobjCreate(device.fd, 0, &handle) != 0)
            return error.CreateFailed;
        return handle;
    }
};

pub const Timeline = struct {
    device: *Device,
    handle: u32,
    references: usize = 1,

    pub fn reference(timeline: *Timeline) Error!void {
        timeline.references = std.math.add(usize, timeline.references, 1) catch
            return error.OutOfMemory;
    }

    pub fn unreference(timeline: *Timeline) void {
        std.debug.assert(timeline.references != 0);
        timeline.references -= 1;
        if (timeline.references != 0) return;
        const device = timeline.device;
        std.debug.assert(c.drmSyncobjDestroy(device.fd, timeline.handle) == 0);
        std.debug.assert(device.timeline_count != 0);
        device.timeline_count -= 1;
        device.allocator.destroy(timeline);
    }

    pub fn point(timeline: *Timeline, value: u64) Error!Point {
        try timeline.reference();
        return .{ .timeline = timeline, .value = value };
    }
};

pub const Point = struct {
    timeline: *Timeline,
    value: u64,

    pub fn clone(point: Point) Error!Point {
        return point.timeline.point(point.value);
    }

    pub fn deinit(point: *Point) void {
        point.timeline.unreference();
        point.* = undefined;
    }

    pub fn sameTimeline(lhs: Point, rhs: Point) bool {
        return lhs.timeline == rhs.timeline;
    }

    pub fn signaled(point: Point) Error!bool {
        var handle = point.timeline.handle;
        var value = point.value;
        const result = c.drmSyncobjTimelineWait(
            point.timeline.device.fd,
            &handle,
            &value,
            1,
            0,
            0,
            null,
        );
        if (result == 0) return true;
        if (std.c.errno(result) == .TIME) return false;
        return error.WaitFailed;
    }

    pub fn signal(point: Point) Error!void {
        var handle = point.timeline.handle;
        var value = point.value;
        if (c.drmSyncobjTimelineSignal(point.timeline.device.fd, &handle, &value, 1) != 0)
            return error.SignalFailed;
    }

    /// Exports this timeline point as a CLOEXEC sync_file. The caller owns the
    /// returned descriptor. Unavailable means the point has not been submitted
    /// yet; unlike a syncobj eventfd, a failed export retains no registration.
    pub fn exportSyncFile(point: Point) Error!linux.fd_t {
        const device = point.timeline.device;
        const binary = try device.createBinary();
        defer std.debug.assert(c.drmSyncobjDestroy(device.fd, binary) == 0);
        if (c.drmSyncobjTransfer(
            device.fd,
            binary,
            0,
            point.timeline.handle,
            point.value,
            0,
        ) != 0) {
            if (std.c.errno(@as(c_int, -1)) == .INVAL) return error.Unavailable;
            return error.TransferFailed;
        }
        var sync_file: c_int = -1;
        if (c.drmSyncobjExportSyncFile(device.fd, binary, &sync_file) != 0)
            return error.ExportFailed;
        return sync_file;
    }

    /// Imports a sync_file into this timeline point. The caller retains
    /// ownership of `sync_file`.
    pub fn importSyncFile(point: Point, sync_file: linux.fd_t) Error!void {
        const device = point.timeline.device;
        const binary = try device.createBinary();
        defer std.debug.assert(c.drmSyncobjDestroy(device.fd, binary) == 0);
        if (c.drmSyncobjImportSyncFile(device.fd, binary, sync_file) != 0)
            return error.ImportFailed;
        if (c.drmSyncobjTransfer(
            device.fd,
            point.timeline.handle,
            point.value,
            binary,
            0,
            0,
        ) != 0) return error.TransferFailed;
    }

    /// Imports every current DMA-BUF user into this timeline point by
    /// exporting the fence required before a subsequent write. The caller
    /// retains ownership of `dma_buf`.
    pub fn importDmaBufWriteFence(point: Point, dma_buf: linux.fd_t) Error!void {
        var export_file: c.struct_dma_buf_export_sync_file = .{
            .flags = c.DMA_BUF_SYNC_WRITE,
            .fd = -1,
        };
        if (c.ioctl(dma_buf, c.DMA_BUF_IOCTL_EXPORT_SYNC_FILE, &export_file) != 0 or
            export_file.fd < 0) return error.ExportFailed;
        defer _ = linux.close(export_file.fd);
        try point.importSyncFile(export_file.fd);
    }
};

pub const Commit = struct {
    acquire: Point,
    release: Point,
    acquire_wait: ?*AcquireWait = null,

    pub fn deinit(commit: *Commit) void {
        if (commit.acquire_wait) |wait| wait.owned = false;
        commit.acquire.deinit();
        commit.release.deinit();
        commit.* = undefined;
    }
};

/// Shared lifetime between a committed point and its asynchronous poll owner.
/// The owner may reclaim this only after the commit releases it and I/O drains.
pub const AcquireWait = struct {
    owned: bool = true,
    signaled: bool = false,
    registered: bool = false,
};

pub fn pointValue(high: u32, low: u32) u64 {
    return (@as(u64, high) << 32) | low;
}

fn hasCapability(fd: linux.fd_t, capability: u64) bool {
    var value: u64 = 0;
    return c.drmGetCap(fd, capability, &value) == 0 and value != 0;
}

test "syncobj point values preserve unsigned wire ordering" {
    try std.testing.expectEqual(@as(u64, 0), pointValue(0, 0));
    try std.testing.expectEqual(@as(u64, 0x0000_0001_ffff_ffff), pointValue(1, 0xffff_ffff));
    try std.testing.expectEqual(std.math.maxInt(u64), pointValue(0xffff_ffff, 0xffff_ffff));
}

test "syncobj points compare exact timeline identity" {
    var first: Timeline = undefined;
    var second: Timeline = undefined;
    const a = Point{ .timeline = &first, .value = 4 };
    const b = Point{ .timeline = &first, .value = 9 };
    const c_point = Point{ .timeline = &second, .value = 4 };
    try std.testing.expect(a.sameTimeline(b));
    try std.testing.expect(!a.sameTimeline(c_point));
}
