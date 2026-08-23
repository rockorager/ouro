//! Generation-safe atomic KMS output ownership. The owner is heap-stable
//! because libdrm retains pointers to its preallocated commit records until a
//! matching page-flip callback has been dispatched.

const std = @import("std");
const linux = std.os.linux;
const completion = @import("../../runtime/completion.zig");
const drm = @import("manager.zig");
const framebuffer = @import("framebuffer.zig");
const atomic = @import("atomic.zig");

pub const State = enum {
    initial,
    active,
    queued,
    in_flight,
    disabling,
    paused,
    removed,
    failed,
    draining,
    drained,
};

pub const Failure = enum {
    readiness,
    event_dispatch,
    callback_mismatch,
    duplicate_callback,
    disable_commit,
};

pub const Event = union(enum) {
    presented: struct {
        image: framebuffer.Handle,
        previous: ?framebuffer.Handle,
        sequence: u32,
        seconds: u32,
        microseconds: u32,
        out_fence_fd: std.posix.fd_t,
    },
    paused,
    removed,
    failed: Failure,
    drained,
};

pub const Config = struct {
    commit_capacity: usize = 2,
    event_capacity: usize = 32,
};

/// Generation-checking adapter for R9's borrowed Session-owned DRM FD.
pub const Device = struct {
    context: *anyopaque,
    get_fd: *const fn (*anyopaque, drm.Handle) anyerror!std.posix.fd_t,

    pub fn fromManager(manager: *drm.Manager) Device {
        return .{ .context = manager, .get_fd = managerFd };
    }

    pub fn fd(self: Device, handle: drm.Handle) !std.posix.fd_t {
        return self.get_fd(self.context, handle);
    }

    fn managerFd(context: *anyopaque, handle: drm.Handle) !std.posix.fd_t {
        const manager: *drm.Manager = @ptrCast(@alignCast(context));
        return manager.deviceFd(handle);
    }
};

/// Allocation-free adapter over R10's image state machine.
pub const Images = struct {
    context: *anyopaque,
    get_image: *const fn (*anyopaque, framebuffer.Handle) anyerror!framebuffer.Image,
    validate_submit: *const fn (*anyopaque, framebuffer.Handle) anyerror!void,
    submit_image: *const fn (*anyopaque, framebuffer.Handle) anyerror!void,
    discard_image: *const fn (*anyopaque, framebuffer.Handle) anyerror!void,
    release_image: *const fn (*anyopaque, framebuffer.Handle) anyerror!void,

    pub fn fromPool(pool: *framebuffer.Pool) Images {
        return .{
            .context = pool,
            .get_image = poolImage,
            .validate_submit = poolValidate,
            .submit_image = poolSubmit,
            .discard_image = poolDiscard,
            .release_image = poolRelease,
        };
    }

    fn poolImage(context: *anyopaque, handle: framebuffer.Handle) !framebuffer.Image {
        return (@as(*framebuffer.Pool, @ptrCast(@alignCast(context)))).image(handle);
    }
    fn poolValidate(context: *anyopaque, handle: framebuffer.Handle) !void {
        return (@as(*framebuffer.Pool, @ptrCast(@alignCast(context)))).validateSubmit(handle);
    }
    fn poolSubmit(context: *anyopaque, handle: framebuffer.Handle) !void {
        return (@as(*framebuffer.Pool, @ptrCast(@alignCast(context)))).submit(handle);
    }
    fn poolDiscard(context: *anyopaque, handle: framebuffer.Handle) !void {
        return (@as(*framebuffer.Pool, @ptrCast(@alignCast(context)))).discard(handle);
    }
    fn poolRelease(context: *anyopaque, handle: framebuffer.Handle) !void {
        return (@as(*framebuffer.Pool, @ptrCast(@alignCast(context)))).release(handle);
    }
};

const RecordState = enum { free, in_flight, callback, retired };

const FlipFact = struct {
    sequence: u32,
    seconds: u32,
    microseconds: u32,
    crtc_id: u32,
};

const CommitRecord = struct {
    request: atomic.Request,
    generation: u32 = 1,
    state: RecordState = .free,
    output_generation: u32 = 0,
    image: framebuffer.Handle = undefined,
    callback_count: u32 = 0,
    fact: FlipFact = undefined,
    out_fence_fd: std.posix.fd_t = -1,
};

const Queued = struct {
    image: framebuffer.Handle,
    in_fence_fd: ?std.posix.fd_t,
    previous_state: State,
};

