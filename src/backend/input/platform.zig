//! Narrow libinput boundary. The backend owner sees normalized values and an
//! opaque device identity; tests replace this entire boundary without udev or
//! evdev devices.

const std = @import("std");

const c = @cImport({
    @cInclude("libinput.h");
    @cInclude("libudev.h");
    @cInclude("errno.h");
});

pub const DeviceRef = usize;

pub const Capabilities = packed struct {
    pointer: bool = false,
    keyboard: bool = false,
    _padding: u6 = 0,
};

pub const RawEvent = union(enum) {
    device_added: struct { device: DeviceRef, capabilities: Capabilities },
    device_removed: DeviceRef,
    pointer_motion: struct { device: DeviceRef, time_usec: u64, dx: f64, dy: f64 },
    pointer_button: struct { device: DeviceRef, time_usec: u64, button: u32, pressed: bool },
    keyboard_key: struct { device: DeviceRef, time_usec: u64, key: u32, pressed: bool },
    ignored,
};

/// libinput retains this stable callback pointer until `destroyContext`.
pub const Restricted = struct {
    userdata: *anyopaque,
    open_fn: *const fn (*anyopaque, [:0]const u8) anyerror!std.posix.fd_t,
    close_fn: *const fn (*anyopaque, std.posix.fd_t) void,
};

pub const Platform = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        create: *const fn (*anyopaque, *Restricted, [:0]const u8) anyerror!*anyopaque,
        destroy: *const fn (*anyopaque, *anyopaque) void,
        get_fd: *const fn (*anyopaque, *anyopaque) anyerror!std.posix.fd_t,
        dispatch: *const fn (*anyopaque, *anyopaque) anyerror!void,
        next_event: *const fn (*anyopaque, *anyopaque) anyerror!?RawEvent,
        suspend_context: *const fn (*anyopaque, *anyopaque) anyerror!void,
        resume_context: *const fn (*anyopaque, *anyopaque) anyerror!void,
    };

    pub fn createContext(self: Platform, restricted: *Restricted, seat: [:0]const u8) !*anyopaque {
        return self.vtable.create(self.context, restricted, seat);
    }

    pub fn destroyContext(self: Platform, value: *anyopaque) void {
        self.vtable.destroy(self.context, value);
    }

    pub fn getFd(self: Platform, value: *anyopaque) !std.posix.fd_t {
        return self.vtable.get_fd(self.context, value);
    }

    pub fn dispatch(self: Platform, value: *anyopaque) !void {
        return self.vtable.dispatch(self.context, value);
    }

    pub fn nextEvent(self: Platform, value: *anyopaque) !?RawEvent {
        return self.vtable.next_event(self.context, value);
    }

    pub fn suspendContext(self: Platform, value: *anyopaque) !void {
        return self.vtable.suspend_context(self.context, value);
    }

    pub fn resumeContext(self: Platform, value: *anyopaque) !void {
        return self.vtable.resume_context(self.context, value);
    }
};

const RealContext = struct {
    udev: *c.struct_udev,
    input: *c.struct_libinput,
};

var real_context: u8 = 0;

pub const real: Platform = .{ .context = &real_context, .vtable = &real_vtable };

const real_vtable: Platform.VTable = .{
    .create = realCreate,
    .destroy = realDestroy,
    .get_fd = realGetFd,
    .dispatch = realDispatch,
    .next_event = realNextEvent,
    .suspend_context = realSuspend,
    .resume_context = realResume,
};

const interface: c.struct_libinput_interface = .{
    .open_restricted = restrictedOpen,
    .close_restricted = restrictedClose,
};

fn restrictedOpen(path: [*c]const u8, _: c_int, userdata: ?*anyopaque) callconv(.c) c_int {
    const restricted: *Restricted = @ptrCast(@alignCast(userdata orelse return -c.EACCES));
    const value = std.mem.span(path);
    return restricted.open_fn(restricted.userdata, value) catch -c.EACCES;
}

fn restrictedClose(fd: c_int, userdata: ?*anyopaque) callconv(.c) void {
    const restricted: *Restricted = @ptrCast(@alignCast(userdata orelse return));
    restricted.close_fn(restricted.userdata, fd);
}

