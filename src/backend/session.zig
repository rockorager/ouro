//! Stable libseat session and device ownership integrated with Ouro's shared
//! io_uring. Creation is heap-only so callback userdata never aliases a moved
//! or returned-by-value session.

const std = @import("std");
const linux = std.os.linux;
const completion = @import("../runtime/completion.zig");
const platform_api = @import("platform.zig");

const none = std.math.maxInt(u32);
const event_capacity = 64;

pub const State = enum {
    enabling,
    enabled,
    disabling,
    disabled,
    failed,
    draining,
};

pub const DeviceHandle = struct {
    slot: u32,
    generation: u32,
    session_generation: u32,
};

pub const Event = union(enum) {
    enabled: u32,
    disabling: u32,
    disabled: u32,
    failed,
    draining,
};

pub const Error = std.mem.Allocator.Error || completion.Error || error{
    InvalidConfig,
    SessionInactive,
    DeviceCapacityExhausted,
    StaleDevice,
    DevicesNotQuiescent,
    InvalidState,
    EventQueueFull,
    SubmissionQueueFull,
    UnknownToken,
    UnexpectedCompletion,
    DrainIncomplete,
};

const Pending = enum {
    none,
    enable,
    disable,
    disable_then_enable,
};

const DeviceSlot = struct {
    active: bool = false,
    generation: u32 = 1,
    next_free: u32 = none,
    session_generation: u32 = 0,
    id: i32 = -1,
    fd: std.posix.fd_t = -1,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    platform: platform_api.Platform,
    seat: *anyopaque,
    callback: platform_api.CallbackContext,
    fd: std.posix.fd_t,
    state: State = .enabling,
    session_generation: u32 = 1,
    pending: Pending = .none,
    devices: []DeviceSlot,
    free_head: u32,
    free_count: usize,
    active_devices: usize = 0,
    poll_token: ?completion.Token = null,
    cancel_token: ?completion.Token = null,
    events_buffer: [event_capacity]Event = undefined,
    event_count: usize = 0,

    /// Allocates the session before handing its callback context to libseat.
    /// Any partial failure closes the libseat handle before freeing callback
    /// storage, then unwinds the device table and stable owner in reverse.
    pub fn create(
        allocator: std.mem.Allocator,
        platform: platform_api.Platform,
        device_capacity: usize,
    ) !*Session {
        if (device_capacity == 0 or device_capacity > std.math.maxInt(u32))
            return error.InvalidConfig;

        const self = try allocator.create(Session);
        errdefer allocator.destroy(self);
        const devices = try allocator.alloc(DeviceSlot, device_capacity);
        errdefer allocator.free(devices);
        for (devices, 0..) |*slot, index| slot.* = .{
            .next_free = if (index + 1 < devices.len) @intCast(index + 1) else none,
        };

        self.* = .{
            .allocator = allocator,
            .platform = platform,
            .seat = undefined,
            .callback = .{
                .listener = .{ .enable = callbackEnable, .disable = callbackDisable },
                .userdata = self,
            },
            .fd = -1,
            .devices = devices,
            .free_head = 0,
            .free_count = devices.len,
        };
        self.seat = try platform.openSeat(&self.callback);
        errdefer platform.closeSeat(self.seat) catch {};
        self.fd = try platform.getFd(self.seat);
        // libseat_open_seat may read an enable event into libseat's userspace
        // buffer while consuming its synchronous open reply. In that case the
        // underlying fd is no longer readable, so waiting for the first poll
        // CQE would strand the buffered callback indefinitely. Drain once
        // nonblocking before readiness becomes poll-driven.
        try platform.dispatch(self.seat);
        return self;
    }

    /// Requires all device and poll/removal CQEs to have drained. Closing is
    /// terminal: libseat may report an error after consuming the seat, so the
    /// callback context is freed and the opaque pointer is never retried.
    pub fn destroy(self: *Session) !void {
        if (self.state != .draining or !self.drainComplete())
            return error.DrainIncomplete;
        const close_result = self.platform.closeSeat(self.seat);
        const allocator = self.allocator;
        allocator.free(self.devices);
        allocator.destroy(self);
        return close_result;
    }

    pub fn events(self: *const Session) []const Event {
        return self.events_buffer[0..self.event_count];
    }

    pub fn clearEvents(self: *Session) void {
        self.event_count = 0;
    }

    pub fn deviceCount(self: *const Session) usize {
        return self.active_devices;
    }

    pub fn availableDevices(self: *const Session) usize {
        return self.free_count;
    }

    pub fn currentGeneration(self: *const Session) u32 {
        return self.session_generation;
    }

    /// Applies callback commands at the coordinator's command phase, never in
    /// C callback or nested libseat dispatch. Duplicate callbacks coalesce.
    pub fn processPending(self: *Session) !void {
        const pending = self.pending;
        self.pending = .none;
        errdefer {
            if (self.pending == .none) self.pending = pending;
        }
        switch (pending) {
            .none => {},
            .enable => try self.applyEnable(),
            .disable => try self.applyDisable(false),
            .disable_then_enable => try self.applyDisable(true),
        }
    }

    /// Acknowledges disable only after both the coordinator and this owner
    /// report dependent devices quiescent. A queued enable is published with a
    /// new generation only after the old disable has been acknowledged.
    pub fn acknowledgeDisable(self: *Session, dependents_quiescent: bool) !void {
        if (self.state != .disabling) return error.InvalidState;
        if (!dependents_quiescent or self.active_devices != 0)
            return error.DevicesNotQuiescent;

        const resumes = self.pending == .enable or self.pending == .disable_then_enable;
        const required_events: usize = if (resumes) 2 else 1;
        if (self.events_buffer.len - self.event_count < required_events)
            return error.EventQueueFull;
        self.platform.disableSeat(self.seat) catch |err| {
            self.events_buffer[self.event_count] = .failed;
            self.event_count += 1;
            self.state = .failed;
            self.pending = .none;
            return err;
        };
        self.events_buffer[self.event_count] = .{ .disabled = self.session_generation };
        self.event_count += 1;
        self.state = .disabled;
        if (resumes) {
            self.pending = .none;
            try self.applyEnable();
        }
    }

    pub fn openDevice(self: *Session, path: [:0]const u8) !DeviceHandle {
        if (self.state != .enabled) return error.SessionInactive;
        if (self.free_head == none) return error.DeviceCapacityExhausted;

        const opened = try self.platform.openDevice(self.seat, path);
        const index = self.free_head;
        const slot = &self.devices[index];
        self.free_head = slot.next_free;
        self.free_count -= 1;
        self.active_devices += 1;
        slot.active = true;
        slot.session_generation = self.session_generation;
        slot.id = opened.id;
        slot.fd = opened.fd;
        return .{
            .slot = index,
            .generation = slot.generation,
            .session_generation = slot.session_generation,
        };
    }

    /// The FD is owned by this session until `closeDevice`. libseat releases
    /// device access by ID, but the caller must close the returned FD.
    pub fn deviceFd(self: *Session, handle: DeviceHandle) !std.posix.fd_t {
        return (try self.getDevice(handle)).fd;
    }

    /// Releases the libseat device and closes its FD exactly once, then retires
    /// the generation even if either operation reports failure. The libseat
    /// error takes precedence when both operations fail.
    pub fn closeDevice(self: *Session, handle: DeviceHandle) !void {
        const slot = try self.getDevice(handle);
        const id = slot.id;
        const fd = slot.fd;
        self.releaseDevice(handle.slot);
        const device_result = self.platform.closeDevice(self.seat, id);
        const fd_result = self.platform.closeFd(fd);
        device_result catch |err| return err;
        try fd_result;
    }

    /// Queues a one-shot poll on the shared Ouro ring. It does not submit.
    pub fn prepareReadiness(
        self: *Session,
        router: *completion.Router,
        ring: *linux.IoUring,
    ) !void {
        if (self.poll_token != null or self.cancel_token != null)
            return error.InvalidState;
        if (self.state == .failed or self.state == .draining)
            return error.InvalidState;

        const token = try router.acquire(.backend_ready);
        errdefer router.retire(token) catch unreachable;
        _ = try ring.poll_add(
            token.encode(),
            self.fd,
            linux.POLL.IN | linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL,
        );
        self.poll_token = token;
    }

    /// Consumes one R1-routed backend CQE. Every poll/removal token is retired
    /// only on its own terminal CQE. A successful readiness dispatch queues C
    /// callback commands and immediately prepares (but does not submit) the
    /// next one-shot poll.
    pub fn completeReadiness(
        self: *Session,
        router: *completion.Router,
        ring: *linux.IoUring,
        token: completion.Token,
        result: i32,
    ) !void {
        if (self.poll_token) |poll_token| {
            if (sameToken(poll_token, token)) {
                try router.retire(token);
                self.poll_token = null;
                if (self.state == .draining or self.state == .failed) return;
                if (result < 0) {
                    try self.markFailed();
                    return;
                }
                const mask: u32 = @intCast(result);
                if (mask & (linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL) != 0) {
                    try self.markFailed();
                    return;
                }
                if (mask & linux.POLL.IN == 0) {
                    try self.markFailed();
                    return error.UnexpectedCompletion;
                }
                self.platform.dispatch(self.seat) catch {
                    try self.markFailed();
                    return;
                };
                try self.prepareReadiness(router, ring);
                return;
            }
        }
        if (self.cancel_token) |cancel_token| {
            if (sameToken(cancel_token, token)) {
                try router.retire(token);
                self.cancel_token = null;
                if (result != 0 and result != negativeErrno(.NOENT) and
                    result != negativeErrno(.CANCELED))
                    return error.UnexpectedCompletion;
                return;
            }
        }
        return error.UnknownToken;
    }

    /// Enters terminal drain and queues poll removal without submitting. Both
    /// the removal and target poll CQEs must be routed back before destroy.
    pub fn beginDrain(
        self: *Session,
        router: *completion.Router,
        ring: *linux.IoUring,
    ) !void {
        if (self.state != .draining) {
            try self.pushEvent(.draining);
            self.state = .draining;
            self.pending = .none;
        }
        if (self.poll_token) |poll_token| if (self.cancel_token == null) {
            const token = try router.acquire(.backend_ready);
            errdefer router.retire(token) catch unreachable;
            _ = try ring.poll_remove(token.encode(), poll_token.encode());
            self.cancel_token = token;
        };
    }

    pub fn drainComplete(self: *const Session) bool {
        return self.poll_token == null and self.cancel_token == null and
            self.active_devices == 0;
    }

    fn applyEnable(self: *Session) !void {
        switch (self.state) {
            .enabling => {},
            .disabled => {
                if (self.session_generation == std.math.maxInt(u32)) {
                    try self.markFailed();
                    return;
                }
                self.session_generation += 1;
            },
            .disabling => {
                self.pending = .enable;
                return;
            },
            .enabled, .failed, .draining => return,
        }
        try self.pushEvent(.{ .enabled = self.session_generation });
        self.state = .enabled;
    }

    fn applyDisable(self: *Session, should_resume: bool) !void {
        switch (self.state) {
            .enabled, .enabling => {
                try self.pushEvent(.{ .disabling = self.session_generation });
                self.state = .disabling;
                if (should_resume) self.pending = .enable;
            },
            .disabling => if (should_resume) {
                self.pending = .enable;
            },
            .disabled => {},
            .failed, .draining => {},
        }
    }

    fn markFailed(self: *Session) !void {
        if (self.state == .failed or self.state == .draining) return;
        try self.pushEvent(.failed);
        self.state = .failed;
        self.pending = .none;
    }

    fn pushEvent(self: *Session, event: Event) !void {
        if (self.event_count == self.events_buffer.len) return error.EventQueueFull;
        self.events_buffer[self.event_count] = event;
        self.event_count += 1;
    }

    fn getDevice(self: *Session, handle: DeviceHandle) !*DeviceSlot {
        if (handle.slot >= self.devices.len) return error.StaleDevice;
        const slot = &self.devices[handle.slot];
        if (!slot.active or slot.generation != handle.generation or
            slot.session_generation != handle.session_generation)
            return error.StaleDevice;
        return slot;
    }

    fn releaseDevice(self: *Session, index: u32) void {
        const slot = &self.devices[index];
        std.debug.assert(slot.active);
        slot.active = false;
        self.active_devices -= 1;
        if (slot.generation != std.math.maxInt(u32)) {
            slot.generation += 1;
            slot.next_free = self.free_head;
            self.free_head = index;
            self.free_count += 1;
        } else {
            slot.next_free = none;
        }
    }
};

