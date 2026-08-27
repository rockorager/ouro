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
pub const ToolRef = usize;
pub const DeviceGroupRef = usize;
pub const max_tablet_pad_groups = 8;
pub const max_tablet_pad_controls = 64;

pub const Capabilities = packed struct {
    pointer: bool = false,
    keyboard: bool = false,
    tablet_tool: bool = false,
    tablet_pad: bool = false,
    _padding: u4 = 0,
};

pub const DeviceInfo = struct {
    capabilities: Capabilities,
    vendor: u32 = 0,
    product: u32 = 0,
    group: DeviceGroupRef = 0,
    pad_buttons: u32 = 0,
    pad_rings: u32 = 0,
    pad_strips: u32 = 0,
    pad_mode_groups: u32 = 0,
    pad_groups: [max_tablet_pad_groups]TabletPadGroupInfo =
        [_]TabletPadGroupInfo{.{}} ** max_tablet_pad_groups,
};

pub const TabletPadGroupInfo = struct {
    buttons: u64 = 0,
    rings: u64 = 0,
    strips: u64 = 0,
    modes: u32 = 0,
};

pub const TabletToolType = enum { pen, eraser, brush, pencil, airbrush, mouse, lens, totem };
pub const TabletToolCapabilities = packed struct {
    pressure: bool = false,
    distance: bool = false,
    tilt: bool = false,
    rotation: bool = false,
    slider: bool = false,
    wheel: bool = false,
    _padding: u2 = 0,
};
pub const TabletToolInfo = struct {
    reference: ToolRef,
    kind: TabletToolType,
    serial: u64,
    hardware_id: u64,
    capabilities: TabletToolCapabilities,
};
pub const TabletToolAxes = struct {
    x: ?f64 = null,
    y: ?f64 = null,
    pressure: ?f64 = null,
    distance: ?f64 = null,
    tilt_x: ?f64 = null,
    tilt_y: ?f64 = null,
    rotation: ?f64 = null,
    slider: ?f64 = null,
    wheel_degrees: ?f64 = null,
    wheel_clicks: i32 = 0,
};
pub const TabletPadSource = enum { finger, unknown };

pub const AxisSource = enum { wheel, finger, continuous };
pub const AxisValue = struct {
    value: f64,
    value120: ?f64 = null,
};

pub const GestureBegin = struct { device: DeviceRef, time_usec: u64, fingers: u32 };
pub const GestureUpdate = struct { device: DeviceRef, time_usec: u64, dx: f64, dy: f64 };
pub const PinchUpdate = struct {
    device: DeviceRef,
    time_usec: u64,
    dx: f64,
    dy: f64,
    scale: f64,
    angle_delta: f64,
};
pub const GestureEnd = struct { device: DeviceRef, time_usec: u64, cancelled: bool };