pub const Output = struct {
    allocator: std.mem.Allocator,
    platform: atomic.Platform,
    device: Device,
    images: Images,
    snapshot_handle: drm.Handle,
    connector: drm.Connector,
    crtc: drm.Crtc,
    plane: drm.Plane,
    mode: drm.Mode,
    fd: std.posix.fd_t,
    mode_blob: u32,
    records: []CommitRecord,
    events_buffer: []Event,
    event_count: usize = 0,
    state: State = .initial,
    queued: ?Queued = null,
    current: ?framebuffer.Handle = null,
    in_flight_slot: ?u32 = null,
    output_generation: u32 = 1,
    modeset_tested: bool = false,
    poll_token: ?completion.Token = null,
    cancel_token: ?completion.Token = null,
    terminal_device_teardown: bool = false,

    pub fn create(
        allocator: std.mem.Allocator,
        platform: atomic.Platform,
        device: Device,
        images: Images,
        snapshot: drm.Snapshot,
        config: Config,
    ) !*Output {
        if (config.commit_capacity == 0 or config.commit_capacity > std.math.maxInt(u32) or
            config.event_capacity == 0)
            return error.InvalidConfig;
        const fd = try device.fd(snapshot.handle);
        const records = try allocator.alloc(CommitRecord, config.commit_capacity);
        errdefer allocator.free(records);
        var created: usize = 0;
        errdefer while (created != 0) {
            created -= 1;
            platform.destroyRequest(records[created].request);
        };
        while (created < records.len) : (created += 1)
            records[created] = .{ .request = try platform.createRequest() };
        const blob = try platform.createBlob(fd, snapshot.selectedMode());
        errdefer platform.destroyBlob(fd, blob) catch {};
        const event_storage = try allocator.alloc(Event, config.event_capacity);
        errdefer allocator.free(event_storage);
        const self = try allocator.create(Output);
        self.* = .{
            .allocator = allocator,
            .platform = platform,
            .device = device,
            .images = images,
            .snapshot_handle = snapshot.handle,
            .connector = snapshot.selectedConnector(),
            .crtc = snapshot.selectedCrtc(),
            .plane = snapshot.selectedPlane(),
            .mode = snapshot.selectedMode(),
            .fd = fd,
            .mode_blob = blob,
            .records = records,
            .events_buffer = event_storage,
        };
        return self;
    }

    /// R14 may destroy this owner only after `drainComplete`. For a live DRM
    /// generation the mode blob is explicitly destroyed; after a declared
    /// terminal device boundary, closing the DRM FD owns blob cleanup.
    pub fn destroy(self: *Output) !void {
        if (!self.drainComplete()) return error.DrainIncomplete;
        var first_error: ?anyerror = null;
        self.clearEvents();
        if (!self.terminal_device_teardown)
            self.platform.destroyBlob(self.fd, self.mode_blob) catch |err| {
                first_error = err;
            };
        var index = self.records.len;
        while (index != 0) {
            index -= 1;
            self.platform.destroyRequest(self.records[index].request);
        }
        const allocator = self.allocator;
        allocator.free(self.events_buffer);
        allocator.free(self.records);
        allocator.destroy(self);
        if (first_error) |err| return err;
    }

    pub fn events(self: *const Output) []const Event {
        return self.events_buffer[0..self.event_count];
    }

    /// Any presented OUT_FENCE_FD not taken by the coordinator is closed here.
    pub fn clearEvents(self: *Output) void {
        for (self.events_buffer[0..self.event_count]) |*event| switch (event.*) {
            .presented => |*presented| if (presented.out_fence_fd >= 0) {
                _ = linux.close(presented.out_fence_fd);
                presented.out_fence_fd = -1;
            },
            else => {},
        };
        self.event_count = 0;
    }

    pub fn takeOutFence(self: *Output, event_index: usize) !std.posix.fd_t {
        if (event_index >= self.event_count) return error.InvalidEvent;
        switch (self.events_buffer[event_index]) {
            .presented => |*presented| {
                if (presented.out_fence_fd < 0) return error.NoOutFence;
                const fd = presented.out_fence_fd;
                presented.out_fence_fd = -1;
                return fd;
            },
            else => return error.NoOutFence,
        }
    }

    /// Takes ownership of an acquired R10 image and, when present, the input
    /// fence only after all validation succeeds. The fence is closed after the
    /// real atomic ioctl attempt or on any earlier rollback.
    pub fn queue(self: *Output, image_handle: framebuffer.Handle, in_fence_fd: ?std.posix.fd_t) !void {
        if (self.state != .initial and self.state != .active and self.state != .paused)
            return error.InvalidState;
        if (in_fence_fd) |fence| if (fence < 0) return error.InvalidInFence;
        if (in_fence_fd != null and self.plane.properties.in_fence_fd == 0)
            return error.InFenceUnsupported;
        const image = try self.images.get_image(self.images.context, image_handle);
        if (image.state != .acquired or image.metadata.width != self.mode.hdisplay or
            image.metadata.height != self.mode.vdisplay)
            return error.InvalidImage;
        try self.images.validate_submit(self.images.context, image_handle);
        self.queued = .{
            .image = image_handle,
            .in_fence_fd = in_fence_fd,
            .previous_state = self.state,
        };
        self.state = .queued;
    }

    /// Performs TEST_ONLY before the first real modeset. Both test and real
    /// requests are built from preallocated records. R10 `submit` occurs only
    /// after the real ioctl succeeds; every earlier failure discards the image.
    pub fn commitQueued(self: *Output) !void {
        if (self.state != .queued) return error.InvalidState;
        const queued = self.queued.?;
        const fd = self.device.fd(self.snapshot_handle) catch |err| {
            try self.rollbackQueued();
            return err;
        };
        const slot = self.freeRecord() orelse {
            try self.rollbackQueued();
            return error.CommitCapacityExhausted;
        };
        const record = &self.records[slot];
        const image = self.images.get_image(self.images.context, queued.image) catch |err| {
            try self.rollbackQueued();
            return err;
        };
        const modeset = queued.previous_state == .initial or queued.previous_state == .paused;

        if (modeset and !self.modeset_tested) {
            self.buildScanout(record, image.framebuffer_id, queued.in_fence_fd, true, false) catch |err| {
                try self.rollbackRecordAndQueued(record);
                return err;
            };
            self.platform.commit(fd, record.request, .{ .test_only = true, .allow_modeset = true }, null) catch |err| {
                try self.rollbackRecordAndQueued(record);
                return err;
            };
            self.modeset_tested = true;
            self.platform.resetRequest(record.request);
        }
        self.buildScanout(record, image.framebuffer_id, queued.in_fence_fd, modeset, true) catch |err| {
            try self.rollbackRecordAndQueued(record);
            return err;
        };

        record.state = .in_flight;
        record.output_generation = self.output_generation;
        record.image = queued.image;
        record.callback_count = 0;
        record.out_fence_fd = -1;
        const flags: atomic.CommitFlags = .{
            .allow_modeset = modeset,
            .nonblock = true,
            .page_flip_event = true,
        };
        self.platform.commit(fd, record.request, flags, record) catch |err| {
            record.state = .free;
            try self.rollbackRecordAndQueued(record);
            return err;
        };
        self.closeQueuedInFence();
        // validateSubmit above makes this infallible under the single-thread
        // turn contract; a failure here means that contract was violated after
        // KMS accepted the image and therefore cannot be rolled back safely.
        self.images.submit_image(self.images.context, queued.image) catch {
            self.state = .failed;
            self.queued = null;
            self.in_flight_slot = @intCast(slot);
            return error.ImageOwnershipViolation;
        };
        self.queued = null;
        self.in_flight_slot = @intCast(slot);
        self.state = .in_flight;
    }

    /// Requests pause. Queued-but-uncommitted images are discarded. An
    /// in-flight image is first allowed to flip, then immediately disabled so
    /// neither old nor new scanout is recycled while KMS may still use it.
    pub fn requestPause(self: *Output) !void {
        switch (self.state) {
            .initial, .paused => {
                try self.pushEvent(.paused);
                self.state = .paused;
            },
            .active => try self.disableNow(),
            .queued => {
                try self.rollbackQueued();
                try self.disableNow();
            },
            .in_flight => self.state = .disabling,
            .disabling => {},
            else => return error.InvalidState,
        }
    }

    /// Records a terminal FD/device teardown boundary already established by
    /// R9/Session (device revocation, close, or physical removal). R14 must not
    /// call this merely to force progress: only that external boundary proves
    /// the kernel can no longer scan out submitted images. R10 remains alive
    /// until this owner subsequently drains and is destroyed.
    pub fn terminalDeviceTeardown(self: *Output) !void {
        if (self.event_count == self.events_buffer.len) return error.EventQueueFull;
        if (self.queued) |queued| {
            self.closeQueuedInFence();
            try self.images.discard_image(self.images.context, queued.image);
            self.queued = null;
        }
        if (self.current) |current| {
            try releaseTerminal(self.images, current);
            self.current = null;
        }
        if (self.in_flight_slot) |slot| {
            const record = &self.records[slot];
            if (record.state == .in_flight or record.state == .callback)
                try releaseTerminal(self.images, record.image);
            retireRecord(self.platform, record);
            self.in_flight_slot = null;
        }
        self.terminal_device_teardown = true;
        self.state = .removed;
        try self.pushEvent(.removed);
    }

    pub fn processCallbacks(self: *Output) !void {
        const slot = self.in_flight_slot orelse {
            if (self.state == .disabling and self.current != null) try self.disableNow();
            return;
        };
        const record = &self.records[slot];
        if (record.state != .callback) return;
        if (record.callback_count != 1) return self.failCallback(.duplicate_callback);
        if (record.output_generation != self.output_generation or record.fact.crtc_id != self.crtc.id)
            return self.failCallback(.callback_mismatch);
        if (self.event_count == self.events_buffer.len) return error.EventQueueFull;

        const previous = self.current;
        if (previous) |old| try releaseDisplayed(self.images, old);
        self.current = record.image;
        self.events_buffer[self.event_count] = .{ .presented = .{
            .image = record.image,
            .previous = previous,
            .sequence = record.fact.sequence,
            .seconds = record.fact.seconds,
            .microseconds = record.fact.microseconds,
            .out_fence_fd = record.out_fence_fd,
        } };
        self.event_count += 1;
        record.out_fence_fd = -1;
        retireRecord(self.platform, record);
        self.in_flight_slot = null;
        const should_disable = self.state == .disabling;
        self.state = if (should_disable) .disabling else .active;
        if (should_disable and self.event_count != self.events_buffer.len) try self.disableNow();
    }

    /// Queues one-shot DRM-FD readiness on the shared ring. Never submits.
    pub fn prepareReadiness(self: *Output, router: *completion.Router, ring: *linux.IoUring) !void {
        if (self.poll_token != null or self.cancel_token != null or
            self.state == .failed or self.state == .draining or self.state == .drained or
            self.state == .removed)
            return error.InvalidState;
        const fd = try self.device.fd(self.snapshot_handle);
        const token = try router.acquire(.backend_ready);
        errdefer router.retire(token) catch unreachable;
        _ = try ring.poll_add(token.encode(), fd, linux.POLL.IN | linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL);
        self.poll_token = token;
    }

    pub fn completeReadiness(
        self: *Output,
        router: *completion.Router,
        ring: *linux.IoUring,
        token: completion.Token,
        result: i32,
    ) !void {
        if (self.poll_token) |poll| if (sameToken(poll, token)) {
            try router.retire(token);
            self.poll_token = null;
            if (self.state == .draining) {
                if (self.cancel_token == null) try self.finishDrain();
                return;
            }
            if (self.state == .removed or self.state == .failed) return;
            if (result < 0) return self.markFailed(.readiness);
            const mask: u32 = @intCast(result);
            if (mask & linux.POLL.IN == 0 or
                mask & (linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL) != 0)
                return self.markFailed(.readiness);
            const fd = self.device.fd(self.snapshot_handle) catch return self.markFailed(.readiness);
            self.platform.handleEvents(fd, pageFlipCallback) catch return self.markFailed(.event_dispatch);
            try self.prepareReadiness(router, ring);
            return;
        };
        if (self.cancel_token) |cancel| if (sameToken(cancel, token)) {
            try router.retire(token);
            self.cancel_token = null;
            if (result != 0 and result != negativeErrno(.NOENT) and result != negativeErrno(.CANCELED))
                return error.UnexpectedCompletion;
            if (self.poll_token == null and self.state == .draining) try self.finishDrain();
            return;
        };
        return error.UnknownToken;
    }

    /// Requires scanout quiescence first. Poll-remove and target CQEs may arrive
    /// in either order; callback/request storage remains alive until both do.
    pub fn beginDrain(self: *Output, router: *completion.Router, ring: *linux.IoUring) !void {
        if (self.current != null or self.queued != null or self.in_flight_slot != null)
            return error.ScanoutNotQuiescent;
        if (self.state != .paused and self.state != .removed and self.state != .draining)
            return error.InvalidState;
        self.state = .draining;
        if (self.poll_token) |poll| if (self.cancel_token == null) {
            const token = try router.acquire(.backend_ready);
            errdefer router.retire(token) catch unreachable;
            _ = try ring.poll_remove(token.encode(), poll.encode());
            self.cancel_token = token;
        };
        if (self.poll_token == null and self.cancel_token == null) try self.finishDrain();
    }

    pub fn drainComplete(self: *const Output) bool {
        return self.state == .drained and self.poll_token == null and self.cancel_token == null and
            self.current == null and self.queued == null and self.in_flight_slot == null;
    }

    fn buildScanout(
        self: *Output,
        record: *CommitRecord,
        framebuffer_id: u32,
        in_fence_fd: ?std.posix.fd_t,
        modeset: bool,
        include_out_fence: bool,
    ) !void {
        const request = record.request;
        if (modeset) {
            try self.platform.addProperty(request, self.connector.id, self.connector.properties.crtc_id, self.crtc.id);
            try self.platform.addProperty(request, self.crtc.id, self.crtc.properties.mode_id, self.mode_blob);
            try self.platform.addProperty(request, self.crtc.id, self.crtc.properties.active, 1);
        }
        try self.platform.addProperty(request, self.plane.id, self.plane.properties.fb_id, framebuffer_id);
        try self.platform.addProperty(request, self.plane.id, self.plane.properties.crtc_id, self.crtc.id);
        try self.platform.addProperty(request, self.plane.id, self.plane.properties.src_x, 0);
        try self.platform.addProperty(request, self.plane.id, self.plane.properties.src_y, 0);
        try self.platform.addProperty(request, self.plane.id, self.plane.properties.src_w, @as(u64, self.mode.hdisplay) << 16);
        try self.platform.addProperty(request, self.plane.id, self.plane.properties.src_h, @as(u64, self.mode.vdisplay) << 16);
        try self.platform.addProperty(request, self.plane.id, self.plane.properties.crtc_x, 0);
        try self.platform.addProperty(request, self.plane.id, self.plane.properties.crtc_y, 0);
        try self.platform.addProperty(request, self.plane.id, self.plane.properties.crtc_w, self.mode.hdisplay);
        try self.platform.addProperty(request, self.plane.id, self.plane.properties.crtc_h, self.mode.vdisplay);
        if (in_fence_fd) |fence|
            try self.platform.addProperty(request, self.plane.id, self.plane.properties.in_fence_fd, @bitCast(@as(i64, fence)));
        if (include_out_fence and self.crtc.properties.out_fence_ptr != 0)
            try self.platform.addProperty(request, self.crtc.id, self.crtc.properties.out_fence_ptr, @intFromPtr(&record.out_fence_fd));
    }

    fn disableNow(self: *Output) !void {
        if (self.event_count == self.events_buffer.len) return error.EventQueueFull;
        if (self.current == null) {
            try self.pushEvent(.paused);
            self.state = .paused;
            return;
        }
        const fd = self.device.fd(self.snapshot_handle) catch |err| {
            try self.markFailed(.disable_commit);
            return err;
        };
        const slot = self.freeRecord() orelse return error.CommitCapacityExhausted;
        const record = &self.records[slot];
        const request = record.request;
        self.platform.resetRequest(request);
        try self.platform.addProperty(request, self.plane.id, self.plane.properties.fb_id, 0);
        try self.platform.addProperty(request, self.plane.id, self.plane.properties.crtc_id, 0);
        try self.platform.addProperty(request, self.connector.id, self.connector.properties.crtc_id, 0);
        try self.platform.addProperty(request, self.crtc.id, self.crtc.properties.active, 0);
        try self.platform.addProperty(request, self.crtc.id, self.crtc.properties.mode_id, 0);
        self.platform.commit(fd, request, .{ .allow_modeset = true }, null) catch |err| {
            self.platform.resetRequest(request);
            try self.markFailed(.disable_commit);
            return err;
        };
        const old = self.current.?;
        self.current = null;
        try releaseDisplayed(self.images, old);
        self.platform.resetRequest(request);
        try self.pushEvent(.paused);
        self.state = .paused;
    }

    fn rollbackQueued(self: *Output) !void {
        const queued = self.queued orelse return;
        self.closeQueuedInFence();
        try self.images.discard_image(self.images.context, queued.image);
        self.queued = null;
        self.state = queued.previous_state;
    }

    fn closeQueuedInFence(self: *Output) void {
        if (self.queued) |*queued| if (queued.in_fence_fd) |fence| {
            _ = linux.close(fence);
            queued.in_fence_fd = null;
        };
    }

    fn rollbackRecordAndQueued(self: *Output, record: *CommitRecord) !void {
        closeRecordFence(record);
        self.platform.resetRequest(record.request);
        record.state = .free;
        try self.rollbackQueued();
    }

    fn freeRecord(self: *Output) ?usize {
        for (self.records, 0..) |record, index| if (record.state == .free) return index;
        return null;
    }

    fn failCallback(self: *Output, failure: Failure) !void {
        try self.markFailed(failure);
        return error.InvalidPageFlipCallback;
    }

    fn markFailed(self: *Output, failure: Failure) !void {
        try self.pushEvent(.{ .failed = failure });
        self.state = .failed;
    }

    fn finishDrain(self: *Output) !void {
        try self.pushEvent(.drained);
        self.state = .drained;
    }

    fn pushEvent(self: *Output, event: Event) !void {
        if (self.event_count == self.events_buffer.len) return error.EventQueueFull;
        self.events_buffer[self.event_count] = event;
        self.event_count += 1;
    }
};

