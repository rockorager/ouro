//! Bounded asynchronous ICC compilation. Submission only duplicates and queues
//! a descriptor; all profile I/O and compilation occurs on the worker thread.

const std = @import("std");
const icc = @import("icc.zig");
const linux = std.os.linux;
const c = @cImport({
    @cInclude("pthread.h");
    @cInclude("unistd.h");
});

pub const Config = struct {
    job_capacity: usize,
    profile_byte_budget: usize,
};

pub const Handle = struct { index: u32, generation: u32 };

pub const Failure = enum {
    read_failed,
    short_read,
    out_of_memory,
    profile_too_large,
    malformed_profile,
    unsupported_profile_version,
    unsupported_color_space,
    unsupported_profile_class,
    transform_creation_failed,
    invalid_transform_output,
};

pub const Result = union(enum) {
    lut: icc.Lut,
    failure: Failure,

    pub fn deinit(result: *Result, allocator: std.mem.Allocator) void {
        switch (result.*) {
            .lut => |*lut| lut.deinit(allocator),
            .failure => {},
        }
        result.* = undefined;
    }
};

const State = enum { free, queued, processing, completed, retired };
const Slot = struct {
    generation: u32 = 0,
    state: State = .free,
    fd: linux.fd_t = -1,
    offset: u64 = 0,
    length: usize = 0,
    result: Result = undefined,
};

pub const InitError = error{ InvalidCapacity, InvalidByteBudget, EventFdUnavailable, ThreadSpawnFailed } || std.mem.Allocator.Error;
pub const SubmitError = error{ Stopped, CapacityExceeded, ByteBudgetExceeded, InvalidRange, DuplicateFailed };
pub const TakeError = error{ StaleHandle, NotCompleted };