pub const RawEvent = union(enum) {
    device_added: struct { device: DeviceRef, info: DeviceInfo },
    device_removed: DeviceRef,
    pointer_motion: struct { device: DeviceRef, time_usec: u64, dx: f64, dy: f64 },
    pointer_button: struct { device: DeviceRef, time_usec: u64, button: u32, pressed: bool },
    pointer_axis: struct {
        device: DeviceRef,
        time_usec: u64,
        source: AxisSource,
        vertical: ?AxisValue,
        horizontal: ?AxisValue,
    },
    swipe_begin: GestureBegin,
    swipe_update: GestureUpdate,
    swipe_end: GestureEnd,
    pinch_begin: GestureBegin,
    pinch_update: PinchUpdate,
    pinch_end: GestureEnd,
    hold_begin: GestureBegin,
    hold_end: GestureEnd,
    keyboard_key: struct { device: DeviceRef, time_usec: u64, key: u32, pressed: bool },
    tablet_tool_axis: struct {
        device: DeviceRef,
        tool: ToolRef,
        time_usec: u64,
        axes: TabletToolAxes,
    },
    tablet_tool_proximity: struct {
        device: DeviceRef,
        tool: TabletToolInfo,
        time_usec: u64,
        entered: bool,
        axes: TabletToolAxes,
    },
    tablet_tool_tip: struct {
        device: DeviceRef,
        tool: ToolRef,
        time_usec: u64,
        down: bool,
        axes: TabletToolAxes,
    },
    tablet_tool_button: struct {
        device: DeviceRef,
        tool: ToolRef,
        time_usec: u64,
        button: u32,
        pressed: bool,
        axes: TabletToolAxes,
    },
    tablet_pad_button: struct {
        device: DeviceRef,
        time_usec: u64,
        button: u32,
        pressed: bool,
        mode: u32,
        group: u32,
    },
    tablet_pad_ring: struct {
        device: DeviceRef,
        time_usec: u64,
        ring: u32,
        position: f64,
        source: TabletPadSource,
        mode: u32,
        group: u32,
    },
    tablet_pad_strip: struct {
        device: DeviceRef,
        time_usec: u64,
        strip: u32,
        position: f64,
        source: TabletPadSource,
        mode: u32,
        group: u32,
    },
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
            .info = deviceInfo(c.libinput_event_get_device(event)),
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
        c.LIBINPUT_EVENT_POINTER_SCROLL_WHEEL,
        c.LIBINPUT_EVENT_POINTER_SCROLL_FINGER,
        c.LIBINPUT_EVENT_POINTER_SCROLL_CONTINUOUS,
        => blk: {
            const pointer = c.libinput_event_get_pointer_event(event) orelse
                return error.InvalidEvent;
            const event_type = c.libinput_event_get_type(event);
            const source: AxisSource = if (event_type == c.LIBINPUT_EVENT_POINTER_SCROLL_WHEEL)
                .wheel
            else if (event_type == c.LIBINPUT_EVENT_POINTER_SCROLL_FINGER)
                .finger
            else
                .continuous;
            break :blk .{ .pointer_axis = .{
                .device = device,
                .time_usec = c.libinput_event_pointer_get_time_usec(pointer),
                .source = source,
                .vertical = axisValue(pointer, source, c.LIBINPUT_POINTER_AXIS_SCROLL_VERTICAL),
                .horizontal = axisValue(pointer, source, c.LIBINPUT_POINTER_AXIS_SCROLL_HORIZONTAL),
            } };
        },
        c.LIBINPUT_EVENT_GESTURE_SWIPE_BEGIN,
        c.LIBINPUT_EVENT_GESTURE_SWIPE_UPDATE,
        c.LIBINPUT_EVENT_GESTURE_SWIPE_END,
        c.LIBINPUT_EVENT_GESTURE_PINCH_BEGIN,
        c.LIBINPUT_EVENT_GESTURE_PINCH_UPDATE,
        c.LIBINPUT_EVENT_GESTURE_PINCH_END,
        c.LIBINPUT_EVENT_GESTURE_HOLD_BEGIN,
        c.LIBINPUT_EVENT_GESTURE_HOLD_END,
        => blk: {
            const gesture = c.libinput_event_get_gesture_event(event) orelse
                return error.InvalidEvent;
            const time_usec = c.libinput_event_gesture_get_time_usec(gesture);
            break :blk switch (c.libinput_event_get_type(event)) {
                c.LIBINPUT_EVENT_GESTURE_SWIPE_BEGIN => .{ .swipe_begin = .{
                    .device = device,
                    .time_usec = time_usec,
                    .fingers = @intCast(c.libinput_event_gesture_get_finger_count(gesture)),
                } },
                c.LIBINPUT_EVENT_GESTURE_SWIPE_UPDATE => .{ .swipe_update = .{
                    .device = device,
                    .time_usec = time_usec,
                    .dx = c.libinput_event_gesture_get_dx(gesture),
                    .dy = c.libinput_event_gesture_get_dy(gesture),
                } },
                c.LIBINPUT_EVENT_GESTURE_SWIPE_END => .{ .swipe_end = .{
                    .device = device,
                    .time_usec = time_usec,
                    .cancelled = c.libinput_event_gesture_get_cancelled(gesture) != 0,
                } },
                c.LIBINPUT_EVENT_GESTURE_PINCH_BEGIN => .{ .pinch_begin = .{
                    .device = device,
                    .time_usec = time_usec,
                    .fingers = @intCast(c.libinput_event_gesture_get_finger_count(gesture)),
                } },
                c.LIBINPUT_EVENT_GESTURE_PINCH_UPDATE => .{ .pinch_update = .{
                    .device = device,
                    .time_usec = time_usec,
                    .dx = c.libinput_event_gesture_get_dx(gesture),
                    .dy = c.libinput_event_gesture_get_dy(gesture),
                    .scale = c.libinput_event_gesture_get_scale(gesture),
                    .angle_delta = c.libinput_event_gesture_get_angle_delta(gesture),
                } },
                c.LIBINPUT_EVENT_GESTURE_PINCH_END => .{ .pinch_end = .{
                    .device = device,
                    .time_usec = time_usec,
                    .cancelled = c.libinput_event_gesture_get_cancelled(gesture) != 0,
                } },
                c.LIBINPUT_EVENT_GESTURE_HOLD_BEGIN => .{ .hold_begin = .{
                    .device = device,
                    .time_usec = time_usec,
                    .fingers = @intCast(c.libinput_event_gesture_get_finger_count(gesture)),
                } },
                c.LIBINPUT_EVENT_GESTURE_HOLD_END => .{ .hold_end = .{
                    .device = device,
                    .time_usec = time_usec,
                    .cancelled = c.libinput_event_gesture_get_cancelled(gesture) != 0,
                } },
                else => unreachable,
            };
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
        c.LIBINPUT_EVENT_TABLET_TOOL_AXIS,
        c.LIBINPUT_EVENT_TABLET_TOOL_PROXIMITY,
        c.LIBINPUT_EVENT_TABLET_TOOL_TIP,
        c.LIBINPUT_EVENT_TABLET_TOOL_BUTTON,
        => blk: {
            const tablet = c.libinput_event_get_tablet_tool_event(event) orelse
                return error.InvalidEvent;
            const tool = c.libinput_event_tablet_tool_get_tool(tablet) orelse
                return error.InvalidEvent;
            const time_usec = c.libinput_event_tablet_tool_get_time_usec(tablet);
            break :blk switch (c.libinput_event_get_type(event)) {
                c.LIBINPUT_EVENT_TABLET_TOOL_AXIS => .{ .tablet_tool_axis = .{
                    .device = device,
                    .tool = @intFromPtr(tool),
                    .time_usec = time_usec,
                    .axes = tabletAxes(tablet),
                } },
                c.LIBINPUT_EVENT_TABLET_TOOL_PROXIMITY => .{ .tablet_tool_proximity = .{
                    .device = device,
                    .tool = tabletToolInfo(tool),
                    .time_usec = time_usec,
                    .entered = c.libinput_event_tablet_tool_get_proximity_state(tablet) ==
                        c.LIBINPUT_TABLET_TOOL_PROXIMITY_STATE_IN,
                    .axes = tabletProximityAxes(tablet),
                } },
                c.LIBINPUT_EVENT_TABLET_TOOL_TIP => .{ .tablet_tool_tip = .{
                    .device = device,
                    .tool = @intFromPtr(tool),
                    .time_usec = time_usec,
                    .down = c.libinput_event_tablet_tool_get_tip_state(tablet) ==
                        c.LIBINPUT_TABLET_TOOL_TIP_DOWN,
                    .axes = tabletAxes(tablet),
                } },
                c.LIBINPUT_EVENT_TABLET_TOOL_BUTTON => .{ .tablet_tool_button = .{
                    .device = device,
                    .tool = @intFromPtr(tool),
                    .time_usec = time_usec,
                    .button = c.libinput_event_tablet_tool_get_button(tablet),
                    .pressed = c.libinput_event_tablet_tool_get_button_state(tablet) ==
                        c.LIBINPUT_BUTTON_STATE_PRESSED,
                    .axes = tabletAxes(tablet),
                } },
                else => unreachable,
            };
        },
        c.LIBINPUT_EVENT_TABLET_PAD_BUTTON,
        c.LIBINPUT_EVENT_TABLET_PAD_RING,
        c.LIBINPUT_EVENT_TABLET_PAD_STRIP,
        => blk: {
            const pad = c.libinput_event_get_tablet_pad_event(event) orelse
                return error.InvalidEvent;
            const time_usec = c.libinput_event_tablet_pad_get_time_usec(pad);
            const mode = c.libinput_event_tablet_pad_get_mode(pad);
            break :blk switch (c.libinput_event_get_type(event)) {
                c.LIBINPUT_EVENT_TABLET_PAD_BUTTON => .{ .tablet_pad_button = .{
                    .device = device,
                    .time_usec = time_usec,
                    .button = c.libinput_event_tablet_pad_get_button_number(pad),
                    .pressed = c.libinput_event_tablet_pad_get_button_state(pad) ==
                        c.LIBINPUT_BUTTON_STATE_PRESSED,
                    .mode = mode,
                    .group = if (c.libinput_event_tablet_pad_get_mode_group(pad)) |group|
                        c.libinput_tablet_pad_mode_group_get_index(group)
                    else
                        0,
                } },
                c.LIBINPUT_EVENT_TABLET_PAD_RING => .{ .tablet_pad_ring = .{
                    .device = device,
                    .time_usec = time_usec,
                    .ring = c.libinput_event_tablet_pad_get_ring_number(pad),
                    .position = c.libinput_event_tablet_pad_get_ring_position(pad),
                    .source = padRingSource(c.libinput_event_tablet_pad_get_ring_source(pad)),
                    .mode = mode,
                    .group = padModeGroup(pad),
                } },
                c.LIBINPUT_EVENT_TABLET_PAD_STRIP => .{ .tablet_pad_strip = .{
                    .device = device,
                    .time_usec = time_usec,
                    .strip = c.libinput_event_tablet_pad_get_strip_number(pad),
                    .position = c.libinput_event_tablet_pad_get_strip_position(pad),
                    .source = padStripSource(c.libinput_event_tablet_pad_get_strip_source(pad)),
                    .mode = mode,
                    .group = padModeGroup(pad),
                } },
                else => unreachable,
            };
        },
        else => .ignored,
    };
}