fn callbackEnable(userdata: *anyopaque) void {
    const self: *Session = @ptrCast(@alignCast(userdata));
    self.pending = switch (self.pending) {
        .none, .enable => .enable,
        .disable, .disable_then_enable => .disable_then_enable,
    };
}

fn callbackDisable(userdata: *anyopaque) void {
    const self: *Session = @ptrCast(@alignCast(userdata));
    self.pending = .disable;
}

fn sameToken(a: completion.Token, b: completion.Token) bool {
    return a.kind == b.kind and a.slot == b.slot and a.generation == b.generation;
}

fn negativeErrno(errno: linux.E) i32 {
    return -@as(i32, @intFromEnum(errno));
}

const FakePlatform = struct {
    callback: ?*platform_api.CallbackContext = null,
    open_count: usize = 0,
    close_count: usize = 0,
    disable_count: usize = 0,
    dispatch_count: usize = 0,
    device_open_count: usize = 0,
    device_close_count: usize = 0,
    fd_close_count: usize = 0,
    next_device_id: i32 = 10,
    next_fd: std.posix.fd_t = 100,
    seat_fd: std.posix.fd_t = 7,
    fail_open_seat: bool = false,
    fail_get_fd: bool = false,
    fail_dispatch: bool = false,
    fail_disable: bool = false,
    fail_open_device: bool = false,
    fail_close_device: bool = false,
    fail_close_fd: bool = false,
    fail_close_seat: bool = false,
    enable_on_open: bool = false,
    queued_enable: bool = false,
    queued_disable: bool = false,
    closed_ids: [16]i32 = undefined,

    const vtable: platform_api.Platform.VTable = .{
        .open_seat = openSeat,
        .close_seat = closeSeat,
        .get_fd = getFd,
        .dispatch = dispatch,
        .disable_seat = disableSeat,
        .open_device = openDevice,
        .close_device = closeDevice,
        .close_fd = closeFd,
    };

    fn platform(self: *FakePlatform) platform_api.Platform {
        return .{ .context = self, .vtable = &vtable };
    }

    fn enable(self: *FakePlatform) void {
        const callback = self.callback.?;
        callback.listener.enable(callback.userdata);
    }

    fn disable(self: *FakePlatform) void {
        const callback = self.callback.?;
        callback.listener.disable(callback.userdata);
    }

    fn openSeat(context: *anyopaque, callback: *platform_api.CallbackContext) !*anyopaque {
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        if (self.fail_open_seat) return error.FakeOpenSeat;
        self.open_count += 1;
        self.callback = callback;
        if (self.enable_on_open) self.enable();
        return @ptrCast(self);
    }

    fn closeSeat(context: *anyopaque, _: *anyopaque) !void {
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        self.close_count += 1;
        self.callback = null;
        if (self.fail_close_seat) return error.FakeCloseSeat;
    }

    fn getFd(context: *anyopaque, _: *anyopaque) !std.posix.fd_t {
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        if (self.fail_get_fd) return error.FakeGetFd;
        return self.seat_fd;
    }

    fn dispatch(context: *anyopaque, _: *anyopaque) !void {
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        self.dispatch_count += 1;
        if (self.fail_dispatch) return error.FakeDispatch;
        if (self.queued_disable) self.disable();
        if (self.queued_enable) self.enable();
        self.queued_disable = false;
        self.queued_enable = false;
    }

    fn disableSeat(context: *anyopaque, _: *anyopaque) !void {
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        self.disable_count += 1;
        if (self.fail_disable) return error.FakeDisable;
    }

    fn openDevice(context: *anyopaque, _: *anyopaque, _: [:0]const u8) !platform_api.OpenedDevice {
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        if (self.fail_open_device) return error.FakeOpenDevice;
        self.device_open_count += 1;
        defer self.next_device_id += 1;
        defer self.next_fd += 1;
        return .{ .id = self.next_device_id, .fd = self.next_fd };
    }

    fn closeDevice(context: *anyopaque, _: *anyopaque, id: i32) !void {
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        self.closed_ids[self.device_close_count] = id;
        self.device_close_count += 1;
        if (self.fail_close_device) return error.FakeCloseDevice;
    }

    fn closeFd(context: *anyopaque, _: std.posix.fd_t) !void {
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        self.fd_close_count += 1;
        if (self.fail_close_fd) return error.FakeCloseFd;
    }
};

