//! Heap-stable, fixed-capacity libinput owner. It preserves per-device
//! physical state and publishes only generation-bearing values. Libinput
//! calls and teardown happen from Ouro turn phases, never from an event
//! callback, and ring operations are prepared without submission.

const std = @import("std");
const linux = std.os.linux;
const completion = @import("../../runtime/completion.zig");
const session_api = @import("../session.zig");
const platform_api = @import("platform.zig");
const log = std.log.scoped(.input_backend);

const none = std.math.maxInt(u32);
const code_count = 0x300;
const state_words = code_count / 64;

pub const State = enum { active, quiescing, suspended, draining, failed };

pub const DeviceId = struct {
    slot: u32,
    generation: u32,
    seat_generation: u32,
};

pub const DeviceDescription = struct {
    id: DeviceId,
    info: platform_api.DeviceInfo,
    defaults: platform_api.DeviceConfiguration,
    current: platform_api.DeviceConfiguration,
    scroll_factor: f64,
    repeat_rate: i32,
    repeat_delay: i32,

    pub fn name(self: *const DeviceDescription) []const u8 {
        return self.info.deviceName();
    }
};

pub const GestureBegin = struct { device: DeviceId, time_usec: u64, fingers: u32 };
pub const GestureUpdate = struct { device: DeviceId, time_usec: u64, dx: f64, dy: f64 };
pub const PinchUpdate = struct {
    device: DeviceId,
    time_usec: u64,
    dx: f64,
    dy: f64,
    scale: f64,
    angle_delta: f64,
};
pub const GestureEnd = struct { device: DeviceId, time_usec: u64, cancelled: bool };
pub const TouchContact = struct {
    device: DeviceId,
    time_usec: u64,
    slot: u32,
    seat_slot: u32,
};
pub const TouchPosition = struct {
    device: DeviceId,
    time_usec: u64,
    slot: u32,
    seat_slot: u32,
    x: f64,
    y: f64,
};

pub const Event = union(enum) {
    device_added: struct { device: DeviceId, info: platform_api.DeviceInfo },
    device_removed: DeviceId,
    pointer_motion: struct {
        device: DeviceId,
        time_usec: u64,
        dx: f64,
        dy: f64,
        dx_unaccel: ?f64 = null,
        dy_unaccel: ?f64 = null,
    },
    pointer_button: struct { device: DeviceId, time_usec: u64, button: u32, pressed: bool },
    pointer_axis: struct {
        device: DeviceId,
        time_usec: u64,
        source: platform_api.AxisSource,
        vertical: ?platform_api.AxisValue,
        horizontal: ?platform_api.AxisValue,
    },
    swipe_begin: GestureBegin,
    swipe_update: GestureUpdate,
    swipe_end: GestureEnd,
    pinch_begin: GestureBegin,
    pinch_update: PinchUpdate,
    pinch_end: GestureEnd,
    hold_begin: GestureBegin,
    hold_end: GestureEnd,
    touch_down: TouchPosition,
    touch_up: TouchContact,
    touch_motion: TouchPosition,
    touch_frame: struct { device: DeviceId },
    touch_cancel: struct { device: DeviceId },
    keyboard_key: struct { device: DeviceId, time_usec: u64, key: u32, pressed: bool },
    tablet_tool_axis: struct {
        device: DeviceId,
        tool: platform_api.ToolRef,
        time_usec: u64,
        axes: platform_api.TabletToolAxes,
    },
    tablet_tool_proximity: struct {
        device: DeviceId,
        tool: platform_api.TabletToolInfo,
        time_usec: u64,
        entered: bool,
        axes: platform_api.TabletToolAxes,
    },
    tablet_tool_tip: struct {
        device: DeviceId,
        tool: platform_api.ToolRef,
        time_usec: u64,
        down: bool,
        axes: platform_api.TabletToolAxes,
    },
    tablet_tool_button: struct {
        device: DeviceId,
        tool: platform_api.ToolRef,
        time_usec: u64,
        button: u32,
        pressed: bool,
        axes: platform_api.TabletToolAxes,
    },
    tablet_pad_button: struct {
        device: DeviceId,
        time_usec: u64,
        button: u32,
        pressed: bool,
        mode: u32,
        group: u32,
    },
    tablet_pad_ring: struct {
        device: DeviceId,
        time_usec: u64,
        ring: u32,
        position: f64,
        source: platform_api.TabletPadSource,
        mode: u32,
        group: u32,
    },
    tablet_pad_strip: struct {
        device: DeviceId,
        time_usec: u64,
        strip: u32,
        position: f64,
        source: platform_api.TabletPadSource,
        mode: u32,
        group: u32,
    },
};

pub const Config = struct {
    device_capacity: usize,
    event_capacity: usize,
    restricted_capacity: usize,
};

const DeviceSlot = struct {
    active: bool = false,
    generation: u32 = 1,
    next_free: u32 = none,
    seat_generation: u32 = 0,
    reference: platform_api.DeviceRef = 0,
    info: platform_api.DeviceInfo = .{ .capabilities = .{} },
    defaults: platform_api.DeviceConfiguration = undefined,
    current: platform_api.DeviceConfiguration = undefined,
    scroll_factor: f64 = 1,
    repeat_rate: i32 = 25,
    repeat_delay: i32 = 600,
    pressed: [state_words]u64 = [_]u64{0} ** state_words,
};

const RestrictedSlot = struct {
    active: bool = false,
    fd: std.posix.fd_t = -1,
    handle: session_api.DeviceHandle = undefined,
};