fn deviceInfo(device: *c.struct_libinput_device) DeviceInfo {
    var capabilities: Capabilities = .{
        .pointer = c.libinput_device_has_capability(device, c.LIBINPUT_DEVICE_CAP_POINTER) != 0,
        .keyboard = c.libinput_device_has_capability(device, c.LIBINPUT_DEVICE_CAP_KEYBOARD) != 0,
        .tablet_tool = c.libinput_device_has_capability(device, c.LIBINPUT_DEVICE_CAP_TABLET_TOOL) != 0,
        .tablet_pad = c.libinput_device_has_capability(device, c.LIBINPUT_DEVICE_CAP_TABLET_PAD) != 0,
    };
    var info: DeviceInfo = .{
        .capabilities = capabilities,
        .vendor = c.libinput_device_get_id_vendor(device),
        .product = c.libinput_device_get_id_product(device),
        .group = @intFromPtr(c.libinput_device_get_device_group(device)),
        .pad_buttons = if (capabilities.tablet_pad) c.libinput_device_tablet_pad_get_num_buttons(device) else 0,
        .pad_rings = if (capabilities.tablet_pad) c.libinput_device_tablet_pad_get_num_rings(device) else 0,
        .pad_strips = if (capabilities.tablet_pad) c.libinput_device_tablet_pad_get_num_strips(device) else 0,
        .pad_mode_groups = if (capabilities.tablet_pad) @intCast(c.libinput_device_tablet_pad_get_num_mode_groups(device)) else 0,
    };
    if (capabilities.tablet_pad and !tabletPadTopology(device, &info)) {
        capabilities.tablet_pad = false;
        info.capabilities.tablet_pad = false;
        info.pad_buttons = 0;
        info.pad_rings = 0;
        info.pad_strips = 0;
        info.pad_mode_groups = 0;
    }
    return info;
}