pub const Worker = struct {
    allocator: std.mem.Allocator,
    slots: []Slot,
    budget: usize,
    reserved: usize = 0,
    completed_count: usize = 0,
    mutex: c.pthread_mutex_t,
    condition: c.pthread_cond_t,
    stopping: bool = false,
    event_fd: linux.fd_t,
    thread: std.Thread,

    pub fn init(allocator: std.mem.Allocator, config: Config) InitError!*Worker {
        if (config.job_capacity == 0 or config.job_capacity > std.math.maxInt(u32)) return error.InvalidCapacity;
        if (config.profile_byte_budget == 0) return error.InvalidByteBudget;
        _ = std.math.mul(usize, config.job_capacity, @sizeOf(Slot)) catch return error.InvalidCapacity;
        const self = try allocator.create(Worker);
        errdefer allocator.destroy(self);
        const slots = try allocator.alloc(Slot, config.job_capacity);
        errdefer allocator.free(slots);
        @memset(slots, .{});
        const raw = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(raw) != .SUCCESS) return error.EventFdUnavailable;
        errdefer _ = linux.close(@intCast(raw));
        self.* = .{
            .allocator = allocator,
            .slots = slots,
            .budget = config.profile_byte_budget,
            .mutex = undefined,
            .condition = undefined,
            .event_fd = @intCast(raw),
            .thread = undefined,
        };
        if (c.pthread_mutex_init(&self.mutex, null) != 0) return error.ThreadSpawnFailed;
        errdefer _ = c.pthread_mutex_destroy(&self.mutex);
        if (c.pthread_cond_init(&self.condition, null) != 0) return error.ThreadSpawnFailed;
        errdefer _ = c.pthread_cond_destroy(&self.condition);
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch return error.ThreadSpawnFailed;
        return self;
    }

    pub fn notificationFd(self: *const Worker) linux.fd_t {
        return self.event_fd;
    }

    /// Drains the nonblocking eventfd counter. True means at least one edge was consumed.
    pub fn consumeNotification(self: *const Worker) error{ NotificationReadFailed, InvalidNotification }!bool {
        var count: u64 = 0;
        const n = linux.read(self.event_fd, std.mem.asBytes(&count).ptr, @sizeOf(u64));
        return switch (linux.errno(n)) {
            .SUCCESS => if (n == @sizeOf(u64) and count != 0) true else error.InvalidNotification,
            .AGAIN => false,
            else => error.NotificationReadFailed,
        };
    }

    /// Duplicates `source_fd`; ownership of the caller's descriptor is unchanged.
    pub fn submit(self: *Worker, source_fd: linux.fd_t, offset: u64, length: usize) SubmitError!Handle {
        if (length == 0 or length > icc.max_profile_bytes or offset > std.math.maxInt(i64)) return error.InvalidRange;
        const end = std.math.add(u64, offset, length) catch return error.InvalidRange;
        if (end > std.math.maxInt(i64)) return error.InvalidRange;
        lock(self);
        defer unlock(self);
        if (self.stopping) return error.Stopped;
        if (length > self.budget - self.reserved) return error.ByteBudgetExceeded;
        var index: ?usize = null;
        for (self.slots, 0..) |slot, i| if (slot.state == .free) {
            index = i;
            break;
        };
        const i = index orelse return error.CapacityExceeded;
        const raw = linux.dup(source_fd);
        if (linux.errno(raw) != .SUCCESS) return error.DuplicateFailed;
        const slot = &self.slots[i];
        slot.generation += 1;
        slot.fd = @intCast(raw);
        slot.offset = offset;
        slot.length = length;
        slot.state = .queued;
        self.reserved += length;
        _ = c.pthread_cond_signal(&self.condition);
        return .{ .index = @intCast(i), .generation = slot.generation };
    }

    /// Transfers ownership of a terminal result to the caller.
    pub fn take(self: *Worker, handle: Handle) TakeError!Result {
        lock(self);
        defer unlock(self);
        if (handle.index >= self.slots.len) return error.StaleHandle;
        const slot = &self.slots[handle.index];
        if (slot.generation != handle.generation or slot.state == .free) return error.StaleHandle;
        if (slot.state != .completed) return error.NotCompleted;
        const result = slot.result;
        self.reserved -= slot.length;
        self.completed_count -= 1;
        slot.state = if (slot.generation == std.math.maxInt(u32)) .retired else .free;
        return result;
    }

    pub fn deinit(self: *Worker) void {
        lock(self);
        self.stopping = true;
        _ = c.pthread_cond_signal(&self.condition);
        unlock(self);
        self.thread.join();
        for (self.slots) |*slot| switch (slot.state) {
            .queued, .processing => _ = linux.close(slot.fd),
            .completed => slot.result.deinit(self.allocator),
            .free, .retired => {},
        };
        _ = linux.close(self.event_fd);
        _ = c.pthread_cond_destroy(&self.condition);
        _ = c.pthread_mutex_destroy(&self.mutex);
        const allocator = self.allocator;
        allocator.free(self.slots);
        allocator.destroy(self);
    }

    fn run(self: *Worker) void {
        while (true) {
            lock(self);
            var chosen: ?usize = null;
            while (chosen == null and !self.stopping) {
                for (self.slots, 0..) |slot, i| if (slot.state == .queued) {
                    chosen = i;
                    break;
                };
                if (chosen == null) _ = c.pthread_cond_wait(&self.condition, &self.mutex);
            }
            if (self.stopping) {
                unlock(self);
                return;
            }
            const i = chosen.?;
            const slot = &self.slots[i];
            slot.state = .processing;
            const fd = slot.fd;
            const offset = slot.offset;
            const length = slot.length;
            unlock(self);

            const result = compileFd(self.allocator, fd, offset, length);
            _ = linux.close(fd);
            lock(self);
            slot.result = result;
            slot.fd = -1;
            slot.state = .completed;
            const notify = self.completed_count == 0;
            self.completed_count += 1;
            if (notify) {
                const one: u64 = 1;
                _ = linux.write(self.event_fd, std.mem.asBytes(&one).ptr, @sizeOf(u64));
            }
            unlock(self);
        }
    }
};

fn lock(self: *Worker) void {
    std.debug.assert(c.pthread_mutex_lock(&self.mutex) == 0);
}

fn unlock(self: *Worker) void {
    std.debug.assert(c.pthread_mutex_unlock(&self.mutex) == 0);
}

