//! Bounded, single-producer performance flight recorder. Only the reporting
//! thread formats or writes output; a stalled sink never blocks the producer.
const std = @import("std");
const linux = std.os.linux;
const c = @cImport({
    @cInclude("time.h");
    @cInclude("signal.h");
    @cInclude("pthread.h");
});
const content = @import("render/content.zig");

pub const Kind = enum {
    commit,
    content_prepare,
    content_slot,
    content_allocate,
    content_inherit,
    content_damage,
    content_full_copy,
    content_publish,
    render,
    render_late,
    render_ready,
    flip_dispatch,
    sample,
};
const kind_count = @typeInfo(Kind).@"enum".fields.len;
pub const work_budget_ns = 2 * std.time.ns_per_ms;
const report_interval_ns = 30 * std.time.ns_per_s;
const context_capacity = 24;
const queue_capacity = 1024;

pub const Context = struct {
    surface: u64 = 0,
    commit: u64 = 0,
    output: u64 = 0,
    frame: u64 = 0,
    bytes: u64 = 0,
    damage_pixels: u64 = 0,
    upload_token: ?u64 = null,
    memory_flags: ?u32 = null,
    reuse: enum { unknown, new, index, stale, surface, incompatible, pinned, replaced } = .unknown,
};

pub const Event = struct {
    kind: Kind,
    start_ns: u64,
    end_ns: u64,
    cpu_ns: ?u64 = null,
    budget_ns: u64 = work_budget_ns,
    context: Context = .{},

    pub fn duration(self: Event) u64 {
        return self.end_ns -| self.start_ns;
    }
};

pub const Stamp = struct {
    ns: u64,
    cpu_ns: ?u64,

    pub fn now() ?Stamp {
        return .{ .ns = clock(c.CLOCK_MONOTONIC) orelse return null, .cpu_ns = clock(c.CLOCK_THREAD_CPUTIME_ID) };
    }
};