fn pageFlipCallback(
    userdata: *anyopaque,
    sequence: u32,
    seconds: u32,
    microseconds: u32,
    crtc_id: u32,
) callconv(.c) void {
    const record: *CommitRecord = @ptrCast(@alignCast(userdata));
    if (record.callback_count != std.math.maxInt(u32)) record.callback_count += 1;
    record.fact = .{
        .sequence = sequence,
        .seconds = seconds,
        .microseconds = microseconds,
        .crtc_id = crtc_id,
    };
    if (record.state == .in_flight) record.state = .callback;
}

fn retireRecord(platform: atomic.Platform, record: *CommitRecord) void {
    closeRecordFence(record);
    platform.resetRequest(record.request);
    record.callback_count = 0;
    if (record.generation == std.math.maxInt(u32)) {
        record.state = .retired;
    } else {
        record.generation += 1;
        record.state = .free;
    }
}

fn closeRecordFence(record: *CommitRecord) void {
    if (record.out_fence_fd >= 0) {
        _ = linux.close(record.out_fence_fd);
        record.out_fence_fd = -1;
    }
}

fn releaseDisplayed(images: Images, handle: framebuffer.Handle) !void {
    images.release_image(images.context, handle) catch |err| switch (err) {
        error.GenerationExhausted => {},
        else => return err,
    };
}