fn tabletPadTopology(device: *c.struct_libinput_device, info: *DeviceInfo) bool {
    if (info.pad_buttons > max_tablet_pad_controls or
        info.pad_rings > max_tablet_pad_controls or
        info.pad_strips > max_tablet_pad_controls or
        info.pad_mode_groups > max_tablet_pad_groups)
        return false;
    for (0..info.pad_mode_groups) |group_index| {
        const group = c.libinput_device_tablet_pad_get_mode_group(device, @intCast(group_index)) orelse
            return false;
        var result: TabletPadGroupInfo = .{
            .modes = c.libinput_tablet_pad_mode_group_get_num_modes(group),
        };
        if (result.modes == 0) return false;
        for (0..info.pad_buttons) |index| {
            if (c.libinput_tablet_pad_mode_group_has_button(group, @intCast(index)) != 0)
                result.buttons |= @as(u64, 1) << @intCast(index);
        }
        for (0..info.pad_rings) |index| {
            if (c.libinput_tablet_pad_mode_group_has_ring(group, @intCast(index)) != 0)
                result.rings |= @as(u64, 1) << @intCast(index);
        }
        for (0..info.pad_strips) |index| {
            if (c.libinput_tablet_pad_mode_group_has_strip(group, @intCast(index)) != 0)
                result.strips |= @as(u64, 1) << @intCast(index);
        }
        info.pad_groups[group_index] = result;
    }
    return true;
}