pub const Backend = struct {
    allocator: std.mem.Allocator,
    platform: platform_api.Platform,
    session: *session_api.Session,
    context: *anyopaque,
    restricted_callback: platform_api.Restricted,
    fd: std.posix.fd_t,
    state: State = .active,
    seat_generation: u32,
    devices: []DeviceSlot,
    free_head: u32,
    active_devices: usize = 0,
    restricted: []RestrictedSlot,
    restricted_count: usize = 0,
    callback_failed: bool = false,
    events_buffer: []Event,
    event_count: usize = 0,
    queue_blocked: bool = false,
    poll_token: ?completion.Token = null,
    cancel_token: ?completion.Token = null,

    pub fn create(
        allocator: std.mem.Allocator,
        platform: platform_api.Platform,
        session: *session_api.Session,
        seat: []const u8,
        config: Config,
    ) !*Backend {
        if (config.device_capacity == 0 or config.device_capacity > std.math.maxInt(u32) or
            config.event_capacity < config.device_capacity or config.restricted_capacity == 0 or
            seat.len == 0)
            return error.InvalidConfig;
        if (session.state != .enabled) return error.SessionInactive;

        const self = try allocator.create(Backend);
        errdefer allocator.destroy(self);
        const devices = try allocator.alloc(DeviceSlot, config.device_capacity);
        errdefer allocator.free(devices);
        for (devices, 0..) |*slot, index| slot.* = .{
            .next_free = if (index + 1 < devices.len) @intCast(index + 1) else none,
        };
        const restricted = try allocator.alloc(RestrictedSlot, config.restricted_capacity);
        errdefer allocator.free(restricted);
        @memset(restricted, .{});
        const event_storage = try allocator.alloc(Event, config.event_capacity);
        errdefer allocator.free(event_storage);
        const seat_z = try allocator.dupeZ(u8, seat);
        defer allocator.free(seat_z);

        self.* = .{
            .allocator = allocator,
            .platform = platform,
            .session = session,
            .context = undefined,
            .restricted_callback = .{
                .userdata = self,
                .open_fn = restrictedOpen,
                .close_fn = restrictedClose,
            },
            .fd = -1,
            .seat_generation = session.currentGeneration(),
            .devices = devices,
            .free_head = 0,
            .restricted = restricted,
            .events_buffer = event_storage,
        };
        self.context = try platform.createContext(&self.restricted_callback, seat_z);
        errdefer platform.destroyContext(self.context);
        if (self.callback_failed) return error.RestrictedDeviceFailed;
        self.fd = try platform.getFd(self.context);
        return self;
    }

    pub fn destroy(self: *Backend) !void {
        if (!self.drainComplete()) return error.DrainIncomplete;
        self.platform.destroyContext(self.context);
        const restricted_failed = self.restricted_count != 0 or self.callback_failed;
        const allocator = self.allocator;
        allocator.free(self.events_buffer);
        allocator.free(self.restricted);
        allocator.free(self.devices);
        allocator.destroy(self);
        if (restricted_failed) return error.RestrictedDeviceFailed;
    }

    pub fn events(self: *const Backend) []const Event {
        return self.events_buffer[0..self.event_count];
    }

    pub fn clearEvents(self: *Backend) void {
        self.event_count = 0;
    }

    pub fn deviceCount(self: *const Backend) usize {
        return self.active_devices;
    }

    /// Copies active generation-bearing IDs into `output` and returns the
    /// number written. Enumeration performs no allocation.
    pub fn enumerateDevices(self: *const Backend, output: []DeviceId) usize {
        var count: usize = 0;
        for (self.devices, 0..) |slot, index| if (slot.active and count < output.len) {
            output[count] = self.idFor(@intCast(index));
            count += 1;
        };
        return count;
    }

    pub fn describeDevice(self: *const Backend, id: DeviceId) !DeviceDescription {
        const slot = try self.getDevice(id);
        return .{
            .id = id,
            .info = slot.info,
            .defaults = slot.defaults,
            .current = slot.current,
            .scroll_factor = slot.scroll_factor,
            .repeat_rate = slot.repeat_rate,
            .repeat_delay = slot.repeat_delay,
        };
    }

    pub fn applySoftwareConfiguration(
        self: *Backend,
        id: DeviceId,
        scroll_factor: f64,
        repeat_rate: i32,
        repeat_delay: i32,
    ) !void {
        if (!std.math.isFinite(scroll_factor) or scroll_factor < 0 or
            repeat_rate < 0 or repeat_delay < 0) return error.InvalidConfiguration;
        const slot: *DeviceSlot = @constCast(try self.getDevice(id));
        slot.scroll_factor = scroll_factor;
        slot.repeat_rate = repeat_rate;
        slot.repeat_delay = repeat_delay;
    }

    pub fn applyDeviceConfiguration(self: *Backend, id: DeviceId, value: platform_api.Configuration) !platform_api.ApplyResult {
        const slot: *DeviceSlot = @constCast(try self.getDevice(id));
        const result = try self.platform.applyConfiguration(slot.reference, value);
        // Re-read native state so rejected fields cannot corrupt the snapshot.
        slot.current = try self.platform.deviceConfiguration(slot.reference);
        if (result.unsupported != 0 or result.invalid != 0)
            log.warn("device configuration partially rejected: unsupported=0x{x} invalid=0x{x}", .{ result.unsupported, result.invalid });
        return result;
    }

    pub fn applyConfigurationToAll(self: *Backend, value: platform_api.Configuration) !platform_api.ApplyResult {
        var total: platform_api.ApplyResult = .{};
        for (self.devices, 0..) |slot, index| if (slot.active) {
            const result = try self.applyDeviceConfiguration(self.idFor(@intCast(index)), value);
            total.applied |= result.applied;
            total.unsupported |= result.unsupported;
            total.invalid |= result.invalid;
        };
        return total;
    }

    pub fn isPressed(self: *const Backend, device: DeviceId, code: u32) !bool {
        if (code >= code_count) return error.InvalidCode;
        const slot = try self.getDevice(device);
        return bitIsSet(&slot.pressed, code);
    }

    /// Dispatches libinput's initial device set and prepares one readiness poll.
    pub fn start(self: *Backend, router: *completion.Router, ring: *linux.IoUring) !void {
        if (self.state != .active or self.poll_token != null) return error.InvalidState;
        try self.platform.dispatch(self.context);
        try self.checkCallback();
        try self.drainEvents();
        if (!self.queue_blocked) try self.prepareReadiness(router, ring);
    }

    /// Continues a fixed-capacity event batch after its consumer clears it.
    /// No submission is performed.
    pub fn advance(self: *Backend, router: *completion.Router, ring: *linux.IoUring) !void {
        if (self.state != .active or !self.queue_blocked or self.event_count != 0) return;
        self.queue_blocked = false;
        try self.drainEvents();
        if (!self.queue_blocked and self.poll_token == null)
            try self.prepareReadiness(router, ring);
    }

    pub fn completeReadiness(
        self: *Backend,
        router: *completion.Router,
        ring: *linux.IoUring,
        token: completion.Token,
        result: i32,
    ) !void {
        if (self.poll_token) |poll| if (sameToken(poll, token)) {
            try router.retire(token);
            self.poll_token = null;
            if (self.state != .active) return;
            if (result < 0) {
                self.state = .failed;
                return error.ReadinessFailed;
            }
            const mask: u32 = @intCast(result);
            if (mask & linux.POLL.IN == 0 or
                mask & (linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL) != 0)
            {
                self.state = .failed;
                return error.ReadinessFailed;
            }
            try self.platform.dispatch(self.context);
            try self.checkCallback();
            try self.drainEvents();
            if (!self.queue_blocked) try self.prepareReadiness(router, ring);
            return;
        };
        if (self.cancel_token) |cancel| if (sameToken(cancel, token)) {
            try router.retire(token);
            self.cancel_token = null;
            if (result != 0 and result != negativeErrno(.NOENT) and
                result != negativeErrno(.CANCELED))
                return error.UnexpectedCompletion;
            return;
        };
        return error.UnknownToken;
    }

    /// Stops event production, releases all restricted Session devices, emits
    /// one removal per physical device, and prepares poll removal. Existing
    /// unconsumed motion/key events are intentionally superseded by removal.
    pub fn beginQuiesce(
        self: *Backend,
        router: *completion.Router,
        ring: *linux.IoUring,
    ) !void {
        if (self.state == .suspended or self.state == .quiescing) return;
        if (self.state != .active and self.state != .failed) return error.InvalidState;
        self.state = .quiescing;
        try self.prepareCancel(router, ring);
        self.event_count = 0;
        self.queue_blocked = false;
        var first_error: ?anyerror = null;
        self.platform.suspendContext(self.context) catch |err| {
            first_error = err;
        };
        self.checkCallback() catch |err| if (first_error == null) {
            first_error = err;
        };
        self.discardPlatformEvents() catch |err| if (first_error == null) {
            first_error = err;
        };
        self.removeAllDevices();
        if (first_error) |err| return err;
    }

    pub fn quiesceComplete(self: *Backend) bool {
        if (self.state == .quiescing and self.poll_token == null and
            self.cancel_token == null and self.restricted_count == 0)
            self.state = .suspended;
        return self.state == .suspended;
    }

    pub fn resumeAfterEnable(
        self: *Backend,
        router: *completion.Router,
        ring: *linux.IoUring,
    ) !void {
        if (self.state != .suspended or self.session.state != .enabled)
            return error.InvalidState;
        self.seat_generation = self.session.currentGeneration();
        self.state = .active;
        errdefer self.state = .failed;
        try self.platform.resumeContext(self.context);
        try self.checkCallback();
        try self.platform.dispatch(self.context);
        try self.checkCallback();
        try self.drainEvents();
        if (!self.queue_blocked) try self.prepareReadiness(router, ring);
    }

    pub fn beginDrain(
        self: *Backend,
        router: *completion.Router,
        ring: *linux.IoUring,
    ) !void {
        if (self.state == .draining) return;
        if (self.state != .suspended) try self.beginQuiesce(router, ring);
        self.state = .draining;
    }

    pub fn drainComplete(self: *const Backend) bool {
        return self.state == .draining and self.poll_token == null and
            self.cancel_token == null and self.active_devices == 0 and
            self.restricted_count == 0;
    }

    pub fn ownsToken(self: *const Backend, token: completion.Token) bool {
        if (self.poll_token) |value| if (sameToken(value, token)) return true;
        if (self.cancel_token) |value| if (sameToken(value, token)) return true;
        return false;
    }

    fn prepareReadiness(self: *Backend, router: *completion.Router, ring: *linux.IoUring) !void {
        const token = try router.acquire(.input_ready);
        errdefer router.retire(token) catch unreachable;
        _ = try ring.poll_add(
            token.encode(),
            self.fd,
            linux.POLL.IN | linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL,
        );
        self.poll_token = token;
    }

    fn prepareCancel(self: *Backend, router: *completion.Router, ring: *linux.IoUring) !void {
        if (self.poll_token) |poll| if (self.cancel_token == null) {
            const token = try router.acquire(.input_ready);
            errdefer router.retire(token) catch unreachable;
            _ = try ring.poll_remove(token.encode(), poll.encode());
            self.cancel_token = token;
        };
    }

    fn drainEvents(self: *Backend) !void {
        while (self.event_count < self.events_buffer.len) {
            const raw = try self.platform.nextEvent(self.context) orelse return;
            try self.consume(raw);
        }
        self.queue_blocked = true;
    }

    fn consume(self: *Backend, raw: platform_api.RawEvent) !void {
        switch (raw) {
            .device_added => |value| {
                if (self.findReference(value.device) != null) return error.DuplicateDevice;
                if (self.free_head == none) try self.growDevices();
                const index = self.free_head;
                const slot = &self.devices[index];
                const captured = try self.platform.deviceConfiguration(value.device);
                self.free_head = slot.next_free;
                slot.active = true;
                slot.seat_generation = self.seat_generation;
                slot.reference = value.device;
                slot.info = value.info;
                slot.defaults = captured;
                slot.current = captured;
                slot.scroll_factor = 1;
                slot.repeat_rate = 25;
                slot.repeat_delay = 600;
                @memset(&slot.pressed, 0);
                self.active_devices += 1;
                self.push(.{ .device_added = .{
                    .device = self.idFor(index),
                    .info = value.info,
                } });
            },
            .device_removed => |reference| {
                const index = self.findReference(reference) orelse return error.UnknownDevice;
                self.push(.{ .device_removed = self.idFor(index) });
                self.releaseDevice(index);
            },
            .pointer_motion => |value| self.push(.{ .pointer_motion = .{
                .device = try self.idForReference(value.device),
                .time_usec = value.time_usec,
                .dx = value.dx,
                .dy = value.dy,
                .dx_unaccel = value.dx_unaccel,
                .dy_unaccel = value.dy_unaccel,
            } }),
            .pointer_button => |value| {
                const index = self.findReference(value.device) orelse return error.UnknownDevice;
                if (value.button >= code_count) return error.InvalidCode;
                setBit(&self.devices[index].pressed, value.button, value.pressed);
                self.push(.{ .pointer_button = .{
                    .device = self.idFor(index),
                    .time_usec = value.time_usec,
                    .button = value.button,
                    .pressed = value.pressed,
                } });
            },
            .pointer_axis => |value| {
                if (value.vertical == null and value.horizontal == null)
                    return error.InvalidAxis;
                inline for (.{ value.vertical, value.horizontal }) |axis| if (axis) |present| {
                    if (!std.math.isFinite(present.value) or
                        (present.value120 != null and !std.math.isFinite(present.value120.?)))
                        return error.InvalidAxis;
                };
                const index = self.findReference(value.device) orelse return error.UnknownDevice;
                const factor = self.devices[index].scroll_factor;
                var vertical = value.vertical;
                var horizontal = value.horizontal;
                inline for (.{ &vertical, &horizontal }) |axis| if (axis.*) |*present| {
                    present.value *= factor;
                    if (present.value120) |value120| present.value120 = value120 * factor;
                    if (!std.math.isFinite(present.value) or
                        (present.value120 != null and !std.math.isFinite(present.value120.?)))
                        return error.InvalidAxis;
                };
                self.push(.{ .pointer_axis = .{
                    .device = self.idFor(index),
                    .time_usec = value.time_usec,
                    .source = value.source,
                    .vertical = vertical,
                    .horizontal = horizontal,
                } });
            },
            .swipe_begin => |value| self.push(.{ .swipe_begin = try self.gestureBegin(value) }),
            .swipe_update => |value| self.push(.{ .swipe_update = try self.gestureUpdate(value) }),
            .swipe_end => |value| self.push(.{ .swipe_end = try self.gestureEnd(value) }),
            .pinch_begin => |value| self.push(.{ .pinch_begin = try self.gestureBegin(value) }),
            .pinch_update => |value| {
                try self.validateGestureDevice(value.device);
                if (!std.math.isFinite(value.dx) or !std.math.isFinite(value.dy) or
                    !std.math.isFinite(value.scale) or !std.math.isFinite(value.angle_delta))
                    return error.InvalidGesture;
                self.push(.{ .pinch_update = .{
                    .device = try self.idForReference(value.device),
                    .time_usec = value.time_usec,
                    .dx = value.dx,
                    .dy = value.dy,
                    .scale = value.scale,
                    .angle_delta = value.angle_delta,
                } });
            },
            .pinch_end => |value| self.push(.{ .pinch_end = try self.gestureEnd(value) }),
            .hold_begin => |value| self.push(.{ .hold_begin = try self.gestureBegin(value) }),
            .hold_end => |value| self.push(.{ .hold_end = try self.gestureEnd(value) }),
            .touch_down => |value| self.push(.{ .touch_down = try self.touchPosition(value) }),
            .touch_up => |value| self.push(.{ .touch_up = try self.touchContact(value) }),
            .touch_motion => |value| self.push(.{ .touch_motion = try self.touchPosition(value) }),
            .touch_frame => |value| self.push(.{ .touch_frame = .{
                .device = try self.validateTouchDevice(value.device),
            } }),
            .touch_cancel => |value| self.push(.{ .touch_cancel = .{
                .device = try self.validateTouchDevice(value.device),
            } }),
            .keyboard_key => |value| {
                const index = self.findReference(value.device) orelse return error.UnknownDevice;
                if (value.key >= code_count) return error.InvalidCode;
                setBit(&self.devices[index].pressed, value.key, value.pressed);
                self.push(.{ .keyboard_key = .{
                    .device = self.idFor(index),
                    .time_usec = value.time_usec,
                    .key = value.key,
                    .pressed = value.pressed,
                } });
            },
            .tablet_tool_axis => |value| {
                _ = try self.validateTabletDevice(value.device, true);
                try validateTabletAxes(value.axes);
                self.push(.{ .tablet_tool_axis = .{
                    .device = try self.idForReference(value.device),
                    .tool = value.tool,
                    .time_usec = value.time_usec,
                    .axes = value.axes,
                } });
            },
            .tablet_tool_proximity => |value| {
                _ = try self.validateTabletDevice(value.device, true);
                try validateTabletAxes(value.axes);
                self.push(.{ .tablet_tool_proximity = .{
                    .device = try self.idForReference(value.device),
                    .tool = value.tool,
                    .time_usec = value.time_usec,
                    .entered = value.entered,
                    .axes = value.axes,
                } });
            },
            .tablet_tool_tip => |value| {
                _ = try self.validateTabletDevice(value.device, true);
                try validateTabletAxes(value.axes);
                self.push(.{ .tablet_tool_tip = .{
                    .device = try self.idForReference(value.device),
                    .tool = value.tool,
                    .time_usec = value.time_usec,
                    .down = value.down,
                    .axes = value.axes,
                } });
            },
            .tablet_tool_button => |value| {
                _ = try self.validateTabletDevice(value.device, true);
                try validateTabletAxes(value.axes);
                self.push(.{ .tablet_tool_button = .{
                    .device = try self.idForReference(value.device),
                    .tool = value.tool,
                    .time_usec = value.time_usec,
                    .button = value.button,
                    .pressed = value.pressed,
                    .axes = value.axes,
                } });
            },
            .tablet_pad_button => |value| {
                const slot = try self.validateTabletDevice(value.device, false);
                if (value.button >= slot.info.pad_buttons or
                    !validPadMode(slot.info, value.group, value.mode) or
                    slot.info.pad_groups[value.group].buttons & (@as(u64, 1) << @intCast(value.button)) == 0)
                    return error.InvalidTabletControl;
                self.push(.{ .tablet_pad_button = .{
                    .device = try self.idForReference(value.device),
                    .time_usec = value.time_usec,
                    .button = value.button,
                    .pressed = value.pressed,
                    .mode = value.mode,
                    .group = value.group,
                } });
            },
            .tablet_pad_ring => |value| {
                const slot = try self.validateTabletDevice(value.device, false);
                if (value.ring >= slot.info.pad_rings or
                    !validPadMode(slot.info, value.group, value.mode) or
                    slot.info.pad_groups[value.group].rings & (@as(u64, 1) << @intCast(value.ring)) == 0 or
                    !std.math.isFinite(value.position))
                    return error.InvalidTabletControl;
                self.push(.{ .tablet_pad_ring = .{
                    .device = try self.idForReference(value.device),
                    .time_usec = value.time_usec,
                    .ring = value.ring,
                    .position = value.position,
                    .source = value.source,
                    .mode = value.mode,
                    .group = value.group,
                } });
            },
            .tablet_pad_strip => |value| {
                const slot = try self.validateTabletDevice(value.device, false);
                if (value.strip >= slot.info.pad_strips or
                    !validPadMode(slot.info, value.group, value.mode) or
                    slot.info.pad_groups[value.group].strips & (@as(u64, 1) << @intCast(value.strip)) == 0 or
                    !std.math.isFinite(value.position))
                    return error.InvalidTabletControl;
                self.push(.{ .tablet_pad_strip = .{
                    .device = try self.idForReference(value.device),
                    .time_usec = value.time_usec,
                    .strip = value.strip,
                    .position = value.position,
                    .source = value.source,
                    .mode = value.mode,
                    .group = value.group,
                } });
            },
            .ignored => {},
        }
    }

    fn validateTabletDevice(
        self: *const Backend,
        reference: platform_api.DeviceRef,
        tool: bool,
    ) !*const DeviceSlot {
        const index = self.findReference(reference) orelse return error.UnknownDevice;
        const slot = &self.devices[index];
        if (if (tool) !slot.info.capabilities.tablet_tool else !slot.info.capabilities.tablet_pad)
            return error.MissingCapability;
        return slot;
    }

    fn validateGestureDevice(self: *const Backend, reference: platform_api.DeviceRef) !void {
        const index = self.findReference(reference) orelse return error.UnknownDevice;
        if (!self.devices[index].info.capabilities.pointer) return error.MissingCapability;
    }

    fn validateTouchDevice(self: *const Backend, reference: platform_api.DeviceRef) !DeviceId {
        const index = self.findReference(reference) orelse return error.UnknownDevice;
        if (!self.devices[index].info.capabilities.touch) return error.MissingCapability;
        return self.idFor(index);
    }

    fn touchContact(self: *const Backend, value: platform_api.TouchContact) !TouchContact {
        const device = try self.validateTouchDevice(value.device);
        if (value.slot < 0 or value.seat_slot < 0) return error.InvalidTouchSlot;
        return .{
            .device = device,
            .time_usec = value.time_usec,
            .slot = @intCast(value.slot),
            .seat_slot = @intCast(value.seat_slot),
        };
    }

    fn touchPosition(self: *const Backend, value: platform_api.TouchPosition) !TouchPosition {
        const contact = try self.touchContact(.{
            .device = value.device,
            .time_usec = value.time_usec,
            .slot = value.slot,
            .seat_slot = value.seat_slot,
        });
        if (!std.math.isFinite(value.x) or !std.math.isFinite(value.y) or
            value.x < 0 or value.x > 1 or value.y < 0 or value.y > 1)
            return error.InvalidTouchPosition;
        return .{
            .device = contact.device,
            .time_usec = contact.time_usec,
            .slot = contact.slot,
            .seat_slot = contact.seat_slot,
            .x = value.x,
            .y = value.y,
        };
    }

    fn gestureBegin(self: *const Backend, value: platform_api.GestureBegin) !GestureBegin {
        try self.validateGestureDevice(value.device);
        return .{ .device = try self.idForReference(value.device), .time_usec = value.time_usec, .fingers = value.fingers };
    }

    fn gestureUpdate(self: *const Backend, value: platform_api.GestureUpdate) !GestureUpdate {
        try self.validateGestureDevice(value.device);
        if (!std.math.isFinite(value.dx) or !std.math.isFinite(value.dy)) return error.InvalidGesture;
        return .{ .device = try self.idForReference(value.device), .time_usec = value.time_usec, .dx = value.dx, .dy = value.dy };
    }

    fn gestureEnd(self: *const Backend, value: platform_api.GestureEnd) !GestureEnd {
        try self.validateGestureDevice(value.device);
        return .{ .device = try self.idForReference(value.device), .time_usec = value.time_usec, .cancelled = value.cancelled };
    }

    fn removeAllDevices(self: *Backend) void {
        for (self.devices, 0..) |*slot, index| if (slot.active) {
            self.push(.{ .device_removed = self.idFor(@intCast(index)) });
            self.releaseDevice(@intCast(index));
        };
    }

    fn discardPlatformEvents(self: *Backend) !void {
        while (try self.platform.nextEvent(self.context) != null) {}
    }

    fn push(self: *Backend, event: Event) void {
        std.debug.assert(self.event_count < self.events_buffer.len);
        self.events_buffer[self.event_count] = event;
        self.event_count += 1;
    }

    fn idFor(self: *const Backend, index: u32) DeviceId {
        const slot = &self.devices[index];
        return .{ .slot = index, .generation = slot.generation, .seat_generation = slot.seat_generation };
    }

    fn idForReference(self: *const Backend, reference: platform_api.DeviceRef) !DeviceId {
        return self.idFor(self.findReference(reference) orelse return error.UnknownDevice);
    }

    fn findReference(self: *const Backend, reference: platform_api.DeviceRef) ?u32 {
        for (self.devices, 0..) |slot, index|
            if (slot.active and slot.reference == reference) return @intCast(index);
        return null;
    }

    fn getDevice(self: *const Backend, id: DeviceId) !*const DeviceSlot {
        if (id.slot >= self.devices.len) return error.StaleDevice;
        const slot = &self.devices[id.slot];
        if (!slot.active or slot.generation != id.generation or
            slot.seat_generation != id.seat_generation)
            return error.StaleDevice;
        return slot;
    }

    fn releaseDevice(self: *Backend, index: u32) void {
        const slot = &self.devices[index];
        slot.active = false;
        self.active_devices -= 1;
        if (slot.generation != std.math.maxInt(u32)) {
            slot.generation += 1;
            slot.next_free = self.free_head;
            self.free_head = index;
        } else slot.next_free = none;
    }

    fn growDevices(self: *Backend) !void {
        const old_len = self.devices.len;
        if (old_len >= none) return error.OutOfMemory;
        const new_len = @min(@as(usize, none), old_len + @max(old_len, 1));
        self.devices = try self.allocator.realloc(self.devices, new_len);
        for (self.devices[old_len..], old_len..) |*slot, index| slot.* = .{
            .next_free = if (index + 1 < new_len) @intCast(index + 1) else none,
        };
        self.free_head = @intCast(old_len);
    }

    fn checkCallback(self: *Backend) !void {
        if (self.callback_failed) return error.RestrictedDeviceFailed;
    }

    fn openRestricted(self: *Backend, path: [:0]const u8) !std.posix.fd_t {
        var available: ?*RestrictedSlot = null;
        for (self.restricted) |*slot| if (!slot.active) {
            available = slot;
            break;
        };
        const slot = available orelse return error.RestrictedCapacityExhausted;
        const handle = try self.session.openDevice(path);
        errdefer self.session.closeDevice(handle) catch {};
        const fd = try self.session.deviceFd(handle);
        slot.* = .{ .active = true, .fd = fd, .handle = handle };
        self.restricted_count += 1;
        return fd;
    }

    fn closeRestricted(self: *Backend, fd: std.posix.fd_t) void {
        for (self.restricted) |*slot| if (slot.active and slot.fd == fd) {
            const handle = slot.handle;
            slot.active = false;
            self.restricted_count -= 1;
            self.session.closeDevice(handle) catch {
                self.callback_failed = true;
            };
            return;
        };
        self.callback_failed = true;
    }
};