fn releaseTerminal(images: Images, handle: framebuffer.Handle) !void {
    try releaseDisplayed(images, handle);
}

fn sameToken(a: completion.Token, b: completion.Token) bool {
    return a.kind == b.kind and a.slot == b.slot and a.generation == b.generation;
}

fn negativeErrno(comptime errno: linux.E) i32 {
    return -@as(i32, @intCast(@intFromEnum(errno)));
}

test "kms: TEST_ONLY failure discards before KMS ownership" {
    var fixture = Fixture{ .atomic_state = .{ .fail_commit_at = 1 } };
    const output = try fixture.create(.{});
    const image = fixture.acquire(0);
    try output.queue(image, null);
    try std.testing.expectError(error.FakeCommit, output.commitQueued());
    try std.testing.expectEqual(State.initial, output.state);
    try std.testing.expectEqual(@as(usize, 1), fixture.images_state.discard_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.images_state.submit_count);
    try fixture.destroy(output);
}

test "kms: real commit failure rolls back and discards" {
    var fixture = Fixture{ .atomic_state = .{ .fail_commit_at = 2 } };
    const output = try fixture.create(.{});
    const in_fence = try createTestFence();
    try output.queue(fixture.acquire(0), in_fence);
    try std.testing.expectError(error.FakeCommit, output.commitQueued());
    try expectClosed(in_fence);
    try std.testing.expectEqual(State.initial, output.state);
    try std.testing.expectEqual(@as(usize, 1), fixture.images_state.discard_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.images_state.submit_count);
    try std.testing.expect(fixture.atomic_state.commits[0].flags.test_only);
    try std.testing.expect(!fixture.atomic_state.commits[1].flags.test_only);
    try fixture.destroy(output);
}