fn realCreate(_: *anyopaque, restricted: *Restricted, seat: [:0]const u8) !*anyopaque {
    const udev = c.udev_new() orelse return error.UdevCreateFailed;
    errdefer _ = c.udev_unref(udev);
    const input = c.libinput_udev_create_context(&interface, restricted, udev) orelse
        return error.LibinputCreateFailed;
    errdefer _ = c.libinput_unref(input);
    if (c.libinput_udev_assign_seat(input, seat.ptr) != 0)
        return error.AssignSeatFailed;
    const owner = std.heap.c_allocator.create(RealContext) catch return error.OutOfMemory;
    owner.* = .{ .udev = udev, .input = input };
    return owner;
}

fn realDestroy(_: *anyopaque, value: *anyopaque) void {
    const owner: *RealContext = @ptrCast(@alignCast(value));
    _ = c.libinput_unref(owner.input);
    _ = c.udev_unref(owner.udev);
    std.heap.c_allocator.destroy(owner);
}

fn realGetFd(_: *anyopaque, value: *anyopaque) !std.posix.fd_t {
    const owner: *RealContext = @ptrCast(@alignCast(value));
    const fd = c.libinput_get_fd(owner.input);
    if (fd < 0) return error.GetFdFailed;
    return fd;
}

fn realDispatch(_: *anyopaque, value: *anyopaque) !void {
    const owner: *RealContext = @ptrCast(@alignCast(value));
    if (c.libinput_dispatch(owner.input) != 0) return error.DispatchFailed;
}

fn realNextEvent(_: *anyopaque, value: *anyopaque) !?RawEvent {
    const owner: *RealContext = @ptrCast(@alignCast(value));
    const event = c.libinput_get_event(owner.input) orelse return null;
    defer c.libinput_event_destroy(event);
    const device: DeviceRef = @intFromPtr(c.libinput_event_get_device(event));
    return switch (c.libinput_event_get_type(event)) {
        c.LIBINPUT_EVENT_DEVICE_ADDED => .{ .device_added = .{
            .device = device,
            .capabilities = .{
                .pointer = c.libinput_device_has_capability(
                    c.libinput_event_get_device(event),
                    c.LIBINPUT_DEVICE_CAP_POINTER,
                ) != 0,
                .keyboard = c.libinput_device_has_capability(
                    c.libinput_event_get_device(event),
                    c.LIBINPUT_DEVICE_CAP_KEYBOARD,
                ) != 0,
            },
        } },
        c.LIBINPUT_EVENT_DEVICE_REMOVED => .{ .device_removed = device },
        c.LIBINPUT_EVENT_POINTER_MOTION => blk: {
            const pointer = c.libinput_event_get_pointer_event(event) orelse
                return error.InvalidEvent;
            break :blk .{ .pointer_motion = .{
                .device = device,
                .time_usec = c.libinput_event_pointer_get_time_usec(pointer),
                .dx = c.libinput_event_pointer_get_dx(pointer),
                .dy = c.libinput_event_pointer_get_dy(pointer),
            } };
        },
        c.LIBINPUT_EVENT_POINTER_BUTTON => blk: {
            const pointer = c.libinput_event_get_pointer_event(event) orelse
                return error.InvalidEvent;
            break :blk .{ .pointer_button = .{
                .device = device,
                .time_usec = c.libinput_event_pointer_get_time_usec(pointer),
                .button = c.libinput_event_pointer_get_button(pointer),
                .pressed = c.libinput_event_pointer_get_button_state(pointer) ==
                    c.LIBINPUT_BUTTON_STATE_PRESSED,
            } };
        },
        c.LIBINPUT_EVENT_KEYBOARD_KEY => blk: {
            const keyboard = c.libinput_event_get_keyboard_event(event) orelse
                return error.InvalidEvent;
            break :blk .{ .keyboard_key = .{
                .device = device,
                .time_usec = c.libinput_event_keyboard_get_time_usec(keyboard),
                .key = c.libinput_event_keyboard_get_key(keyboard),
                .pressed = c.libinput_event_keyboard_get_key_state(keyboard) ==
                    c.LIBINPUT_KEY_STATE_PRESSED,
            } };
        },
        else => .ignored,
    };
}

fn realSuspend(_: *anyopaque, value: *anyopaque) !void {
    const owner: *RealContext = @ptrCast(@alignCast(value));
    c.libinput_suspend(owner.input);
}

fn realResume(_: *anyopaque, value: *anyopaque) !void {
    const owner: *RealContext = @ptrCast(@alignCast(value));
    if (c.libinput_resume(owner.input) != 0) return error.ResumeFailed;
}
