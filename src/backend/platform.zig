//! Narrow libseat boundary. Tests replace only the operations owned by a
//! session; device discovery and policy deliberately do not live here.

const std = @import("std");

const c = @cImport({
    @cInclude("libseat.h");
});

pub const Listener = struct {
    enable: *const fn (*anyopaque) void,
    disable: *const fn (*anyopaque) void,
};

/// Stored by the heap-stable session and passed unchanged to libseat. It must
/// outlive the libseat handle because C may retain this pointer until close.
pub const CallbackContext = struct {
    listener: Listener,
    userdata: *anyopaque,
};

pub const OpenedDevice = struct {
    id: i32,
    fd: std.posix.fd_t,
};

pub const Platform = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        open_seat: *const fn (*anyopaque, *CallbackContext) anyerror!*anyopaque,
        close_seat: *const fn (*anyopaque, *anyopaque) anyerror!void,
        get_fd: *const fn (*anyopaque, *anyopaque) anyerror!std.posix.fd_t,
        dispatch: *const fn (*anyopaque, *anyopaque) anyerror!void,
        disable_seat: *const fn (*anyopaque, *anyopaque) anyerror!void,
        open_device: *const fn (*anyopaque, *anyopaque, [:0]const u8) anyerror!OpenedDevice,
        close_device: *const fn (*anyopaque, *anyopaque, i32) anyerror!void,
        close_fd: *const fn (*anyopaque, std.posix.fd_t) anyerror!void,
    };

    pub fn openSeat(self: Platform, callback: *CallbackContext) !*anyopaque {
        return self.vtable.open_seat(self.context, callback);
    }

    pub fn closeSeat(self: Platform, seat: *anyopaque) !void {
        return self.vtable.close_seat(self.context, seat);
    }

    pub fn getFd(self: Platform, seat: *anyopaque) !std.posix.fd_t {
        return self.vtable.get_fd(self.context, seat);
    }

    pub fn dispatch(self: Platform, seat: *anyopaque) !void {
        return self.vtable.dispatch(self.context, seat);
    }

    pub fn disableSeat(self: Platform, seat: *anyopaque) !void {
        return self.vtable.disable_seat(self.context, seat);
    }

    pub fn openDevice(self: Platform, seat: *anyopaque, path: [:0]const u8) !OpenedDevice {
        return self.vtable.open_device(self.context, seat, path);
    }

    pub fn closeDevice(self: Platform, seat: *anyopaque, id: i32) !void {
        return self.vtable.close_device(self.context, seat, id);
    }

    pub fn closeFd(self: Platform, fd: std.posix.fd_t) !void {
        return self.vtable.close_fd(self.context, fd);
    }
};

var real_context: u8 = 0;

pub const real: Platform = .{
    .context = &real_context,
    .vtable = &real_vtable,
};

const real_vtable: Platform.VTable = .{
    .open_seat = realOpenSeat,
    .close_seat = realCloseSeat,
    .get_fd = realGetFd,
    .dispatch = realDispatch,
    .disable_seat = realDisableSeat,
    .open_device = realOpenDevice,
    .close_device = realCloseDevice,
    .close_fd = realCloseFd,
};

const seat_listener: c.struct_libseat_seat_listener = .{
    .enable_seat = handleEnable,
    .disable_seat = handleDisable,
};

fn handleEnable(_: ?*c.struct_libseat, userdata: ?*anyopaque) callconv(.c) void {
    const callback: *CallbackContext = @ptrCast(@alignCast(userdata orelse return));
    callback.listener.enable(callback.userdata);
}

fn handleDisable(_: ?*c.struct_libseat, userdata: ?*anyopaque) callconv(.c) void {
    const callback: *CallbackContext = @ptrCast(@alignCast(userdata orelse return));
    callback.listener.disable(callback.userdata);
}

fn realOpenSeat(_: *anyopaque, callback: *CallbackContext) !*anyopaque {
    const seat = c.libseat_open_seat(&seat_listener, callback) orelse return error.OpenSeatFailed;
    return @ptrCast(seat);
}

fn realCloseSeat(_: *anyopaque, seat: *anyopaque) !void {
    if (c.libseat_close_seat(@ptrCast(@alignCast(seat))) < 0) return error.CloseSeatFailed;
}

fn realGetFd(_: *anyopaque, seat: *anyopaque) !std.posix.fd_t {
    const fd = c.libseat_get_fd(@ptrCast(@alignCast(seat)));
    if (fd < 0) return error.GetFdFailed;
    return fd;
}

fn realDispatch(_: *anyopaque, seat: *anyopaque) !void {
    if (c.libseat_dispatch(@ptrCast(@alignCast(seat)), 0) < 0)
        return error.DispatchFailed;
}

fn realDisableSeat(_: *anyopaque, seat: *anyopaque) !void {
    if (c.libseat_disable_seat(@ptrCast(@alignCast(seat))) < 0)
        return error.DisableFailed;
}

fn realOpenDevice(_: *anyopaque, seat: *anyopaque, path: [:0]const u8) !OpenedDevice {
    var fd: c_int = -1;
    const id = c.libseat_open_device(@ptrCast(@alignCast(seat)), path.ptr, &fd);
    if (id < 0) return error.OpenDeviceFailed;
    if (fd < 0) {
        // A successful ID must be rolled back even if the backend violates the
        // contract by not returning the caller-owned FD.
        _ = c.libseat_close_device(@ptrCast(@alignCast(seat)), id);
        return error.OpenDeviceFailed;
    }
    return .{ .id = id, .fd = fd };
}

fn realCloseDevice(_: *anyopaque, seat: *anyopaque, id: i32) !void {
    if (c.libseat_close_device(@ptrCast(@alignCast(seat)), id) < 0)
        return error.CloseDeviceFailed;
}

fn realCloseFd(_: *anyopaque, fd: std.posix.fd_t) !void {
    _ = std.os.linux.close(fd);
}