fn restrictedOpen(userdata: *anyopaque, path: [:0]const u8) !std.posix.fd_t {
    const self: *Backend = @ptrCast(@alignCast(userdata));
    return self.openRestricted(path);
}

fn restrictedClose(userdata: *anyopaque, fd: std.posix.fd_t) void {
    const self: *Backend = @ptrCast(@alignCast(userdata));
    self.closeRestricted(fd);
}

fn bitIsSet(words: *const [state_words]u64, code: u32) bool {
    return words[code / 64] & (@as(u64, 1) << @intCast(code % 64)) != 0;
}

fn setBit(words: *[state_words]u64, code: u32, value: bool) void {
    const mask = @as(u64, 1) << @intCast(code % 64);
    if (value) words[code / 64] |= mask else words[code / 64] &= ~mask;
}

fn validateTabletAxes(axes: platform_api.TabletToolAxes) !void {
    inline for (.{
        axes.x,
        axes.y,
        axes.pressure,
        axes.distance,
        axes.tilt_x,
        axes.tilt_y,
        axes.rotation,
        axes.slider,
        axes.wheel_degrees,
    }) |axis| if (axis) |value| if (!std.math.isFinite(value))
        return error.InvalidTabletAxis;
}

fn validPadMode(info: platform_api.DeviceInfo, group: u32, mode: u32) bool {
    return group < info.pad_mode_groups and mode < info.pad_groups[group].modes;
}