fn createEnabled(fake: *FakePlatform, capacity: usize) !*Session {
    fake.enable_on_open = true;
    const session = try Session.create(std.testing.allocator, fake.platform(), capacity);
    try session.processPending();
    return session;
}

fn destroyWithoutPoll(session: *Session) !void {
    session.clearEvents();
    session.state = .draining;
    try session.destroy();
}

test "session: initial enable uses heap-stable callback context and coalesces callbacks" {
    var fake: FakePlatform = .{ .enable_on_open = true };
    const session = try Session.create(std.testing.allocator, fake.platform(), 2);
    defer destroyWithoutPoll(session) catch unreachable;
    try std.testing.expectEqual(@intFromPtr(session), @intFromPtr(session.callback.userdata));
    fake.enable();
    fake.enable();
    try session.processPending();
    try std.testing.expectEqual(State.enabled, session.state);
    try std.testing.expectEqualSlices(Event, &.{.{ .enabled = 1 }}, session.events());
}

test "session: initial dispatch consumes an enable buffered while opening" {
    var fake: FakePlatform = .{ .queued_enable = true };
    const session = try Session.create(std.testing.allocator, fake.platform(), 1);
    defer destroyWithoutPoll(session) catch unreachable;

    try std.testing.expectEqual(@as(usize, 1), fake.dispatch_count);
    try std.testing.expectEqual(State.enabling, session.state);
    try session.processPending();
    try std.testing.expectEqual(State.enabled, session.state);
    try std.testing.expectEqualSlices(Event, &.{.{ .enabled = 1 }}, session.events());
}

