//! Stable-address ownership root for Ouro's headless Wayring runtime.
//!
//! `Compositor.create` allocates the root before initializing anything that
//! retains an interior pointer. The returned allocation must therefore never
//! be copied or moved. Subsystems receive only the dependency they need:
//! Wayring's reactor borrows `ring`, and its runtime borrows `reactor`.

const std = @import("std");
const wayring = @import("wayring");

const linux = std.os.linux;

/// Setup parameters for the shared ring Ouro owns and Wayring borrows.
pub const RingConfig = struct {
    /// Submission queue depth. Must be a power of two.
    entries: u16,
    /// Completion queue depth. Zero accepts the kernel default of twice
    /// `entries`; any other value is rounded up to a power of two by the
    /// kernel. Multishot receive, accept, and poll operations post more
    /// CQEs than the SQEs that armed them, so a deeper CQ keeps bursts out
    /// of the kernel's slower overflow list.
    cq_entries: u32 = 0,
    flags: u32 = default_flags,

    /// Every ring operation, including every blocking wait, is issued from the
    /// thread that created the ring, so completions can be deferred until that
    /// thread enters the ring instead of interrupting it mid-turn, and the
    /// kernel can skip submission locking. Deferred completions are invisible
    /// to `cq_ready` until an enter runs them; `TASKRUN_FLAG` makes the kernel
    /// raise `IORING_SQ_TASKRUN` so a non-waiting turn knows to enter. The
    /// kernel raises that flag only when this setup flag is present, so it is
    /// not optional. `SUBMIT_ALL` keeps one rejected SQE from stalling the rest
    /// of a turn's batch until the next enter.
    pub const default_flags: u32 = linux.IORING_SETUP_SINGLE_ISSUER |
        linux.IORING_SETUP_DEFER_TASKRUN |
        linux.IORING_SETUP_TASKRUN_FLAG |
        linux.IORING_SETUP_SUBMIT_ALL;
};

/// Creates the ring, retrying without setup flags on kernels that predate
/// them so a stale kernel degrades to interrupt-driven completions instead of
/// failing startup.
pub fn initRing(config: RingConfig) !linux.IoUring {
    return initRingWithFlags(config, config.flags) catch |err| switch (err) {
        error.ArgumentsInvalid => if (config.flags != 0) fallback: {
            // Warn only once the retry proves the flags were the problem
            // rather than the entry counts.
            const ring = try initRingWithFlags(config, 0);
            std.log.warn(
                "kernel rejected io_uring setup flags 0x{x}; continuing without them",
                .{config.flags},
            );
            break :fallback ring;
        } else err,
        else => err,
    };
}

fn initRingWithFlags(config: RingConfig, flags: u32) !linux.IoUring {
    var params = std.mem.zeroInit(linux.io_uring_params, .{
        .flags = flags,
        .sq_thread_idle = 1000,
    });
    if (config.cq_entries != 0) {
        params.flags |= linux.IORING_SETUP_CQSIZE;
        params.cq_entries = config.cq_entries;
    }
    return linux.IoUring.init_params(config.entries, &params);
}

/// Returns the composition-root type for a generated Wayland protocol module.
pub fn Compositor(comptime protocol: type) type {
    return struct {
        const Self = @This();

        pub const Runtime = wayring.server.Runtime(protocol);

        pub const Config = struct {
            ring: RingConfig,
            reactor: wayring.io_uring.Config,
            runtime: Runtime.Config,
        };

        allocator: std.mem.Allocator,
        ring: linux.IoUring,
        reactor: wayring.io_uring.Reactor,
        runtime: Runtime,

        /// Allocates the root at its final address and takes ownership of
        /// `listener_fd`, including on every initialization failure.
        pub fn create(
            allocator: std.mem.Allocator,
            listener_fd: linux.fd_t,
            config: Config,
        ) !*Self {
            var listener_owned = true;
            errdefer if (listener_owned) {
                _ = linux.close(listener_fd);
            };

            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.allocator = allocator;

            self.ring = try initRing(config.ring);
            errdefer self.ring.deinit();

            try self.reactor.initBorrowed(allocator, &self.ring, config.reactor);
            errdefer self.reactor.deinit(allocator);

            // Runtime.init consumes the descriptor whether it succeeds or
            // fails, so ownership transfers immediately before the call.
            listener_owned = false;
            self.runtime = try Runtime.init(
                allocator,
                &self.reactor,
                listener_fd,
                config.runtime,
            );
            return self;
        }

        /// Destroys a quiescent runtime in strict reverse initialization order.
        ///
        /// If Wayring reports an armed listener or active clients, no part of
        /// the root has been torn down and the caller may finish shutdown and
        /// retry. A successful call invalidates `self`.
        pub fn deinit(self: *Self) !void {
            try self.runtime.deinit(self.allocator);
            self.reactor.deinit(self.allocator);
            self.ring.deinit();

            const allocator = self.allocator;
            allocator.destroy(self);
        }
    };
}