fn clock(id: c.clockid_t) ?u64 {
    var value: c.struct_timespec = undefined;
    if (c.clock_gettime(id, &value) != 0 or value.tv_sec < 0) return null;
    return @as(u64, @intCast(value.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(value.tv_nsec));
}

/// Stack-owned context installed only while processing a candidate. No client
/// pointers, strings, pixel data, titles, or input events enter the recorder.
pub const Scope = struct {
    recorder: *Recorder,
    context: Context,

    pub fn finish(self: *const Scope, kind: Kind, start: ?Stamp) void {
        self.recorder.finish(kind, start, self.context);
    }
};

/// Reuses the content store's existing observer without enabling verbose
/// pacing logs. This borrowed observer never outlives the preparation call.
pub const ContentWork = struct {
    scope: ?Scope,
    verbose: ?content.PreparationTrace = null,
    begin: ?Stamp = null,

    pub fn observer(self: *ContentWork) ?content.PreparationTrace {
        if (self.scope == null and self.verbose == null) return null;
        return .{ .context = self, .emit_fn = emit };
    }

    fn emit(context: *const anyopaque, event: content.PreparationTrace.Event) void {
        const self: *ContentWork = @ptrCast(@alignCast(@constCast(context)));
        if (self.scope) |*scope| {
            if (event.bytes) |bytes| scope.context.bytes = bytes;
            if (event.token) |token| scope.context.upload_token = token;
            if (event.memory) |memory| scope.context.memory_flags = memory.property_flags;
            const reasons = .{ "missing", "index", "stale", "surface", "incompatible", "pinned" };
            const values = .{ .new, .index, .stale, .surface, .incompatible, .pinned };
            inline for (reasons, values) |reason, value| {
                if (std.mem.eql(u8, event.stage, "content-reuse-rejected-" ++ reason)) scope.context.reuse = value;
            }
            if (std.mem.eql(u8, event.stage, "content-reuse-accepted")) scope.context.reuse = .replaced;
            const names = .{ "slot", "backing", "inherit", "damage", "full-copy" };
            const kinds = [_]Kind{ .content_slot, .content_allocate, .content_inherit, .content_damage, .content_full_copy };
            inline for (names, kinds) |name, kind| {
                if (std.mem.eql(u8, event.stage, "content-" ++ name ++ "-begin")) self.begin = Stamp.now();
                if (std.mem.eql(u8, event.stage, "content-" ++ name ++ "-end")) {
                    scope.finish(kind, self.begin);
                    self.begin = null;
                }
            }
        }
        if (self.verbose) |trace| trace.emit_fn(trace.context, event);
    }
};

pub const Recorder = struct {
    queue: [queue_capacity]Event = undefined,
    written: std.atomic.Value(usize) = .init(0),
    read: std.atomic.Value(usize) = .init(0),
    dropped: std.atomic.Value(u64) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    /// Borrowed sink, defaulting to the existing session log. Never closed here.
    output_fd: linux.fd_t = 2,

    /// Must stay at this address until stop. Exactly one producer is allowed.
    pub fn start(self: *Recorder) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Stop only after the producer is finished. Joining may wait for the log
    /// sink, but never occurs in the compositor's active event loop.
    pub fn stop(self: *Recorder) void {
        self.stopping.store(true, .release);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    pub fn finish(self: *Recorder, kind: Kind, started: ?Stamp, context: Context) void {
        const before = started orelse return;
        const after = Stamp.now() orelse return;
        self.record(.{
            .kind = kind,
            .start_ns = before.ns,
            .end_ns = after.ns,
            .cpu_ns = if (before.cpu_ns != null and after.cpu_ns != null)
                after.cpu_ns.? -| before.cpu_ns.?
            else
                null,
            .context = context,
        });
    }

    pub fn record(self: *Recorder, event: Event) void {
        // Independent timestamp providers can disagree slightly. Do not turn
        // a negative delta into a huge latency or a false zero measurement.
        if (event.end_ns < event.start_ns) return;
        const tail = self.written.load(.monotonic);
        if (tail -% self.read.load(.acquire) == queue_capacity) {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return;
        }
        self.queue[tail % queue_capacity] = event;
        self.written.store(tail +% 1, .release);
    }

    /// Single consumer; also permits deterministic analysis without a worker.
    pub fn take(self: *Recorder) ?Event {
        const head = self.read.load(.monotonic);
        if (head == self.written.load(.acquire)) return null;
        const event = self.queue[head % queue_capacity];
        self.read.store(head +% 1, .release);
        return event;
    }

    fn run(self: *Recorder) void {
        // A closed logging pipe is a lost report, not a compositor shutdown.
        var mask: c.sigset_t = undefined;
        _ = c.sigemptyset(&mask);
        _ = c.sigaddset(&mask, c.SIGPIPE);
        _ = c.pthread_sigmask(c.SIG_BLOCK, &mask, null);
        var analyzer: Analyzer = .{};
        while (true) {
            // Bound each drain even when the producer stays busy.
            for (0..queue_capacity) |_| {
                analyzer.add(self.take() orelse break);
            }
            const now = clock(c.CLOCK_MONOTONIC) orelse 0;
            const dropped = self.dropped.load(.monotonic);
            if (analyzer.due(now, dropped)) analyzer.report(self.output_fd, now, dropped);
            if (self.stopping.load(.acquire) and
                self.read.load(.monotonic) == self.written.load(.acquire))
            {
                if (analyzer.pending or dropped != analyzer.reported_dropped)
                    analyzer.report(self.output_fd, now, dropped);
                return;
            }
            const delay: linux.timespec = .{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
            _ = linux.nanosleep(&delay, null);
        }
    }
};

const Summary = struct {
    count: u64 = 0,
    slow: u64 = 0,
    worst: ?Event = null,
    // Duration buckets: <=1, <=2, <=8, <=16, <=50, >50 ms.
    histogram: [6]u64 = @splat(0),
};

pub const Analyzer = struct {
    summaries: [kind_count]Summary = @splat(.{}),
    history: [context_capacity]Event = undefined,
    history_count: usize = 0,
    history_next: usize = 0,
    incident: [context_capacity]Event = undefined,
    incident_count: usize = 0,
    following: usize = 0,
    worst_excess: u64 = 0,
    pending: bool = false,
    first_pending_ns: u64 = 0,
    last_report_ns: ?u64 = null,
    reported_dropped: u64 = 0,

    pub fn add(self: *Analyzer, event: Event) void {
        const elapsed = event.duration();
        const summary = &self.summaries[@intFromEnum(event.kind)];
        summary.count +|= 1;
        if (summary.worst == null or elapsed > summary.worst.?.duration()) summary.worst = event;
        const limits = [_]u64{ 1, 2, 8, 16, 50 };
        var bucket: usize = 0;
        while (bucket < limits.len and elapsed > limits[bucket] * std.time.ns_per_ms) : (bucket += 1) {}
        summary.histogram[bucket] +|= 1;
        if (elapsed > event.budget_ns) {
            summary.slow +|= 1;
            if (!self.pending) self.first_pending_ns = event.end_ns;
            self.pending = true;
            const excess = elapsed - event.budget_ns;
            if (excess > self.worst_excess) {
                self.worst_excess = excess;
                // Retain up to 15 preceding records, the trigger, and 8
                // following records. Nested spans can overlap; do not sum them.
                const before: usize = @min(self.history_count, context_capacity - 9);
                for (0..before) |i| self.incident[i] = self.history[
                    (self.history_next + context_capacity - before + i) % context_capacity
                ];
                self.incident[before] = event;
                self.incident_count = before + 1;
                self.following = 8;
            } else self.appendFollowing(event);
        } else self.appendFollowing(event);
        self.history[self.history_next] = event;
        self.history_next = (self.history_next + 1) % context_capacity;
        self.history_count = @min(self.history_count + 1, context_capacity);
    }

    fn appendFollowing(self: *Analyzer, event: Event) void {
        if (self.following == 0) return;
        self.incident[self.incident_count] = event;
        self.incident_count += 1;
        self.following -= 1;
    }

    pub fn due(self: *const Analyzer, now: u64, dropped: u64) bool {
        if (!self.pending and dropped == self.reported_dropped) return false;
        if (self.last_report_ns) |last| return now -| last >= report_interval_ns;
        // Allow post-incident context to arrive before the first report.
        return now -| self.first_pending_ns >= std.time.ns_per_s;
    }

    fn report(self: *Analyzer, fd: linux.fd_t, now: u64, dropped: u64) void {
        writeLine(fd, "perf-incident ns={d} dropped_total={d} context_records={d} (durations in ns; overlapping spans)", .{ now, dropped, self.incident_count });
        for (self.summaries, 0..) |summary, index| {
            if (summary.slow == 0) continue;
            const kind: Kind = @enumFromInt(index);
            writeLine(fd, "perf-summary kind={s} count={d} slow={d} worst_ns={d} histogram_le_1_2_8_16_50_over50_ms={any}", .{
                @tagName(kind), summary.count, summary.slow, summary.worst.?.duration(), summary.histogram,
            });
            writeEvent(fd, "worst", summary.worst.?);
        }
        for (self.incident[0..self.incident_count]) |event| writeEvent(fd, "context", event);
        self.pending = false;
        self.last_report_ns = now;
        self.reported_dropped = dropped;
        self.worst_excess = 0;
        self.incident_count = 0;
        self.following = 0;
    }
};

fn writeEvent(fd: linux.fd_t, comptime label: []const u8, event: Event) void {
    writeLine(fd, "perf-" ++ label ++ " kind={s} start_ns={d} end_ns={d} elapsed_ns={d} cpu_ns={?d} budget_ns={d} surface={d} commit={d} output={d} frame={d} bytes={d} damage_pixels={d} reuse={s} upload_token={?d} memory_flags={?d}", .{
        @tagName(event.kind),          event.start_ns,             event.end_ns,               event.duration(),    event.cpu_ns,        event.budget_ns,
        event.context.surface,         event.context.commit,       event.context.output,       event.context.frame, event.context.bytes, event.context.damage_pixels,
        @tagName(event.context.reuse), event.context.upload_token, event.context.memory_flags,
    });
}

fn writeLine(fd: linux.fd_t, comptime format: []const u8, args: anytype) void {
    var buffer: [2048]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, format ++ "\n", args) catch return;
    // Do not take std.log's process-wide stderr lock: its other users include
    // the compositor thread. Slow/failed writes affect only this worker.
    var offset: usize = 0;
    while (offset < line.len) {
        const result = linux.write(fd, line.ptr + offset, line.len - offset);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) return;
                offset += result;
            },
            .INTR => continue,
            else => return,
        }
    }
}

