//! Replaceable udev DRM hotplug monitor integrated with Ouro's shared ring.

const std = @import("std");
const linux = std.os.linux;
const completion = @import("../../runtime/completion.zig");

const c = @cImport({
    @cInclude("libudev.h");
});

pub const Event = enum { change, remove, ignored };

pub const Platform = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        create: *const fn (*anyopaque) anyerror!*anyopaque,
        destroy: *const fn (*anyopaque, *anyopaque) void,
        get_fd: *const fn (*anyopaque, *anyopaque) anyerror!std.posix.fd_t,
        next_event: *const fn (*anyopaque, *anyopaque) anyerror!?Event,
    };

    pub fn create(self: Platform) !*anyopaque {
        return self.vtable.create(self.context);
    }
    pub fn destroy(self: Platform, monitor: *anyopaque) void {
        self.vtable.destroy(self.context, monitor);
    }
    pub fn getFd(self: Platform, monitor: *anyopaque) !std.posix.fd_t {
        return self.vtable.get_fd(self.context, monitor);
    }
    pub fn nextEvent(self: Platform, monitor: *anyopaque) !?Event {
        return self.vtable.next_event(self.context, monitor);
    }
};

pub const Monitor = struct {
    platform: Platform,
    context: *anyopaque,
    fd: std.posix.fd_t,
    poll_token: ?completion.Token = null,
    cancel_token: ?completion.Token = null,
    changed: bool = false,
    draining: bool = false,

    pub fn init(platform: Platform) !Monitor {
        const context = try platform.create();
        errdefer platform.destroy(context);
        return .{ .platform = platform, .context = context, .fd = try platform.getFd(context) };
    }

    pub fn deinit(self: *Monitor) void {
        std.debug.assert(self.poll_token == null and self.cancel_token == null);
        self.platform.destroy(self.context);
        self.* = undefined;
    }

    pub fn start(self: *Monitor, router: *completion.Router, ring: *linux.IoUring) !void {
        if (self.poll_token != null or self.draining) return error.InvalidState;
        try self.preparePoll(router, ring);
    }

    pub fn ownsToken(self: *const Monitor, token: completion.Token) bool {
        return sameToken(self.poll_token, token) or sameToken(self.cancel_token, token);
    }

    pub fn complete(
        self: *Monitor,
        router: *completion.Router,
        ring: *linux.IoUring,
        token: completion.Token,
        result: i32,
    ) !void {
        if (sameToken(self.poll_token, token)) {
            try router.retire(token);
            self.poll_token = null;
            if (self.draining and result == -@as(i32, @intFromEnum(linux.E.CANCELED))) return;
            if (result < 0) return error.ReadinessFailed;
            const mask: u32 = @intCast(result);
            if (mask & linux.POLL.IN == 0 or
                mask & (linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL) != 0)
                return error.ReadinessFailed;
            while (try self.platform.nextEvent(self.context)) |event| switch (event) {
                .change, .remove => self.changed = true,
                .ignored => {},
            };
            if (!self.draining) try self.preparePoll(router, ring);
            return;
        }
        if (sameToken(self.cancel_token, token)) {
            try router.retire(token);
            self.cancel_token = null;
            if (result != 0 and result != -@as(i32, @intFromEnum(linux.E.NOENT)) and
                result != -@as(i32, @intFromEnum(linux.E.CANCELED)))
                return error.UnexpectedCompletion;
            return;
        }
        return error.UnknownToken;
    }

    pub fn takeChanged(self: *Monitor) bool {
        const changed = self.changed;
        self.changed = false;
        return changed;
    }

    pub fn beginDrain(self: *Monitor, router: *completion.Router, ring: *linux.IoUring) !void {
        if (self.draining) return;
        self.draining = true;
        if (self.poll_token) |poll| {
            const cancel = try router.acquire(.hotplug_ready);
            errdefer router.retire(cancel) catch unreachable;
            _ = try ring.poll_remove(cancel.encode(), poll.encode());
            self.cancel_token = cancel;
        }
    }

    pub fn drainComplete(self: *const Monitor) bool {
        return self.draining and self.poll_token == null and self.cancel_token == null;
    }

    fn preparePoll(self: *Monitor, router: *completion.Router, ring: *linux.IoUring) !void {
        const token = try router.acquire(.hotplug_ready);
        errdefer router.retire(token) catch unreachable;
        _ = try ring.poll_add(
            token.encode(),
            self.fd,
            linux.POLL.IN | linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL,
        );
        self.poll_token = token;
    }
};

fn sameToken(value: ?completion.Token, token: completion.Token) bool {
    return value != null and std.meta.eql(value.?, token);
}

const Real = struct {
    udev: *c.struct_udev,
    monitor: *c.struct_udev_monitor,
};

var real_context: u8 = 0;
pub const real: Platform = .{ .context = &real_context, .vtable = &real_vtable };
const real_vtable: Platform.VTable = .{
    .create = realCreate,
    .destroy = realDestroy,
    .get_fd = realGetFd,
    .next_event = realNextEvent,
};

fn realCreate(_: *anyopaque) !*anyopaque {
    const udev = c.udev_new() orelse return error.UdevUnavailable;
    errdefer _ = c.udev_unref(udev);
    const monitor = c.udev_monitor_new_from_netlink(udev, "udev") orelse
        return error.UdevMonitorUnavailable;
    errdefer _ = c.udev_monitor_unref(monitor);
    if (c.udev_monitor_filter_add_match_subsystem_devtype(monitor, "drm", null) < 0 or
        c.udev_monitor_enable_receiving(monitor) < 0)
        return error.UdevMonitorUnavailable;
    const owner = std.heap.c_allocator.create(Real) catch return error.OutOfMemory;
    owner.* = .{ .udev = udev, .monitor = monitor };
    return owner;
}

fn realDestroy(_: *anyopaque, context: *anyopaque) void {
    const owner: *Real = @ptrCast(@alignCast(context));
    _ = c.udev_monitor_unref(owner.monitor);
    _ = c.udev_unref(owner.udev);
    std.heap.c_allocator.destroy(owner);
}

fn realGetFd(_: *anyopaque, context: *anyopaque) !std.posix.fd_t {
    const owner: *Real = @ptrCast(@alignCast(context));
    const fd = c.udev_monitor_get_fd(owner.monitor);
    if (fd < 0) return error.UdevMonitorUnavailable;
    return fd;
}

fn realNextEvent(_: *anyopaque, context: *anyopaque) !?Event {
    const owner: *Real = @ptrCast(@alignCast(context));
    const device = c.udev_monitor_receive_device(owner.monitor) orelse return null;
    defer _ = c.udev_device_unref(device);
    const action = c.udev_device_get_action(device) orelse return .ignored;
    const value = std.mem.span(action);
    if (std.mem.eql(u8, value, "change")) return .change;
    if (std.mem.eql(u8, value, "remove")) return .remove;
    return .ignored;
}
