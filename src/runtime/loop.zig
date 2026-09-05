//! One bounded, non-nested server event turn over Ouro's shared io_uring.

const std = @import("std");
const wayring = @import("wayring");
const completion = @import("completion.zig");
const compositor = @import("compositor.zig");
const shutdown_signal = @import("shutdown_signal.zig");
const timer = @import("timer.zig");

const linux = std.os.linux;
const Cqe = linux.io_uring_cqe;

fn boundedCount(ready: u32, capacity: usize) usize {
    return @min(@as(usize, ready), capacity);
}

pub const Error = std.mem.Allocator.Error || error{InvalidConfig};

pub const Config = struct {
    /// Maximum CQEs consumed by one turn. A received Wayland CQE contains at
    /// most the reactor's configured receive-buffer size, so this also bounds
    /// request bytes decoded by Wayring during a turn.
    completion_batch: usize,

    pub fn validate(config: Config) Error!void {
        if (config.completion_batch == 0 or
            config.completion_batch > std.math.maxInt(u32))
            return error.InvalidConfig;
    }
};

pub const TimerOutcome = struct {
    token: completion.Token,
    handle: timer.Handle,
    event: timer.Event,
};

pub const OuroCompletion = struct {
    token: completion.Token,
    cqe: Cqe,
};