fn sameToken(a: completion.Token, b: completion.Token) bool {
    return a.kind == b.kind and a.slot == b.slot and a.generation == b.generation;
}

fn negativeErrno(errno: linux.E) i32 {
    return -@as(i32, @intFromEnum(errno));
}

const FakeSeat = struct {
    callback: ?*@import("../platform.zig").CallbackContext = null,
    next_fd: std.posix.fd_t = 100,
    opens: usize = 0,
    closes: usize = 0,

    const seat_platform = @import("../platform.zig");
    const vtable: seat_platform.Platform.VTable = .{
        .open_seat = openSeat,
        .close_seat = closeSeat,
        .get_fd = getFd,
        .dispatch = dispatch,
        .disable_seat = disableSeat,
        .open_device = openDevice,
        .close_device = closeDevice,
        .close_fd = closeFd,
    };

    fn platform(self: *FakeSeat) seat_platform.Platform {
        return .{ .context = self, .vtable = &vtable };
    }

    fn openSeat(context: *anyopaque, callback: *seat_platform.CallbackContext) !*anyopaque {
        const self: *FakeSeat = @ptrCast(@alignCast(context));
        self.callback = callback;
        callback.listener.enable(callback.userdata);
        return self;
    }

    fn closeSeat(context: *anyopaque, _: *anyopaque) !void {
        const self: *FakeSeat = @ptrCast(@alignCast(context));
        self.callback = null;
    }

    fn getFd(_: *anyopaque, _: *anyopaque) !std.posix.fd_t {
        return 9;
    }

    fn dispatch(_: *anyopaque, _: *anyopaque) !void {}
    fn disableSeat(_: *anyopaque, _: *anyopaque) !void {}

    fn openDevice(context: *anyopaque, _: *anyopaque, _: [:0]const u8) !seat_platform.OpenedDevice {
        const self: *FakeSeat = @ptrCast(@alignCast(context));
        const fd = self.next_fd;
        self.next_fd += 1;
        self.opens += 1;
        return .{ .id = @intCast(self.opens), .fd = fd };
    }

    fn closeDevice(context: *anyopaque, _: *anyopaque, _: i32) !void {
        const self: *FakeSeat = @ptrCast(@alignCast(context));
        self.closes += 1;
    }

    fn closeFd(_: *anyopaque, _: std.posix.fd_t) !void {}
};