test "reactor failure unwinds the ring and consumes the listener descriptor" {
    const TestCompositor = Compositor(struct {});
    const open_result = linux.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(open_result));
    const listener_fd: linux.fd_t = @intCast(open_result);

    try std.testing.expectError(error.InvalidConfig, TestCompositor.create(
        std.testing.allocator,
        listener_fd,
        .{
            .ring = .{ .entries = 8 },
            .reactor = .{
                .receive_buffer_size = 4096,
                .receive_buffer_count = 3,
                .receive_control_capacity = 64,
                .fragment_block_size = 64,
                .fragment_block_count = 1,
                .transmit_block_size = 64,
                .transmit_block_count = 1,
                .descriptor_count = 1,
                .send_descriptor_capacity = 1,
            },
            .runtime = .{
                .actor = .{
                    .received_fd_budget = 1,
                    .transmit_byte_budget = 64,
                    .transmit_fd_budget = 1,
                },
                .object_capacity = 2,
                .object_quota = 2,
                .buckets_per_client = 2,
                .max_globals = 1,
                .registry_capacity = 1,
            },
        },
    ));
    try std.testing.expectEqual(
        linux.E.BADF,
        linux.errno(linux.fcntl(listener_fd, linux.F.GETFD, 0)),
    );
}

test "ring setup honors the requested completion depth and flags" {
    var ring = initRing(.{ .entries = 8, .cq_entries = 64 }) catch |err| switch (err) {
        error.PermissionDenied, error.SystemOutdated => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();
    try std.testing.expectEqual(@as(usize, 8), ring.sq.sqes.len);
    try std.testing.expectEqual(@as(usize, 64), ring.cq.cqes.len);
    // The kernel echoes the accepted setup flags plus CQSIZE. A pre-6.1
    // kernel takes the fallback path, which the next test covers directly.
    const setup_flags = ring.flags & ~@as(u32, linux.IORING_SETUP_CQSIZE);
    try std.testing.expect(setup_flags == RingConfig.default_flags or setup_flags == 0);
    try std.testing.expect(ring.flags & linux.IORING_SETUP_CQSIZE != 0);
}

test "ring setup falls back to no flags when the kernel rejects them" {
    // Bit 31 is not a defined setup flag on any kernel, so the first attempt
    // always fails with EINVAL and the fallback must succeed without it.
    var ring = initRing(.{ .entries = 8, .cq_entries = 32, .flags = 1 << 31 }) catch |err| switch (err) {
        error.PermissionDenied, error.SystemOutdated => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();
    try std.testing.expectEqual(@as(u32, linux.IORING_SETUP_CQSIZE), ring.flags);
    try std.testing.expectEqual(@as(usize, 32), ring.cq.cqes.len);
}

test "ring setup surfaces an invalid completion depth instead of retrying" {
    // CQSIZE below the SQ depth is EINVAL with or without the other flags, so
    // the fallback must not mask a genuine configuration error.
    try std.testing.expectError(
        error.ArgumentsInvalid,
        initRing(.{ .entries = 64, .cq_entries = 8 }),
    );
}