test "flight recorder bounds stalled-consumer storage and resumes without overwriting" {
    var recorder: Recorder = .{};
    for (0..queue_capacity + 9) |i| recorder.record(.{ .kind = .commit, .start_ns = i, .end_ns = i + 1 });
    try std.testing.expectEqual(9, recorder.dropped.load(.monotonic));
    for (0..queue_capacity) |i| try std.testing.expectEqual(i, recorder.take().?.start_ns);
    try std.testing.expect(recorder.take() == null);
    recorder.record(.{ .kind = .commit, .start_ns = 2, .end_ns = 1 });
    try std.testing.expect(recorder.take() == null);
    // Exercise counter wrapping as well as ordinary ring wrapping.
    recorder.read.store(std.math.maxInt(usize), .monotonic);
    recorder.written.store(std.math.maxInt(usize), .monotonic);
    recorder.record(.{ .kind = .commit, .start_ns = 7, .end_ns = 8 });
    try std.testing.expectEqual(7, recorder.take().?.start_ns);
}

test "automatic budgets detect imperceptible work and preserve before and after context" {
    var analyzer: Analyzer = .{};
    for (0..40) |i| analyzer.add(.{ .kind = .commit, .start_ns = i, .end_ns = i + 1 });
    try std.testing.expect(!analyzer.due(100 * std.time.ns_per_s, 0)); // idle is not a stall
    const slow: Event = .{
        .kind = .content_inherit,
        .start_ns = std.time.ns_per_s,
        .end_ns = std.time.ns_per_s + 56 * std.time.ns_per_ms,
        .cpu_ns = 55 * std.time.ns_per_ms,
        .context = .{ .surface = 77, .commit = 3, .bytes = 9631008, .reuse = .pinned, .memory_flags = 7 },
    };
    analyzer.add(slow);
    for (0..12) |i| analyzer.add(.{ .kind = .content_damage, .start_ns = slow.end_ns + i, .end_ns = slow.end_ns + i + 1 });
    try std.testing.expectEqual(context_capacity, analyzer.incident_count);
    try std.testing.expectEqual(25, analyzer.incident[0].start_ns);
    try std.testing.expectEqual(slow, analyzer.incident[15]);
    const summary = analyzer.summaries[@intFromEnum(Kind.content_inherit)];
    try std.testing.expectEqual(1, summary.slow);
    try std.testing.expectEqual(1, summary.histogram[5]);
    try std.testing.expect(!analyzer.due(slow.end_ns, 0));
    try std.testing.expect(analyzer.due(slow.end_ns + std.time.ns_per_s, 0));
    analyzer.last_report_ns = slow.end_ns;
    try std.testing.expect(!analyzer.due(slow.end_ns + 29 * std.time.ns_per_s, 0));
    try std.testing.expect(analyzer.due(slow.end_ns + 30 * std.time.ns_per_s, 0));
    const reported_at = slow.end_ns + 30 * std.time.ns_per_s;
    analyzer.report(-1, reported_at, 0);
    try std.testing.expect(!analyzer.due(reported_at + report_interval_ns, 0));
    analyzer.add(slow); // repeated incidents count, but cannot flood the sink
    try std.testing.expectEqual(2, analyzer.summaries[@intFromEnum(Kind.content_inherit)].slow);
    try std.testing.expect(!analyzer.due(reported_at + std.time.ns_per_s, 0));
    try std.testing.expect(analyzer.due(reported_at + report_interval_ns, 0));
    analyzer.report(-1, reported_at + report_interval_ns, 0);
    try std.testing.expect(analyzer.due(reported_at + 2 * report_interval_ns, 1)); // dropped records alone are visible
}