const FakeInput = struct {
    restricted: ?*platform_api.Restricted = null,
    fd: std.posix.fd_t = 11,
    opened_fd: ?std.posix.fd_t = null,
    values: [32]platform_api.RawEvent = undefined,
    next: usize = 0,
    count: usize = 0,
    destroys: usize = 0,
    configuration: platform_api.DeviceConfiguration = .{
        .send_events = .{ .default = .{}, .current = .{} },
        .tap = .{ .default = .disabled, .current = .disabled },
        .accel_speed = .{ .default = 0, .current = 0 },
    },
    apply_count: usize = 0,

    const vtable: platform_api.Platform.VTable = .{
        .create = createContext,
        .destroy = destroyContext,
        .get_fd = getFd,
        .dispatch = dispatch,
        .next_event = nextEvent,
        .suspend_context = suspendContext,
        .resume_context = resumeContext,
        .device_configuration = deviceConfiguration,
        .apply_configuration = applyConfiguration,
    };

    fn platform(self: *FakeInput) platform_api.Platform {
        return .{ .context = self, .vtable = &vtable };
    }

    fn append(self: *FakeInput, value: platform_api.RawEvent) void {
        self.values[self.count] = value;
        self.count += 1;
    }

    fn createContext(context: *anyopaque, restricted: *platform_api.Restricted, seat: [:0]const u8) !*anyopaque {
        const self: *FakeInput = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, seat, "seat0")) return error.WrongSeat;
        self.restricted = restricted;
        self.opened_fd = try restricted.open_fn(restricted.userdata, "/dev/input/fake");
        return self;
    }

    fn destroyContext(context: *anyopaque, _: *anyopaque) void {
        const self: *FakeInput = @ptrCast(@alignCast(context));
        std.debug.assert(self.opened_fd == null);
        self.destroys += 1;
    }

    fn getFd(context: *anyopaque, _: *anyopaque) !std.posix.fd_t {
        const self: *FakeInput = @ptrCast(@alignCast(context));
        return self.fd;
    }

    fn dispatch(_: *anyopaque, _: *anyopaque) !void {}

    fn nextEvent(context: *anyopaque, _: *anyopaque) !?platform_api.RawEvent {
        const self: *FakeInput = @ptrCast(@alignCast(context));
        if (self.next == self.count) {
            self.next = 0;
            self.count = 0;
            return null;
        }
        defer self.next += 1;
        return self.values[self.next];
    }

    fn suspendContext(context: *anyopaque, _: *anyopaque) !void {
        const self: *FakeInput = @ptrCast(@alignCast(context));
        if (self.opened_fd) |fd| self.restricted.?.close_fn(self.restricted.?.userdata, fd);
        self.opened_fd = null;
    }

    fn resumeContext(context: *anyopaque, _: *anyopaque) !void {
        const self: *FakeInput = @ptrCast(@alignCast(context));
        self.opened_fd = try self.restricted.?.open_fn(
            self.restricted.?.userdata,
            "/dev/input/fake",
        );
    }

    fn deviceConfiguration(context: *anyopaque, _: platform_api.DeviceRef) !platform_api.DeviceConfiguration {
        const self: *FakeInput = @ptrCast(@alignCast(context));
        return self.configuration;
    }

    fn applyConfiguration(context: *anyopaque, _: platform_api.DeviceRef, value: platform_api.Configuration) !platform_api.ApplyResult {
        const self: *FakeInput = @ptrCast(@alignCast(context));
        self.apply_count += 1;
        var result: platform_api.ApplyResult = .{};
        if (value.tap) |tap| {
            self.configuration.tap.?.current = tap;
            result.applied |= 1 << 1;
        }
        if (value.accel_speed) |speed| if (std.math.isFinite(speed) and speed >= -1 and speed <= 1) {
            self.configuration.accel_speed.?.current = speed;
            result.applied |= 1 << 7;
        } else {
            result.invalid |= 1 << 7;
        };
        if (value.rotation != null) result.unsupported |= 1 << 18;
        return result;
    }
};

fn testBackend(seat_fake: *FakeSeat, input_fake: *FakeInput, event_capacity: usize) !*Backend {
    const session = try session_api.Session.create(std.testing.allocator, seat_fake.platform(), 4);
    errdefer {
        session.clearEvents();
        session.state = .draining;
        session.destroy() catch {};
    }
    try session.processPending();
    return Backend.create(std.testing.allocator, input_fake.platform(), session, "seat0", .{
        .device_capacity = 2,
        .event_capacity = event_capacity,
        .restricted_capacity = 2,
    });
}

fn destroyTestBackend(backend: *Backend) !void {
    var router = try completion.Router.init(std.testing.allocator, 2);
    defer router.deinit(std.testing.allocator);
    var ring: linux.IoUring = undefined;
    try backend.beginDrain(&router, &ring);
    try std.testing.expect(backend.drainComplete());
    const session = backend.session;
    try backend.destroy();
    session.clearEvents();
    session.state = .draining;
    try session.destroy();
}