/// Returns the allocation-owning event-loop type for a generated protocol.
/// The compositor, completion router, and timers must outlive it.
pub fn Loop(comptime protocol: type) type {
    return struct {
        const Self = @This();
        const Compositor = compositor.Compositor(protocol);
        const Driver = wayring.server.Driver(protocol);
        const WayringCompletion = Driver.RoutedCompletion;

        pub const Progress = struct {
            reaped: usize,
            wayring_completions: usize,
            timer_outcomes: []const TimerOutcome,
            ouro_completions: []const OuroCompletion,
            /// CQEs which belong to neither a live Ouro operation nor a live
            /// Wayring operation. They have been consumed but never dispatched.
            unrouted_completions: []const Cqe,
            wayring: Driver.Progress,
            submitted: u32,
            shutdown_requested: bool,
            reload_requested: bool,
            /// More CQEs or deferred Wayring preparation remain for a future
            /// turn. The caller can use this to avoid blocking.
            needs_more_work: bool,
        };

        allocator: std.mem.Allocator,
        compositor: *Compositor,
        router: *completion.Router,
        timers: *timer.Timers,
        driver: Driver,
        cqes: []Cqe,
        wayring_cqes: []WayringCompletion,
        timer_outcomes: []TimerOutcome,
        ouro_completions: []OuroCompletion,
        unrouted_completions: []Cqe,
        shutdown: ?*shutdown_signal.Watcher = null,
        shutdown_token: ?completion.Token = null,
        shutdown_seen: bool = false,
        pending_wayring_count: usize = 0,
        retained_wayring_progress: Driver.Progress = .{},
        retained_shutdown_requested: bool = false,
        retained_reload_requested: bool = false,

        /// Allocates all turn storage and queues the initial listener accept.
        /// Nothing is submitted until the first call to `turn`.
        pub fn init(
            allocator: std.mem.Allocator,
            owner: *Compositor,
            router: *completion.Router,
            timers: *timer.Timers,
            display_context: ?*anyopaque,
            config: Config,
        ) !Self {
            try config.validate();

            var driver = try Driver.init(allocator, &owner.runtime, display_context);
            errdefer driver.deinit(allocator);
            const cqes = try allocator.alloc(Cqe, config.completion_batch);
            errdefer allocator.free(cqes);
            const wayring_cqes = try allocator.alloc(WayringCompletion, config.completion_batch);
            errdefer allocator.free(wayring_cqes);
            const timer_outcomes = try allocator.alloc(TimerOutcome, config.completion_batch);
            errdefer allocator.free(timer_outcomes);
            const ouro_completions = try allocator.alloc(OuroCompletion, config.completion_batch);
            errdefer allocator.free(ouro_completions);
            const unrouted_completions = try allocator.alloc(Cqe, config.completion_batch);
            errdefer allocator.free(unrouted_completions);

            try owner.runtime.prepareAccept();
            return .{
                .allocator = allocator,
                .compositor = owner,
                .router = router,
                .timers = timers,
                .driver = driver,
                .cqes = cqes,
                .wayring_cqes = wayring_cqes,
                .timer_outcomes = timer_outcomes,
                .ouro_completions = ouro_completions,
                .unrouted_completions = unrouted_completions,
            };
        }

        /// Requires completed shutdown and invalidates slices returned by the
        /// last turn.
        pub fn deinit(self: *Self) void {
            std.debug.assert(self.shutdown_token == null);
            std.debug.assert(self.pending_wayring_count == 0);
            self.driver.deinit(self.allocator);
            self.allocator.free(self.unrouted_completions);
            self.allocator.free(self.ouro_completions);
            self.allocator.free(self.timer_outcomes);
            self.allocator.free(self.wayring_cqes);
            self.allocator.free(self.cqes);
            self.* = undefined;
        }

        /// Queues the process signal descriptor poll for the first turn's sole
        /// submission. The poll remains owned until a watched signal arrives.
        pub fn installShutdown(self: *Self, watcher: *shutdown_signal.Watcher) !void {
            if (self.shutdown != null) return error.AlreadyInstalled;
            self.shutdown = watcher;
            try self.armSignalPoll();
        }

        fn armSignalPoll(self: *Self) !void {
            const token = try self.router.acquire(.shutdown);
            errdefer self.router.retire(token) catch unreachable;
            _ = try self.compositor.ring.poll_add(
                token.encode(),
                self.shutdown.?.descriptor(),
                linux.POLL.IN | linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL,
            );
            self.shutdown_token = token;
        }

        /// Starts Wayring's abrupt listener/client drain. Cancellation SQEs are
        /// prepared by the next turn and all resulting CQEs must continue to be
        /// processed until `Progress.wayring.shutdown_complete` is true.
        pub fn requestShutdown(self: *Self) !void {
            if (self.shutdown) |watcher| watcher.request();
            try self.driver.requestShutdown();
        }

        /// Waits without flushing or submitting SQEs. The preceding turn has
        /// already submitted every prepared operation; this only blocks until
        /// one completion is available for the following turn to consume.
        pub fn waitForCompletion(self: *Self) !void {
            if (self.compositor.ring.cq_ready() != 0) return;
            _ = self.compositor.ring.enter(0, 1, linux.IORING_ENTER_GETEVENTS) catch |err| switch (err) {
                error.SignalInterrupt => return,
                else => return err,
            };
        }

        /// Performs one allocation-free turn without waiting for future CQEs.
        ///
        /// CQEs are clipped before consumption. Every live Ouro completion is
        /// classified before Wayring dispatch, so a full Wayring batch cannot
        /// postpone a timer CQE already in that batch. If the handler declares
        /// `completions`, it receives both borrowed Ouro outcome slices as one
        /// batch and may update state or prepare SQEs before Wayring dispatch.
        /// Wayring completions retain their classification from the shared-ring
        /// routing pass and then undergo bounded request dispatch. If declared,
        /// `prepare(*Handler) !void` runs afterward so the coordinator can
        /// consume events produced by that dispatch and schedule their protocol
        /// output before Wayring's single preparation pass and submission.
        /// `submissionWorkPending(*const Handler) bool` prevents sleeping when
        /// SQ pressure requires a submit followed by another prepare turn.
        /// The ring enter is deliberately last and includes initial accept,
        /// timer, completion/dispatch/prepare-hook, shutdown, and Wayring SQEs.
        /// The completion hook has this contract:
        ///
        /// `fn completions(*Handler, []const TimerOutcome,
        ///     []const OuroCompletion) !void`
        ///
        /// Returned slices borrow fixed loop storage and remain valid only until
        /// the next turn or `deinit`.
        pub fn turn(self: *Self, handler: anytype) !Progress {
            return self.turnInternal(handler, false);
        }

        /// Performs a turn and combines its submission with the next wait when
        /// no bounded work remains. Production uses this to avoid a separate
        /// submit syscall before every blocking `io_uring_enter` while tests
        /// and embedders can retain the nonblocking `turn` contract.
        pub fn turnAndWait(self: *Self, handler: anytype) !Progress {
            return self.turnInternal(handler, true);
        }

        fn turnInternal(self: *Self, handler: anytype, wait_on_idle: bool) !Progress {
            var phase: enum { reap, route, completions, dispatch, coordinator_prepare, driver_prepare, submit } = .reap;
            errdefer std.log.err("compositor loop failed in phase {t}", .{phase});
            const copied = if (self.pending_wayring_count != 0)
                0
            else copied: {
                const ready = self.compositor.ring.cq_ready();
                const count = boundedCount(ready, self.cqes.len);
                break :copied if (count == 0)
                    0
                else
                    try self.compositor.ring.copy_cqes(self.cqes[0..count], 0);
            };

            var wayring_count = self.pending_wayring_count;
            var timer_count: usize = 0;
            var ouro_count: usize = 0;
            var unrouted_count: usize = 0;
            phase = .route;
            for (self.cqes[0..copied]) |cqe| {
                if (cqe.user_data == completion.skipped_success_user_data) {
                    if (cqe.res < 0) return error.SkippedOperationFailed;
                    return error.UnexpectedSkippedCompletion;
                }
                if (self.router.route(cqe.user_data)) |token| {
                    if (token.kind == .shutdown) {
                        if (self.shutdown_token == null or
                            !std.meta.eql(self.shutdown_token.?, token))
                            return error.UnexpectedShutdownCompletion;
                        if (cqe.res < 0 or @as(u32, @intCast(cqe.res)) & linux.POLL.IN == 0)
                            return error.ShutdownPollFailed;
                        const events = try self.shutdown.?.consume();
                        std.log.info(
                            "received process signal: shutdown={}, reload={}, sender_pid={d}, sender_uid={d}",
                            .{ events.shutdown, events.reload, events.sender_pid, events.sender_uid },
                        );
                        try self.router.retire(token);
                        self.shutdown_token = null;
                        self.retained_shutdown_requested =
                            self.retained_shutdown_requested or events.shutdown;
                        self.retained_reload_requested =
                            self.retained_reload_requested or events.reload;
                        self.shutdown_seen = self.shutdown_seen or events.shutdown;
                        if (!self.shutdown_seen) try self.armSignalPoll();
                        continue;
                    }
                    if (token.kind == .timer) {
                        const completed = try self.timers.complete(self.router, token, cqe.res);
                        self.timer_outcomes[timer_count] = .{
                            .token = token,
                            .handle = completed.handle,
                            .event = completed.event,
                        };
                        timer_count += 1;
                    } else {
                        self.ouro_completions[ouro_count] = .{
                            .token = token,
                            .cqe = cqe,
                        };
                        ouro_count += 1;
                    }
                    continue;
                }

                // Decode the namespace first, then use Wayring's live reactor
                // routing contract. In particular, forged/stale Ouro values
                // cannot fall through into Driver.dispatch.
                _ = wayring.completion.Token.decode(cqe.user_data) catch {
                    self.unrouted_completions[unrouted_count] = cqe;
                    unrouted_count += 1;
                    continue;
                };
                const target = self.compositor.reactor.route(
                    &self.compositor.runtime.endpoint.listener,
                    cqe,
                ) orelse {
                    self.unrouted_completions[unrouted_count] = cqe;
                    unrouted_count += 1;
                    continue;
                };
                self.wayring_cqes[wayring_count] = .{
                    .completion = cqe,
                    .target = target,
                };
                wayring_count += 1;
            }
            self.pending_wayring_count = wayring_count;

            const completed_timers = self.timer_outcomes[0..timer_count];
            const completed_ouro = self.ouro_completions[0..ouro_count];
            phase = .completions;
            if (timer_count != 0 or ouro_count != 0) {
                if (@hasDecl(@TypeOf(handler.*), "completions"))
                    try handler.completions(completed_timers, completed_ouro);
            }

            phase = .dispatch;
            const dispatched = self.driver.dispatchRouted(
                self.wayring_cqes[0..wayring_count],
                handler,
            );
            switch (dispatched) {
                .complete => |progress| {
                    self.retained_wayring_progress.merge(progress);
                    self.pending_wayring_count = 0;
                },
                .failed => |failure| {
                    self.retained_wayring_progress.merge(failure.progress);
                    const suffix = self.wayring_cqes[failure.progress.completions..wayring_count];
                    std.mem.copyForwards(
                        WayringCompletion,
                        self.wayring_cqes[0..suffix.len],
                        suffix,
                    );
                    self.pending_wayring_count = suffix.len;
                    return failure.cause;
                },
            }
            var wayring_progress = self.retained_wayring_progress;
            phase = .coordinator_prepare;
            if (@hasDecl(@TypeOf(handler.*), "prepare"))
                try handler.prepare();
            // Dispatch and coordinator convergence can both schedule peers.
            // Prepare their combined output once before this turn's sole
            // submission.
            phase = .driver_prepare;
            wayring_progress.merge(try self.driver.prepare(handler));
            const backend_drained = if (@hasDecl(@TypeOf(handler.*), "backendDrainComplete"))
                handler.backendDrainComplete()
            else
                false;
            const bindings_work_pending = if (@hasDecl(@TypeOf(handler.*), "bindingsWorkPending"))
                handler.bindingsWorkPending()
            else
                false;
            const submission_work_pending = if (@hasDecl(@TypeOf(handler.*), "submissionWorkPending"))
                handler.submissionWorkPending()
            else
                false;
            const can_wait = wait_on_idle and self.compositor.ring.cq_ready() == 0 and
                !wayring_progress.pending and !self.retained_shutdown_requested and
                !self.retained_reload_requested and
                !bindings_work_pending and !submission_work_pending and
                !(wayring_progress.shutdown_complete and backend_drained);
            phase = .submit;
            const submitted = if (can_wait)
                self.compositor.ring.submit_and_wait(1) catch |err| switch (err) {
                    // TERM/INT and tracing can interrupt the wait after the
                    // SQ tail has been published. Pending operations remain
                    // owned by the ring and a later turn consumes their CQEs.
                    error.SignalInterrupt => 0,
                    else => return err,
                }
            else if (self.compositor.ring.sq_ready() != 0)
                try self.compositor.ring.submit()
            else
                0;
            const progress: Progress = .{
                .reaped = copied,
                .wayring_completions = wayring_count,
                .timer_outcomes = completed_timers,
                .ouro_completions = completed_ouro,
                .unrouted_completions = self.unrouted_completions[0..unrouted_count],
                .wayring = wayring_progress,
                .submitted = submitted,
                .shutdown_requested = self.retained_shutdown_requested,
                .reload_requested = self.retained_reload_requested,
                .needs_more_work = self.compositor.ring.cq_ready() != 0 or
                    self.pending_wayring_count != 0 or wayring_progress.pending or
                    bindings_work_pending or submission_work_pending,
            };
            self.retained_wayring_progress = .{};
            self.retained_shutdown_requested = false;
            self.retained_reload_requested = false;
            return progress;
        }
    };
}

test "event turn rejects an unbounded zero batch" {
    try std.testing.expectError(
        error.InvalidConfig,
        (Config{ .completion_batch = 0 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidConfig,
        (Config{ .completion_batch = @as(usize, std.math.maxInt(u32)) + 1 }).validate(),
    );
    try (Config{ .completion_batch = 1 }).validate();
}

test "ready completions are clipped to the configured batch" {
    try std.testing.expectEqual(@as(usize, 3), boundedCount(8, 3));
    try std.testing.expectEqual(@as(usize, 2), boundedCount(2, 3));
    try std.testing.expectEqual(@as(usize, 0), boundedCount(0, 3));
}