test "kms: scanout properties flags and optional fences match capabilities" {
    var fixture = Fixture{};
    var output = try fixture.create(.{});
    const in_fence = try createTestFence();
    try output.queue(fixture.acquire(0), in_fence);
    try output.commitQueued();
    try expectClosed(in_fence);
    try std.testing.expect(fixture.atomic_state.commits[0].flags.test_only);
    try std.testing.expect(fixture.atomic_state.commits[0].flags.allow_modeset);
    try std.testing.expect(fixture.atomic_state.commits[1].flags.allow_modeset);
    try std.testing.expect(fixture.atomic_state.commits[1].flags.nonblock);
    try std.testing.expect(fixture.atomic_state.commits[1].flags.page_flip_event);
    try std.testing.expect(fixture.atomic_state.hasProperty(30, 32, 100));
    try std.testing.expect(fixture.atomic_state.hasProperty(30, 36, @as(u64, 64) << 16));
    try std.testing.expect(fixture.atomic_state.hasProperty(30, 40, 64));
    try std.testing.expect(fixture.atomic_state.hasProperty(30, 42, @bitCast(@as(i64, in_fence))));
    try std.testing.expect(fixture.atomic_state.hasProperty(20, 23, @intFromPtr(&output.records[0].out_fence_fd)));
    try output.terminalDeviceTeardown();
    try fixture.drainAndDestroy(output);

    fixture = .{};
    fixture.plane[0].properties.in_fence_fd = 0;
    output = try fixture.create(.{});
    const image = fixture.acquire(0);
    const rejected_fence = try createTestFence();
    defer _ = linux.close(rejected_fence);
    try std.testing.expectError(error.InFenceUnsupported, output.queue(image, rejected_fence));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fcntl(rejected_fence, linux.F.GETFD, 0)));
    try FakeImages.discard(&fixture.images_state, image);
    try fixture.destroy(output);
}

test "kms: flips present new and release only previous scanout" {
    var fixture = Fixture{};
    const output = try fixture.create(.{});
    const first = fixture.acquire(0);
    try output.queue(first, null);
    try output.commitQueued();
    try std.testing.expectEqual(@as(usize, 1), fixture.images_state.submit_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.images_state.release_count);
    fixture.flip(output, fixture.crtc[0].id, false);
    try output.processCallbacks();
    try std.testing.expectEqual(first, output.current.?);
    try std.testing.expectEqual(@as(usize, 0), fixture.images_state.release_count);

    const second = fixture.acquire(1);
    try output.queue(second, null);
    try output.commitQueued();
    fixture.flip(output, fixture.crtc[0].id, false);
    try output.processCallbacks();
    try std.testing.expectEqual(second, output.current.?);
    try std.testing.expectEqualSlices(framebuffer.Handle, &.{first}, fixture.images_state.released[0..fixture.images_state.release_count]);
    try output.requestPause();
    try std.testing.expectEqualSlices(framebuffer.Handle, &.{ first, second }, fixture.images_state.released[0..fixture.images_state.release_count]);
    try fixture.drainAndDestroy(output);
}

test "kms: mismatched and duplicate callbacks retain all KMS images" {
    var fixture = Fixture{};
    var output = try fixture.create(.{});
    const wrong = fixture.acquire(0);
    try output.queue(wrong, null);
    try output.commitQueued();
    fixture.flip(output, 999, false);
    try std.testing.expectError(error.InvalidPageFlipCallback, output.processCallbacks());
    try std.testing.expectEqual(State.failed, output.state);
    try std.testing.expectEqual(@as(usize, 0), fixture.images_state.release_count);
    try output.terminalDeviceTeardown();
    try fixture.drainAndDestroy(output);

    fixture = .{};
    output = try fixture.create(.{});
    try output.queue(fixture.acquire(0), null);
    try output.commitQueued();
    fixture.flip(output, fixture.crtc[0].id, true);
    try std.testing.expectError(error.InvalidPageFlipCallback, output.processCallbacks());
    try std.testing.expectEqual(@as(usize, 0), fixture.images_state.release_count);
    try output.terminalDeviceTeardown();
    try fixture.drainAndDestroy(output);
}