test "input: multitouch preserves contacts frames cancellation and generations" {
    var seat_fake: FakeSeat = .{};
    var input_fake: FakeInput = .{};
    const backend = try testBackend(&seat_fake, &input_fake, 16);
    defer destroyTestBackend(backend) catch unreachable;

    try backend.consume(.{ .device_added = .{
        .device = 7,
        .info = .{ .capabilities = .{ .touch = true } },
    } });
    const first = backend.events()[0].device_added.device;
    try backend.consume(.{ .touch_down = .{
        .device = 7,
        .time_usec = 10,
        .slot = 2,
        .seat_slot = 4,
        .x = 0.25,
        .y = 0.75,
    } });
    try backend.consume(.{ .touch_down = .{
        .device = 7,
        .time_usec = 11,
        .slot = 5,
        .seat_slot = 8,
        .x = 1,
        .y = 0,
    } });
    try backend.consume(.{ .touch_frame = .{ .device = 7 } });
    try backend.consume(.{ .touch_motion = .{
        .device = 7,
        .time_usec = 12,
        .slot = 2,
        .seat_slot = 4,
        .x = 0.5,
        .y = 0.6,
    } });
    try backend.consume(.{ .touch_up = .{
        .device = 7,
        .time_usec = 13,
        .slot = 5,
        .seat_slot = 8,
    } });
    try backend.consume(.{ .touch_frame = .{ .device = 7 } });
    try backend.consume(.{ .touch_cancel = .{ .device = 7 } });

    try std.testing.expectEqual(@as(usize, 8), backend.events().len);
    try std.testing.expectEqual(@as(u32, 2), backend.events()[1].touch_down.slot);
    try std.testing.expectEqual(@as(u32, 4), backend.events()[1].touch_down.seat_slot);
    try std.testing.expectEqual(@as(u32, 5), backend.events()[2].touch_down.slot);
    try std.testing.expect(backend.events()[3] == .touch_frame);
    try std.testing.expectEqual(@as(u64, 12), backend.events()[4].touch_motion.time_usec);
    try std.testing.expectEqual(@as(u32, 8), backend.events()[5].touch_up.seat_slot);
    try std.testing.expect(backend.events()[6] == .touch_frame);
    try std.testing.expect(backend.events()[7] == .touch_cancel);

    const valid_count = backend.event_count;
    try std.testing.expectError(error.InvalidTouchPosition, backend.consume(.{ .touch_motion = .{
        .device = 7,
        .time_usec = 14,
        .slot = 2,
        .seat_slot = 4,
        .x = std.math.nan(f64),
        .y = 0.5,
    } }));
    try std.testing.expectError(error.InvalidTouchPosition, backend.consume(.{ .touch_down = .{
        .device = 7,
        .time_usec = 14,
        .slot = 2,
        .seat_slot = 4,
        .x = 1.01,
        .y = 0.5,
    } }));
    try std.testing.expectError(error.InvalidTouchSlot, backend.consume(.{ .touch_up = .{
        .device = 7,
        .time_usec = 14,
        .slot = -1,
        .seat_slot = 4,
    } }));
    try std.testing.expectEqual(valid_count, backend.event_count);

    try backend.consume(.{ .device_removed = 7 });
    try std.testing.expect(backend.events()[valid_count] == .device_removed);
    try std.testing.expectError(error.UnknownDevice, backend.consume(.{ .touch_cancel = .{ .device = 7 } }));
    backend.clearEvents();
    try backend.consume(.{ .device_added = .{
        .device = 7,
        .info = .{ .capabilities = .{ .touch = true } },
    } });
    const replacement = backend.events()[0].device_added.device;
    try std.testing.expectEqual(first.slot, replacement.slot);
    try std.testing.expect(first.generation != replacement.generation);
    try std.testing.expectError(error.StaleDevice, backend.getDevice(first));
}

test "input: physical state remains distinct and device reuse advances generation" {
    var seat_fake: FakeSeat = .{};
    var input_fake: FakeInput = .{};
    const backend = try testBackend(&seat_fake, &input_fake, 8);
    defer destroyTestBackend(backend) catch unreachable;

    input_fake.append(.{ .device_added = .{
        .device = 1,
        .info = .{ .capabilities = .{ .keyboard = true } },
    } });
    input_fake.append(.{ .device_added = .{
        .device = 2,
        .info = .{ .capabilities = .{ .keyboard = true } },
    } });
    input_fake.append(.{ .keyboard_key = .{
        .device = 1,
        .time_usec = 10,
        .key = 30,
        .pressed = true,
    } });
    try backend.drainEvents();
    const first = backend.events()[0].device_added.device;
    const second = backend.events()[1].device_added.device;
    try std.testing.expect(try backend.isPressed(first, 30));
    try std.testing.expect(!try backend.isPressed(second, 30));

    backend.clearEvents();
    input_fake.append(.{ .device_removed = 1 });
    input_fake.append(.{ .device_added = .{
        .device = 3,
        .info = .{ .capabilities = .{ .pointer = true } },
    } });
    try backend.drainEvents();
    const replacement = backend.events()[1].device_added.device;
    try std.testing.expectEqual(first.slot, replacement.slot);
    try std.testing.expect(first.generation != replacement.generation);
    try std.testing.expectError(error.StaleDevice, backend.isPressed(first, 30));
}

test "input: device storage grows beyond its initial reservation" {
    var seat_fake: FakeSeat = .{};
    var input_fake: FakeInput = .{};
    const backend = try testBackend(&seat_fake, &input_fake, 4);
    defer destroyTestBackend(backend) catch unreachable;

    for (1..4) |reference| try backend.consume(.{ .device_added = .{
        .device = reference,
        .info = .{ .capabilities = .{ .keyboard = true } },
    } });

    try std.testing.expectEqual(@as(usize, 3), backend.deviceCount());
    try std.testing.expectEqual(@as(usize, 4), backend.devices.len);
    try std.testing.expectEqual(@as(usize, 3), backend.events().len);
}

test "input: pointer button motion and keyboard events retain generation identity" {
    var seat_fake: FakeSeat = .{};
    var input_fake: FakeInput = .{};
    const backend = try testBackend(&seat_fake, &input_fake, 8);
    defer destroyTestBackend(backend) catch unreachable;

    input_fake.append(.{ .device_added = .{
        .device = 7,
        .info = .{ .capabilities = .{ .pointer = true, .keyboard = true } },
    } });
    input_fake.append(.{ .pointer_motion = .{
        .device = 7,
        .time_usec = 11,
        .dx = 1.25,
        .dy = -2.5,
        .dx_unaccel = 2.5,
        .dy_unaccel = -5,
    } });
    input_fake.append(.{ .pointer_button = .{
        .device = 7,
        .time_usec = 12,
        .button = 0x110,
        .pressed = true,
    } });
    input_fake.append(.{ .pointer_axis = .{
        .device = 7,
        .time_usec = 13,
        .source = .wheel,
        .vertical = .{ .value = 15, .value120 = 120 },
        .horizontal = null,
    } });
    input_fake.append(.{ .keyboard_key = .{
        .device = 7,
        .time_usec = 14,
        .key = 42,
        .pressed = true,
    } });
    try backend.drainEvents();
    const id = backend.events()[0].device_added.device;
    const motion = backend.events()[1].pointer_motion;
    try std.testing.expectEqual(id, motion.device);
    try std.testing.expectEqual(@as(?f64, 2.5), motion.dx_unaccel);
    try std.testing.expectEqual(@as(?f64, -5), motion.dy_unaccel);
    try std.testing.expectEqual(id, backend.events()[2].pointer_button.device);
    const axis = backend.events()[3].pointer_axis;
    try std.testing.expectEqual(id, axis.device);
    try std.testing.expectEqual(platform_api.AxisSource.wheel, axis.source);
    try std.testing.expectEqual(@as(f64, 15), axis.vertical.?.value);
    try std.testing.expectEqual(@as(?f64, 120), axis.vertical.?.value120);
    try std.testing.expectEqual(@as(?platform_api.AxisValue, null), axis.horizontal);
    try std.testing.expectEqual(id, backend.events()[4].keyboard_key.device);
    try std.testing.expect(try backend.isPressed(id, 0x110));
    try std.testing.expect(try backend.isPressed(id, 42));
}