test "session: device table closes through platform once and rejects stale handles" {
    var fake: FakePlatform = .{};
    const session = try createEnabled(&fake, 1);
    defer destroyWithoutPoll(session) catch unreachable;
    const first = try session.openDevice("/dev/fake0");
    try std.testing.expectEqual(@as(std.posix.fd_t, 100), try session.deviceFd(first));
    try session.closeDevice(first);
    try std.testing.expectError(error.StaleDevice, session.closeDevice(first));
    const second = try session.openDevice("/dev/fake1");
    try std.testing.expectEqual(first.slot, second.slot);
    try std.testing.expect(first.generation != second.generation);
    try session.closeDevice(second);
    try std.testing.expectEqual(@as(usize, 2), fake.device_close_count);
    try std.testing.expectEqual(@as(usize, 2), fake.fd_close_count);
}

test "session: disable acknowledgment waits for coordinator and devices" {
    var fake: FakePlatform = .{};
    const session = try createEnabled(&fake, 1);
    defer destroyWithoutPoll(session) catch unreachable;
    const device = try session.openDevice("/dev/fake");
    fake.disable();
    try session.processPending();
    try std.testing.expectEqual(State.disabling, session.state);
    try std.testing.expectError(error.DevicesNotQuiescent, session.acknowledgeDisable(true));
    try std.testing.expectEqual(@as(usize, 0), fake.disable_count);
    try session.closeDevice(device);
    try std.testing.expectError(error.DevicesNotQuiescent, session.acknowledgeDisable(false));
    try session.acknowledgeDisable(true);
    try std.testing.expectEqual(State.disabled, session.state);
    try std.testing.expectEqual(@as(usize, 1), fake.disable_count);
}

