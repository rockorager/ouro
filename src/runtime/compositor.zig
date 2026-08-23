//! Stable-address ownership root for Ouro's headless Wayring runtime.
//!
//! `Compositor.create` allocates the root before initializing anything that
//! retains an interior pointer. The returned allocation must therefore never
//! be copied or moved. Subsystems receive only the dependency they need:
//! Wayring's reactor borrows `ring`, and its runtime borrows `reactor`.

const std = @import("std");
const wayring = @import("wayring");

const linux = std.os.linux;

/// Returns the composition-root type for a generated Wayland protocol module.
pub fn Compositor(comptime protocol: type) type {
    return struct {
        const Self = @This();

        pub const Runtime = wayring.server.Runtime(protocol);

        pub const Config = struct {
            ring: wayring.io_uring.RingConfig,
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

            self.ring = try linux.IoUring.init(config.ring.entries, config.ring.flags);
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
                .max_connections = 1,
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