test "kms: event capacity delays policy and previous release" {
    var fixture = Fixture{};
    const output = try fixture.create(.{ .event_capacity = 1 });
    const first = fixture.acquire(0);
    try output.queue(first, null);
    try output.commitQueued();
    fixture.flip(output, fixture.crtc[0].id, false);
    try output.processCallbacks();
    const second = fixture.acquire(1);
    try output.queue(second, null);
    try output.commitQueued();
    fixture.flip(output, fixture.crtc[0].id, false);
    try std.testing.expectError(error.EventQueueFull, output.processCallbacks());
    try std.testing.expectEqual(@as(usize, 0), fixture.images_state.release_count);
    output.clearEvents();
    try output.processCallbacks();
    try std.testing.expectEqualSlices(framebuffer.Handle, &.{first}, fixture.images_state.released[0..fixture.images_state.release_count]);
    output.clearEvents();
    try output.requestPause();
    output.clearEvents();
    try fixture.drainAndDestroy(output);
}

test "kms: pause pending flip and terminal removal preserve scanout lifetime" {
    var fixture = Fixture{};
    var output = try fixture.create(.{});
    const image = fixture.acquire(0);
    try output.queue(image, null);
    try output.commitQueued();
    try output.requestPause();
    try std.testing.expectEqual(State.disabling, output.state);
    try std.testing.expectEqual(@as(usize, 0), fixture.images_state.release_count);
    fixture.flip(output, fixture.crtc[0].id, false);
    try output.processCallbacks();
    try std.testing.expectEqual(State.paused, output.state);
    try std.testing.expectEqualSlices(framebuffer.Handle, &.{image}, fixture.images_state.released[0..fixture.images_state.release_count]);
    try fixture.drainAndDestroy(output);

    fixture = .{};
    output = try fixture.create(.{});
    const current = fixture.acquire(0);
    try output.queue(current, null);
    try output.commitQueued();
    fixture.flip(output, fixture.crtc[0].id, false);
    try output.processCallbacks();
    const pending = fixture.acquire(1);
    try output.queue(pending, null);
    try output.commitQueued();
    try output.terminalDeviceTeardown();
    try std.testing.expectEqualSlices(framebuffer.Handle, &.{ current, pending }, fixture.images_state.released[0..fixture.images_state.release_count]);
    try fixture.drainAndDestroy(output);
    try std.testing.expectEqual(@as(usize, 0), fixture.atomic_state.blob_destroy_count);
}

test "kms: mode blob and request cleanup is reverse and generation exhaustion never aliases" {
    var fixture = Fixture{};
    const output = try fixture.create(.{ .commit_capacity = 2 });
    output.records[0].generation = std.math.maxInt(u32);
    try output.queue(fixture.acquire(0), null);
    try output.commitQueued();
    fixture.flip(output, fixture.crtc[0].id, false);
    try output.processCallbacks();
    try std.testing.expectEqual(RecordState.retired, output.records[0].state);
    try output.requestPause();
    try fixture.drainAndDestroy(output);
    try std.testing.expectEqual(@as(usize, 1), fixture.atomic_state.blob_destroy_count);
    try std.testing.expectEqualSlices(usize, &.{ 2, 1 }, fixture.atomic_state.destroyed_requests[0..fixture.atomic_state.destroy_count]);

    fixture = .{ .atomic_state = .{ .fail_request_at = 2 } };
    try std.testing.expectError(error.FakeRequest, fixture.create(.{ .commit_capacity = 3 }));
    try std.testing.expectEqualSlices(usize, &.{1}, fixture.atomic_state.destroyed_requests[0..fixture.atomic_state.destroy_count]);
}

test "kms: poll cancellation CQEs drain in either order" {
    var fixture = Fixture{};
    var output = try fixture.create(.{});
    output.state = .paused;
    var router = try completion.Router.init(std.testing.allocator, 4);
    defer router.deinit(std.testing.allocator);
    const poll = try router.acquire(.backend_ready);
    const cancel = try router.acquire(.backend_ready);
    output.poll_token = poll;
    output.cancel_token = cancel;
    output.state = .draining;
    var ring: linux.IoUring = undefined;
    try output.completeReadiness(&router, &ring, cancel, 0);
    try std.testing.expect(!output.drainComplete());
    try output.completeReadiness(&router, &ring, poll, negativeErrno(.CANCELED));
    try std.testing.expect(output.drainComplete());
    try output.destroy();

    fixture = .{};
    output = try fixture.create(.{});
    const poll2 = try router.acquire(.backend_ready);
    const cancel2 = try router.acquire(.backend_ready);
    output.poll_token = poll2;
    output.cancel_token = cancel2;
    output.state = .draining;
    try output.completeReadiness(&router, &ring, poll2, negativeErrno(.CANCELED));
    try output.completeReadiness(&router, &ring, cancel2, errorNoEntry());
    try std.testing.expect(output.drainComplete());
    try output.destroy();
}

test "kms: one-shot readiness rearms without submitting internally" {
    var ring = linux.IoUring.init(8, 0) catch |err| switch (err) {
        error.PermissionDenied, error.SystemOutdated => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();
    const raw_fd = linux.eventfd(1, linux.EFD.CLOEXEC);
    if (linux.errno(raw_fd) != .SUCCESS) return error.EventFdFailed;
    const fd: std.posix.fd_t = @intCast(raw_fd);
    defer _ = linux.close(fd);

    var fixture = Fixture{ .device_fd = fd };
    const output = try fixture.create(.{});
    var router = try completion.Router.init(std.testing.allocator, 4);
    defer router.deinit(std.testing.allocator);
    try output.prepareReadiness(&router, &ring);
    try std.testing.expectEqual(@as(u32, 1), ring.sq_ready());
    _ = try ring.submit_and_wait(1);
    const cqe = try ring.copy_cqe();
    const token = router.route(cqe.user_data) orelse return error.UnknownToken;
    try output.completeReadiness(&router, &ring, token, cqe.res);
    try std.testing.expectEqual(@as(usize, 1), fixture.atomic_state.handle_event_count);
    try std.testing.expectEqual(@as(u32, 1), ring.sq_ready());

    try output.requestPause();
    try output.beginDrain(&router, &ring);
    try std.testing.expectEqual(@as(u32, 2), ring.sq_ready());
    _ = try ring.submit_and_wait(2);
    var completed: usize = 0;
    while (completed < 2) : (completed += 1) {
        const drained = try ring.copy_cqe();
        const drained_token = router.route(drained.user_data) orelse return error.UnknownToken;
        try output.completeReadiness(&router, &ring, drained_token, drained.res);
    }
    try std.testing.expect(output.drainComplete());
    try output.destroy();
}

test "kms: stale DRM generation discards queued image before commit" {
    var fixture = Fixture{};
    const output = try fixture.create(.{});
    try output.queue(fixture.acquire(0), null);
    fixture.device_generation += 1;
    try std.testing.expectError(error.StaleSnapshot, output.commitQueued());
    try std.testing.expectEqual(@as(usize, 1), fixture.images_state.discard_count);
    fixture.device_generation -= 1;
    try fixture.destroy(output);
}

fn errorNoEntry() i32 {
    return negativeErrno(.NOENT);
}

fn createTestFence() !std.posix.fd_t {
    const raw_fd = linux.eventfd(0, linux.EFD.CLOEXEC);
    if (linux.errno(raw_fd) != .SUCCESS) return error.EventFdFailed;
    return @intCast(raw_fd);
}

fn expectClosed(fd: std.posix.fd_t) !void {
    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));
}

