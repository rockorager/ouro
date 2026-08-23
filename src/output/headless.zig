//! Deterministic, fixed-capacity output scheduling without a DRM device.
//!
//! The coordinator owns timer completion routing. During its pre-submit hook it
//! passes routed timer events to `timerEvent`, asks `timerRequest` for the next
//! absolute deadline, arms that deadline through `runtime/timer.zig`, and then
//! commits the returned handle with `timerArmed`. This split keeps SQE failure
//! transactional and makes the scheduling policy independently deterministic.

const std = @import("std");
const timer = @import("../runtime/timer.zig");

pub const Timestamp = u64;

pub const OutputId = struct {
    index: u32,
    generation: u32,
};

pub const SurfaceId = struct {
    index: u32,
    generation: u32,
};

/// Immutable identity carried by every render and timer outcome. The output
/// generation prevents an old completion from aliasing a replacement output.
pub const FrameId = struct {
    output: OutputId,
    sequence: u64,
};

pub const Reason = enum(u3) {
    damage,
    callback,
    animation,
    explicit,
};

pub const Requests = struct {
    bits: u8 = 0,

    pub fn contains(requests: Requests, reason: Reason) bool {
        return requests.bits & bit(reason) != 0;
    }

    fn add(requests: *Requests, reason: Reason) void {
        requests.bits |= bit(reason);
    }

    fn bit(reason: Reason) u8 {
        return @as(u8, 1) << @intFromEnum(reason);
    }
};

pub const Stage = enum {
    idle,
    requested,
    armed,
    rendering,
    submitted,
    removed,
};

pub const Config = struct {
    /// CLOCK_MONOTONIC phase of the modeled refresh clock.
    phase_ns: Timestamp = 0,
    refresh_ns: Timestamp,
    render_budget_ns: Timestamp,

    pub fn validate(config: Config) Error!void {
        if (config.refresh_ns == 0 or config.render_budget_ns == 0 or
            config.render_budget_ns >= config.refresh_ns)
            return error.InvalidConfig;
    }
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidConfig,
    InvalidStage,
    StaleFrame,
    StaleTimerRequest,
    MissingSamples,
    SamplesAlreadyCaptured,
    TooManySamples,
    SequenceExhausted,
    TimestampOverflow,
    OutputRemoved,
    UnexpectedTimerEvent,
};

pub const TimerPurpose = enum {
    render_deadline,
    presentation,
};

pub const TimerRequest = struct {
    purpose: TimerPurpose,
    frame: FrameId,
    deadline: timer.Deadline,
};

pub const RenderRequest = struct {
    frame: FrameId,
    requests: Requests,
    target_ns: Timestamp,
};

pub const Disposition = enum {
    presented,
    retired,
};

/// A presented outcome is the only outcome which paces frame callbacks. In
/// both dispositions every entry in `sampled` is safe for the coordinator to
/// finish in `presentation.Queue`, and no unlisted presentation may be
/// released as a consequence of this frame. The slice borrows scheduler
/// storage until the next call to `captureSamples` or `deinit`.
pub fn FrameOutcome(comptime PresentationToken: type) type {
    return struct {
        disposition: Disposition,
        frame: FrameId,
        requests: Requests,
        requested_ns: Timestamp,
        target_ns: Timestamp,
        render_deadline_ns: Timestamp,
        render_started_ns: Timestamp,
        render_finished_ns: Timestamp,
        submitted_ns: ?Timestamp,
        actual_ns: ?Timestamp,
        frame_callbacks_due: bool,
        output_removed: bool,
        sampled: []const Sample(PresentationToken),
    };
}

pub fn Sample(comptime PresentationToken: type) type {
    return struct {
        surface: SurfaceId,
        presentation: PresentationToken,
    };
}