test "session: enable after disable receives a new session generation" {
    var fake: FakePlatform = .{};
    const session = try createEnabled(&fake, 1);
    defer destroyWithoutPoll(session) catch unreachable;
    fake.disable();
    try session.processPending();
    fake.enable();
    try session.processPending();
    try std.testing.expectEqual(State.disabling, session.state);
    try session.acknowledgeDisable(true);
    try std.testing.expectEqual(State.enabled, session.state);
    try std.testing.expectEqual(@as(u32, 2), session.currentGeneration());
}

test "session: fixed device capacity rejects before calling platform" {
    var fake: FakePlatform = .{};
    const session = try createEnabled(&fake, 1);
    defer destroyWithoutPoll(session) catch unreachable;
    const device = try session.openDevice("/dev/fake0");
    try std.testing.expectError(error.DeviceCapacityExhausted, session.openDevice("/dev/fake1"));
    try std.testing.expectEqual(@as(usize, 1), fake.device_open_count);
    try session.closeDevice(device);
}

test "session: partial initialization and device failures unwind exactly once" {
    var fake: FakePlatform = .{ .fail_get_fd = true };
    try std.testing.expectError(
        error.FakeGetFd,
        Session.create(std.testing.allocator, fake.platform(), 1),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.open_count);
    try std.testing.expectEqual(@as(usize, 1), fake.close_count);

    fake = .{ .fail_dispatch = true };
    try std.testing.expectError(
        error.FakeDispatch,
        Session.create(std.testing.allocator, fake.platform(), 1),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.open_count);
    try std.testing.expectEqual(@as(usize, 1), fake.dispatch_count);
    try std.testing.expectEqual(@as(usize, 1), fake.close_count);

    fake = .{ .enable_on_open = true, .fail_open_device = true };
    const session = try Session.create(std.testing.allocator, fake.platform(), 1);
    defer destroyWithoutPoll(session) catch unreachable;
    try session.processPending();
    try std.testing.expectError(error.FakeOpenDevice, session.openDevice("/dev/fake"));
    try std.testing.expectEqual(@as(usize, 1), session.availableDevices());
}