test "output budgets use refresh intervals, not time between frames" {
    var analyzer: Analyzer = .{};
    analyzer.add(.{ .kind = .render_late, .start_ns = 100, .end_ns = 8 * std.time.ns_per_ms + 100, .budget_ns = 16666667 });
    analyzer.add(.{ .kind = .render_late, .start_ns = 100, .end_ns = 9 * std.time.ns_per_ms + 100, .budget_ns = 8333333 });
    const summary = analyzer.summaries[@intFromEnum(Kind.render_late)];
    try std.testing.expectEqual(2, summary.count);
    try std.testing.expectEqual(1, summary.slow);
}

test "content observer detects slow backing without verbose tracing and preserves copy-on-write metadata" {
    const Backing = struct {
        storage: [2][8]u8 = undefined,
        used: usize = 0,

        fn allocate(context: *anyopaque, size: usize) !content.Allocation {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.used == self.storage.len or size != 8) return error.OutOfMemory;
            if (self.used != 0) {
                const delay: linux.timespec = .{ .sec = 0, .nsec = 4 * std.time.ns_per_ms };
                _ = linux.nanosleep(&delay, null);
            }
            const bytes = &self.storage[self.used];
            self.used += 1;
            return .{ .bytes = bytes, .upload = .{ .owner = self, .token = self.used, .offset = 0 } };
        }
        fn release(_: *anyopaque, _: u64) void {}
        fn pinned(_: *anyopaque, _: u64) bool {
            return true;
        }
    };
    var backing: Backing = .{};
    var store = try content.Store.initWithProvider(std.testing.allocator, .{ .version_capacity = 2, .byte_capacity = 16 }, .{
        .context = &backing,
        .allocate_fn = Backing.allocate,
        .release_fn = Backing.release,
        .pinned_fn = Backing.pinned,
        .memory_info = .{ .type_index = 1, .property_flags = 7 },
    });
    defer store.deinit();
    var recorder: Recorder = .{};
    var work: ContentWork = .{ .scope = .{ .recorder = &recorder, .context = .{ .surface = 77, .commit = 2 } } };
    const render = @import("render/types.zig");
    var source: render.Source = .{ .size = .{ .width = 2, .height = 1 }, .stride = 8, .format = .xrgb8888, .bytes = &.{ 1, 2, 3, 4, 5, 6, 7, 8 } };
    const old = store.publish(try store.prepareReplacingTraced(null, .{ .surface = 77, .commit_sequence = 1 }, source, .{}, null));
    defer store.release(old);
    source.bytes = &.{ 9, 9, 9, 9, 9, 9, 9, 9 };
    var damage: render.UploadDamage = .{};
    damage.rects[0] = .{ .min_x = 0, .min_y = 0, .max_x = 1, .max_y = 1 };
    damage.count = 1;
    work.scope.?.context.damage_pixels = 1;
    const prepared = try store.prepareReplacingTraced(old, .{ .surface = 77, .commit_sequence = 2 }, source, damage, work.observer());
    const next = store.publish(prepared);
    defer store.release(next);
    try std.testing.expectEqualSlices(u8, &.{ 9, 9, 9, 9, 5, 6, 7, 8 }, (try store.resolve(next)).bytes);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, (try store.resolve(old)).bytes);
    var analyzer: Analyzer = .{};
    while (recorder.take()) |event| {
        try std.testing.expect(event.cpu_ns != null);
        try std.testing.expectEqual(77, event.context.surface);
        try std.testing.expectEqual(2, event.context.commit);
        analyzer.add(event);
    }
    const allocation = analyzer.summaries[@intFromEnum(Kind.content_allocate)];
    try std.testing.expectEqual(1, allocation.slow);
    try std.testing.expectEqual(@as(?u64, 2), allocation.worst.?.context.upload_token);
    const inherit = analyzer.summaries[@intFromEnum(Kind.content_inherit)];
    try std.testing.expectEqual(1, inherit.count);
    try std.testing.expectEqual(8, inherit.worst.?.context.bytes);
    try std.testing.expectEqual(@as(?u64, 1), inherit.worst.?.context.upload_token);
    try std.testing.expectEqual(@as(?u32, 7), inherit.worst.?.context.memory_flags);
    try std.testing.expectEqual(.pinned, inherit.worst.?.context.reuse);
    try std.testing.expectEqual(1, inherit.worst.?.context.damage_pixels);
}