fn compileFd(allocator: std.mem.Allocator, fd: linux.fd_t, offset: u64, length: usize) Result {
    const bytes = allocator.alloc(u8, length) catch return .{ .failure = .out_of_memory };
    defer allocator.free(bytes);
    var read: usize = 0;
    while (read < bytes.len) {
        const n = linux.pread(fd, bytes[read..].ptr, bytes.len - read, @intCast(offset + read));
        if (linux.errno(n) != .SUCCESS) return .{ .failure = .read_failed };
        if (n == 0) return .{ .failure = .short_read };
        read += n;
    }
    const lut = icc.compile(allocator, bytes) catch |err| return .{ .failure = switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.ProfileTooLarge => .profile_too_large,
        error.MalformedProfile => .malformed_profile,
        error.UnsupportedProfileVersion => .unsupported_profile_version,
        error.UnsupportedColorSpace => .unsupported_color_space,
        error.UnsupportedProfileClass => .unsupported_profile_class,
        error.TransformCreationFailed => .transform_creation_failed,
        error.InvalidTransformOutput => .invalid_transform_output,
    } };
    return .{ .lut = lut };
}

fn waitTake(worker: *Worker, handle: Handle) !Result {
    for (0..10_000) |_| {
        if (worker.take(handle)) |result| return result else |err| switch (err) {
            error.NotCompleted => {
                _ = c.usleep(1000);
                continue;
            },
            else => return err,
        }
    }
    return error.TestTimedOut;
}

fn profileFile(bytes: []const u8) !struct { dir: std.testing.TmpDir, file: std.Io.File } {
    var dir = std.testing.tmpDir(.{});
    errdefer dir.cleanup();
    const file = try dir.dir.createFile(std.testing.io, "profile.icc", .{ .read = true });
    errdefer file.close(std.testing.io);
    if (linux.write(file.handle, bytes.ptr, bytes.len) != bytes.len) return error.WriteFailed;
    return .{ .dir = dir, .file = file };
}

test "icc worker: valid and malformed jobs, notification edge, and stale handle" {
    const allocator = std.testing.allocator;
    const bytes = try icc.testSrgbBytes(allocator);
    defer allocator.free(bytes);
    var backing = try profileFile(bytes);
    defer backing.dir.cleanup();
    defer backing.file.close(std.testing.io);
    var worker = try Worker.init(allocator, .{ .job_capacity = 2, .profile_byte_budget = bytes.len + 3 });
    defer worker.deinit();

    try std.testing.expect(!(try worker.consumeNotification()));
    const valid = try worker.submit(backing.file.handle, 0, bytes.len);
    const malformed = try worker.submit(backing.file.handle, 0, 3);
    // The second job cannot complete until the first has also completed.
    var second = try waitTake(worker, malformed);
    defer second.deinit(allocator);
    try std.testing.expectEqual(Failure.malformed_profile, second.failure);
    var first = try worker.take(valid);
    defer first.deinit(allocator);
    try std.testing.expect(first == .lut);
    // Both completions belong to one nonempty interval, hence exactly one edge.
    try std.testing.expect(try worker.consumeNotification());
    try std.testing.expect(!(try worker.consumeNotification()));
    try std.testing.expectError(error.StaleHandle, worker.take(valid));
}

test "icc worker: capacity and byte budget are hard reservations" {
    var backing = try profileFile("bad!");
    defer backing.dir.cleanup();
    defer backing.file.close(std.testing.io);
    var capacity = try Worker.init(std.testing.allocator, .{ .job_capacity = 1, .profile_byte_budget = 8 });
    defer capacity.deinit();
    _ = try capacity.submit(backing.file.handle, 0, 4);
    try std.testing.expectError(error.CapacityExceeded, capacity.submit(backing.file.handle, 0, 4));

    var budget = try Worker.init(std.testing.allocator, .{ .job_capacity = 2, .profile_byte_budget = 4 });
    defer budget.deinit();
    _ = try budget.submit(backing.file.handle, 0, 3);
    try std.testing.expectError(error.ByteBudgetExceeded, budget.submit(backing.file.handle, 0, 2));
}

test "icc worker: configuration validation and shutdown owns outstanding resources" {
    try std.testing.expectError(error.InvalidCapacity, Worker.init(std.testing.allocator, .{ .job_capacity = 0, .profile_byte_budget = 1 }));
    try std.testing.expectError(error.InvalidByteBudget, Worker.init(std.testing.allocator, .{ .job_capacity = 1, .profile_byte_budget = 0 }));
    var backing = try profileFile("malformed");
    defer backing.dir.cleanup();
    defer backing.file.close(std.testing.io);
    var worker = try Worker.init(std.testing.allocator, .{ .job_capacity = 2, .profile_byte_budget = 18 });
    _ = try worker.submit(backing.file.handle, 0, 9);
    _ = try worker.submit(backing.file.handle, 0, 9);
    worker.deinit();
}