test "session: close failure still retires ownership and cannot double close" {
    var fake: FakePlatform = .{ .fail_close_device = true };
    const session = try createEnabled(&fake, 1);
    defer destroyWithoutPoll(session) catch unreachable;
    const device = try session.openDevice("/dev/fake");
    try std.testing.expectError(error.FakeCloseDevice, session.closeDevice(device));
    try std.testing.expectError(error.StaleDevice, session.closeDevice(device));
    try std.testing.expectEqual(@as(usize, 1), fake.device_close_count);
    try std.testing.expectEqual(@as(usize, 1), fake.fd_close_count);
}

test "session: fd close failure retires ownership and cannot double close" {
    var fake: FakePlatform = .{ .fail_close_fd = true };
    const session = try createEnabled(&fake, 1);
    defer destroyWithoutPoll(session) catch unreachable;
    const device = try session.openDevice("/dev/fake");
    try std.testing.expectError(error.FakeCloseFd, session.closeDevice(device));
    try std.testing.expectError(error.StaleDevice, session.closeDevice(device));
    try std.testing.expectEqual(@as(usize, 1), fake.device_close_count);
    try std.testing.expectEqual(@as(usize, 1), fake.fd_close_count);
}

test "session: seat close error still consumes stable callback storage" {
    var fake: FakePlatform = .{ .fail_close_seat = true };
    const session = try createEnabled(&fake, 1);
    session.clearEvents();
    session.state = .draining;
    try std.testing.expectError(error.FakeCloseSeat, session.destroy());
    try std.testing.expectEqual(@as(usize, 1), fake.close_count);
    try std.testing.expect(fake.callback == null);
}