test "input: gesture lifecycles preserve normalized values and device identity" {
    var seat_fake: FakeSeat = .{};
    var input_fake: FakeInput = .{};
    const backend = try testBackend(&seat_fake, &input_fake, 16);
    defer destroyTestBackend(backend) catch unreachable;

    try backend.consume(.{ .device_added = .{
        .device = 7,
        .info = .{ .capabilities = .{ .pointer = true } },
    } });
    const id = backend.events()[0].device_added.device;
    backend.clearEvents();
    try backend.consume(.{ .swipe_begin = .{ .device = 7, .time_usec = 10, .fingers = 3 } });
    try backend.consume(.{ .swipe_update = .{ .device = 7, .time_usec = 11, .dx = 1.25, .dy = -2.5 } });
    try backend.consume(.{ .swipe_end = .{ .device = 7, .time_usec = 12, .cancelled = true } });
    try backend.consume(.{ .pinch_begin = .{ .device = 7, .time_usec = 20, .fingers = 4 } });
    try backend.consume(.{ .pinch_update = .{
        .device = 7,
        .time_usec = 21,
        .dx = -3,
        .dy = 4,
        .scale = 0.75,
        .angle_delta = 12.5,
    } });
    try backend.consume(.{ .pinch_end = .{ .device = 7, .time_usec = 22, .cancelled = false } });
    try backend.consume(.{ .hold_begin = .{ .device = 7, .time_usec = 30, .fingers = 2 } });
    try backend.consume(.{ .hold_end = .{ .device = 7, .time_usec = 31, .cancelled = true } });

    try std.testing.expectEqual(id, backend.events()[0].swipe_begin.device);
    try std.testing.expectEqual(@as(u32, 3), backend.events()[0].swipe_begin.fingers);
    try std.testing.expectEqual(@as(u64, 11), backend.events()[1].swipe_update.time_usec);
    try std.testing.expectEqual(@as(f64, -2.5), backend.events()[1].swipe_update.dy);
    try std.testing.expect(backend.events()[2].swipe_end.cancelled);
    try std.testing.expectEqual(@as(u32, 4), backend.events()[3].pinch_begin.fingers);
    try std.testing.expectEqual(@as(f64, 0.75), backend.events()[4].pinch_update.scale);
    try std.testing.expectEqual(@as(f64, 12.5), backend.events()[4].pinch_update.angle_delta);
    try std.testing.expect(!backend.events()[5].pinch_end.cancelled);
    try std.testing.expectEqual(@as(u64, 30), backend.events()[6].hold_begin.time_usec);
    try std.testing.expect(backend.events()[7].hold_end.cancelled);
}

test "input: gestures reject unknown non-pointer and non-finite values" {
    var seat_fake: FakeSeat = .{};
    var input_fake: FakeInput = .{};
    const backend = try testBackend(&seat_fake, &input_fake, 8);
    defer destroyTestBackend(backend) catch unreachable;

    try std.testing.expectError(error.UnknownDevice, backend.consume(.{ .hold_begin = .{
        .device = 99,
        .time_usec = 1,
        .fingers = 2,
    } }));
    try backend.consume(.{ .device_added = .{
        .device = 1,
        .info = .{ .capabilities = .{} },
    } });
    try std.testing.expectError(error.MissingCapability, backend.consume(.{ .swipe_begin = .{
        .device = 1,
        .time_usec = 2,
        .fingers = 3,
    } }));
    try backend.consume(.{ .device_added = .{
        .device = 2,
        .info = .{ .capabilities = .{ .pointer = true } },
    } });
    try std.testing.expectError(error.InvalidGesture, backend.consume(.{ .swipe_update = .{
        .device = 2,
        .time_usec = 3,
        .dx = std.math.nan(f64),
        .dy = 0,
    } }));
    try std.testing.expectError(error.InvalidGesture, backend.consume(.{ .pinch_update = .{
        .device = 2,
        .time_usec = 4,
        .dx = 0,
        .dy = 0,
        .scale = std.math.inf(f64),
        .angle_delta = 0,
    } }));
}

test "input: quiesce closes Session devices and teardown occurs outside callbacks" {
    var seat_fake: FakeSeat = .{};
    var input_fake: FakeInput = .{};
    const backend = try testBackend(&seat_fake, &input_fake, 4);
    input_fake.append(.{ .device_added = .{
        .device = 9,
        .info = .{ .capabilities = .{ .pointer = true } },
    } });
    try backend.drainEvents();
    var router = try completion.Router.init(std.testing.allocator, 2);
    defer router.deinit(std.testing.allocator);
    var ring: linux.IoUring = undefined;

    try backend.beginQuiesce(&router, &ring);
    try std.testing.expect(backend.quiesceComplete());
    try std.testing.expectEqual(@as(usize, 1), seat_fake.closes);
    try std.testing.expectEqual(@as(usize, 0), input_fake.destroys);
    try std.testing.expectEqual(@as(usize, 1), backend.events().len);
    try std.testing.expectEqual(Event.device_removed, std.meta.activeTag(backend.events()[0]));
    backend.state = .draining;
    const session = backend.session;
    try backend.destroy();
    try std.testing.expectEqual(@as(usize, 1), input_fake.destroys);
    session.clearEvents();
    session.state = .draining;
    try session.destroy();
}

test "input: poll and removal CQEs drain in either order" {
    var seat_fake: FakeSeat = .{};
    var input_fake: FakeInput = .{};
    const backend = try testBackend(&seat_fake, &input_fake, 2);
    defer destroyTestBackend(backend) catch unreachable;
    var router = try completion.Router.init(std.testing.allocator, 2);
    defer router.deinit(std.testing.allocator);
    const poll = try router.acquire(.input_ready);
    const cancel = try router.acquire(.input_ready);
    backend.poll_token = poll;
    backend.cancel_token = cancel;
    backend.state = .quiescing;
    backend.restricted_callback.close_fn(
        backend.restricted_callback.userdata,
        input_fake.opened_fd.?,
    );
    input_fake.opened_fd = null;
    var ring: linux.IoUring = undefined;

    try backend.completeReadiness(&router, &ring, cancel, 0);
    try std.testing.expect(!backend.quiesceComplete());
    try backend.completeReadiness(&router, &ring, poll, negativeErrno(.CANCELED));
    try std.testing.expect(backend.quiesceComplete());
}

test "input: target poll may complete before poll removal" {
    var seat_fake: FakeSeat = .{};
    var input_fake: FakeInput = .{};
    const backend = try testBackend(&seat_fake, &input_fake, 2);
    defer destroyTestBackend(backend) catch unreachable;
    var router = try completion.Router.init(std.testing.allocator, 2);
    defer router.deinit(std.testing.allocator);
    const poll = try router.acquire(.input_ready);
    const cancel = try router.acquire(.input_ready);
    backend.poll_token = poll;
    backend.cancel_token = cancel;
    backend.state = .quiescing;
    backend.restricted_callback.close_fn(
        backend.restricted_callback.userdata,
        input_fake.opened_fd.?,
    );
    input_fake.opened_fd = null;
    var ring: linux.IoUring = undefined;

    try backend.completeReadiness(&router, &ring, poll, negativeErrno(.CANCELED));
    try std.testing.expect(!backend.quiesceComplete());
    try backend.completeReadiness(&router, &ring, cancel, negativeErrno(.NOENT));
    try std.testing.expect(backend.quiesceComplete());
}

test "input: Session re-enable advances seat generation before new devices" {
    var seat_fake: FakeSeat = .{};
    var input_fake: FakeInput = .{};
    const backend = try testBackend(&seat_fake, &input_fake, 2);
    defer destroyTestBackend(backend) catch unreachable;
    input_fake.append(.{ .device_added = .{
        .device = 1,
        .info = .{ .capabilities = .{ .keyboard = true } },
    } });
    try backend.drainEvents();
    const old = backend.events()[0].device_added.device;
    backend.clearEvents();
    var router = try completion.Router.init(std.testing.allocator, 2);
    defer router.deinit(std.testing.allocator);
    var ring: linux.IoUring = undefined;
    try backend.beginQuiesce(&router, &ring);
    try std.testing.expect(backend.quiesceComplete());
    backend.clearEvents();

    const callback = seat_fake.callback.?;
    callback.listener.disable(callback.userdata);
    try backend.session.processPending();
    try backend.session.acknowledgeDisable(true);
    backend.session.clearEvents();
    callback.listener.enable(callback.userdata);
    try backend.session.processPending();
    try std.testing.expectEqual(@as(u32, 2), backend.session.currentGeneration());

    input_fake.append(.{ .device_added = .{
        .device = 2,
        .info = .{ .capabilities = .{ .pointer = true } },
    } });
    input_fake.append(.{ .device_added = .{
        .device = 3,
        .info = .{ .capabilities = .{ .keyboard = true } },
    } });
    try backend.resumeAfterEnable(&router, &ring);
    const current = backend.events()[0].device_added.device;
    try std.testing.expectEqual(@as(u32, 2), current.seat_generation);
    try std.testing.expect(old.seat_generation != current.seat_generation);
}