const FakeAtomic = struct {
    const Property = struct { object: u32, property: u32, value: u64 };
    const Commit = struct { flags: atomic.CommitFlags, userdata: ?*anyopaque };

    request_count: usize = 0,
    fail_request_at: usize = 0,
    destroyed_requests: [8]usize = undefined,
    destroy_count: usize = 0,
    properties: [128]Property = undefined,
    property_count: usize = 0,
    reset_count: usize = 0,
    commits: [16]Commit = undefined,
    commit_count: usize = 0,
    fail_commit_at: usize = 0,
    blob_create_count: usize = 0,
    blob_destroy_count: usize = 0,
    handle_event_count: usize = 0,
    callback_userdata: ?*anyopaque = null,

    const vtable: atomic.Platform.VTable = .{
        .create_blob = createBlob,
        .destroy_blob = destroyBlob,
        .create_request = createRequest,
        .destroy_request = destroyRequest,
        .reset_request = resetRequest,
        .add_property = addProperty,
        .commit = commit,
        .handle_events = handleEvents,
    };

    fn platform(self: *FakeAtomic) atomic.Platform {
        return .{ .context = self, .vtable = &vtable };
    }
    fn hasProperty(self: *const FakeAtomic, object: u32, property: u32, value: u64) bool {
        for (self.properties[0..self.property_count]) |candidate|
            if (candidate.object == object and candidate.property == property and candidate.value == value)
                return true;
        return false;
    }
    fn createBlob(context: *anyopaque, _: std.posix.fd_t, _: drm.Mode) !u32 {
        const self: *FakeAtomic = @ptrCast(@alignCast(context));
        self.blob_create_count += 1;
        return 77;
    }
    fn destroyBlob(context: *anyopaque, _: std.posix.fd_t, _: u32) !void {
        const self: *FakeAtomic = @ptrCast(@alignCast(context));
        self.blob_destroy_count += 1;
    }
    fn createRequest(context: *anyopaque) !atomic.Request {
        const self: *FakeAtomic = @ptrCast(@alignCast(context));
        self.request_count += 1;
        if (self.request_count == self.fail_request_at) return error.FakeRequest;
        return @ptrFromInt(self.request_count * 16);
    }
    fn destroyRequest(context: *anyopaque, request: atomic.Request) void {
        const self: *FakeAtomic = @ptrCast(@alignCast(context));
        self.destroyed_requests[self.destroy_count] = @intFromPtr(request) / 16;
        self.destroy_count += 1;
    }
    fn resetRequest(context: *anyopaque, _: atomic.Request) void {
        const self: *FakeAtomic = @ptrCast(@alignCast(context));
        self.reset_count += 1;
    }
    fn addProperty(context: *anyopaque, _: atomic.Request, object: u32, property: u32, value: u64) !void {
        const self: *FakeAtomic = @ptrCast(@alignCast(context));
        self.properties[self.property_count] = .{ .object = object, .property = property, .value = value };
        self.property_count += 1;
    }
    fn commit(
        context: *anyopaque,
        _: std.posix.fd_t,
        _: atomic.Request,
        flags: atomic.CommitFlags,
        userdata: ?*anyopaque,
    ) !void {
        const self: *FakeAtomic = @ptrCast(@alignCast(context));
        self.commit_count += 1;
        self.commits[self.commit_count - 1] = .{ .flags = flags, .userdata = userdata };
        if (self.commit_count == self.fail_commit_at) return error.FakeCommit;
        if (userdata != null) self.callback_userdata = userdata;
    }
    fn handleEvents(context: *anyopaque, _: std.posix.fd_t, _: atomic.FlipCallback) !void {
        const self: *FakeAtomic = @ptrCast(@alignCast(context));
        self.handle_event_count += 1;
    }
};