test "session: stale readiness and cancellation races retain tokens until each CQE" {
    var fake: FakePlatform = .{};
    const session = try createEnabled(&fake, 1);
    defer destroyWithoutPoll(session) catch unreachable;
    var router = try completion.Router.init(std.testing.allocator, 4);
    defer router.deinit(std.testing.allocator);

    const poll = try router.acquire(.backend_ready);
    const cancel = try router.acquire(.backend_ready);
    session.poll_token = poll;
    session.cancel_token = cancel;
    session.state = .draining;
    var ring: linux.IoUring = undefined;

    var stale = poll;
    stale.generation +%= 1;
    try std.testing.expectError(
        error.UnknownToken,
        session.completeReadiness(&router, &ring, stale, negativeErrno(.CANCELED)),
    );
    try session.completeReadiness(&router, &ring, cancel, 0);
    try std.testing.expect(router.route(cancel.encode()) == null);
    try std.testing.expect(router.route(poll.encode()) != null);
    try session.completeReadiness(&router, &ring, poll, negativeErrno(.CANCELED));
    try std.testing.expect(session.drainComplete());
}

test "session: one-shot readiness joins shared submission and rearms after dispatch" {
    var ring = linux.IoUring.init(8, 0) catch |err| switch (err) {
        error.PermissionDenied, error.SystemOutdated => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();
    const raw_fd = linux.eventfd(1, linux.EFD.CLOEXEC);
    switch (linux.errno(raw_fd)) {
        .SUCCESS => {},
        else => return error.EventFdFailed,
    }
    const fd: std.posix.fd_t = @intCast(raw_fd);
    defer _ = linux.close(fd);

    var fake: FakePlatform = .{
        .seat_fd = fd,
        .queued_disable = true,
        .queued_enable = true,
    };
    const session = try createEnabled(&fake, 1);
    defer destroyWithoutPoll(session) catch unreachable;
    var router = try completion.Router.init(std.testing.allocator, 4);
    defer router.deinit(std.testing.allocator);

    try session.prepareReadiness(&router, &ring);
    try std.testing.expectEqual(@as(u32, 1), ring.sq_ready());
    _ = try ring.submit_and_wait(1);
    const ready = try ring.copy_cqe();
    const ready_token = router.route(ready.user_data) orelse return error.UnknownToken;
    try session.completeReadiness(&router, &ring, ready_token, ready.res);
    try std.testing.expectEqual(@as(usize, 2), fake.dispatch_count);
    try std.testing.expectEqual(@as(u32, 1), ring.sq_ready());
    try session.processPending();
    try std.testing.expectEqual(State.disabling, session.state);

    session.clearEvents();
    try session.beginDrain(&router, &ring);
    try std.testing.expectEqual(@as(u32, 2), ring.sq_ready());
    _ = try ring.submit_and_wait(2);
    var completed: usize = 0;
    while (completed < 2) : (completed += 1) {
        const cqe = try ring.copy_cqe();
        const token = router.route(cqe.user_data) orelse return error.UnknownToken;
        try session.completeReadiness(&router, &ring, token, cqe.res);
    }
    try std.testing.expect(session.drainComplete());
}

test "session: teardown cannot free callback context before poll and devices drain" {
    var fake: FakePlatform = .{};
    const session = try createEnabled(&fake, 1);
    const device = try session.openDevice("/dev/fake");
    session.clearEvents();
    session.state = .draining;
    try std.testing.expectError(error.DrainIncomplete, session.destroy());
    try std.testing.expect(fake.callback != null);
    try session.closeDevice(device);
    try session.destroy();
    try std.testing.expect(fake.callback == null);
}