test "input: tablet metadata and events retain generational device ownership" {
    var seat_fake: FakeSeat = .{};
    var input_fake: FakeInput = .{};
    const backend = try testBackend(&seat_fake, &input_fake, 16);
    defer destroyTestBackend(backend) catch unreachable;

    try backend.consume(.{ .device_added = .{
        .device = 12,
        .info = .{
            .capabilities = .{ .tablet_tool = true, .tablet_pad = true },
            .vendor = 0x56a,
            .product = 0x37,
            .group = 44,
            .pad_buttons = 2,
            .pad_rings = 1,
            .pad_strips = 1,
            .pad_mode_groups = 1,
            .pad_groups = groups: {
                var groups = [_]platform_api.TabletPadGroupInfo{.{}} **
                    platform_api.max_tablet_pad_groups;
                groups[0] = .{ .buttons = 0b11, .rings = 0b1, .strips = 0b1, .modes = 2 };
                break :groups groups;
            },
        },
    } });
    const id = backend.events()[0].device_added.device;
    try std.testing.expectEqual(@as(u32, 0x56a), backend.events()[0].device_added.info.vendor);
    backend.clearEvents();

    try backend.consume(.{ .tablet_tool_proximity = .{
        .device = 12,
        .tool = .{
            .reference = 91,
            .kind = .pen,
            .serial = 1234,
            .hardware_id = 5678,
            .capabilities = .{ .pressure = true, .tilt = true },
        },
        .time_usec = 100,
        .entered = true,
        .axes = .{ .x = 0.25, .y = 0.75, .pressure = 0.5 },
    } });
    try backend.consume(.{ .tablet_tool_axis = .{
        .device = 12,
        .tool = 91,
        .time_usec = 101,
        .axes = .{ .x = 0.5, .pressure = 0.8, .wheel_clicks = -1 },
    } });
    try backend.consume(.{ .tablet_tool_tip = .{
        .device = 12,
        .tool = 91,
        .time_usec = 102,
        .down = true,
        .axes = .{ .x = 0.6, .y = 0.7, .pressure = 1 },
    } });
    try backend.consume(.{ .tablet_pad_ring = .{
        .device = 12,
        .time_usec = 103,
        .ring = 0,
        .position = 90,
        .source = .finger,
        .mode = 0,
        .group = 0,
    } });
    try std.testing.expectEqual(id, backend.events()[0].tablet_tool_proximity.device);
    try std.testing.expectEqual(@as(platform_api.ToolRef, 91), backend.events()[1].tablet_tool_axis.tool);
    try std.testing.expectEqual(@as(?f64, 1), backend.events()[2].tablet_tool_tip.axes.pressure);
    try std.testing.expectEqual(platform_api.TabletPadSource.finger, backend.events()[3].tablet_pad_ring.source);

    try std.testing.expectError(error.InvalidTabletAxis, backend.consume(.{ .tablet_tool_axis = .{
        .device = 12,
        .tool = 91,
        .time_usec = 104,
        .axes = .{ .pressure = std.math.nan(f64) },
    } }));
    try std.testing.expectError(error.InvalidTabletAxis, backend.consume(.{ .tablet_tool_button = .{
        .device = 12,
        .tool = 91,
        .time_usec = 105,
        .button = 1,
        .pressed = true,
        .axes = .{ .rotation = std.math.inf(f64) },
    } }));
    try std.testing.expectError(error.InvalidTabletControl, backend.consume(.{ .tablet_pad_button = .{
        .device = 12,
        .time_usec = 106,
        .button = 2,
        .pressed = true,
        .mode = 0,
        .group = 0,
    } }));
}

test "input: readiness and removal join the shared ring without internal submit" {
    var ring = linux.IoUring.init(8, 0) catch |err| switch (err) {
        error.PermissionDenied, error.SystemOutdated => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();
    const raw_fd = linux.eventfd(1, linux.EFD.CLOEXEC);
    if (linux.errno(raw_fd) != .SUCCESS) return error.EventFdFailed;
    const fd: std.posix.fd_t = @intCast(raw_fd);
    defer _ = linux.close(fd);

    var seat_fake: FakeSeat = .{};
    var input_fake: FakeInput = .{ .fd = fd };
    const backend = try testBackend(&seat_fake, &input_fake, 4);
    var router = try completion.Router.init(std.testing.allocator, 4);
    defer router.deinit(std.testing.allocator);

    try backend.start(&router, &ring);
    try std.testing.expectEqual(@as(u32, 1), ring.sq_ready());
    _ = try ring.submit_and_wait(1);
    const ready = try ring.copy_cqe();
    const ready_token = router.route(ready.user_data) orelse return error.UnknownToken;
    try backend.completeReadiness(&router, &ring, ready_token, ready.res);
    try std.testing.expectEqual(@as(u32, 1), ring.sq_ready());

    try backend.beginDrain(&router, &ring);
    try std.testing.expectEqual(@as(u32, 2), ring.sq_ready());
    _ = try ring.submit_and_wait(2);
    var completed: usize = 0;
    while (completed < 2) : (completed += 1) {
        const cqe = try ring.copy_cqe();
        const token = router.route(cqe.user_data) orelse return error.UnknownToken;
        try backend.completeReadiness(&router, &ring, token, cqe.res);
    }
    try std.testing.expect(backend.drainComplete());
    const session = backend.session;
    try backend.destroy();
    session.clearEvents();
    session.state = .draining;
    try session.destroy();
}

test "input: configuration snapshots survive hotplug and stale IDs" {
    var seat_fake: FakeSeat = .{};
    var input_fake: FakeInput = .{};
    const backend = try testBackend(&seat_fake, &input_fake, 8);
    defer destroyTestBackend(backend) catch unreachable;

    var info: platform_api.DeviceInfo = .{
        .capabilities = .{ .pointer = true, .touch = true },
        .is_touchpad = true,
    };
    @memcpy(info.name[0..8], "Touchpad");
    info.name_len = 8;
    input_fake.append(.{ .device_added = .{ .device = 41, .info = info } });
    try backend.drainEvents();

    var ids: [2]DeviceId = undefined;
    try std.testing.expectEqual(@as(usize, 1), backend.enumerateDevices(&ids));
    const initial = try backend.describeDevice(ids[0]);
    try std.testing.expectEqualStrings("Touchpad", initial.name());
    try std.testing.expect(initial.info.is_touchpad);
    try std.testing.expectEqual(platform_api.Toggle.disabled, initial.defaults.tap.?.default);

    const first = try backend.applyDeviceConfiguration(ids[0], .{
        .tap = .enabled,
        .accel_speed = 0.5,
        .rotation = 90,
    });
    try std.testing.expect(first.applied & (1 << 1) != 0);
    try std.testing.expect(first.unsupported & (1 << 18) != 0);
    const configured = try backend.describeDevice(ids[0]);
    try std.testing.expectEqual(platform_api.Toggle.enabled, configured.current.tap.?.current);
    try std.testing.expectEqual(@as(f64, 0.5), configured.current.accel_speed.?.current);
    try std.testing.expectEqual(platform_api.Toggle.disabled, configured.defaults.tap.?.default);

    // Reload-style aggregate application reaches existing and later hotplugged
    // devices, while removed generations remain unusable.
    _ = try backend.applyConfigurationToAll(.{ .tap = .disabled });
    input_fake.append(.{ .device_removed = 41 });
    try backend.drainEvents();
    try std.testing.expectError(error.StaleDevice, backend.describeDevice(ids[0]));
    input_fake.append(.{ .device_added = .{ .device = 42, .info = info } });
    try backend.drainEvents();
    try std.testing.expectEqual(@as(usize, 1), backend.enumerateDevices(&ids));
    _ = try backend.applyConfigurationToAll(.{ .tap = .enabled });
    try std.testing.expectEqual(platform_api.Toggle.enabled, (try backend.describeDevice(ids[0])).current.tap.?.current);
    try std.testing.expectEqual(@as(usize, 3), input_fake.apply_count);
}