/// One allocation-owning scheduler for one generational output identity.
/// Initialization allocates the exact maximum sample set; all turns thereafter
/// are allocation-free.
pub fn Scheduler(comptime PresentationToken: type) type {
    return struct {
        const Self = @This();
        const SampleType = Sample(PresentationToken);
        const Outcome = FrameOutcome(PresentationToken);

        const Frame = struct {
            id: FrameId,
            requests: Requests,
            requested_ns: Timestamp,
            target_ns: Timestamp,
            render_deadline_ns: Timestamp,
            render_started_ns: ?Timestamp = null,
            render_finished_ns: ?Timestamp = null,
            submitted_ns: ?Timestamp = null,
        };

        output: OutputId,
        config: Config,
        samples: []SampleType,
        sample_count: usize = 0,
        samples_captured: bool = false,
        stage: Stage = .idle,
        pending: Requests = .{},
        pending_since_ns: Timestamp = 0,
        frame: ?Frame = null,
        timer_handle: ?timer.Handle = null,
        next_sequence: u64 = 1,
        retiring: bool = false,

        pub fn init(
            allocator: std.mem.Allocator,
            output: OutputId,
            config: Config,
            max_samples: usize,
        ) Error!Self {
            try config.validate();
            if (max_samples == 0) return error.InvalidConfig;
            return .{
                .output = output,
                .config = config,
                .samples = try allocator.alloc(SampleType, max_samples),
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            std.debug.assert(self.stage == .idle or self.stage == .removed);
            allocator.free(self.samples);
            self.* = undefined;
        }

        pub fn currentStage(self: Self) Stage {
            return self.stage;
        }

        /// Coalesces reasons while preserving the timestamp of the earliest
        /// request not already assigned to a frame.
        pub fn request(self: *Self, reason: Reason, now_ns: Timestamp) Error!void {
            if (self.retiring or self.stage == .removed) return error.OutputRemoved;
            if (self.pending.bits == 0) self.pending_since_ns = now_ns;
            self.pending.add(reason);
            if (self.stage == .idle) self.stage = .requested;
        }

        /// Describes an absolute timer to prepare before the loop's sole
        /// submission. State changes only after `timerArmed`, so an SQE failure
        /// can be retried without losing or duplicating a frame request.
        pub fn timerRequest(self: *const Self, now_ns: Timestamp) Error!?TimerRequest {
            return switch (self.stage) {
                .requested => blk: {
                    const id = try self.prospectiveFrameId();
                    const target = try self.nextTarget(now_ns);
                    break :blk .{
                        .purpose = .render_deadline,
                        .frame = id,
                        .deadline = try deadlineFromNs(target - self.config.render_budget_ns),
                    };
                },
                .rendering => blk: {
                    const active = self.frame.?;
                    if (active.render_finished_ns == null or self.retiring) break :blk null;
                    break :blk .{
                        .purpose = .presentation,
                        .frame = active.id,
                        .deadline = try deadlineFromNs(active.target_ns),
                    };
                },
                else => null,
            };
        }

        /// Commits a successfully prepared Ouro timer handle.
        pub fn timerArmed(
            self: *Self,
            request_value: TimerRequest,
            handle: timer.Handle,
            now_ns: Timestamp,
        ) Error!void {
            switch (request_value.purpose) {
                .render_deadline => {
                    if (self.stage != .requested or self.retiring or
                        !std.meta.eql(request_value.frame, try self.prospectiveFrameId()))
                        return error.StaleTimerRequest;
                    const deadline_ns = try nsFromDeadline(request_value.deadline);
                    const target = std.math.add(
                        Timestamp,
                        deadline_ns,
                        self.config.render_budget_ns,
                    ) catch return error.TimestampOverflow;
                    self.frame = .{
                        .id = request_value.frame,
                        .requests = self.pending,
                        .requested_ns = self.pending_since_ns,
                        .target_ns = target,
                        .render_deadline_ns = target - self.config.render_budget_ns,
                    };
                    self.pending = .{};
                    self.samples_captured = false;
                    self.next_sequence += 1;
                    self.timer_handle = handle;
                    self.stage = .armed;
                },
                .presentation => {
                    const active = self.frame orelse return error.StaleTimerRequest;
                    if (self.stage != .rendering or self.retiring or
                        active.render_finished_ns == null or
                        !std.meta.eql(active.id, request_value.frame) or
                        try nsFromDeadline(request_value.deadline) != active.target_ns)
                        return error.StaleTimerRequest;
                    self.frame.?.submitted_ns = now_ns;
                    self.timer_handle = handle;
                    self.stage = .submitted;
                },
            }
        }

        /// Consumes a timer event already completed through `timer.Timers`.
        /// Unknown and cleanup-only events are harmless, allowing cancellation
        /// races and stale CQEs to converge without aliasing current work.
        pub fn timerEvent(
            self: *Self,
            handle: timer.Handle,
            event: timer.Event,
            now_ns: Timestamp,
        ) Error!?union(enum) {
            render: RenderRequest,
            frame: Outcome,
        } {
            const current_handle = self.timer_handle orelse return null;
            if (!std.meta.eql(current_handle, handle)) return null;
            if (event == .pending_cleanup or event == .cleanup_complete) return null;

            return switch (self.stage) {
                .armed => switch (event) {
                    .fired => {
                        self.timer_handle = null;
                        if (self.retiring) {
                            self.finishRemoved();
                            return null;
                        }
                        self.frame.?.render_started_ns = now_ns;
                        self.stage = .rendering;
                        return .{ .render = .{
                            .frame = self.frame.?.id,
                            .requests = self.frame.?.requests,
                            .target_ns = self.frame.?.target_ns,
                        } };
                    },
                    .canceled => {
                        if (!self.retiring) return error.UnexpectedTimerEvent;
                        self.timer_handle = null;
                        self.finishRemoved();
                        return null;
                    },
                    else => unreachable,
                },
                .submitted => switch (event) {
                    .fired => {
                        self.timer_handle = null;
                        return .{ .frame = self.finishFrame(.presented, now_ns) };
                    },
                    .canceled => {
                        if (!self.retiring) return error.UnexpectedTimerEvent;
                        self.timer_handle = null;
                        return .{ .frame = self.finishFrame(.retired, null) };
                    },
                    else => unreachable,
                },
                else => null,
            };
        }

        /// Captures the exact presentations retained by asynchronous render
        /// work. Call this before launching that work; ownership remains in the
        /// presentation queue and these immutable tokens identify the leases.
        pub fn captureSamples(
            self: *Self,
            frame_id: FrameId,
            sampled: []const SampleType,
        ) Error!void {
            try self.requireFrame(frame_id, .rendering);
            if (self.samples_captured) return error.SamplesAlreadyCaptured;
            if (sampled.len > self.samples.len) return error.TooManySamples;
            @memcpy(self.samples[0..sampled.len], sampled);
            self.sample_count = sampled.len;
            self.samples_captured = true;
        }

        /// Records asynchronous render completion. The presentation timer is
        /// prepared by the following pre-submit `timerRequest` call.
        pub fn renderComplete(
            self: *Self,
            frame_id: FrameId,
            now_ns: Timestamp,
        ) Error!?Outcome {
            try self.requireFrame(frame_id, .rendering);
            if (self.frame.?.render_finished_ns != null) return error.StaleFrame;
            if (!self.samples_captured) return error.MissingSamples;
            self.frame.?.render_finished_ns = now_ns;
            if (!self.retiring) return null;
            return self.finishFrame(.retired, null);
        }

        /// Marks the output terminal. A returned timer handle must be canceled
        /// through `timer.Timers.cancel` before submission; if queuing the SQE
        /// fails, call this again next turn to retry. Render work already in
        /// flight is retired only when its immutable FrameId completes.
        pub fn remove(self: *Self) Error!?union(enum) {
            cancel: timer.Handle,
            frame: Outcome,
        } {
            if (self.stage == .removed) return null;
            self.retiring = true;
            switch (self.stage) {
                .idle, .requested => self.finishRemoved(),
                .armed, .submitted => return .{ .cancel = self.timer_handle.? },
                .rendering => if (self.frame.?.render_finished_ns != null) {
                    return .{ .frame = self.finishFrame(.retired, null) };
                },
                .removed => unreachable,
            }
            return null;
        }

        fn prospectiveFrameId(self: *const Self) Error!FrameId {
            if (self.next_sequence == std.math.maxInt(u64))
                return error.SequenceExhausted;
            return .{ .output = self.output, .sequence = self.next_sequence };
        }

        fn nextTarget(self: *const Self, now_ns: Timestamp) Error!Timestamp {
            const threshold = std.math.add(Timestamp, now_ns, self.config.render_budget_ns) catch
                return error.TimestampOverflow;
            if (self.config.phase_ns > threshold) return self.config.phase_ns;
            const elapsed = threshold - self.config.phase_ns;
            const periods = elapsed / self.config.refresh_ns + 1;
            const advance = std.math.mul(Timestamp, periods, self.config.refresh_ns) catch
                return error.TimestampOverflow;
            return std.math.add(Timestamp, self.config.phase_ns, advance) catch
                return error.TimestampOverflow;
        }

        fn requireFrame(self: *const Self, frame_id: FrameId, stage: Stage) Error!void {
            if (self.stage != stage) return error.InvalidStage;
            const active = self.frame orelse return error.StaleFrame;
            if (!std.meta.eql(active.id, frame_id)) return error.StaleFrame;
        }

        fn finishFrame(
            self: *Self,
            disposition: Disposition,
            actual_ns: ?Timestamp,
        ) Outcome {
            const active = self.frame.?;
            const removed = self.retiring;
            const outcome: Outcome = .{
                .disposition = disposition,
                .frame = active.id,
                .requests = active.requests,
                .requested_ns = active.requested_ns,
                .target_ns = active.target_ns,
                .render_deadline_ns = active.render_deadline_ns,
                .render_started_ns = active.render_started_ns.?,
                .render_finished_ns = active.render_finished_ns.?,
                .submitted_ns = active.submitted_ns,
                .actual_ns = actual_ns,
                .frame_callbacks_due = disposition == .presented,
                .output_removed = removed,
                .sampled = self.samples[0..self.sample_count],
            };
            self.frame = null;
            self.timer_handle = null;
            if (removed) {
                self.stage = .removed;
                self.pending = .{};
            } else if (self.pending.bits != 0) {
                self.stage = .requested;
            } else {
                self.stage = .idle;
            }
            return outcome;
        }

        fn finishRemoved(self: *Self) void {
            self.frame = null;
            self.timer_handle = null;
            self.pending = .{};
            self.stage = .removed;
        }
    };
}

fn deadlineFromNs(ns: Timestamp) Error!timer.Deadline {
    const seconds = ns / std.time.ns_per_s;
    if (seconds > std.math.maxInt(i64)) return error.TimestampOverflow;
    return .{
        .sec = @intCast(seconds),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
}

fn nsFromDeadline(deadline: timer.Deadline) Error!Timestamp {
    if (deadline.sec < 0 or deadline.nsec < 0 or deadline.nsec >= std.time.ns_per_s)
        return error.InvalidConfig;
    const seconds: Timestamp = @intCast(deadline.sec);
    const sec_ns = std.math.mul(Timestamp, seconds, std.time.ns_per_s) catch
        return error.TimestampOverflow;
    return std.math.add(Timestamp, sec_ns, @intCast(deadline.nsec)) catch
        return error.TimestampOverflow;
}

const TestScheduler = Scheduler(u32);
const test_output: OutputId = .{ .index = 4, .generation = 9 };
const test_config: Config = .{
    .phase_ns = 0,
    .refresh_ns = 10,
    .render_budget_ns = 3,
};

fn testInit(max_samples: usize) !TestScheduler {
    return TestScheduler.init(std.testing.allocator, test_output, test_config, max_samples);
}

fn fakeHandle(generation: u32) timer.Handle {
    return .{ .slot = 2, .generation = generation };
}

fn armRender(scheduler: *TestScheduler, now_ns: Timestamp, handle: timer.Handle) !FrameId {
    const request_value = (try scheduler.timerRequest(now_ns)).?;
    try scheduler.timerArmed(request_value, handle, now_ns);
    return request_value.frame;
}

fn startRender(scheduler: *TestScheduler, handle: timer.Handle, now_ns: Timestamp) !FrameId {
    const event = (try scheduler.timerEvent(handle, .fired, now_ns)).?;
    return event.render.frame;
}

fn submit(
    scheduler: *TestScheduler,
    now_ns: Timestamp,
    handle: timer.Handle,
) !void {
    const request_value = (try scheduler.timerRequest(now_ns)).?;
    try std.testing.expectEqual(TimerPurpose.presentation, request_value.purpose);
    try scheduler.timerArmed(request_value, handle, now_ns);
}

test "ordinary headless frame presents exact samples once" {
    var scheduler = try testInit(2);
    defer scheduler.deinit(std.testing.allocator);
    try scheduler.request(.damage, 1);
    const frame_id = try armRender(&scheduler, 1, fakeHandle(1));
    try std.testing.expectEqual(@as(Timestamp, 7), scheduler.frame.?.render_deadline_ns);
    _ = try startRender(&scheduler, fakeHandle(1), 7);
    const samples = [_]Sample(u32){
        .{ .surface = .{ .index = 1, .generation = 2 }, .presentation = 11 },
        .{ .surface = .{ .index = 3, .generation = 4 }, .presentation = 12 },
    };
    try scheduler.captureSamples(frame_id, &samples);
    try std.testing.expect((try scheduler.renderComplete(frame_id, 8)) == null);
    try submit(&scheduler, 8, fakeHandle(2));

    const event = (try scheduler.timerEvent(fakeHandle(2), .fired, 10)).?;
    const outcome = event.frame;
    try std.testing.expectEqual(Disposition.presented, outcome.disposition);
    try std.testing.expect(outcome.frame_callbacks_due);
    try std.testing.expectEqual(@as(Timestamp, 1), outcome.requested_ns);
    try std.testing.expectEqual(@as(Timestamp, 7), outcome.render_started_ns);
    try std.testing.expectEqual(@as(Timestamp, 8), outcome.render_finished_ns);
    try std.testing.expectEqual(@as(?Timestamp, 8), outcome.submitted_ns);
    try std.testing.expectEqual(@as(?Timestamp, 10), outcome.actual_ns);
    try std.testing.expectEqualSlices(Sample(u32), &samples, outcome.sampled);
    try std.testing.expectEqual(Stage.idle, scheduler.currentStage());
    try std.testing.expect((try scheduler.timerEvent(fakeHandle(2), .fired, 10)) == null);
}

test "multiple requests coalesce during and after a frame" {
    var scheduler = try testInit(1);
    defer scheduler.deinit(std.testing.allocator);
    try scheduler.request(.damage, 1);
    try scheduler.request(.callback, 2);
    const first = try armRender(&scheduler, 2, fakeHandle(1));
    try std.testing.expect(scheduler.frame.?.requests.contains(.damage));
    try std.testing.expect(scheduler.frame.?.requests.contains(.callback));
    _ = try startRender(&scheduler, fakeHandle(1), 7);
    try scheduler.captureSamples(first, &.{});
    try scheduler.request(.animation, 8);
    try scheduler.request(.explicit, 9);
    _ = try scheduler.renderComplete(first, 8);
    try submit(&scheduler, 8, fakeHandle(2));
    _ = try scheduler.timerEvent(fakeHandle(2), .fired, 10);
    try std.testing.expectEqual(Stage.requested, scheduler.currentStage());
    const second_request = (try scheduler.timerRequest(10)).?;
    try scheduler.timerArmed(second_request, fakeHandle(3), 10);
    try std.testing.expect(second_request.frame.sequence == first.sequence + 1);
    try std.testing.expect(scheduler.frame.?.requests.contains(.animation));
    try std.testing.expect(scheduler.frame.?.requests.contains(.explicit));
    _ = try scheduler.remove();
    _ = try scheduler.timerEvent(fakeHandle(3), .canceled, 11);
}

test "missed and exact render deadlines defer to a future refresh" {
    var scheduler = try testInit(1);
    defer scheduler.deinit(std.testing.allocator);
    try scheduler.request(.damage, 10);
    const first = (try scheduler.timerRequest(10)).?;
    try std.testing.expectEqual(@as(Timestamp, 17), try nsFromDeadline(first.deadline));
    try scheduler.timerArmed(first, fakeHandle(1), 10);
    _ = try scheduler.remove();
    _ = try scheduler.timerEvent(fakeHandle(1), .canceled, 11);
    try std.testing.expectEqual(Stage.removed, scheduler.currentStage());

    var exact = try testInit(1);
    defer exact.deinit(std.testing.allocator);
    try exact.request(.damage, 17);
    const deferred = (try exact.timerRequest(17)).?;
    try std.testing.expectEqual(@as(Timestamp, 27), try nsFromDeadline(deferred.deadline));
    try exact.timerArmed(deferred, fakeHandle(2), 17);
    _ = try exact.remove();
    _ = try exact.timerEvent(fakeHandle(2), .canceled, 18);
}

test "stale frame timer and output generations cannot alias" {
    var scheduler = try testInit(1);
    defer scheduler.deinit(std.testing.allocator);
    try scheduler.request(.damage, 1);
    const frame_id = try armRender(&scheduler, 1, fakeHandle(3));
    try std.testing.expect((try scheduler.timerEvent(fakeHandle(2), .fired, 7)) == null);
    _ = try startRender(&scheduler, fakeHandle(3), 7);
    var stale = frame_id;
    stale.output.generation -= 1;
    try std.testing.expectError(error.StaleFrame, scheduler.captureSamples(stale, &.{}));
    try scheduler.captureSamples(frame_id, &.{});
    _ = try scheduler.renderComplete(frame_id, 8);
    try submit(&scheduler, 8, fakeHandle(4));
    _ = try scheduler.timerEvent(fakeHandle(4), .fired, 10);
    try std.testing.expect((try scheduler.timerEvent(fakeHandle(4), .fired, 10)) == null);
}

test "output removal retires requested armed and rendering stages" {
    var requested = try testInit(1);
    defer requested.deinit(std.testing.allocator);
    try requested.request(.damage, 1);
    try std.testing.expect((try requested.remove()) == null);
    try std.testing.expectEqual(Stage.removed, requested.currentStage());

    var armed = try testInit(1);
    defer armed.deinit(std.testing.allocator);
    try armed.request(.damage, 1);
    _ = try armRender(&armed, 1, fakeHandle(1));
    try std.testing.expectEqual(fakeHandle(1), (try armed.remove()).?.cancel);
    try std.testing.expectEqual(fakeHandle(1), (try armed.remove()).?.cancel);
    try std.testing.expect((try armed.timerEvent(fakeHandle(1), .pending_cleanup, 2)) == null);
    try std.testing.expect((try armed.timerEvent(fakeHandle(1), .canceled, 2)) == null);
    try std.testing.expectEqual(Stage.removed, armed.currentStage());

    var rendering = try testInit(1);
    defer rendering.deinit(std.testing.allocator);
    try rendering.request(.damage, 1);
    const frame_id = try armRender(&rendering, 1, fakeHandle(1));
    _ = try startRender(&rendering, fakeHandle(1), 7);
    const sample = [_]Sample(u32){.{
        .surface = .{ .index = 8, .generation = 1 },
        .presentation = 42,
    }};
    try rendering.captureSamples(frame_id, &sample);
    try std.testing.expect((try rendering.remove()) == null);
    const outcome = (try rendering.renderComplete(frame_id, 8)).?;
    try std.testing.expectEqual(Disposition.retired, outcome.disposition);
    try std.testing.expect(!outcome.frame_callbacks_due);
    try std.testing.expect(outcome.output_removed);
    try std.testing.expectEqualSlices(Sample(u32), &sample, outcome.sampled);
}

test "output removal during submission reports one safe outcome" {
    var scheduler = try testInit(1);
    defer scheduler.deinit(std.testing.allocator);
    try scheduler.request(.damage, 1);
    const frame_id = try armRender(&scheduler, 1, fakeHandle(1));
    _ = try startRender(&scheduler, fakeHandle(1), 7);
    const sample = [_]Sample(u32){.{
        .surface = .{ .index = 5, .generation = 6 },
        .presentation = 99,
    }};
    try scheduler.captureSamples(frame_id, &sample);
    _ = try scheduler.renderComplete(frame_id, 8);
    try submit(&scheduler, 8, fakeHandle(2));
    try std.testing.expectEqual(fakeHandle(2), (try scheduler.remove()).?.cancel);
    const event = (try scheduler.timerEvent(fakeHandle(2), .canceled, 9)).?;
    try std.testing.expectEqual(Disposition.retired, event.frame.disposition);
    try std.testing.expectEqualSlices(Sample(u32), &sample, event.frame.sampled);
    try std.testing.expect((try scheduler.timerEvent(fakeHandle(2), .canceled, 9)) == null);
    try std.testing.expectEqual(Stage.removed, scheduler.currentStage());
}

test "output removal after render completion returns release-facing outcome" {
    var scheduler = try testInit(1);
    defer scheduler.deinit(std.testing.allocator);
    try scheduler.request(.damage, 1);
    const frame_id = try armRender(&scheduler, 1, fakeHandle(1));
    _ = try startRender(&scheduler, fakeHandle(1), 7);
    const sample = [_]Sample(u32){.{
        .surface = .{ .index = 7, .generation = 3 },
        .presentation = 81,
    }};
    try scheduler.captureSamples(frame_id, &sample);
    _ = try scheduler.renderComplete(frame_id, 8);
    const removal = (try scheduler.remove()).?;
    try std.testing.expectEqual(Disposition.retired, removal.frame.disposition);
    try std.testing.expectEqualSlices(Sample(u32), &sample, removal.frame.sampled);
    try std.testing.expect(!removal.frame.frame_callbacks_due);
    try std.testing.expectEqual(Stage.removed, scheduler.currentStage());
}

test "presentation wins output-removal cancellation race exactly once" {
    var scheduler = try testInit(1);
    defer scheduler.deinit(std.testing.allocator);
    try scheduler.request(.callback, 1);
    const frame_id = try armRender(&scheduler, 1, fakeHandle(1));
    _ = try startRender(&scheduler, fakeHandle(1), 7);
    try scheduler.captureSamples(frame_id, &.{});
    _ = try scheduler.renderComplete(frame_id, 8);
    try submit(&scheduler, 8, fakeHandle(2));
    _ = try scheduler.remove();
    const event = (try scheduler.timerEvent(fakeHandle(2), .fired, 10)).?;
    try std.testing.expectEqual(Disposition.presented, event.frame.disposition);
    try std.testing.expect(event.frame.frame_callbacks_due);
    try std.testing.expect(event.frame.output_removed);
    try std.testing.expect((try scheduler.timerEvent(fakeHandle(2), .cleanup_complete, 10)) == null);
}
