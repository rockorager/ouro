//! One bounded, non-nested server event turn over Ouro's shared io_uring.

const std = @import("std");
const wayring = @import("wayring");
const completion = @import("completion.zig");
const compositor = @import("compositor.zig");
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
        wayring_cqes: []Cqe,
        timer_outcomes: []TimerOutcome,
        ouro_completions: []OuroCompletion,
        unrouted_completions: []Cqe,

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
            const wayring_cqes = try allocator.alloc(Cqe, config.completion_batch);
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
            self.driver.deinit(self.allocator);
            self.allocator.free(self.unrouted_completions);
            self.allocator.free(self.ouro_completions);
            self.allocator.free(self.timer_outcomes);
            self.allocator.free(self.wayring_cqes);
            self.allocator.free(self.cqes);
            self.* = undefined;
        }

        /// Starts Wayring's abrupt listener/client drain. Cancellation SQEs are
        /// prepared by the next turn and all resulting CQEs must continue to be
        /// processed until `Progress.wayring.shutdown_complete` is true.
        pub fn requestShutdown(self: *Self) !void {
            try self.driver.requestShutdown();
        }

        /// Performs one allocation-free turn and exactly one ring submission.
        ///
        /// CQEs are clipped before consumption. Every live Ouro completion is
        /// classified before Wayring dispatch, so a full Wayring batch cannot
        /// postpone a timer CQE already in that batch. If the handler declares
        /// `completions`, it receives both borrowed Ouro outcome slices as one
        /// batch and may update state or prepare SQEs before Wayring dispatch.
        /// Wayring then performs completion routing and bounded request
        /// dispatch. If declared, `prepare(*Handler) !void` runs afterward so
        /// the coordinator can consume events produced by that dispatch and
        /// schedule their protocol output in the same submission. The sole
        /// submission is deliberately last and includes initial accept, timer,
        /// completion/dispatch/prepare-hook, shutdown, and Wayring SQEs. The completion
        /// hook has this contract:
        ///
        /// `fn completions(*Handler, []const TimerOutcome,
        ///     []const OuroCompletion) !void`
        ///
        /// Returned slices borrow fixed loop storage and remain valid only until
        /// the next turn or `deinit`.
        pub fn turn(self: *Self, handler: anytype) !Progress {
            const ready = self.compositor.ring.cq_ready();
            const count = boundedCount(ready, self.cqes.len);
            const copied = if (count == 0)
                0
            else
                try self.compositor.ring.copy_cqes(self.cqes[0..count], 0);

            var wayring_count: usize = 0;
            var timer_count: usize = 0;
            var ouro_count: usize = 0;
            var unrouted_count: usize = 0;
            for (self.cqes[0..copied]) |cqe| {
                if (self.router.route(cqe.user_data)) |token| {
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
                if (self.compositor.reactor.route(
                    &self.compositor.runtime.endpoint.listener,
                    cqe,
                ) == null) {
                    self.unrouted_completions[unrouted_count] = cqe;
                    unrouted_count += 1;
                    continue;
                }
                self.wayring_cqes[wayring_count] = cqe;
                wayring_count += 1;
            }

            const completed_timers = self.timer_outcomes[0..timer_count];
            const completed_ouro = self.ouro_completions[0..ouro_count];
            if (timer_count != 0 or ouro_count != 0) {
                if (@hasDecl(@TypeOf(handler.*), "completions"))
                    try handler.completions(completed_timers, completed_ouro);
            }

            var wayring_progress = try self.driver.dispatch(
                self.wayring_cqes[0..wayring_count],
                handler,
            );
            if (@hasDecl(@TypeOf(handler.*), "prepare")) {
                try handler.prepare();
                // Dispatch prepares before invoking request handlers. The
                // coordinator hook can schedule peers in response to the
                // terminal request in that batch, so prepare those newly
                // scheduled sends before this turn's sole submission.
                const prepared = try self.driver.prepare(handler);
                wayring_progress.prepared += prepared.prepared;
                wayring_progress.pending = prepared.pending;
            }
            const submitted = try self.compositor.ring.submit();
            return .{
                .reaped = copied,
                .wayring_completions = wayring_count,
                .timer_outcomes = completed_timers,
                .ouro_completions = completed_ouro,
                .unrouted_completions = self.unrouted_completions[0..unrouted_count],
                .wayring = wayring_progress,
                .submitted = submitted,
                .needs_more_work = self.compositor.ring.cq_ready() != 0 or
                    wayring_progress.pending,
            };
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
