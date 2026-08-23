//! Heap-stable, fixed-capacity libinput owner. It preserves per-device
//! physical state and publishes only generation-bearing values. Libinput
//! calls and teardown happen from Ouro turn phases, never from an event
//! callback, and ring operations are prepared without submission.

const std = @import("std");
const linux = std.os.linux;
const completion = @import("../../runtime/completion.zig");
const session_api = @import("../session.zig");
const platform_api = @import("platform.zig");

const none = std.math.maxInt(u32);
const code_count = 0x300;
const state_words = code_count / 64;

pub const State = enum { active, quiescing, suspended, draining, failed };

pub const DeviceId = struct {
    slot: u32,
    generation: u32,
    seat_generation: u32,
};

pub const Event = union(enum) {
    device_added: struct { device: DeviceId, capabilities: platform_api.Capabilities },
    device_removed: DeviceId,
    pointer_motion: struct { device: DeviceId, time_usec: u64, dx: f64, dy: f64 },
    pointer_button: struct { device: DeviceId, time_usec: u64, button: u32, pressed: bool },
    keyboard_key: struct { device: DeviceId, time_usec: u64, key: u32, pressed: bool },
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
    capabilities: platform_api.Capabilities = .{},
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
                if (self.free_head == none) return error.DeviceCapacityExhausted;
                const index = self.free_head;
                const slot = &self.devices[index];
                self.free_head = slot.next_free;
                slot.active = true;
                slot.seat_generation = self.seat_generation;
                slot.reference = value.device;
                slot.capabilities = value.capabilities;
                @memset(&slot.pressed, 0);
                self.active_devices += 1;
                self.push(.{ .device_added = .{
                    .device = self.idFor(index),
                    .capabilities = value.capabilities,
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
            .ignored => {},
        }
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

    const vtable: platform_api.Platform.VTable = .{
        .create = createContext,
        .destroy = destroyContext,
        .get_fd = getFd,
        .dispatch = dispatch,
        .next_event = nextEvent,
        .suspend_context = suspendContext,
        .resume_context = resumeContext,
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

test "input: physical state remains distinct and device reuse advances generation" {
    var seat_fake: FakeSeat = .{};
    var input_fake: FakeInput = .{};
    const backend = try testBackend(&seat_fake, &input_fake, 8);
    defer destroyTestBackend(backend) catch unreachable;

    input_fake.append(.{ .device_added = .{
        .device = 1,
        .capabilities = .{ .keyboard = true },
    } });
    input_fake.append(.{ .device_added = .{
        .device = 2,
        .capabilities = .{ .keyboard = true },
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
        .capabilities = .{ .pointer = true },
    } });
    try backend.drainEvents();
    const replacement = backend.events()[1].device_added.device;
    try std.testing.expectEqual(first.slot, replacement.slot);
    try std.testing.expect(first.generation != replacement.generation);
    try std.testing.expectError(error.StaleDevice, backend.isPressed(first, 30));
}

test "input: pointer button motion and keyboard events retain generation identity" {
    var seat_fake: FakeSeat = .{};
    var input_fake: FakeInput = .{};
    const backend = try testBackend(&seat_fake, &input_fake, 8);
    defer destroyTestBackend(backend) catch unreachable;

    input_fake.append(.{ .device_added = .{
        .device = 7,
        .capabilities = .{ .pointer = true, .keyboard = true },
    } });
    input_fake.append(.{ .pointer_motion = .{
        .device = 7,
        .time_usec = 11,
        .dx = 1.25,
        .dy = -2.5,
    } });
    input_fake.append(.{ .pointer_button = .{
        .device = 7,
        .time_usec = 12,
        .button = 0x110,
        .pressed = true,
    } });
    input_fake.append(.{ .keyboard_key = .{
        .device = 7,
        .time_usec = 13,
        .key = 42,
        .pressed = true,
    } });
    try backend.drainEvents();
    const id = backend.events()[0].device_added.device;
    try std.testing.expectEqual(id, backend.events()[1].pointer_motion.device);
    try std.testing.expectEqual(id, backend.events()[2].pointer_button.device);
    try std.testing.expectEqual(id, backend.events()[3].keyboard_key.device);
    try std.testing.expect(try backend.isPressed(id, 0x110));
    try std.testing.expect(try backend.isPressed(id, 42));
}

test "input: quiesce closes Session devices and teardown occurs outside callbacks" {
    var seat_fake: FakeSeat = .{};
    var input_fake: FakeInput = .{};
    const backend = try testBackend(&seat_fake, &input_fake, 4);
    input_fake.append(.{ .device_added = .{
        .device = 9,
        .capabilities = .{ .pointer = true },
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
        .capabilities = .{ .keyboard = true },
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
        .capabilities = .{ .pointer = true },
    } });
    input_fake.append(.{ .device_added = .{
        .device = 3,
        .capabilities = .{ .keyboard = true },
    } });
    try backend.resumeAfterEnable(&router, &ring);
    const current = backend.events()[0].device_added.device;
    try std.testing.expectEqual(@as(u32, 2), current.seat_generation);
    try std.testing.expect(old.seat_generation != current.seat_generation);
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