const FakeImages = struct {
    states: [3]framebuffer.State = .{ .free, .free, .free },
    generations: [3]u32 = .{ 1, 1, 1 },
    submitted: [3]framebuffer.Handle = undefined,
    submit_count: usize = 0,
    discarded: [3]framebuffer.Handle = undefined,
    discard_count: usize = 0,
    released: [3]framebuffer.Handle = undefined,
    release_count: usize = 0,

    fn images(self: *FakeImages) Images {
        return .{
            .context = self,
            .get_image = getImage,
            .validate_submit = validate,
            .submit_image = submit,
            .discard_image = discard,
            .release_image = release,
        };
    }
    fn acquire(self: *FakeImages, slot: usize) framebuffer.Handle {
        std.debug.assert(self.states[slot] == .free);
        self.states[slot] = .acquired;
        return .{ .slot = @intCast(slot), .generation = self.generations[slot] };
    }
    fn get(self: *FakeImages, handle: framebuffer.Handle) !usize {
        if (handle.slot >= self.states.len or self.generations[handle.slot] != handle.generation or
            self.states[handle.slot] == .free)
            return error.StaleImage;
        return handle.slot;
    }
    fn getImage(context: *anyopaque, handle: framebuffer.Handle) !framebuffer.Image {
        const self: *FakeImages = @ptrCast(@alignCast(context));
        const slot = try self.get(handle);
        var metadata: @import("../gbm.zig").Metadata = .{
            .width = 64,
            .height = 48,
            .format = @import("../gbm.zig").format_xrgb8888,
            .modifier = @import("../gbm.zig").modifier_linear,
            .plane_count = 1,
        };
        metadata.handles[0] = @intCast(slot + 1);
        metadata.strides[0] = 64;
        return .{ .metadata = metadata, .framebuffer_id = @intCast(100 + slot), .state = self.states[slot] };
    }
    fn validate(context: *anyopaque, handle: framebuffer.Handle) !void {
        const self: *FakeImages = @ptrCast(@alignCast(context));
        const slot = try self.get(handle);
        if (self.states[slot] != .acquired) return error.InvalidTransition;
    }
    fn submit(context: *anyopaque, handle: framebuffer.Handle) !void {
        const self: *FakeImages = @ptrCast(@alignCast(context));
        const slot = try self.get(handle);
        if (self.states[slot] != .acquired) return error.InvalidTransition;
        self.states[slot] = .submitted;
        self.submitted[self.submit_count] = handle;
        self.submit_count += 1;
    }
    fn discard(context: *anyopaque, handle: framebuffer.Handle) !void {
        const self: *FakeImages = @ptrCast(@alignCast(context));
        const slot = try self.get(handle);
        if (self.states[slot] != .acquired) return error.InvalidTransition;
        self.discarded[self.discard_count] = handle;
        self.discard_count += 1;
        self.recycle(slot);
    }
    fn release(context: *anyopaque, handle: framebuffer.Handle) !void {
        const self: *FakeImages = @ptrCast(@alignCast(context));
        const slot = try self.get(handle);
        if (self.states[slot] != .submitted) return error.InvalidTransition;
        self.released[self.release_count] = handle;
        self.release_count += 1;
        self.recycle(slot);
    }
    fn recycle(self: *FakeImages, slot: usize) void {
        self.states[slot] = .free;
        self.generations[slot] += 1;
    }
};

const Fixture = struct {
    atomic_state: FakeAtomic = .{},
    images_state: FakeImages = .{},
    device_generation: u32 = 7,
    device_fd: std.posix.fd_t = 17,
    connector: [1]drm.Connector = .{.{
        .id = 10,
        .connector_type = 0,
        .connector_type_id = 0,
        .connected = true,
        .desktop = true,
        .width_mm = 1,
        .height_mm = 1,
        .encoder_id = 0,
        .mode_start = 0,
        .mode_count = 1,
        .encoder_start = 0,
        .encoder_count = 0,
        .properties = .{ .crtc_id = 11 },
    }},
    mode: [1]drm.Mode = .{.{
        .clock = 1,
        .hdisplay = 64,
        .hsync_start = 64,
        .hsync_end = 64,
        .htotal = 64,
        .hskew = 0,
        .vdisplay = 48,
        .vsync_start = 48,
        .vsync_end = 48,
        .vtotal = 48,
        .vscan = 0,
        .vrefresh = 60,
        .flags = 0,
        .mode_type = 0,
    }},
    crtc: [1]drm.Crtc = .{.{
        .id = 20,
        .index = 0,
        .properties = .{ .active = 21, .mode_id = 22, .out_fence_ptr = 23 },
    }},
    plane: [1]drm.Plane = .{.{
        .id = 30,
        .possible_crtcs = 1,
        .plane_type_value = 1,
        .format_start = 0,
        .format_count = 1,
        .properties = .{
            .plane_type = 31,
            .fb_id = 32,
            .crtc_id = 33,
            .src_x = 34,
            .src_y = 35,
            .src_w = 36,
            .src_h = 37,
            .crtc_x = 38,
            .crtc_y = 39,
            .crtc_w = 40,
            .crtc_h = 41,
            .in_fence_fd = 42,
        },
    }},
    formats: [1]drm.Format = .{.{ .fourcc = 0, .modifier = 0 }},

    fn create(self: *Fixture, config: Config) !*Output {
        return Output.create(
            std.testing.allocator,
            self.atomic_state.platform(),
            .{ .context = self, .get_fd = deviceFd },
            self.images_state.images(),
            self.snapshot(),
            config,
        );
    }
    fn snapshot(self: *Fixture) drm.Snapshot {
        return .{
            .handle = .{ .generation = self.device_generation },
            .card = .{},
            .connectors = &self.connector,
            .modes = &self.mode,
            .connector_encoders = &.{},
            .encoders = &.{},
            .crtcs = &self.crtc,
            .planes = &self.plane,
            .formats = &self.formats,
            .selection = .{ .connector_index = 0, .mode_index = 0, .crtc_index = 0, .plane_index = 0 },
        };
    }
    fn acquire(self: *Fixture, slot: usize) framebuffer.Handle {
        return self.images_state.acquire(slot);
    }
    fn flip(self: *Fixture, _: *Output, crtc_id: u32, duplicate: bool) void {
        const userdata = self.atomic_state.callback_userdata.?;
        pageFlipCallback(userdata, 1, 2, 3, crtc_id);
        if (duplicate) pageFlipCallback(userdata, 1, 2, 3, crtc_id);
    }
    fn destroy(self: *Fixture, output: *Output) !void {
        if (output.state != .paused and output.state != .removed) {
            if (output.state == .initial) try output.requestPause() else try output.terminalDeviceTeardown();
        }
        try self.drainAndDestroy(output);
    }
    fn drainAndDestroy(_: *Fixture, output: *Output) !void {
        var router = try completion.Router.init(std.testing.allocator, 2);
        defer router.deinit(std.testing.allocator);
        var ring: linux.IoUring = undefined;
        try output.beginDrain(&router, &ring);
        try output.destroy();
    }
    fn deviceFd(context: *anyopaque, handle: drm.Handle) !std.posix.fd_t {
        const self: *Fixture = @ptrCast(@alignCast(context));
        if (handle.generation != self.device_generation) return error.StaleSnapshot;
        return self.device_fd;
    }
};