fn tabletToolInfo(tool: *c.struct_libinput_tablet_tool) TabletToolInfo {
    return .{
        .reference = @intFromPtr(tool),
        .kind = switch (c.libinput_tablet_tool_get_type(tool)) {
            c.LIBINPUT_TABLET_TOOL_TYPE_PEN => .pen,
            c.LIBINPUT_TABLET_TOOL_TYPE_ERASER => .eraser,
            c.LIBINPUT_TABLET_TOOL_TYPE_BRUSH => .brush,
            c.LIBINPUT_TABLET_TOOL_TYPE_PENCIL => .pencil,
            c.LIBINPUT_TABLET_TOOL_TYPE_AIRBRUSH => .airbrush,
            c.LIBINPUT_TABLET_TOOL_TYPE_MOUSE => .mouse,
            c.LIBINPUT_TABLET_TOOL_TYPE_LENS => .lens,
            c.LIBINPUT_TABLET_TOOL_TYPE_TOTEM => .totem,
            else => .pen,
        },
        .serial = c.libinput_tablet_tool_get_serial(tool),
        .hardware_id = c.libinput_tablet_tool_get_tool_id(tool),
        .capabilities = .{
            .pressure = c.libinput_tablet_tool_has_pressure(tool) != 0,
            .distance = c.libinput_tablet_tool_has_distance(tool) != 0,
            .tilt = c.libinput_tablet_tool_has_tilt(tool) != 0,
            .rotation = c.libinput_tablet_tool_has_rotation(tool) != 0,
            .slider = c.libinput_tablet_tool_has_slider(tool) != 0,
            .wheel = c.libinput_tablet_tool_has_wheel(tool) != 0,
        },
    };
}

fn tabletAxes(event: *c.struct_libinput_event_tablet_tool) TabletToolAxes {
    const position_changed = c.libinput_event_tablet_tool_x_has_changed(event) != 0 or
        c.libinput_event_tablet_tool_y_has_changed(event) != 0;
    const tilt_changed = c.libinput_event_tablet_tool_tilt_x_has_changed(event) != 0 or
        c.libinput_event_tablet_tool_tilt_y_has_changed(event) != 0;
    const wheel_changed = c.libinput_event_tablet_tool_wheel_has_changed(event) != 0;
    return .{
        .x = if (position_changed)
            c.libinput_event_tablet_tool_get_x_transformed(event, 1)
        else
            null,
        .y = if (position_changed)
            c.libinput_event_tablet_tool_get_y_transformed(event, 1)
        else
            null,
        .pressure = changedAxis(event, c.libinput_event_tablet_tool_pressure_has_changed, c.libinput_event_tablet_tool_get_pressure),
        .distance = changedAxis(event, c.libinput_event_tablet_tool_distance_has_changed, c.libinput_event_tablet_tool_get_distance),
        .tilt_x = if (tilt_changed) c.libinput_event_tablet_tool_get_tilt_x(event) else null,
        .tilt_y = if (tilt_changed) c.libinput_event_tablet_tool_get_tilt_y(event) else null,
        .rotation = changedAxis(event, c.libinput_event_tablet_tool_rotation_has_changed, c.libinput_event_tablet_tool_get_rotation),
        .slider = changedAxis(event, c.libinput_event_tablet_tool_slider_has_changed, c.libinput_event_tablet_tool_get_slider_position),
        .wheel_degrees = if (wheel_changed) c.libinput_event_tablet_tool_get_wheel_delta(event) else null,
        .wheel_clicks = if (wheel_changed) c.libinput_event_tablet_tool_get_wheel_delta_discrete(event) else 0,
    };
}

fn tabletProximityAxes(event: *c.struct_libinput_event_tablet_tool) TabletToolAxes {
    if (c.libinput_event_tablet_tool_get_proximity_state(event) ==
        c.LIBINPUT_TABLET_TOOL_PROXIMITY_STATE_OUT) return .{};
    return tabletAxes(event);
}

fn changedAxis(event: anytype, changed: anytype, get: anytype) ?f64 {
    return if (changed(event) != 0) get(event) else null;
}

fn padRingSource(source: c.enum_libinput_tablet_pad_ring_axis_source) TabletPadSource {
    return if (source == c.LIBINPUT_TABLET_PAD_RING_SOURCE_FINGER) .finger else .unknown;
}

fn padStripSource(source: c.enum_libinput_tablet_pad_strip_axis_source) TabletPadSource {
    return if (source == c.LIBINPUT_TABLET_PAD_STRIP_SOURCE_FINGER) .finger else .unknown;
}

fn padModeGroup(event: *c.struct_libinput_event_tablet_pad) u32 {
    const group = c.libinput_event_tablet_pad_get_mode_group(event) orelse return 0;
    return c.libinput_tablet_pad_mode_group_get_index(group);
}

fn axisValue(
    event: *c.struct_libinput_event_pointer,
    source: AxisSource,
    axis: c.enum_libinput_pointer_axis,
) ?AxisValue {
    if (c.libinput_event_pointer_has_axis(event, axis) == 0) return null;
    return .{
        .value = c.libinput_event_pointer_get_scroll_value(event, axis),
        .value120 = if (source == .wheel)
            c.libinput_event_pointer_get_scroll_value_v120(event, axis)
        else
            null,
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