test "worker flushes an automatic incident at shutdown and tolerates closed sinks" {
    var pipe: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })));
    defer _ = linux.close(pipe[0]);
    defer _ = linux.close(pipe[1]);
    var recorder: Recorder = .{ .output_fd = pipe[1] };
    try recorder.start();
    recorder.record(.{ .kind = .content_inherit, .start_ns = 100, .end_ns = 56000100, .cpu_ns = 55000000, .context = .{ .surface = 77, .commit = 3, .bytes = 9631008, .memory_flags = 7, .reuse = .pinned } });
    recorder.stop();
    var buffer: [4096]u8 = undefined;
    const size = linux.read(pipe[0], &buffer, buffer.len);
    try std.testing.expectEqual(.SUCCESS, linux.errno(size));
    const text = buffer[0..size];
    try std.testing.expect(std.mem.indexOf(u8, text, "perf-incident") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "kind=content_inherit count=1 slow=1 worst_ns=56000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cpu_ns=55000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "memory_flags=7") != null);

    var broken: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&broken, .{ .CLOEXEC = true })));
    _ = linux.close(broken[0]);
    defer _ = linux.close(broken[1]);
    var lost: Recorder = .{ .output_fd = broken[1] };
    try lost.start();
    lost.record(.{ .kind = .commit, .start_ns = 0, .end_ns = 3000000 });
    lost.stop(); // SIGPIPE from the reporting thread must not terminate Ouro.
}
